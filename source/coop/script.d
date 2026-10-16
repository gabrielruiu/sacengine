// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Mission script (TRIG) runtime for co-op games. Runs inside the simulation, once per frame from endTriggers.
// All mutable state is ScriptState (in TriggerState: copied on rollback, serialised, hashed). The parsed triggers
// and the map's markers, texts and sample lengths are read-only after init and identical on every peer.
// Trigger semantics are inferred from the scripts (research R7): see the comments on fireTriggers and runSlot.
module coop.script;

import std.algorithm, std.array, std.conv, std.path, std.range, std.stdio, std.string;
import dlib.math;
import std.math: atan2;
import trig, ntts: Marker, Flags;
import state;
import util: facingQuaternion, rotate;
import stats: CreatureStats;
import bots.shiny: botSideChanged;
import coop.missionmodel;

private:

// --- static mission data, built once at init (research R10) ---

struct MarkerInfo{ int id; Vector3f position; float radius; }
bool coopGame;
Trig trigs;
MarkerInfo[] markers; // sorted by id
string[char[4]] texts, variableNames, objectiveTexts; // by tag: TRIG.FLDR texts, TVAR.FLDR, MOBJ.FLDR
int[char[4]] sampleFrames; // speech sample lengths in frames, from the sample headers
bool[string] logged; // process-wide: each unsupported type is logged once; never read by the simulation
bool[long] loggedFires; // (frame, trigger, side) already logged; re-simulation after a rollback repeats frames
bool trace; // COOP_SCRIPT_TRACE=1: log every action as it runs

public:

void init(B)(ObjectState!B state,ref GameInit!B gi){
	coopGame=true;
	state.trig.script=ScriptState.init;
	foreach(ref slot;state.trig.script.slots) slot.trigger=-1;
	state.trig.script.lastFired[]=int.min/2;
	trigs=state.map.trig;
	markers=state.map.ntts.markers.map!(m=>MarkerInfo(m.unknown1[1],Vector3f(m.x,m.y,m.z),m.unknown2[0])).array;
	markers.sort!((a,b)=>a.id<b.id);
	auto folder=state.map.mapFolder;
	import nttData: makeFileIndex, samps;
	import samp: loadSAMP;
	texts=textsByTag(buildPath(folder,"ENGL.LANG","TRIG.FLDR"));
	variableNames=textsByTag(buildPath(folder,"ENGL.LANG","TVAR.FLDR"));
	objectiveTexts=textsByTag(buildPath(folder,"ENGL.LANG","MOBJ.FLDR"));
	foreach(tag,file;makeFileIndex(true,[buildPath(folder,"SAMP.FLDR")],"SAMP",false)){
		samps[tag]=file; // the audio backend loads samples by tag
		auto samp=loadSAMP(file);
		auto bytesPerSecond=2*samp.header.sampleRate; // decoded 16-bit mono; header.byteRate is the ADPCM rate
		sampleFrames[tag]=cast(int)((samp.data.length*updateFPS+bytesPerSecond-1)/bytesPerSecond);
	}
	if(trigs.triggers.length>maxTriggers) stderr.writefln!"coop script: %d triggers, only the first %d run"(trigs.triggers.length,maxTriggers);
	presetVariables(state.trig.script);
	import std.process: environment;
	trace=environment.get("COOP_SCRIPT_TRACE","")=="1";
	stderr.writefln!"coop script: %d triggers, %d markers, %d texts, %d samples"(trigs.triggers.length,markers.length,texts.length,sampleFrames.length);
}

// Once per frame (hook H5, endTriggers): triggers fire, scripts run, attack records clear, then the handover.
void step(B)(ObjectState!B state){
	if(!coopGame) return;
	auto script=&state.trig.script;
	script.frame++;
	fireTriggers(state);
	foreach(i;0..maxScriptSlots) runSlot(state,i);
	script.attacked[]=0; // "is attacked" conditions see one frame of damage
	auto coop=&state.trig.coop;
	if(!coop.spawned&&handover(script.cinematic>0,!!state.getWizardForSide(coop.hostSide),script.sawCinematicEnd,script.sawCinematicStart,script.frame)){
		import coop.wizards: spawnAll;
		spawnAll(state);
	}
}

// Hook H7: damage from attackerSide reached targetId.
void recordAttack(B)(int attackerSide,int targetId,ObjectState!B state){
	if(!coopGame||attackerSide<0||attackerSide>=32||!state.isValidTarget(targetId)) return;
	auto side=objectSide(targetId,state);
	if(0<=side&&side<32) state.trig.script.attacked[attackerSide]|=1u<<side;
}

// Presentation (coop.cinematic) reads these.
string variableName(int variable){ return variableNames.get(numberTag(variable),null); }

float currentFade(const ref ScriptState script){
	with(script.fade){
		if(duration<=0||script.frame>=startFrame+duration) return toAlpha;
		auto t=float(script.frame-startFrame)/duration;
		return fromAlpha+(toAlpha-fromAlpha)*t;
	}
}

private:

string[char[4]] textsByTag(string folder){
	import nttData: makeFileIndex;
	import text_: loadText;
	string[char[4]] result;
	foreach(tag,file;makeFileIndex(true,[folder],"TEXT",false)) result[tag]=loadText(file);
	return result;
}
// Variable and objective texts are files named by number, e.g. 0026.TEXT, whose tag is reversed ("6200").
char[4] numberTag(int n){ char[4] tag=format!"%04d"(n%10000)[0..4]; reverse(tag[]); return tag; }

