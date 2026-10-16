// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op mission rules, kept free of backend and engine imports so they can be unit-tested alone:
//   ldc2 -unittest -main -run source/coop/missionmodel.d
module coop.missionmodel;

// The values of enum God (ntts.d), copied so this module stays free of engine imports.
enum: int{ godNone=0, persephone=1, pyro=2, james=3, stratos=4, charnel=5 }
enum defaultGod=james; // ja01 is the reference mission

// Base name of a god's first mission, e.g. "ja01" (the map is maps/Campaign/Sacrifice/(ja01).scp).
string missionBase(int god)in{ assert(persephone<=god&&god<=charnel); }do{
	static immutable bases=["pe01","py01","ja01","st01","ch01"];
	return bases[god-persephone];
}

// The god the host's _dog button switches to: Persephone → Pyro → James → Stratos → Charnel → Persephone.
int nextGod(int god){ return god>=charnel||god<persephone?persephone:god+1; }

unittest{
	assert(missionBase(persephone)=="pe01");
	assert(missionBase(pyro)=="py01");
	assert(missionBase(james)=="ja01");
	assert(missionBase(stratos)=="st01");
	assert(missionBase(charnel)=="ch01");
	int[] seen;
	for(int g=persephone;seen.length<5;g=nextGod(g)) seen~=g;
	assert(seen==[persephone,pyro,james,stratos,charnel]);
	assert(nextGod(charnel)==persephone);
	import core.exception: AssertError;
	import std.exception: assertThrown;
	assertThrown!AssertError(missionBase(godNone));
}

// Co-op player slot k (1..3) plays on its own side: 30, 29, 28. They are unused on the first missions; 31 is the
// neutral side.
enum maxCoopPlayers=3;
int coopSide(int slot)in{ assert(1<=slot&&slot<=maxCoopPlayers); }do{ return 30-(slot-1); }
uint coopSidesMask(int numPlayers){
	uint mask=0;
	foreach(slot;1..numPlayers) if(slot<=maxCoopPlayers) mask|=1u<<coopSide(slot);
	return mask;
}

unittest{
	assert(coopSide(1)==30&&coopSide(2)==29&&coopSide(3)==28);
	assert(coopSidesMask(1)==0);
	assert(coopSidesMask(2)==1u<<30);
	assert(coopSidesMask(4)==(1u<<30|1u<<29|1u<<28));
	assert(!(coopSidesMask(4)&(1u<<31|1u<<0)));
}

// Frames without an opening cinematic after which the co-op wizards spawn anyway (research R8).
enum handoverFallbackFrames=600;

// Co-op wizards spawn on the first frame where this holds (research R8).
bool handover(bool cinematicActive,bool hostWizardExists,bool sawCinematicEnd,bool sawCinematicStart,int frame){
	if(cinematicActive||!hostWizardExists) return false;
	return sawCinematicEnd||!sawCinematicStart&&frame>=handoverFallbackFrames;
}

unittest{
	bool run(int start,int end,int frames,bool hostWizard=true){ // a cinematic from start to end (-1: none)
		foreach(frame;1..frames){
			bool active=start!=-1&&start<=frame&&frame<end;
			if(handover(active,hostWizard,end!=-1&&frame>=end,start!=-1&&frame>=start,frame)) return frame==frames-1;
		}
		return false;
	}
	assert(!run(200,1000,2)); // not at frame 1 although no cinematic runs yet
	assert(!run(200,1000,601)); // not at 600 during the opening
	assert(run(200,1000,1001)); // at the opening's end
	assert(run(-1,-1,601)); // no opening: the fallback
	assert(!run(-1,-1,600));
	assert(!run(-1,-1,2000,false)); // never without the host's wizard
	assert(!handover(true,true,true,true,5000)); // never during a cinematic
}

// The index-th spot (0-based) tried around the host on ring 1..6 (radius 10..60), when spawnPosition fails.
enum numSpawnRings=6, spotsPerRing=8;
float[2] spawnRingOffset(int index,int ring){
	import std.math: cos, sin, PI;
	auto radius=10.0f*ring, angle=2*PI*(index%spotsPerRing)/spotsPerRing;
	return [radius*cos(angle),radius*sin(angle)];
}

unittest{
	import std.math: isClose, sqrt;
	foreach(ring;1..numSpawnRings+1){
		float[2][] seen;
		foreach(index;0..spotsPerRing){
			auto o=spawnRingOffset(index,ring);
			assert(isClose(sqrt(o[0]^^2+o[1]^^2),10.0f*ring,1e-4));
			foreach(s;seen) assert((s[0]-o[0])^^2+(s[1]-o[1])^^2>1.0f);
			seen~=o;
		}
	}
}

// Which commands the simulation applies (contracts/engine-hooks.md). The command types are CommandType's values
// (state.d), copied here: moveForward..stopTurning = 1..6, surrender = 30, chatMessage = 31.
enum: int{ cmdMoveFirst=1, cmdMoveLast=6, cmdSurrender=30, cmdChatMessage=31 }
bool coopAllows(int commandType,bool fromCoopSide,bool ownActiveWizard,bool cinematic){
	if(commandType==cmdChatMessage) return true;
	if(cinematic) return false;
	if(!fromCoopSide) return true;
	return cmdMoveFirst<=commandType&&commandType<=cmdMoveLast&&ownActiveWizard;
}

unittest{
	foreach(t;cmdMoveFirst..cmdMoveLast+1){
		assert(coopAllows(t,true,true,false));
		assert(!coopAllows(t,true,false,false)); // someone else's wizard, or not spawned yet
		assert(coopAllows(t,false,false,false)); // host side: as upstream
		assert(!coopAllows(t,false,true,true)&&!coopAllows(t,true,true,true)); // cinematic lock
	}
	foreach(t;[7,8,20,26,27,29,cmdSurrender]){
		assert(!coopAllows(t,true,true,false));
		assert(coopAllows(t,false,true,false));
		assert(!coopAllows(t,false,true,true));
	}
	foreach(coop;[false,true]) foreach(cine;[false,true]) assert(coopAllows(cmdChatMessage,coop,false,cine));
}

// Synced co-op state. Lives in TriggerState (state.d), which is copied on rollback, serialised and hashed, so
// plain values and static arrays only. The serialiser picks up structs marked coopSynced.

enum CoopWizardState{ pending, active, gone }

struct CoopWizard{
	enum coopSynced=true;
	int side=-1; // 30, 29, 28 for slots 1, 2, 3; -1 = unused entry
	char[4] tag;
	int level;
	int id=0; // object id once placed
	CoopWizardState state;
}

struct CoopState{
	enum coopSynced=true;
	uint coopSides;
	int hostSide=-1; // -1: not a co-op game
	CoopWizard[maxCoopPlayers] wizards; // co-op slots 1..3
	bool spawned; // the handover has happened
}

struct ScriptState{
	enum coopSynced=true;
	int frame; // frames since mission start
	int cinematic; // nesting of CinematicsStart/End, 0 = players have control
	bool sawCinematicEnd, sawCinematicStart;
}
