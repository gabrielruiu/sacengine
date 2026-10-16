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
