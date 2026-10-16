// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Co-op front end (--menu): the original title, single-player, TCP/IP, lobby and character editor
// forms, driven over sacengine's own Network. Lobby data is pre-game Settings, never simulation state.
module coop.frontend;

import std.algorithm, std.array, std.conv, std.range, std.stdio, std.string;
import options: Options, Settings;
import form: Element, FormHeader, ElementType, parseForm;
import sacform: FormFont, SacForm, SacFormElement, SacFormState, sacFormInstance, formFontType, fitTextEnd;
import sacfont: SacFont, FormatSettings, getSize;
import nttData: forms, formTexts, mouseoverTexts, texts, randomWizardName, wizards;
import network: Network, isConnectedStatus;
import coop.lobbymodel;
import coop.missionmodel: nextGod;
import coop.mission: hostGod;

enum Screen{ title, singlePlayer, tcpip, connecting, lobby, characterEditor }

package template FE(B){
	Screen screen;
	Options options;
	Network!B network;
	int pressed=-1; // element index pressed this frame, handled in tick
	string status; // message shown on the TCP/IP screen
	string joinIP;
	int frame, joinFrame;
	string draftName; // character editor draft
	size_t draftWizard;
	string lastLog;
	string controlPath; // test automation, see pollControl
	size_t controlDone;
}

void start(B)(ref Options options){
	patchSinglePlayerForm();
	FE!B.options=options;
	import std.process: environment;
	FE!B.controlPath=environment.get("COOP_CONTROL","");
	showScreen!B(Screen.title);
	B.scene.enableMenu();
	B.addLogicCallback(delegate()=>tick!B());
}

// Called from SacScene.updateForm for every activated element of any form.
void onFormElement(B)(int formIndex,int elementIndex){
	if(!B.scene.mouse.menuMode||formIndex!=0) return;
	FE!B.pressed=elementIndex; // act in tick, outside menuControl's use of the form
}

package: // coop.mission uses the screen and element helpers

// 1ply gets "Coop Campaign" between the six entries and Cancel. In memory only; nothing is written to disk.
void patchSinglePlayerForm(){
	auto old=forms["ylp1"];
	auto elements=old.elements.dup;
	auto i=elements.countUntil!(e=>e.id=="unem");
	if(i<0||elements.canFind!(e=>e.id=="pooc")) return;
	auto coop=elements[i];
	coop.id=coop.text=coop.mouseover="pooc";
	elements[i].top+=24;
	elements=elements[0..i]~coop~elements[i..$];
	FormHeader header=*old.header;
	header.height+=24;
	header.numElements=cast(ubyte)elements.length;
	auto data=(cast(ubyte*)&header)[0..FormHeader.sizeof].dup~cast(ubyte[])elements;
	forms.addEntry("ylp1",parseForm(data));
	formTexts.addEntry("pooc","Coop Campaign");
	mouseoverTexts.addEntry("pooc","Play the campaign together with up to three friends");
}

// the tables are immutable-valued but owned by nttData; adding an entry before first use is safe
void addEntry(V)(ref immutable(V)[char[4]] table,char[4] key,V value){ (cast(V[char[4]])table)[key]=value; }

immutable char[4][Screen.max+1] screenTags=["ltit","ylp1","ipct","ipct","ybol","cwen"];

ref SacFormState!B current(B)(){ return B.scene.forms[0]; }

void showScreen(B)(Screen screen){
	with(B.scene){ forms.length=0; forms~=sacFormInstance!B(screenTags[screen]); }
	FE!B.screen=screen;
	auto tag=screenTags[screen];
	stdout.writefln!"coop: screen=%s"(tag[].retro);
	stdout.flush();
	final switch(screen) with(Screen){
		case title, singlePlayer, lobby: break;
		case tcpip:
			sacElement!B(0).texts[0].font=FormFont.standard; // status line in the title bar; long messages need the small font
			if(FE!B.status.length) setText!B(0,FE!B.status);
			setEntry!B(find!B("__pi"),FE!B.joinIP.length?FE!B.joinIP:"127.0.0.1");
			break;
		case connecting:
			sacElement!B(0).texts[0].font=FormFont.standard;
			setText!B(0,"Connecting…");
			foreach(id;["8erc","__pi","nioj","lcnc"]) current!B.elements[find!B(id)].enabled=false;
			break;
		case characterEditor:
			setEntry!B(find!B("manp"),FE!B.draftName);
			current!B.elements[find!B("bpse")].visible=false;
			break;
	}
}

