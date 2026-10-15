// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

// Character editor wizard preview: the editor's wizard is rendered into the otherwise empty menu 3D frame,
// and the ziws canvas copies the middle of that frame instead of filling itself black. Local UI only.
module coop.preview;

import dlib.math.vector, dlib.math.matrix, dlib.math.quaternion, dlib.math.transformation, dlib.math.utils: Axis;
import sacobject: SacObject, animFPS;
import ntts: Wizard;
import animations: AnimationState;
import nttData: wizards;
import renderer: RenderInfo;
import coop.frontend: FE, Screen;

/// Wizard tags whose model failed to load; never retried in this session.
bool[char[4]] failed;

// the model fills this fraction of the 3D frame's height, leaving room for the idle animation
enum fill=0.7f;
// world height fitted into `fill`: a bit above the tallest wizard hitbox (2awc, 3.36); per-wizard hitboxes
// undershoot some models (1ewc's is 1.6 but its model is taller), so all wizards share one scale
enum modelHeight=3.6f;
// UI frames per full turn (UI runs at 60 per second)
enum turnFrames=60*12;

bool active(B)(){ return FE!B.screen==Screen.characterEditor&&!(tag!B in failed); }
char[4] tag(B)(){ return cast(char[4])wizards[FE!B.draftWizard]; }

// Called from SacScene.renderOpaqueEntities3D when there is no game state.
void render3D(B)(B.RenderContext rc){
	if(!active!B) return;
	SacObject!B sacObject;
	try sacObject=SacObject!B.getSAXS!Wizard(tag!B);
	catch(Throwable e){ // a corrupt model fails the parsers' bounds checks (an Error), not only with an Exception
		import std.stdio: stderr;
		stderr.writeln("coop: wizard preview: ",e.msg);
		failed[tag!B]=true;
		return;
	}
	auto frame=FE!B.frame*animFPS/60%sacObject.numFrames(AnimationState.stance1);
	// distance at which the model covers `fill` of the frame height: visible half-height at d is d/P[1][1]
	auto distance=modelHeight*rc.projectionMatrix.a22/(2.0f*fill);
	auto view=rc.invViewMatrix;
	auto up=view.up, back=view.forward; // camera looks down -z
	auto position=view.translation-distance*back-0.5f*modelHeight*up;
	// the menu's default sun shines from behind the model; light it from above the camera instead
	B.scene.environment.sunRotation=rotationBetween(Vector3f(0.0f,0.0f,1.0f),(back+up).normalized);
	// model space is z-up and faces +y: map z to the camera's up and +y towards the camera, then turn
	auto basis=Matrix4x4f.identity;
	foreach(k;0..3){ basis[k,0]=-view.right[k]; basis[k,1]=back[k]; basis[k,2]=up[k]; }
	import std.math: PI;
	auto rotation=Quaternionf.fromMatrix(basis)*rotationQuaternion(Axis.z,cast(float)(2*PI*(FE!B.frame%turnFrames)/turnFrames));
	auto pose=sacObject.getRenderFrame(AnimationState.stance1,frame,false);
	foreach(i,material;sacObject.materials){
		if(!material) continue;
		auto blending=B.blending(material);
		if(blending==B.Blending.Additive||blending==B.Blending.Transparent) continue;
		material.bind(rc);
		scope(success) material.unbind(rc);
		material.backend.setTransformationScaled(position,rotation,Vector3f(1.0f,1.0f,1.0f),rc);
		material.backend.setInformation(Vector4f(0.0f,0.0f,0.0f,0.0f));
		if(material.backend is B.boneMaterialBackend) B.boneMaterialBackend.setPose(pose.matrices);
		if(material.backend is B.shadelessBoneMaterialBackend) B.shadelessBoneMaterialBackend.setPose(pose.matrices);
		sacObject.saxsi.meshes[i].render(rc);
	}
}

// Called from Renderer.renderForm for every canvas before its black fill; true if it filled the canvas.
bool drawCanvas(B)(char[4] id,Vector2f position,Vector2f size,ref RenderInfo!B info){
	if(id!="ziws"||!active!B) return false;
	auto source=B.scene.finalizerFilter.inputBuffer;
	if(!source) return false;
	import derelict.opengl;
	// source: centred, canvas aspect ratio, `fill` of the frame height plus a margin for raised arms and weapons
	auto sh=fill*1.35f*info.height, sw=sh*size.x/size.y;
	auto sx=0.5f*(info.width-sw), sy=0.5f*(info.height-sh);
	// destination: canvas rectangle in window pixels, y up (as renderMinimap's scissor)
	auto dx=info.xOffset+position.x*info.screenScaling;
	auto dy=info.windowHeight-(position.y+size.y)*info.screenScaling-info.yOffset;
	GLint previous;
	glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&previous);
	glBindFramebuffer(GL_READ_FRAMEBUFFER,source.fbo);
	glBlitFramebuffer(cast(int)sx,cast(int)sy,cast(int)(sx+sw),cast(int)(sy+sh),
	                  cast(int)dx,cast(int)dy,cast(int)(dx+size.x*info.screenScaling),cast(int)(dy+size.y*info.screenScaling),
	                  GL_COLOR_BUFFER_BIT,GL_LINEAR);
	glBindFramebuffer(GL_READ_FRAMEBUFFER,previous);
	return true;
}
