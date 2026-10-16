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
	bool[] left; // host, in game: players whose co-op wizard was already removed
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
			if(network.isHost) removeLeavers!B();
			auto result=B.state.committed.trig.script.missionResult;
			if(result!=MissionResult.none) end!B(result==MissionResult.victory?Screen.victory:Screen.defeat,null);
			else if(!network.isHost&&!network.players[network.host].connection) end!B(Screen.message,"The host has left the game.");
			return m.phase==Phase.playing;
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

// The mission is over or the host left: tear the game down (controller, state, network) and show the original
// end screen; its button or Escape returns to the title menu.
void end(B)(Screen screen,string message){
	alias m=M!B;
	stdout.writefln!"coop: mission over: %s"(message.length?message:screen==Screen.victory?"victory":"defeat");
	stdout.flush();
	import state: Target;
	with(B.scene){ // nothing may point into the old game: updateMouseTarget reads state for a cached target
		mouse.target=mouse.cachedTarget=mouse.xmenuTarget=Target.init;
		camera.target=0;
		info.activeChatMessages=typeof(info.activeChatMessages).init; // renderChatMessages loops forever on them without a state
		controller=null;
		state=null;
	}
	leave!B();
	m.lobby=null;
	m.phase=Phase.lobby;
	FE!B.status=message;
	B.scene.enableMenu();
	B.scene.mouse.visible=true; // forms only draw with a visible mouse; the game hid it
	B.scene.fpview.active=false;
	showScreen!B(screen);

}

// Host, in game: a co-op player who dropped gets one surrender for their side, which removes their wizard
// (or keeps it from spawning) on every peer (research R9).
void removeLeavers(B)(){
	import state: Command;
	alias m=M!B;
	auto network=FE!B.network;
	m.left.length=network.players.length;
	foreach(i,ref p;network.players.data){
		if(i==network.host||m.left[i]||isConnectedStatus(p.status)||p.slot<1||p.slot>maxCoopPlayers) continue;
		m.left[i]=true;
		B.controller.addCommand(Command!B(coopSide(p.slot)));
		stdout.writefln!"coop: %s left, removing side %d"(p.settings.name,coopSide(p.slot));
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
		case "cmd": // any command for the local side, as a modified client could send it (US4 scenario 5)
			auto c=testCommand!B(words[1],side,wizard,gs);
			if(c.type==CommandType.none){ stderr.writeln("coop: control: cannot build ",words[1]); return; }
			controller.addCommand(c);
			return;
		default:
			stderr.writeln("coop: control: unknown in-game line: ",words.join(" "));
	}
}

// A command of the named CommandType for side/wizard, aimed at the host's wizard; type none if it cannot be built.
auto testCommand(B,G)(string name,int side,int wizard,G gs){
	import state: Command, CommandType, Target, TargetType, Formation, movingObjectById, defaultSpells;
	import sacspell: SacSpell;
	import dlib.math: Vector3f;
	Command!B c;
	CommandType type;
	try type=name.to!CommandType; catch(Exception) return c;
	auto host=gs.slots.length?gs.slots[0].wizard:0;
	auto position=gs.current.movingObjectById!((ref obj)=>obj.position,()=>Vector3f(0.0f,0.0f,0.0f))(host);
	auto creature=Target(TargetType.creature,host,position), terrain=Target(TargetType.terrain,0,position);
	auto spell=SacSpell!B.get(defaultSpells[God.james][0].tag);
	final switch(type) with(CommandType){
		case none,chatMessage: break;
		case moveForward,moveBackward,stopMoving,turnLeft,turnRight,stopTurning,select,selectAll,automaticSelectAll,
			toggleSelection,automaticToggleSelection,addAllToSelection,automaticAddAllToSelection:
			if(host) c=Command!B(type,side,wizard,type<=stopTurning?wizard:host,Target.init,0.0f); break;
		case clearSelection: c=Command!B(type,side,wizard,0,Target.init,0.0f); break;
		case defineGroup,addToGroup,selectGroup,automaticSelectGroup: c=Command!B(type,side,wizard,1); break;
		case setFormation: c=Command!B(side,wizard,Formation.line); break;
		case move,guardArea,advance: c=Command!B(type,side,wizard,0,terrain,0.0f); break;
		case retreat,capture,guard,attack: if(host) c=Command!B(type,side,wizard,0,creature,0.0f); break;
		case castSpell: if(host) c=Command!B(side,wizard,spell,creature); break;
		case useAbility: if(host) c=Command!B(side,spell,creature); break;
		case dropSoul: c=Command!B(side,wizard); break;
		case surrender: c=Command!B(side); break;
	}
	return c;
}