// Test only: COOP_SCRIPT_VARS="N=V,..." presets variables (quickstart §4). Every peer must set it identically.
void presetVariables(ref ScriptState script){
	import std.process: environment;
	foreach(pair;environment.get("COOP_SCRIPT_VARS","").split(",").filter!(p=>p.canFind('='))){
		auto nv=pair.split("=");
		auto n=nv[0].strip.to!int, v=nv[1].strip.to!int;
		if(0<=n&&n<maxVariables){ script.variables[n]=v; stderr.writefln!"coop script: preset variable %d=%d"(n,v); }
	}
}

void unsupported(string what,int trigger){
	if(what in logged) return;
	logged[what]=true;
	stderr.writefln!"coop script: unsupported %s (trigger %d)"(what,trigger);
}
string typeName(Object o){ return typeid(o).name.split('.')[$-1].chompPrefix("Trig"); }

// --- firing (data-model "Transitions per frame") ---

// A trigger fires for each side in its mask (co-op sides removed, FR-012) when all conditions hold, it is not
// running, and it is not a runOnce trigger that already fired. The others re-arm when their script ends.
void fireTriggers(B)(ObjectState!B state){
	auto script=&state.trig.script;
	auto coopSides=state.trig.coop.coopSides;
	foreach(t,ref trigger;trigs.triggers[0..min($,maxTriggers)]){
		auto i=cast(int)t;
		bool runOnce=!!(trigger.flags&TriggerFlags.runOnce);
		foreach(side;0..32){
			if(!(trigger.sides&~coopSides&1u<<side)) continue;
			if(bit(script.running,i)||runOnce&&bit(script.fired,i)) break;
			if(!runOnce&&script.frame<script.lastFired[i]+rearmFrames) break;
			if(!trigger.conditions.all!(c=>holds(c,side,i,state))) continue;
			auto slot=script.slots[].countUntil!(s=>s.trigger==-1);
			if(slot==-1){ unsupported("more than 16 running scripts",i); break; } // retried next frame
			script.slots[slot]=ScriptSlot(i,side,0,script.frame);
			setBit(script.running,i,true);
			if(runOnce) setBit(script.fired,i,true);
			script.lastFired[i]=script.frame;
			long key=cast(long)script.frame<<16|i<<5|side;
			if(key!in loggedFires){ loggedFires[key]=true; stderr.writefln!"coop script: trigger %d fired (side %d) at frame %d"(i,side,script.frame); }
		}
	}
}

// Each slot runs actions until one blocks (Pause, speech) by setting wakeFrame.
void runSlot(B)(ObjectState!B state,int slotIndex){
	auto script=&state.trig.script;
	auto slot=&script.slots[slotIndex];
	while(slot.trigger!=-1&&script.frame>=slot.wakeFrame){
		auto actions=trigs.triggers[slot.trigger].actions;
		if(slot.action>=actions.length){
			setBit(script.running,slot.trigger,false);
			if(script.pendingSlot==slotIndex){ script.missionResult=script.pendingResult; script.pendingSlot=-1; }
			slot.trigger=-1;
			return;
		}
		auto action=actions[slot.action++];
		auto wait=run(action,*slot,slotIndex,state);
		if(trace){
			long key=cast(long)script.frame<<20|slot.trigger<<12|slot.action;
			if(key!in loggedFires){ loggedFires[key]=true; stderr.writefln!"coop script: frame %d T%d.%d %s wait %d"(script.frame,slot.trigger,slot.action-1,action,wait); }
		}
		if(wait>0) slot.wakeFrame=script.frame+wait;
	}
}

// --- references ---

uint tagValue(string t){ return t[0]|t[1]<<8|t[2]<<16|t[3]<<24; } // as trig.d's nttToString reads them
enum swct=tagValue("swct"), cwct=tagValue("cwct");

int hostWizard(B)(ObjectState!B state){
	auto w=state.getWizardForSide(state.trig.coop.hostSide);
	return w?w.id:0;
}
// Object id of an ntt reference; 0 if it does not exist (any more).
int objectId(B)(TrigNtt ntt,int side,ObjectState!B state){
	uint id;
	if(auto c=cast(TrigCreature)ntt) id=c.id;
	else if(auto w=cast(TrigWizard)ntt) id=w.id;
	else if(auto s=cast(TrigStructure)ntt) id=s.id;
	else return 0;
	int result;
	if(id==swct) result=hostWizard(state);
	else if(id==cwct){ auto w=state.getWizardForSide(side); result=w?w.id:0; }
	else result=state.triggers.associatedId(id);
	return result&&state.isValidId(result)?result:0; // building ids are valid ids but not targets
}
bool isCreature(B)(int id,ObjectState!B state){ return id&&state.isValidTarget(id,TargetType.creature); }
Vector3f objectPosition(B)(int id,ObjectState!B state){
	if(isCreature(id,state)) return state.movingObjectById!((ref obj)=>obj.position,()=>Vector3f.init)(id);
	return state.buildingById!((ref bldg,state)=>bldg.position(state),()=>Vector3f.init)(id,state);
}
int objectSide(B)(int id,ObjectState!B state){
	if(isCreature(id,state)) return state.movingObjectById!((ref obj)=>obj.side,()=>-1)(id);
	return id?state.buildingById!((ref bldg)=>bldg.side,()=>-1)(id):-1;
}

