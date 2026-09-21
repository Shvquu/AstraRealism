#ifndef ASTRA_UNIFORMS_GLSL
#define ASTRA_UNIFORMS_GLSL

/*
 * AstraRealism - Built-in uniform declarations.
 *
 * Every uniform Iris/OptiFine can supply that this pack uses is declared here,
 * once. Unused uniforms are eliminated by the driver, so including the whole
 * set everywhere costs nothing and removes a whole class of "undeclared
 * identifier" errors that only show up in one program.
 *
 * Note: the legacy sampler name `texture` is NOT declared. In GLSL 1.30+ it
 * collides with the built-in texture() function. Iris exposes `gtexture` as the
 * modern alias and that is what this pack uses throughout.
 *
 * Vertex attributes are deliberately absent - they are only legal in gbuffers
 * and shadow vertex stages, so they are declared there.
 */

//==============================================================================
// MATRICES
//==============================================================================

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;

//==============================================================================
// CAMERA & WORLD POSITION
//==============================================================================

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

// Direction vectors in view space. `shadowLightPosition` follows whichever of
// the sun or moon is currently casting, which is why shadow code should use it
// rather than sunPosition.
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;

//==============================================================================
// TIME
//==============================================================================

uniform int   frameCounter;     // increments every frame, wraps at 720720
uniform float frameTime;        // seconds taken by the previous frame
uniform float frameTimeCounter; // seconds since load, wraps at 3600

uniform int   worldTime;        // ticks within the current day, 0-23999
uniform int   worldDay;
uniform int   moonPhase;        // 0-7

// 0.0 at sunrise, 0.25 at noon, 0.5 at sunset, 0.75 at midnight.
uniform float sunAngle;
uniform float shadowAngle;

//==============================================================================
// VIEWPORT
//==============================================================================

uniform float viewWidth;
uniform float viewHeight;
uniform float aspectRatio;
uniform float near;
uniform float far;

//==============================================================================
// ENVIRONMENT
//==============================================================================

uniform float rainStrength;   // 0-1, instantaneous
uniform float wetness;        // 0-1, smoothed - surfaces stay wet after rain

uniform int   isEyeInWater;   // 0 air, 1 water, 2 lava, 3 powder snow
uniform float eyeAltitude;
uniform ivec2 eyeBrightness;
uniform ivec2 eyeBrightnessSmooth;

uniform float blindness;
uniform float darknessFactor;
uniform float darknessLightFactor;
uniform float nightVision;
uniform float screenBrightness;

uniform vec3  fogColor;
uniform vec3  skyColor;
uniform float fogStart;
uniform float fogEnd;

uniform int   heldBlockLightValue;
uniform int   heldBlockLightValue2;

//==============================================================================
// RENDERING STATE
//==============================================================================

uniform float alphaTestRef;
uniform ivec2 atlasSize;
uniform int   renderStage;

//==============================================================================
// SAMPLERS - SCENE
//==============================================================================

uniform sampler2D gtexture;   // the bound atlas / entity texture
uniform sampler2D lightmap;   // vanilla block+sky lightmap LUT
uniform sampler2D normals;    // LabPBR normal map (_n)
uniform sampler2D specular;   // LabPBR specular map (_s)

uniform sampler2D noisetex;

//==============================================================================
// SAMPLERS - COLOR ATTACHMENTS
//==============================================================================

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform sampler2D colortex10;
uniform sampler2D colortex11;
uniform sampler2D colortex12;
uniform sampler2D colortex13;
uniform sampler2D colortex14;
uniform sampler2D colortex15;

//==============================================================================
// SAMPLERS - DEPTH
//
// depthtex0  everything, including translucents
// depthtex1  opaque only - the surface behind water, needed for absorption
// depthtex2  opaque only, excluding the hand
//==============================================================================

uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D depthtex2;

//==============================================================================
// SAMPLERS - SHADOW
//
// shadowtex0  all shadow casters
// shadowtex1  opaque casters only - comparing the two is how coloured shadows
//             are detected without a separate flag
//==============================================================================

uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;

#endif // ASTRA_UNIFORMS_GLSL
