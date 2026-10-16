// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Cutscene presentation for co-op games: scripted camera, letterbox, fade. Reads ScriptState, never writes it.
module coop.cinematic;

bool camera(S,C)(S state,ref C cam){ return false; }
void render2D(S,I)(S state,ref I info){}
