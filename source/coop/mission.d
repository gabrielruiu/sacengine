// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op mission start: the lobby's Start drives sacengine's own Lobby state machine (commit check, map hash,
// GameInit, load, synchronised start) over the front end's existing Network, then watches the running game.
module coop.mission;

import std.algorithm, std.conv, std.path, std.range, std.stdio, std.string;
import ntts: God;
import options: Options, GameMode;
import network: isConnectedStatus;
import lobby: Lobby, LobbyState;
import coop.missionmodel;
import coop.frontend;

string missionMap(God god){ return "maps/Campaign/Sacrifice/("~missionBase(god)~").scp"; }

enum Phase{ lobby, loading, playing }

package template M(B){
	Phase phase;
	Lobby!B lobby;
	Options options;
	string mission; // base name, e.g. "ja01"
}

// The host's mission choice as every client sees it (default James).
God hostGod(N)(N network){
	auto god=network.hostSettings.coopGod;
	return persephone<=god&&god<=charnel?cast(God)god:cast(God)defaultGod;
}

// Host: Start was pressed in the lobby.
void start(B)(){
	auto network=FE!B.network;
	auto options=FE!B.options;
	options.map=missionMap(hostGod(network));
	options.gameMode=GameMode.scenario;
	options.coopMission=true;
	options.numSlots=cast(int)network.players.data.count!(p=>isConnectedStatus(p.status)&&p.slot!=-1);
	network.acceptingNewConnections=false;
	network.updateSetting!"pauseOnDrop"(false); // a dropped co-op player must not pause the host (R9)
	network.updateSetting!"map"(options.map); // synchronizeSettings sends only the hash
	enter!B(options,0);
}

// Called from the front end's tick. True while the mission owns the frame (loading or in game).
bool tick(B)(){
	alias m=M!B;
	auto network=FE!B.network;
	final switch(m.phase){
		case Phase.lobby:
			if(network&&!network.isHost&&FE!B.screen==Screen.lobby&&network.hostCommitHashReady) joinerEnter!B();
			return m.phase!=Phase.lobby;
		case Phase.loading:
			if(network.isHost) dropLeavers!B();
			if(!m.lobby.update(m.options)) return true;
			m.lobby.start(m.options);
			B.scene.forms.length=0;
			B.scene.disableMenu();
			m.phase=Phase.playing;
			stdout.writefln!"coop: started %s slot=%s"(m.mission,m.lobby.slot);
			stdout.flush();
			return true;
		case Phase.playing:
			return true;
	}
}

private:

void enter(B)(Options options,int slot){
	alias m=M!B;
	m.options=options;
	m.mission=options.map.baseName.stripExtension.strip("()");
	m.lobby=new Lobby!B();
	m.lobby.initialize(slot,m.options);
	m.lobby.network=FE!B.network; // never tryConnect: hostGame asserts an empty player list
	m.lobby.state=LobbyState.connected;
	m.phase=Phase.loading;
	setText!B(0,"Loading "~m.mission~"…");
	stdout.writefln!"coop: loading %s"(m.mission);
	stdout.flush();
}

// Joiner: the host has committed its map. Refuse instead of letting synchronizeMap write the host's copy into
// maps/ (research R3): the campaign maps differ only on a modified install.
void joinerEnter(B)(){
	auto network=FE!B.network;
	auto map=network.hostSettings.map;
	if(!map.length) return; // the name is still on its way
	if(!sameMap(map,network.hostSettings.mapHash)){
		auto mission=map.baseName.stripExtension.strip("()");
		refuse!B("Your copy of "~mission~" differs from the host's");
		return;
	}
	auto options=FE!B.options;
	options.map=map;
	options.gameMode=GameMode.scenario; // GameInit comes from the host; this only skips the skirmish altar check
	enter!B(options,network.slot);
}

bool sameMap(string map,int hash){
	import std.file: exists, read;
	import std.digest.crc: CRC32, digest;
	if(!exists(map)) return false;
	auto crc=digest!CRC32(read(map)); // the hash Lobby uses (sacmap.d, loadSacMap)
	return *cast(uint*)crc.ptr==cast(uint)hash;
}

// Host, before the game starts: a player who left must not get a wizard or be waited for (research R9).
void dropLeavers(B)(){
	alias m=M!B;
	auto network=FE!B.network;
	foreach(i,ref p;network.players.data){
		if(i==network.host||isConnectedStatus(p.status)) continue;
		p.settings.observer=true; // host-local: gameInit and Lobby.updateSettings skip observers
		if(p.slot!=-1) network.updateSlot(cast(int)i,-1); // its lobby slot would index past the game's slots
	}
	auto connected=cast(int)network.players.data.count!(p=>isConnectedStatus(p.status)&&!p.settings.observer);
	if(m.options.numSlots>connected){
		m.options.numSlots=connected;
		stdout.writefln!"coop: a player left during loading, %s slots"(connected);
		stdout.flush();
	}
}

package:

// In-game COOP_CONTROL lines (contracts/ui-and-test.md), see coop.frontend.pollControl.
void control(B)(string[] words){
	import state: Command, CommandType, Target, movingObjectById;
	auto controller=B.controller, gs=B.state;
	if(!controller||controller.controlledSlot==-1) return;
	auto side=controller.controlledSide, wizard=gs.slots[controller.controlledSlot].wizard;
	switch(words[0]){
		case "move": // the commands the movement keys send, for the local wizard
			if(!wizard){ stderr.writeln("coop: control: no wizard to move"); return; }
			static immutable CommandType[][string] types=[
				"forward":[CommandType.moveForward],"backward":[CommandType.moveBackward],
				"left":[CommandType.turnLeft],"right":[CommandType.turnRight],
				"stop":[CommandType.stopMoving,CommandType.stopTurning],
			];
			auto ts=words[1] in types;
			if(!ts){ stderr.writeln("coop: control: bad move ",words[1]); return; }
			auto facing=gs.current.movingObjectById!((ref obj)=>obj.creatureState.facing,()=>0.0f)(wizard);
			foreach(t;*ts) controller.addCommand(Command!B(t,side,wizard,wizard,Target.init,facing));
			return;
		default:
			stderr.writeln("coop: control: unknown in-game line: ",words.join(" "));
	}
}