bool tick(B)(){
	alias fe=FE!B;
	fe.frame++;
	import coop.mission;
	if(coop.mission.tick!B()){ pollControl!B(); return true; } // loading or in game
	if(fe.network) fe.network.update(null);
	if(fe.screen==Screen.connecting&&fe.frame>=fe.joinFrame) join!B();
	if(fe.network&&fe.network.isHost) hostPolicy!B();
	if(fe.network&&!fe.network.isHost&&!fe.network.players[0].connection) hostDropped!B();
	pollControl!B();
	auto pressed=fe.pressed;
	fe.pressed=-1;
	if(pressed>=0&&pressed<current!B.elements.length){
		current!B.elements[pressed].checked=false; // buttons never reset it themselves
		handle!B(current!B.elements[pressed].id);
	}
	if(fe.screen.among(Screen.lobby,Screen.characterEditor)) logLobby!B();
	if(fe.screen==Screen.lobby) fillLobby!B();
	if(fe.screen==Screen.characterEditor) showWizard!B(); // every frame: a load failure is only seen while rendering
	return true;
}

// Test automation for tools/run-local-coop.sh: each line appended to the file $COOP_CONTROL acts on the current
// screen: "press ID[#N]" presses the N-th element ID like a click, "type ID TEXT" sets an entry box.
void pollControl(B)(){
	alias fe=FE!B;
	if(!fe.controlPath.length||fe.frame%10) return;
	import std.file: exists, readText;
	if(!exists(fe.controlPath)) return;
	auto lines=readText(fe.controlPath).splitLines;
	for(;fe.controlDone<lines.length&&fe.pressed==-1;fe.controlDone++){ // one press per poll
		auto words=lines[fe.controlDone].split;
		if(words.length<2) continue;
		if(!B.scene.forms.length){ import coop.mission; coop.mission.control!B(words); continue; } // in game
		auto id=words[1].split('#');
		auto all=current!B.elements.data.indexes(id[0]);
		auto n=id.length>1?id[1].to!size_t-1:0;
		if(n>=all.length){ stderr.writeln("coop: control: no element ",words[1]); continue; }
		auto i=all[n];
		if(words[0]=="type") setEntry!B(i,words.length>2?std.array.join(words[2..$]," "):"");
		else if(current!B.elements[i].visible&&current!B.elements[i].enabled) fe.pressed=i;
		else stderr.writeln("coop: control: ",words[1]," is not clickable");
	}
}

void handle(B)(char[4] id){
	alias fe=FE!B;
	final switch(fe.screen) with(Screen){
		case title:
			if(id=="p1_g") showScreen!B(singlePlayer);
			else if(id=="tiuq") B.app.exit();
			break; // pm_g, magl, stpo: inert
		case singlePlayer:
			if(id=="pooc"){ fe.status=null; showScreen!B(tcpip); }
			else if(id=="unem") showScreen!B(title);
			break; // tutorials and campaigns: inert
		case tcpip:
			if(id=="lcnc") showScreen!B(singlePlayer);
			else if(id=="8erc") host!B();
			else if(id=="nioj"){
				fe.joinIP=current!B.elements[find!B("__pi")].textInput.data.idup.strip;
				fe.joinFrame=fe.frame+2; // let "Connecting…" render before the blocking connect
				showScreen!B(connecting);
			}
			break;
		case connecting: break;
		case lobby:{
			auto me=fe.network.me;
			if(id=="lcnc"){ leave!B(); showScreen!B(singlePlayer); }
			else if(me==-1) break;
			else if(id=="tesg") fe.network.updateSetting!"ready"(!fe.network.players[me].settings.ready);
			else if(id=="trts"){ import coop.mission; coop.mission.start!B(); }
			else if(id=="_dog"&&fe.network.isHost) fe.network.updateSetting!"coopGod"(nextGod(hostGod(fe.network)));
			else if(id=="eman"){
				fe.draftName=fe.network.players[me].settings.name;
				fe.draftWizard=cast(size_t)max(0,wizards.countUntil(fe.network.players[me].settings.wizard));
				showScreen!B(characterEditor);
			}
			break;
		}
		case characterEditor:
			if(id=="-ziw"||id=="+ziw"){
				fe.draftWizard=(fe.draftWizard+(id=="+ziw"?1:wizards.length-1))%wizards.length;
			}else if(id=="_KO_"){
				auto me=fe.network.me;
				auto name=sanitizeName(current!B.elements[find!B("manp")].textInput.data.idup,fe.network.players[me].settings.name);
				fe.network.updateSetting!"name"(name);
				fe.network.updateSetting!"wizard"(cast(char[4])wizards[fe.draftWizard]);
				showScreen!B(lobby);
			}else if(id=="lcnc") showScreen!B(lobby);
			break;
	}
}