enum nttRadius=15.0f; // "at <creature>": within this distance (a guess; markers carry their own radius)
bool location(B)(TrigLocation loc,int side,ObjectState!B state,out Vector3f position,out float radius){
	int markerId=-1; float height=0.0f;
	if(auto m=cast(TrigMarker)loc) markerId=m.id;
	else if(auto m=cast(TrigMarkerAtHeight)loc){ markerId=m.id; height=m.height; }
	else if(auto n=cast(TrigAtNtt)loc){
		auto id=objectId(n.ntt,side,state);
		if(!id) return false;
		position=objectPosition(id,state);
		radius=nttRadius;
		return true;
	}else return false;
	auto r=markers.assumeSorted!((a,b)=>a.id<b.id).equalRange(MarkerInfo(markerId));
	if(r.empty) return false;
	position=r.front.position;
	position.z=state.getHeight(position)+height;
	radius=r.front.radius;
	return true;
}
bool within(Vector3f p,Vector3f center,float radius){ return (p.xy-center.xy).lengthsqr<=radius^^2; }

// Side specs resolve against the map's sides only; co-op sides never satisfy a trigger (FR-012).
uint sides(B)(TrigSideSpec spec,int current,ObjectState!B state){
	uint mask;
	if(cast(TrigCurrentSide)spec) mask=1u<<current;
	else if(auto s=cast(TrigSide)spec) mask=s.side<32?1u<<s.side:0;
	else{
		auto stance=cast(TrigEnemySides)spec?Stance.enemy:cast(TrigFriendlySides)spec?Stance.ally:Stance.neutral;
		foreach(other;0..32) if(other!=current&&state.sides.getStance(current,other)==stance) mask|=1u<<other;
	}
	return mask&~state.trig.coop.coopSides;
}

bool matchesCreatureType(B)(ref MovingObject!B obj,char[4] ctype){
	switch(ctype){
		case "rctt": return !obj.isWizard;
		case "zwtt": return obj.isWizard;
		case "cwtt": return true;
		case "lstt": return !obj.isWizard&&!obj.isPeasant;
		case "pctt": return !obj.isAlive;
		default: return obj.sacObject.nttTag==ctype;
	}
}
bool matchesStructureType(B)(ref Building!B bldg,char[4] stype){
	switch(stype){
		case "latt": return bldg.isAltar;
		case "fmtt": return bldg.isManafount;
		case "nmtt": return bldg.isManalith;
		default: return bldg.sacBuilding.tag==stype;
	}
}

// --- conditions ---

int quantity(B)(TrigQuantity q,int side,ObjectState!B state){
	auto vars=state.trig.script.variables[];
	if(cast(TrigQuantityTrue)q) return 1;
	if(cast(TrigQuantityFalse)q) return 0;
	if(auto i=cast(TrigQuantityInteger)q) return i.value;
	if(auto v=cast(TrigQuantityVariable)q) return v.variable<maxVariables?vars[v.variable]:0;
	if(auto a=cast(TrigQuantityAdd)q) return quantity(a.a,side,state)+quantity(a.b,side,state);
	if(auto a=cast(TrigQuantitySub)q) return quantity(a.a,side,state)-quantity(a.b,side,state);
	if(auto a=cast(TrigQuantityMul)q) return quantity(a.a,side,state)*quantity(a.b,side,state);
	if(auto a=cast(TrigQuantityDiv)q){ auto d=quantity(a.b,side,state); return d?quantity(a.a,side,state)/d:0; }
	if(auto s=cast(TrigQuantityCreatureStat)q){
		auto id=objectId(s.creature,side,state);
		if(!isCreature(id,state)) return 0;
		return state.movingObjectById!((ref obj,stat)=>cast(int)statRef(obj.creatureStats,stat),()=>0)(id,s.stat);
	}
	return 0;
}
ref float statRef(ref CreatureStats s,TrigCreatureStat stat){
	static float dummy;
	switch(stat) with(TrigCreatureStat){
		case speed: return s.runningSpeed;
		case flyingSpeed: return s.flyingSpeed;
		case maxHealth: return s.maxHealth;
		case regeneration: return s.regeneration;
		case drain: return s.drain;
		case rangedAccuracy: return s.rangedAccuracy;
		case resistanceToMelee: return s.meleeResistance;
		case resistanceToDirectSpell: return s.directSpellResistance;
		case resistanceToSplashSpell: return s.splashSpellResistance;
		case resistanceToDirectRanged: return s.directRangedResistance;
		case resistanceToSplashRanged: return s.splashRangedResistance;
		case maxMana: return s.maxMana;
		default: dummy=0.0f; return dummy;
	}
}
// value against a constraint; total is how many there are in all (for "all"), -1 when not meaningful.
bool satisfies(B)(TrigConstraint c,int value,int total,int side,ObjectState!B state){
	if(auto a=cast(TrigAtLeast)c) return value>=quantity(a.quantity,side,state);
	if(auto a=cast(TrigAtMost)c) return value<=quantity(a.quantity,side,state);
	if(auto a=cast(TrigExactly)c) return value==quantity(a.quantity,side,state);
	if(cast(TrigAll)c) return total>=0?value==total&&total>0:value!=0;
	if(cast(TrigNone)c||cast(TrigFalse)c) return value==0;
	if(cast(TrigTrue)c) return value!=0;
	return false;
}

