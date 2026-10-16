// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Mission script (TRIG) runtime for co-op games. Runs inside the simulation; all mutable state is ScriptState.
module coop.script;

struct ScriptState{ enum coopSynced=true; }

void init(B,G)(B state,ref G gameInit){}
void step(B)(B state){}
void recordAttack(B)(int attackerSide,int targetId,B state){}
