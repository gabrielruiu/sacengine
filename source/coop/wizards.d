// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op wizards: extra allied sides that may only walk, spawned next to the host's wizard at the handover.
module coop.wizards;

struct CoopState{ enum coopSynced=true; }

void prepare(B,G)(B state,ref G gameInit){}
void init(B,G)(B state,ref G gameInit){}
bool allowCommand(B,C)(ref C command,B state){ return true; }
bool isCoopSide(B)(int side,B state){ return false; }
void spawnAll(B)(B state){}
void syncSlots(G)(G gameState){}