// Does any side in mask command ntts (optionally inside a circle)?
bool commands(B)(uint mask,TrigNtts ntts,int side,ObjectState!B state,bool atLocation=false,Vector3f center=Vector3f.init,float radius=0.0f){
	static bool owned(int s,uint mask){ return 0<=s&&s<32&&(mask&1u<<s); }
	static bool inside(Vector3f p,bool atLocation,Vector3f center,float radius){ return !atLocation||within(p,center,radius); }
	if(auto c=cast(TrigNttsCreature)ntts){
		auto id=objectId(c.creature,side,state);
		if(!isCreature(id,state)) return false;
		return state.movingObjectById!((ref obj,mask,atLocation,center,radius)=>obj.isAlive&&owned(obj.side,mask)&&inside(obj.position,atLocation,center,radius),()=>false)(id,mask,atLocation,center,radius);
	}
	if(auto s=cast(TrigNttsStructure)ntts){
		auto id=objectId(s.structure,side,state);
		return id&&owned(objectSide(id,state),mask)&&inside(objectPosition(id,state),atLocation,center,radius);
	}
	if(auto q=cast(TrigQuantityCreatureType)ntts){
		int count=0,total=0;
		state.eachMoving!((ref obj,state,count,total,ctype,mask,atLocation,center,radius){
			if(!obj.isAlive||!matchesCreatureType(obj,ctype)) return;
			*total+=1;
			if(owned(obj.side,mask)&&inside(obj.position,atLocation,center,radius)) *count+=1;
		})(state,&count,&total,q.ctype,mask,atLocation,center,radius);
		return satisfies(q.constraint,count,total,side,state);
	}
	if(auto q=cast(TrigQuantityStructureType)ntts){
		int count=0,total=0;
		state.eachBuilding!((ref bldg,state,count,total,stype,mask,atLocation,center,radius){
			if(!matchesStructureType(bldg,stype)) return;
			*total+=1;
			if(owned(bldg.side,mask)&&inside(bldg.position(state),atLocation,center,radius)) *count+=1;
		})(state,&count,&total,q.stype,mask,atLocation,center,radius);
		return satisfies(q.constraint,count,total,side,state);
	}
	return false;
}

enum seeDistance=100.0f; // IfNttSeesNtts/IfSideSpecSeesNtts: approximated as "within 100 m" (research R7)

bool holds(B)(TrigCondition condition,int side,int trigger,ObjectState!B state){
	auto script=&state.trig.script;
	auto all=~state.trig.coop.coopSides;
	if(cast(TrigAlways)condition) return true;
	if(auto c=cast(TrigIfVariableCondition)condition)
		return c.variable<maxVariables&&satisfies(c.constraint,script.variables[c.variable],-1,side,state);
	if(auto c=cast(TrigIfSideSpecCommandsNttsCondition)condition) return commands(sides(c.sideSpec,side,state),c.ntts,side,state);
	if(auto c=cast(TrigIfSideSpecDoesNotCommandNttsCondition)condition) return !commands(sides(c.sideSpec,side,state),c.ntts,side,state);
	if(auto c=cast(TrigIfSideSpecCommandsNttsAtLocationCondition)condition){
		Vector3f p; float r;
		return location(c.location,side,state,p,r)&&commands(sides(c.sideSpec,side,state),c.ntts,side,state,true,p,r);
	}
	if(auto c=cast(TrigIfSideSpecDoesNotCommandNttsAtLocationCondition)condition){
		Vector3f p; float r;
		return !location(c.location,side,state,p,r)||!commands(sides(c.sideSpec,side,state),c.ntts,side,state,true,p,r);
	}
	if(auto c=cast(TrigIfSideSpecCommandsNttsWithinMetersOfNttCondition)condition){
		auto id=objectId(c.ntt,side,state);
		return id&&commands(sides(c.sideSpec,side,state),c.ntts,side,state,true,objectPosition(id,state),quantity(c.quantity,side,state));
	}
	if(auto c=cast(TrigIfNttSeesNttsCondition)condition){
		unsupported("NttSeesNtts (approximated: within 100 m)",trigger);
		auto id=objectId(c.ntt,side,state);
		return id&&commands(all,c.ntts,side,state,true,objectPosition(id,state),seeDistance);
	}
	if(auto c=cast(TrigIfSideSpecSeesNttsCondition)condition){
		unsupported("SideSpecSeesNtts (approximated: a creature of the side within 100 m)",trigger);
		auto mask=sides(c.sideSpec,side,state);
		int[] watchers;
		state.eachMoving!((ref obj,state,watchers,mask){
			if(obj.isAlive&&0<=obj.side&&obj.side<32&&(mask&1u<<obj.side)) *watchers~=obj.id;
		})(state,&watchers,mask);
		return watchers.any!(w=>commands(all,c.ntts,side,state,true,objectPosition(w,state),seeDistance));
	}
	if(auto c=cast(TrigIfNttHasResourceCondition)condition){
		auto id=objectId(c.ntt,side,state);
		int value=0;
		if(isCreature(id,state)) value=state.movingObjectById!((ref obj,resource)=>
			cast(int)(resource==TrigResource.health?obj.health:resource==TrigResource.mana?obj.creatureStats.mana:obj.creatureStats.souls),()=>0)(id,c.resource);
		else if(id&&c.resource==TrigResource.health) value=state.buildingById!((ref bldg)=>cast(int)bldg.health,()=>0)(id);
		return satisfies(c.constraint,value,-1,side,state);
	}
	if(auto c=cast(TrigIfCreatureIsAliveCondition)condition){
		auto id=objectId(c.creature,side,state);
		return isCreature(id,state)&&state.movingObjectById!((ref obj)=>obj.isAlive,()=>false)(id);
	}
	if(auto c=cast(TrigIfNttExistsCondition)condition) return !!objectId(c.ntt,side,state);
	if(auto c=cast(TrigIfNttExistsOnTheCurrentSideCondition)condition){ auto id=objectId(c.ntt,side,state); return id&&objectSide(id,state)==side; }
	if(auto c=cast(TrigIfCreatureIsAttackedBySideSpecCondition)condition){
		auto id=objectId(c.creature,side,state);
		if(!id) return false;
		auto target=objectSide(id,state);
		auto mask=sides(c.sideSpec,side,state);
		return 0<=target&&target<32&&iota(32).any!(a=>(mask&1u<<a)&&(script.attacked[a]&1u<<target));
	}
	if(auto c=cast(TrigIfSideSpecIsAttackedBySideCondition)condition){
		auto mask=sides(c.sideSpec,side,state);
		return c.sideId<32&&!!(script.attacked[c.sideId]&mask);
	}
	if(auto c=cast(TrigIfElapsedGameTimeIsFramesCondition)condition) return satisfies(c.constraint,script.frame,-1,side,state);
	if(cast(TrigIfCurrentSideIsAPlayerSide)condition) return side==state.trig.coop.hostSide;
	if(cast(TrigIfCurrentSideIsAnAiSide)condition) return side!=state.trig.coop.hostSide;
	if(auto c=cast(TrigOrCondition)condition) return holds(c.condition1,side,trigger,state)||holds(c.condition2,side,trigger,state);
	if(auto c=cast(TrigAndCondition)condition) return holds(c.condition1,side,trigger,state)&&holds(c.condition2,side,trigger,state);
	if(auto c=cast(TrigNotCondition)condition) return !holds(c.condition,side,trigger,state);
	unsupported(typeName(condition),trigger);
	return false;
}

