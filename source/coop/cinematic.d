// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Cutscene presentation for co-op games: scripted camera, letterbox, fade and displayed variables. A pure function
// of the synced ScriptState and its frame, so two clients at the same frame draw the same shot (SC-004). Reads the
// simulation state, never writes it.
module coop.cinematic;

import std.algorithm, std.math;
import dlib.math, dlib.image.color: Color4f;
import state;
import coop.missionmodel;

// Hook H10 (updateCameraPosition): during a cinematic the camera follows ScriptCamera. True = camera set.
bool camera(B,C)(GameState!B gs,ref C cam){
	if(!gs) return false;
	auto s=gs.current;
	auto script=&s.trig.script;
	if(s.trig.coop.hostSide==-1||script.cinematic<=0||script.camera.changedFrame==0) return false;
	auto c=&script.camera;
	auto origin=Vector3f(c.origin), focus=Vector3f(c.focus);
	if(c.focusId&&s.isValidTarget(c.focusId,TargetType.creature)){ // follow the object
		auto p=s.movingObjectById!((ref obj)=>obj.position,()=>Vector3f.init)(c.focusId);
		if(!c.fixedOrigin) origin+=p-focus;
		focus=p;
	}
	auto frames=cameraFrames(c.speed);
	auto t=frames?min(1.0f,float(script.frame-c.changedFrame)/frames):1.0f;
	t=t*t*(3.0f-2.0f*t); // ease in and out
	origin=(1.0f-t)*Vector3f(c.from[0])+t*origin;
	focus=(1.0f-t)*Vector3f(c.from[1])+t*focus;
	focus.z+=1.5f; // look at the chest, not the feet
	origin.z=max(origin.z,s.getHeight(origin)+1.0f);
	auto d=focus-origin;
	cam.position=origin;
	cam.turn=radtodeg(atan2(d.x,d.y)); // as positionCamera: the view direction is rotate(-turn)·(0,1,0)
	cam.pitch=-90.0f;
	cam.pitchOffset=radtodeg(atan2(-d.z,d.xy.length));
	return true;
}

private bool hudForced, savedHud, savedMinimap;

// Hook H11 (renderEntities2D, before the HUD): letterbox and no HUD during cinematics, fades, displayed variables.
void render2D(R,B,I,C)(R renderer,ObjectState!B state,ref I info,C rc){
	if(!state||state.trig.coop.hostSide==-1) return;
	auto script=&state.trig.script;
	bool cinematic=script.cinematic>0;
	if(cinematic&&!hudForced){ hudForced=true; savedHud=info.hudVisible; savedMinimap=info.minimapVisible; }
	if(hudForced){
		if(cinematic){ info.hudVisible=false; info.minimapVisible=false; }
		else{ hudForced=false; info.hudVisible=savedHud; info.minimapVisible=savedMinimap; }
	}
	import coop.script: currentFade, variableName;
	auto fade=currentFade(*script);
	with(script.fade) if(fade>0.0f) rectangle!B(renderer,0.0f,0.0f,info.width,info.height,Color4f(color[0]/255.0f,color[1]/255.0f,color[2]/255.0f,fade),rc);
	if(cinematic){
		auto bar=0.12f*info.height;
		rectangle!B(renderer,0.0f,0.0f,info.width,bar,Color4f(0.0f,0.0f,0.0f,1.0f),rc);
		rectangle!B(renderer,0.0f,info.height-bar,info.width,bar,Color4f(0.0f,0.0f,0.0f,1.0f),rc);
	}
	float top=(cinematic?0.12f*info.height:0.0f)+20.0f*info.hudScaling;
	foreach(v;0..maxVariables){
		if(!bit(script.displayed,v)) continue;
		if(auto text=variableName(v)) top+=centeredText!B(renderer,text,top,info,rc);
	}
}

private void rectangle(B,R,C)(R renderer,float x,float y,float width,float height,Color4f color,C rc){
	B.colorHUDMaterialBackend.bind(null,rc);
	scope(success) B.colorHUDMaterialBackend.unbind(null,rc);
	B.colorHUDMaterialBackend.bindDiffuse(renderer.whiteTexture);
	B.colorHUDMaterialBackend.setColor(color);
	B.colorHUDMaterialBackend.setTransformationScaled(Vector3f(x,y,0.0f),Quaternionf.identity(),Vector3f(width,height,0.0f),rc);
	renderer.quad.render(rc);
}

// Draws text centred at height top, as the renderer draws its timeout message; returns the line height.
private float centeredText(B,R,I,C)(R renderer,string text,float top,ref I info,C rc){
	import sacfont: SacFont, FontType, FormatSettings, FlowType, getSize;
	auto font=SacFont!B.get(FontType.fnwt);
	renderer.bindFont(font,rc);
	renderer.setFontColor(font,Color4f(1.0f,1.0f,1.0f,1.0f));
	FormatSettings settings={flowType:FlowType.left,scale:info.hudScaling};
	auto size=font.getSize(text,settings);
	renderer.drawText(font,text,0.5f*(info.width-size.x),top,settings,info,rc);
	renderer.unbindFont(font,rc);
	return size.y+4.0f*info.hudScaling;
}
