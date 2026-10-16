// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op wizards: each co-op player gets an extra side allied with the host's single-player side. Its wizard is
// declared in GameInit but placed next to the host's wizard only at the handover, may only walk, cannot be hurt
// and is invisible to AI. All state is CoopState (in TriggerState: copied on rollback, serialised, hashed).
module coop.wizards;

import std.algorithm, std.array, std.conv, std.range, std.stdio;
import dlib.math;
import ntts: God, Flags, Wizard;
import state;
import sacobject: SacObject;
import util: facingQuaternion, rotate;
import coop.missionmodel;


// Names never change after init and are the same on every peer (they come from GameInit), so like the map
// they stay outside the synced state.
private string[maxCoopPlayers] names;

// Start of initGame, on every peer: the host gets the map's single-player level, souls and spellbook; each co-op
// slot k is moved to side coopSide(k) with the host's level and no spells, allied with the host and each other.
void prepare(B)(ObjectState!B state,ref GameInit!B gi){
	gi.wizards=gi.wizards.dup; // the caller's GameInit is kept for recordings
	auto hostIndex=gi.slots.length?gi.slots[0].wizardIndex:-1;
	if(hostIndex==-1) return;
	auto host=&gi.wizards[hostIndex];
	with(state.map.levl){
		host.minLevel=host.level=singleStartLevel;
		host.maxLevel=singleMaxLevel;
		host.souls=singleSouls;
		if(God.none<singleAssociatedGod&&singleAssociatedGod<=God.max) host.spellbook=getDefaultSpellbook!B(singleAssociatedGod);
	}
	gi.coopSides=coopSidesMask(cast(int)gi.slots.length);
	foreach(slot;1..min(gi.slots.length,maxCoopPlayers+1)){
		auto index=gi.slots[slot].wizardIndex;
		if(index==-1) continue;
		with(gi.wizards[index]){
			side=coopSide(cast(int)slot);
			minLevel=maxLevel=level=host.level;
			souls=0;
			spellbook=Spellbook!B.init;
		}
		foreach(other;[host.side]~iota(1,cast(int)slot).map!coopSide.array){
			gi.stanceSettings~=GameInit!B.StanceSetting(other,coopSide(cast(int)slot),Stance.ally);
			gi.stanceSettings~=GameInit!B.StanceSetting(coopSide(cast(int)slot),other,Stance.ally);
		}
	}
}

// End of initGame, on every peer: the co-op wizards' altar placement found no altar (id 0), so they wait for the
// handover. Co-op sides never count for victory or defeat.
void init(B)(ObjectState!B state,ref GameInit!B gi){
	auto coop=&state.trig.coop;
	*coop=CoopState.init;
	coop.coopSides=gi.coopSides;
	coop.hostSide=gi.wizards[gi.slots[0].wizardIndex].side;
	foreach(ref w;gi.wizards){
		if(!isCoopSideMask(w.side,coop.coopSides)) continue;
		auto k=30-w.side; // slot-1
		coop.wizards[k]=CoopWizard(w.side,cast(char[4])w.tag,w.level);
		names[k]=w.name;
	}
	state.sid.altarSides&=~cast(int)coop.coopSides;
}

bool isCoopSide(B)(int side,ObjectState!B state){ return isCoopSideMask(side,state.trig.coop.coopSides); }
private bool isCoopSideMask(int side,uint mask){ return 0<=side&&side<32&&(mask&1u<<side); }

ref CoopWizard wizardOf(ref CoopState coop,int side)in{ assert(isCoopSideMask(side,coop.coopSides)); }do{
	return coop.wizards[30-side];
}

// applyCommand filter (hook H4). False drops the command on every peer.
bool allowCommand(B)(ref Command!B command,ObjectState!B state){
	static assert(CommandType.moveForward==cmdMoveFirst&&CommandType.stopTurning==cmdMoveLast);
	static assert(CommandType.surrender==cmdSurrender&&CommandType.chatMessage==cmdChatMessage);
	auto coop=&state.trig.coop;
	if(coop.hostSide==-1) return true; // not a co-op game
	bool fromCoop=isCoopSide(command.side,state);
	if(fromCoop&&command.type==CommandType.surrender){
		remove(*coop,wizardOf(*coop,command.side),state);
		return false;
	}
	bool own=fromCoop&&wizardOf(*coop,command.side).state==CoopWizardState.active&&command.creature==wizardOf(*coop,command.side).id;
	if(coopAllows(command.type,fromCoop,own,state.trig.script.cinematic>0)) return true;
	stderr.writefln!"coop: dropped %s from side %d"(command.type,command.side);
	return false;
}