// --- actions ---

// Runs one action of a script; returns how many frames the script now sleeps.
int run(B)(TrigAction action,ref ScriptSlot slot,int slotIndex,ObjectState!B state){
	auto script=&state.trig.script;
	auto side=slot.side, trigger=slot.trigger;
	void setVariable(uint v,int value){ if(v<maxVariables) script.variables[v]=value; else unsupported(text("variable ",v),trigger); }
	if(auto a=cast(TrigPauseAction)action) return a.numFrames;
	if(auto a=cast(TrigSetVariableAction)action){ setVariable(a.variable,quantity(a.quantity,side,state)); return 0; }
	if(auto a=cast(TrigSetVariableToRandomNumberInRangeAction)action){
		auto lo=quantity(a.low,side,state), hi=quantity(a.high,side,state);
		setVariable(a.variable,hi>lo?lo+state.uniform(hi-lo+1):lo);
		return 0;
	}
	if(cast(TrigCinematicsStartAction)action){
		script.cinematic++;
		script.sawCinematicStart=true;
		auto host=hostWizard(state);
		if(host&&script.cinematic==1) setCamera(*script,objectPosition(host,state),host,false,Vector3f.init,state); // start on the host
		stderr.writefln!"coop script: cinematic start at frame %d"(script.frame);
		return 0;
	}
	if(cast(TrigCinematicsEndAction)action){
		script.cinematic=max(0,script.cinematic-1);
		script.sawCinematicEnd=true;
		stderr.writefln!"coop script: cinematic end at frame %d"(script.frame);
		return 0;
	}
	if(auto a=cast(TrigEnableObjectiveAction)action){ if(a.missionObjective<maxObjectives) script.objectives[a.missionObjective]=1; return 0; }
	if(auto a=cast(TrigDisableObjectiveAction)action){ if(a.missionObjective<maxObjectives) script.objectives[a.missionObjective]=0; return 0; }
	if(auto a=cast(TrigSetObjectiveCompleteAction)action){ if(a.missionObjective<maxObjectives) script.objectives[a.missionObjective]=2; return 0; }
	if(auto a=cast(TrigDisplayVariableAction)action){ if(a.variable<maxVariables) setBit(script.displayed,a.variable,true); return 0; }
	if(auto a=cast(TrigHideVariableAction)action){ if(a.variable<maxVariables) setBit(script.displayed,a.variable,false); return 0; }
	if(auto a=cast(TrigOrderAction)action){ orderCreature(a.creature,a.order,side,trigger,state); return 0; }
	if(auto a=cast(TrigOrderListAction)action){ foreach(c;a.creatures) orderCreature(c,a.order,side,trigger,state); return 0; }
	if(auto a=cast(TrigOrderAllOfTypeAction)action){ orderAll(a.ctype,false,Vector3f.init,0.0f,a.order,side,trigger,state); return 0; }
	if(auto a=cast(TrigOrderAllOfTypeAtLocationAction)action){
		Vector3f p; float r;
		if(location(a.location,side,state,p,r)) orderAll(a.ctype,true,p,r,a.order,side,trigger,state);
		return 0;
	}
	// camera: only ScriptState changes here; coop.cinematic draws it (research R12)
	if(auto a=cast(TrigSetViewZoomAction)action){ script.camera.zoom=clamp(cast(int)a.zoomLevel-TrigZoomLevel.closest,0,4); return 0; }
	if(auto a=cast(TrigSetViewSpeedAction)action){ script.camera.speed=clamp(quantity(a.quantity,side,state),0,600); return 0; }
	if(auto a=cast(TrigSetViewFocusToLocationAction)action){
		Vector3f p; float r;
		if(location(a.location,side,state,p,r)) setCamera(*script,p,locationObject(a.location,side,state),false,Vector3f.init,state);
		return 0;
	}
	if(auto a=cast(TrigSetViewOriginFromLocationAction)action){
		Vector3f p; float r;
		if(location(a.location,side,state,p,r)){
			auto c=script.camera;
			setCamera(*script,Vector3f(c.focus),c.focusId,true,p,state);
		}
		return 0;
	}
	if(auto a=cast(TrigSetViewOriginFromLocationFocusToLocationAction)action){
		Vector3f o,p; float r;
		if(location(a.location1,side,state,o,r)&&location(a.location2,side,state,p,r))
			setCamera(*script,p,locationObject(a.location2,side,state),true,o,state);
		return 0;
	}
	if(auto a=cast(TrigFadeToColorOverFramesAction)action){
		auto from=currentFade(*script);
		with(script.fade){
			fromAlpha=from;
			static immutable ubyte[3][4] colors=[[0,0,0],[255,255,255],[255,0,0],[0,0,0]];
			if(a.color!=TrigColor.clear) color=colors[a.color-TrigColor.black];
			toAlpha=a.color==TrigColor.clear?0.0f:1.0f;
			startFrame=script.frame;
			duration=max(0,quantity(a.quantity,side,state));
		}
		return 0;
	}
	// speech: subtitle as a synced chat message, sample through the dialog queue (research R12)
	if(auto a=cast(TrigSpeechWithTextAction)action)
		return speak(actorName(a.actor,side,state),a.text,sampleOf(a.sampleSpec),timing(a.timing,side,state),state);
	if(auto a=cast(TrigSpeechCreatureSpeaksSampleAction)action) return speak(creatureName(a.creature,side,state),"\0\0\0\0",a.sample,-1,state);
	if(auto a=cast(TrigSpeechCreatureSaysTextWithSampleAction)action) return speak(creatureName(a.creature,side,state),a.text,a.sample,-1,state);
	if(auto a=cast(TrigSpeechCreatureAsksTextWithSampleAction)action) return speak(creatureName(a.creature,side,state),a.text,a.sample,-1,state);
	if(auto a=cast(TrigSpeechCreatureExclaimsTextWithSampleAction)action) return speak(creatureName(a.creature,side,state),a.text,a.sample,-1,state);
	if(auto a=cast(TrigSpeechGodSaysTextWithSampleAction)action) return speak(godToString(a.god),a.text,a.sample,-1,state);
	if(auto a=cast(TrigSpeechNarratorNarratesTextWithSampleAction)action) return speak(null,a.text,a.sample,-1,state);
	if(cast(TrigAddIntroSampleToSpeechHistoryAction)action||cast(TrigAddTextWithSampleToSpeechHistoryAction)action) return 0; // no speech history UI
	if(auto a=cast(TrigAskTextWithSampleAction)action){
		// shortcut: the first answer is chosen once the question has been asked; a host choice UI comes later
		auto wait=speak(null,a.question,sampleOf(a.sampleSpec),-1,state);
		setVariable(a.variable,1);
		stderr.writefln!"coop script: ask (trigger %d) answered with option 1"(trigger);
		return wait;
	}
	if(auto a=cast(TrigTeleportCreatureToLocationAction)action){
		Vector3f p; float r;
		auto id=objectId(a.creature,side,state);
		if(isCreature(id,state)&&location(a.location,side,state,p,r)) state.movingObjectById!((ref obj,p,state){ obj.teleport(p,state); },(){})(id,p,state);
		return 0;
	}
	if(auto a=cast(TrigTeleportAllOfTypeAtLocationToLocationAction)action){
		Vector3f p1,p2; float r1,r2;
		if(location(a.location1,side,state,p1,r1)&&location(a.location2,side,state,p2,r2)){
			int[] ids;
			state.eachMoving!((ref obj,state,ids,ctype,p1,r1){
				if(obj.isAlive&&matchesCreatureType(obj,ctype)&&within(obj.position,p1,r1)&&!isCoopObject(obj.side,state)) *ids~=obj.id;
			})(state,&ids,a.ctype,p1,r1);
			foreach(id;ids) state.movingObjectById!((ref obj,p,state){ obj.teleport(p,state); },(){})(id,p2+(objectPosition(id,state)-p1),state);
		}
		return 0;
	}
	if(auto a=cast(TrigChangeSideAction)action){
		auto id=objectId(a.ntt,side,state);
		if(isCreature(id,state)&&a.side<32) state.movingObjectById!((ref obj,newSide,state){ // as rescuedBy (state.d)
			obj.clearOrderQueue(state); obj.unselect(state); obj.removeFromGroups(state);
			obj.side=newSide;
			state.botSideChanged(obj);
		},(){})(id,cast(int)a.side,state);
		else if(id&&a.side<32) state.buildingById!((ref bldg,newSide){ bldg.side=newSide; },(){})(id,cast(int)a.side);
		return 0;
	}
	if(auto a=cast(TrigSetNttStateAction)action){
		auto id=objectId(a.ntt,side,state);
		int flag=nttStateFlag(a.state);
		if(!flag){ unsupported(text("SetNttState ",a.state),trigger); return 0; }
		bool on=a.switch_==TrigSwitch.on;
		if(isCreature(id,state)) state.movingObjectById!((ref obj,flag,on){ if(on) obj.creatureStats.flags|=flag; else obj.creatureStats.flags&=~flag; },(){})(id,flag,on);
		else if(id) state.buildingById!((ref bldg,flag,on){ if(on) bldg.flags|=flag; else bldg.flags&=~flag; },(){})(id,flag,on);
		return 0;
	}
	if(auto a=cast(TrigSetCreatureStatAction)action){
		auto id=objectId(a.creature,side,state);
		auto value=quantity(a.quantity,side,state);
		if(isCreature(id,state)) state.movingObjectById!((ref obj,stat,value){ statRef(obj.creatureStats,stat)=value; },(){})(id,a.creatureStat,value);
		return 0;
	}
	if(auto a=cast(TrigScreenShakeAtLocationAction)action){
		Vector3f p; float r;
		if(location(a.location,side,state,p,r)) screenShake(p,60,1.0f,100.0f,state);
		return 0;
	}
	if(auto a=cast(TrigCreateCreatureTypeAtLocationAction)action){ create(a.ctype,side,a.location,1,side,state); return 0; }
	if(auto a=cast(TrigCreateCreatureTypeOnSideAtLocationAction)action){ create(a.ctype,a.side,a.location,1,side,state); return 0; }
	if(auto a=cast(TrigCreateMultipleCreatureTypeOnSideAtLocationAction)action){ create(a.ctype,a.side,a.location,a.amount,side,state); return 0; }
	if(cast(TrigEndMissionInVictoryAction)action||cast(TrigEndMissionInDefeatAction)action){
		bool won=!!cast(TrigEndMissionInVictoryAction)action;
		if(won) state.victory(state.trig.coop.hostSide); else state.defeat(state.trig.coop.hostSide);
		script.pendingResult=won?MissionResult.victory:MissionResult.defeat;
		script.pendingSlot=slotIndex; // the end screen waits for the rest of this script (the closing scene)
		stderr.writefln!"coop script: mission %s at frame %d"(won?"won":"lost",script.frame);
		return 0;
	}
	unsupported(typeName(action),trigger);
	return 0;
}

