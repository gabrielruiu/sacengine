// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op lobby rules, kept free of backend and engine imports so they can be unit-tested alone:
//   ldc2 -unittest -main -run source/coop/lobbymodel.d
module coop.lobbymodel;

import std.algorithm: all, canFind;
import std.range: empty, take;
import std.string: strip;
import std.conv: text;

enum maxPlayers=4, maxNameLength=16;

// Lowest lobby position 0..maxPlayers-1 not in taken, or -1 when the lobby is full.
int lowestFreeSlot(const(int)[] taken){
	foreach(slot;0..maxPlayers) if(!taken.canFind(slot)) return slot;
	return -1;
}

// Why the host connection of a joiner dropped, worked out from what the joiner had received.
string refusalReason(bool gotId,bool commitMatches,size_t numPlayers){
	if(!gotId) return "Could not join: incompatible version or no co-op lobby at this address";
	if(!commitMatches) return "Incompatible game version";
	if(numPlayers>maxPlayers) return "Lobby is full";
	return "Host left the lobby";
}

// Trimmed name of at most maxNameLength code points; empty input keeps the previous name.
string sanitizeName(string input,string previous){
	auto name=input.strip;
	if(name.empty) return previous;
	return name.take(maxNameLength).text;
}

bool canStart(const(bool)[] ready){ return !ready.empty&&ready.all; }

unittest{
	assert(lowestFreeSlot([0])==1);
	assert(lowestFreeSlot([0,2])==1);
	assert(lowestFreeSlot([0,1,2])==3);
	assert(lowestFreeSlot([0,1,2,3])==-1);
}

unittest{ // checked in priority order
	assert(refusalReason(false,false,9)=="Could not join: incompatible version or no co-op lobby at this address");
	assert(refusalReason(true,false,9)=="Incompatible game version");
	assert(refusalReason(true,true,maxPlayers+1)=="Lobby is full");
	assert(refusalReason(true,true,maxPlayers)=="Host left the lobby");
	assert(refusalReason(true,true,1)=="Host left the lobby");
}

unittest{
	assert(sanitizeName("","Old")=="Old");
	assert(sanitizeName("   ","Old")=="Old");
	assert(sanitizeName("Bob","Old")=="Bob");
	assert(sanitizeName("  Bob ","Old")=="Bob");
	assert(sanitizeName("abcdefghijklmnopqrst","Old")=="abcdefghijklmnop");
	assert(sanitizeName("äöüäöüäöüäöüäöüäöüäö","Old")=="äöüäöüäöüäöüäöüä"); // cut on code points, not bytes
}

unittest{
	assert(!canStart([]));
	assert(!canStart([false]));
	assert(canStart([true]));
	assert(!canStart([true,false]));
	assert(canStart([true,true,true,true]));
}