// The player left: the wizard disappears, or is never placed. No lose/killAll: co-op sides cannot lose (FR-026).
void remove(B)(ref CoopState coop,ref CoopWizard w,ObjectState!B state){
	if(w.state==CoopWizardState.gone) return;
	if(w.state==CoopWizardState.active&&state.isValidTarget(w.id,TargetType.creature)){
		state.removeWizard(w.id);
		state.removeLater(w.id);
	}
	w.state=CoopWizardState.gone;
	stderr.writefln!"coop: side %d left at frame %d"(w.side,state.frame);
}

// The handover (called by coop.script.step): place every pending co-op wizard next to the host's, in slot order.
void spawnAll(B)(ObjectState!B state){
	auto coop=&state.trig.coop;
	auto host=state.getWizardForSide(coop.hostSide);
	if(!host) return;
	auto hostPos=state.movingObjectById!((ref obj)=>obj.position,()=>Vector3f.init)(host.id);
	auto facing=state.movingObjectById!((ref obj)=>obj.creatureState.facing,()=>0.0f)(host.id);
	Vector3f[maxCoopPlayers] taken;
	int numTaken=0;
	bool free(Vector3f p){ return !taken[0..numTaken].any!(t=>(t-p).xy.lengthsqr<3.0f^^2)&&(p-hostPos).xy.lengthsqr>=2.0f^^2; }
	foreach(k,ref w;coop.wizards){
		if(w.side==-1||w.state!=CoopWizardState.pending) continue;
		auto sacObject=SacObject!B.getSAXS!Wizard(w.tag);
		// spawnPosition's hitbox check needs an animation wizards lack, so: 6 m in front of the host like
		// spawnPosition, then rings of radius 10..60 (research R5), then the host's own spot
		auto position=hostPos;
		auto front=hostPos+rotate(facingQuaternion(facing),Vector3f(0.0f,6.0f,0.0f));
		front.z=state.getHeight(front);
		if(free(front)&&validSpot(front,state)) position=front;
		else Lsearch: foreach(ring;1..numSpawnRings+1) foreach(i;0..spotsPerRing){
			auto o=spawnRingOffset(cast(int)(i+k),ring);
			auto p=hostPos+Vector3f(o[0],o[1],0.0f);
			p.z=state.getHeight(p);
			if(free(p)&&validSpot(p,state)){ position=p; break Lsearch; }
		}
		taken[numTaken++]=position;
		enum flags=Flags.cannotDamage|Flags.cannotDestroyKill|Flags.notOnMinimap;
		w.id=state.placeWizard(sacObject,names[k],flags,w.side,w.level,0,0.0f,w.level,w.level,1.0f,Spellbook!B.init,position,facing);
		w.state=CoopWizardState.active;
		stderr.writefln!"coop: handover at frame %d, spawned side %d id %d"(state.frame,w.side,w.id);
	}
	coop.spawned=true;
}

// On the ground and clear of every object (the first half of isValidSpawnPosition, state.d).
bool validSpot(B)(Vector3f position,ObjectState!B state){
	if(!state.isOnGround(position)) return false;
	bool collides=false;
	static void hit(ProximityEntry entry,ObjectState!B state,bool* collides){ *collides=true; }
	Vector3f[2] box=[position-Vector3f(1.0f,1.0f,10.0f),position+Vector3f(1.0f,1.0f,10.0f)];
	state.proximity.collide!hit(box,state,&collides);
	return !collides;
}

// After each run of the controller (hook H9): slots live outside ObjectState, so copy the co-op wizards' ids in
// (camera focus, observing, number keys read them) and focus the local camera once on the local co-op wizard.
private int focused=0;
void syncSlots(B)(GameState!B gs){
	auto coop=&gs.committed.trig.coop;
	if(coop.hostSide==-1) return;
	foreach(k,ref w;coop.wizards){
		auto slot=k+1;
		if(w.side==-1||slot>=gs.slots.length) continue;
		gs.slots[slot].wizard=w.state==CoopWizardState.active?w.id:0;
		if(w.state!=CoopWizardState.active||focused==w.id||!B.controller||B.controller.controlledSlot!=slot) continue;
		focused=w.id;
		B.focusCamera(w.id);
	}
}