Settings playerSettings(B)(int slot){
	Settings settings=FE!B.options.settings;
	settings.name=randomWizardName();
	if(settings.name=="") settings.name="Wizard";
	settings.slot=slot;
	settings.ready=false;
	return settings;
}

void host(B)(){
	alias fe=FE!B;
	try{
		fe.network=new Network!B(fe.options);
		fe.network.hostGame(playerSettings!B(0),false);
	}catch(Exception e){
		stderr.writeln("coop: cannot host: ",e.msg);
		leave!B();
		fe.status="Cannot host: "~e.msg;
		showScreen!B(Screen.tcpip);
		return;
	}
	showScreen!B(Screen.lobby);
}

void join(B)(){
	alias fe=FE!B;
	fe.network=new Network!B(fe.options);
	bool ok=false;
	// shortcut: blocking connect on the UI thread; move to a non-blocking connect + poll if the freeze is a problem
	try ok=fe.network.joinGame(fe.joinIP,9116,playerSettings!B(-1),false);
	catch(Exception e) stderr.writeln("coop: join failed: ",e.msg);
	if(!ok){
		leave!B();
		fe.status="No lobby found at "~fe.joinIP;
		stdout.writeln("coop: refused: ",fe.status);
		stdout.flush();
		showScreen!B(Screen.tcpip);
		return;
	}
	showScreen!B(Screen.lobby);
}

void leave(B)(){
	if(!FE!B.network) return;
	FE!B.network.shutdown();
	FE!B.network=null;
}

void hostPolicy(B)(){
	auto network=FE!B.network;
	auto players=network.players.data;
	foreach(i,ref p;players) // free the positions of players who left
		if(i!=network.host&&!isConnectedStatus(p.status)&&p.slot!=-1) network.updateSlot(cast(int)i,-1);
	foreach(i,ref p;players){
		if(i==network.host||!isConnectedStatus(p.status)||!p.connection) continue;
		if(p.settings.commit!=network.hostSettings.commit){ network.dropPlayer(cast(int)i,null); continue; }
		if(p.slot!=-1) continue;
		auto taken=players.filter!(q=>isConnectedStatus(q.status)&&q.slot!=-1).map!(q=>q.slot).array;
		auto slot=lowestFreeSlot(taken);
		if(slot==-1) network.dropPlayer(cast(int)i,null); // lobby full
		else network.updateSlot(cast(int)i,slot);
	}
}

void hostDropped(B)(){
	alias fe=FE!B;
	auto network=fe.network;
	auto me=network.me;
	auto listed=iota(network.players.length).count!(i=>i==network.host||i==me||isConnectedStatus(network.players[i].status));
	fe.status=refusalReason(me!=-1,network.hostSettings.commit==fe.options.commit,listed);
	stdout.writeln("coop: refused: ",fe.status);
	stdout.flush();
	leave!B();
	showScreen!B(Screen.tcpip);
}

void fillLobby(B)(){
	auto network=FE!B.network;
	auto elements=current!B.elements.data;
	foreach(id;["iPAM","tahc","txtc"]){ // map info and chat: out of scope
		auto i=find!B(id);
		foreach(j;i..i+1+elements[i].numChildren) elements[j].visible=false;
	}
	auto me=network.me;
	foreach(row,eman;elements.indexes("eman").filter!(i=>elements[i].type==ElementType.button).enumerate){
		auto rowForm=container!B(eman);
		auto rowElements=iota(rowForm,rowForm+1+elements[rowForm].numChildren);
		auto player=row<maxPlayers?network.players.data.countUntil!(p=>isConnectedStatus(p.status)&&p.slot==row):-1;
		foreach(i;rowElements) elements[i].visible=player!=-1;
		if(player==-1) continue;
		auto settings=&network.players[player].settings;
		foreach(i;rowElements){
			switch(elements[i].id[]){
				// the row pictures render at the screen's corner in sacengine, so ready is part of the name label
				case "munp","epyt","maet","yder": elements[i].visible=false; break;
				case "eman":
					auto label=settings.name~" \u2013 "~wizardName(settings.wizard);
					setText!B(i,settings.ready?label~" \u2013 Ready":label,false);
					elements[i].enabled=player==me;
					break;
				case "_dog": // the mission: the host's god, chosen on the host's own row
					setText!B(i,godName(hostGod(network)),false);
					elements[i].enabled=network.isHost&&player==me;
					break;
				default: break;
			}
		}
	}
	auto ready=me!=-1&&network.players[me].settings.ready;
	setText!B(find!B("tesg"),ready?"Not Ready":"Ready");
	elements[find!B("tesg")].enabled=me!=-1;
	auto trts=find!B("trts");
	elements[trts].visible=network.isHost;
	elements[trts].enabled=network.isHost&&canStart(readyFlags(network));
}