bool isCoopObject(B)(int side,ObjectState!B state){ return 0<=side&&side<32&&(state.trig.coop.coopSides&1u<<side); }

int nttStateFlag(TrigNttState s){
	switch(s) with(TrigNttState){
		case rescuable: return Flags.rescuable;
		case cannotGib: return Flags.cannotGib;
		case cannotDamage: return Flags.cannotDamage;
		case cannotDestroy: return Flags.cannotDestroyKill;
		case notOnMinimap: return Flags.notOnMinimap;
		default: return 0;
	}
}

int locationObject(B)(TrigLocation loc,int side,ObjectState!B state){
	if(auto n=cast(TrigAtNtt)loc) return objectId(n.ntt,side,state);
	return 0;
}

void create(B)(char[4] ctype,uint newSide,TrigLocation loc,uint amount,int side,ObjectState!B state){
	Vector3f p; float r;
	if(!location(loc,side,state,p,r)||newSide>=32) return;
	foreach(_;0..min(amount,50)) state.placeCreature(ctype,0,cast(int)newSide,p,0.0f);
}

void orderAll(B)(char[4] ctype,bool atLocation,Vector3f center,float radius,TrigOrder order,int side,int trigger,ObjectState!B state){
	int[] ids;
	state.eachMoving!((ref obj,state,ids,ctype,atLocation,center,radius){
		if(!obj.isAlive||!matchesCreatureType(obj,ctype)||isCoopObject(obj.side,state)) return;
		if(atLocation&&!within(obj.position,center,radius)) return;
		*ids~=obj.id;
	})(state,&ids,ctype,atLocation,center,radius);
	foreach(id;ids) orderId(id,order,side,trigger,state);
}
void orderCreature(B)(TrigCreature creature,TrigOrder order,int side,int trigger,ObjectState!B state){
	auto id=objectId(creature,side,state);
	if(isCreature(id,state)) orderId(id,order,side,trigger,state);
}
// Script orders go straight to the creature (not through commands), so the cinematic input lock leaves them alone.
void orderId(B)(int id,TrigOrder order,int side,int trigger,ObjectState!B state){
	OrderTarget target(TrigNtt ntt){
		auto t=objectId(ntt,side,state);
		return t?centerTarget(t,state):OrderTarget.init;
	}
	OrderTarget at(TrigLocation loc){
		Vector3f p; float r;
		if(location(loc,side,state,p,r)) return positionTarget(p,state);
		return OrderTarget.init;
	}
	Order o;
	if(auto x=cast(TrigOrderAttack)order) o=Order(CommandType.attack,target(x.target));
	else if(auto x=cast(TrigOrderGoToLocation)order) o=Order(CommandType.move,at(x.location));
	else if(auto x=cast(TrigOrderGoToLocationInFormation)order) o=Order(CommandType.move,at(x.location));
	else if(auto x=cast(TrigOrderAttackLocation)order) o=Order(CommandType.advance,at(x.location));
	else if(auto x=cast(TrigOrderAttackLocationInFormation)order) o=Order(CommandType.advance,at(x.location));
	else if(auto x=cast(TrigOrderGuardLocation)order){
		auto t=cast(TrigAtNtt)x.location;
		auto g=t?objectId(t.ntt,side,state):0;
		o=g&&isCreature(g,state)?Order(CommandType.guard,centerTarget(g,state)):Order(CommandType.guardArea,at(x.location));
	}else if(auto x=cast(TrigOrderGuardLocationInFormation)order) o=Order(CommandType.guardArea,at(x.location));
	else if(auto x=cast(TrigOrderTurnToFaceLocation)order){
		// a move to where it stands, facing the location: the creature turns on the spot
		auto t=at(x.location);
		if(t.type==TargetType.none) return;
		auto here=objectPosition(id,state);
		auto d=t.position-here;
		o=Order(CommandType.move,positionTarget(here,state),atan2(-d.x,d.y));
	}else if(cast(TrigOrderCancelOrders)order){
		state.movingObjectById!((ref obj,state){ obj.clearOrderQueue(state); },(){})(id,state);
		return;
	}else if(cast(TrigOrderDie)order){
		state.movingObjectById!((ref obj,state){ obj.kill(state); },(){})(id,state);
		return;
	}else{ unsupported(typeName(order),trigger); return; } // e.g. notify: only changes what a creature attends to
	if(o.target.type==TargetType.none) return;
	state.movingObjectById!((ref obj,o,state){ .order(obj,o,state); },(){})(id,o,state);
}

