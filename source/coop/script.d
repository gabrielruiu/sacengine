// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Mission script (TRIG) runtime for co-op games. Runs inside the simulation, once per frame from endTriggers;
// all mutable state is ScriptState (in TriggerState: copied on rollback, serialised, hashed).
module coop.script;

import std.stdio;
import state;
import coop.missionmodel;


// Set by init, identical on every peer (it follows GameInit.coopMission). Static data like the map.
private bool coopGame;

void init(B)(ObjectState!B state,ref GameInit!B gi){
	coopGame=true;
	state.trig.script=ScriptState.init;
}

void step(B)(ObjectState!B state){
	if(!coopGame) return;
	auto script=&state.trig.script;
	script.frame++;
	auto coop=&state.trig.coop;
	if(!coop.spawned&&handover(script.cinematic>0,!!state.getWizardForSide(coop.hostSide),script.sawCinematicEnd,script.sawCinematicStart,script.frame)){
		import coop.wizards: spawnAll;
		spawnAll(state);
	}
}

void recordAttack(B)(int attackerSide,int targetId,ObjectState!B state){}