bool[] readyFlags(N)(N network){
	return network.players.data.filter!(p=>isConnectedStatus(p.status)&&p.slot!=-1).map!(p=>p.settings.ready).array;
}

void logLobby(B)(){
	auto network=FE!B.network;
	if(!network) return;
	auto players=iota(network.players.length).filter!(i=>isConnectedStatus(network.players[i].status)&&network.players[i].slot!=-1)
		.array.sort!((i,j)=>network.players[i].slot<network.players[j].slot)
		.map!(i=>format!"%s:%s:%s:%d"(network.players[i].slot,network.players[i].settings.name,wizardName(network.players[i].settings.wizard),network.players[i].settings.ready));
	import coop.missionmodel: missionBase;
	auto line=format!"coop: me=%s players=[%-(%s,%)] mission=%s"(network.me,players,missionBase(hostGod(network)));
	if(network.isHost) line~=canStart(readyFlags(network))?" start=enabled":" start=disabled";
	if(line==FE!B.lastLog) return;
	FE!B.lastLog=line;
	stdout.writeln(line);
	stdout.flush();
}

string godName(int god){ return ["Persephone","Pyro","James","Stratos","Charnel"][god-1]; }

// Back to the TCP/IP screen, disconnected, with the reason in its title line.
void refuse(B)(string reason){
	FE!B.status=reason;
	stdout.writeln("coop: refused: ",reason);
	stdout.flush();
	leave!B();
	showScreen!B(Screen.tcpip);
}

string wizardName(char[4] tag){
	if(auto name=tag in texts) return *name;
	return tag[].retro.text;
}

void showWizard(B)(){
	auto i=find!B("ziws");
	import coop.preview: failed;
	auto tag=cast(char[4])wizards[FE!B.draftWizard];
	setText!B(i,tag in failed?wizardName(tag):""); // the 3D preview fills the canvas unless the model failed to load
	auto e=&sacElement!B(i);
	if(e.texts.length) e.texts[0].position.y=e.offset.y+0.5f*e.size.y-8;
}

// element helpers on the single on-screen form

int find(B)(string id){
	auto i=current!B.elements.data.countUntil!(e=>e.id[]==id);
	assert(i>=0,text("coop: no element ",id," on ",current!B.sacForm.tag[]));
	return cast(int)i;
}
auto indexes(E)(E[] elements,string id){
	return iota(elements.length).filter!(i=>elements[i].id[]==id).map!(i=>cast(int)i).array;
}

// Index of the innermost form holding element i. Sub-forms are flattened into one list, and ElementState.parent
// is not usable for this (children of a sub-form get the sub-form's parent).
int container(B)(int i){
	auto elements=current!B.elements.data;
	foreach_reverse(j;0..i) if(elements[j].type==ElementType.form&&i<=j+elements[j].numChildren) return j;
	return -1;
}
SacForm!B sacFormOf(B)(int formElement){
	if(formElement==0) return current!B.sacForm;
	return sacFormOf!B(container!B(formElement)).sacElements[current!B.elements[formElement].sacFormIndex].subForms[0].form;
}
ref SacFormElement!B sacElement(B)(int i){
	if(i==0) return current!B.sacForm.sacElements[0];
	return sacFormOf!B(container!B(i)).sacElements[current!B.elements[i].sacFormIndex];
}
// Replaces the label of element i. The text position lives in the cached SacForm of the form tag, shared by
// all rows of a sub-form, so shared rows get left-aligned text and unique elements get it re-centred.
void setText(B)(int i,string text,bool center=true){
	auto st=&current!B.elements[i];
	if(st.textInput.data==text) return;
	st.textInput.length=0;
	foreach(char c;text) st.textInput~=c;
	st.textStart=0;
	st.textEnd=cast(int)text.length;
	auto e=&sacElement!B(i);
	if(!e.texts.length) return;
	auto width=SacFont!B.get(formFontType(e.texts[0].font)).getSize(text,FormatSettings()).x;
	e.texts[0].position.x=e.offset.x+(center?0.5f*(e.size.x-width):20.0f);
}

void setEntry(B)(int i,string text){
	auto st=&current!B.elements[i];
	st.textInput.length=0;
	foreach(char c;text) st.textInput~=c;
	st.textStart=0;
	st.textCursor=cast(int)text.length;
	(*st).fitTextEnd!B();
}