// Camera target change: interpolation runs from the previous origin/focus (research R12).
void setCamera(B)(ref ScriptState script,Vector3f focus,int focusId,bool fixedOrigin,Vector3f origin,ObjectState!B state){
	auto c=&script.camera;
	bool first=c.changedFrame==0;
	auto oldOrigin=Vector3f(c.origin), oldFocus=Vector3f(c.focus);
	if(!fixedOrigin){ // keep looking from the side we looked from, at the zoom's distance
		static immutable float[5] distances=[10.0f,18.0f,30.0f,45.0f,65.0f];
		auto dir=oldFocus-oldOrigin;
		dir.z=0.0f;
		if(first||dir.lengthsqr<1.0f){ // first shot: from behind the host's wizard
			auto host=hostWizard(state);
			auto facing=host?state.movingObjectById!((ref obj)=>obj.creatureState.facing,()=>0.0f)(host):0.0f;
			dir=rotate(facingQuaternion(facing),Vector3f(0.0f,1.0f,0.0f));
			dir.z=0.0f;
		}
		dir=dir.normalized;
		auto d=distances[c.zoom];
		origin=focus-d*dir+Vector3f(0.0f,0.0f,0.45f*d);
	}
	c.from=first?[origin.arrayof,focus.arrayof]:[oldOrigin.arrayof,oldFocus.arrayof];
	c.origin=origin.arrayof;
	c.focus=focus.arrayof;
	c.focusId=focusId;
	c.fixedOrigin=fixedOrigin;
	c.mode=focusId?CameraMode.focusObject:CameraMode.focusPosition;
	c.changedFrame=script.frame;
}

// --- speech ---

char[4] sampleOf(TrigSampleSpec spec){
	if(auto s=cast(TrigWithSample)spec) return s.sample;
	return "\0\0\0\0";
}
// Frames a speech blocks the script: -1 = as long as the sample (or the text, without a sample); below -1 the
// sample length minus (-1-value) frames.
int timing(B)(TrigTiming t,int side,ObjectState!B state){
	if(auto f=cast(TrigForFrames)t) return max(0,quantity(f.quantity,side,state));
	if(auto f=cast(TrigSampleLengthMinusFrames)t) return -1-max(0,quantity(f.quantity,side,state));
	return -1;
}
string creatureName(B)(TrigCreature creature,int side,ObjectState!B state){
	auto id=objectId(creature,side,state);
	return id?getCreatureName(id,state):null;
}
string actorName(B)(TrigActor actor,int side,ObjectState!B state){
	if(auto a=cast(TrigActorCreature)actor) return creatureName(a.creature,side,state);
	if(auto a=cast(TrigActorNameText)actor) return texts.get(a.text,null);
	if(cast(TrigActorNamePlayerWizard)actor){ auto h=hostWizard(state); return h?getCreatureName(h,state):null; }
	if(auto a=cast(TrigActorGod)actor) return godToString(a.god);
	return null;
}
int speak(B)(string speaker,char[4] text,char[4] sample,int frames,ObjectState!B state){
	auto body=texts.get(text,null);
	auto sampleLength=sampleFrames.get(sample,0);
	int wait;
	if(frames>=0) wait=frames;
	else if(frames<-1) wait=max(0,sampleLength-(-1-frames));
	else wait=sampleLength;
	if(body.length){ // subtitle: synced, so every player sees it at the same frame
		auto message=makeChatMessage!B(-1,-1,ChatMessageType.standard,speaker,body,state.frame);
		message.lifetime=max(message.lifetime,wait+updateFPS);
		if(!wait) wait=message.lifetime;
		sendChatMessage(move(message),state);
	}
	if(sampleLength){
		static if(B.hasAudio) if(playAudio) B.queueDialogSound(-1,sample,DialogPriority.advisorImportant);
	}
	return wait;
}
