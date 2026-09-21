#ifndef ASTRA_SPACES_GLSL
#define ASTRA_SPACES_GLSL

#include "/lib/common/settings.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/uniforms.glsl"

/*
 * AstraRealism - Coordinate space conversions.
 *
 * Spaces used in this pack:
 *
 *   screen   [0,1]^2 UV plus [0,1] hardware depth
 *   ndc      [-1,1]^3 clip space after perspective divide
 *   view     camera at origin, -Z forward, right-handed
 *   scene    world-aligned axes, still relative to the camera. This is what
 *            "world space" means everywhere in this pack, because Minecraft's
 *            absolute coordinates are far too large for float precision.
 *   world    scene + cameraPosition. Only used where absolute position genuinely
 *            matters (noise lookups, waves), and always via worldPosition().
 *   shadow   the light's clip space, after distortion
 */

//==============================================================================
// SCREEN <-> NDC
//==============================================================================

vec3 screenToNDC(vec3 screenPos) { return screenPos * 2.0 - 1.0; }
vec3 ndcToScreen(vec3 ndcPos)    { return ndcPos * 0.5 + 0.5; }

//==============================================================================
// NDC <-> VIEW
//==============================================================================

/*
 * Perspective-correct unprojection. Written as an explicit matrix multiply
 * rather than the common "assume a symmetric frustum" shortcut, because Iris
 * applies a TAA jitter to the projection matrix and the shortcut silently
 * ignores it.
 */
vec3 ndcToView(vec3 ndcPos) {
    vec4 viewPos = gbufferProjectionInverse * vec4(ndcPos, 1.0);
    return viewPos.xyz / viewPos.w;
}

vec3 viewToNDC(vec3 viewPos) {
    vec4 clipPos = gbufferProjection * vec4(viewPos, 1.0);
    return clipPos.xyz / clipPos.w;
}

vec3 screenToView(vec3 screenPos) { return ndcToView(screenToNDC(screenPos)); }
vec3 viewToScreen(vec3 viewPos)   { return ndcToScreen(viewToNDC(viewPos)); }

//==============================================================================
// VIEW <-> SCENE
//==============================================================================

vec3 viewToScene(vec3 viewPos) {
    return mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
}

vec3 sceneToView(vec3 scenePos) {
    return mat3(gbufferModelView) * scenePos + gbufferModelView[3].xyz;
}

// Direction vectors must not pick up the translation column.
vec3 viewToSceneDir(vec3 viewDir)  { return mat3(gbufferModelViewInverse) * viewDir; }
vec3 sceneToViewDir(vec3 sceneDir) { return mat3(gbufferModelView) * sceneDir; }

// Absolute world position. Only correct within a frame - cameraPosition moves.
vec3 worldPosition(vec3 scenePos) { return scenePos + cameraPosition; }

//==============================================================================
// DEPTH
//==============================================================================

/*
 * Hardware depth to positive view-space distance along -Z.
 * Uses the projection matrix rather than near/far directly so it stays correct
 * if Iris ever hands us a reversed or infinite-far projection.
 */
float linearizeDepth(float hardwareDepth) {
    float ndcZ = hardwareDepth * 2.0 - 1.0;
    return -gbufferProjection[3][2] / (ndcZ + gbufferProjection[2][2]);
}

float delinearizeDepth(float viewDistance) {
    float ndcZ = -gbufferProjection[3][2] / viewDistance - gbufferProjection[2][2];
    return ndcZ * 0.5 + 0.5;
}

// True at pixels the geometry pass never wrote - i.e. sky.
bool isSky(float hardwareDepth) { return hardwareDepth >= 1.0; }

//==============================================================================
// TEMPORAL REPROJECTION
//==============================================================================

/*
 * Where this frame's scene point was on the previous frame's screen.
 *
 * The camera-delta term is essential: Minecraft's scene space is camera-relative
 * and shifts every frame, so reprojecting with the matrices alone leaves a
 * translation error that shows up as smearing whenever the player moves.
 *
 * `isHandOrStatic` should be true for geometry that does not move with the
 * world (the held item), which must not receive the camera delta.
 */
vec3 reprojectScene(vec3 scenePos, bool isHandOrStatic) {
    vec3 previousScenePos = scenePos;

    if (!isHandOrStatic) {
        previousScenePos += cameraPosition - previousCameraPosition;
    }

    vec4 previousView = gbufferPreviousModelView * vec4(previousScenePos, 1.0);
    vec4 previousClip = gbufferPreviousProjection * previousView;

    return ndcToScreen(previousClip.xyz / previousClip.w);
}

// Screen-space motion vector, in UV units, pointing from current to previous.
vec2 motionVector(vec3 scenePos, vec2 currentUV, bool isHandOrStatic) {
    return reprojectScene(scenePos, isHandOrStatic).xy - currentUV;
}

//==============================================================================
// SHADOW SPACE
//==============================================================================

/*
 * Shadow map distortion.
 *
 * A plain orthographic shadow map spends most of its texels on distant geometry
 * the player can barely see. Warping the projection by 1/(|xy| + k) concentrates
 * texels near the camera, which is the single most effective way to get crisp
 * near-field shadows out of a fixed-resolution map.
 *
 * This is the standard OptiFine/Iris distortion; `shadowDistortionFactor`
 * trades near-field sharpness against far-field precision.
 */
float shadowDistortFactor(vec2 shadowXY) {
    return 1.0 / (length(shadowXY) * shadowDistortionFactor
                  + (1.0 - shadowDistortionFactor));
}

/*
 * Z compression factor applied alongside the XY warp.
 *
 * The XY distortion pulls distant geometry inward, which effectively extends
 * how far along the light direction the map must reach. Scaling Z down keeps
 * that extended range inside the depth buffer. Any code converting a shadow
 * depth difference back into world units must divide this out again.
 */
const float SHADOW_Z_COMPRESSION = 0.2;

vec3 distortShadowClip(vec3 shadowClipPos) {
    float factor = shadowDistortFactor(shadowClipPos.xy);
    shadowClipPos.xy *= factor;
    shadowClipPos.z *= SHADOW_Z_COMPRESSION;

    return shadowClipPos;
}

/*
 * World units spanned by one shadow map texel at the given shadow clip
 * position. The distortion makes this vary across the map, so bias and filter
 * radii must be scaled by it to stay constant in world space.
 */
float shadowTexelWorldSize(vec2 shadowClipXY) {
    // Clip space spans [-1,1] over 2*shadowDistance world units.
    float undistorted = 2.0 * shadowDistance / float(shadowMapResolution);
    return undistorted / max(shadowDistortFactor(shadowClipXY), 0.05);
}

/*
 * World distance along the light direction corresponding to a difference in
 * stored shadow depth. Undoes both the [0,1] texture mapping and the Z
 * compression above.
 */
float shadowDepthToWorld(float depthDelta) {
    // The orthographic projection maps 2/|m22| world units onto clip [-1,1].
    float range = 2.0 / max(abs(shadowProjection[2][2]), ASTRA_EPSILON);
    return depthDelta * range / SHADOW_Z_COMPRESSION;
}

// The derivative of the distortion, needed to scale bias and PCF radii so they
// stay constant in world units across the warped map.
float shadowDistortDerivative(vec2 shadowXY) {
    float d = shadowDistortFactor(shadowXY);
    return d * d;
}

vec3 sceneToShadowClip(vec3 scenePos) {
    vec4 shadowViewPos = shadowModelView * vec4(scenePos, 1.0);
    vec4 shadowClipPos = shadowProjection * shadowViewPos;
    return shadowClipPos.xyz / shadowClipPos.w;
}

// Full transform to the [0,1]^3 texture space of the shadow map.
vec3 sceneToShadowScreen(vec3 scenePos) {
    return distortShadowClip(sceneToShadowClip(scenePos)) * 0.5 + 0.5;
}

//==============================================================================
// VIEW RAYS
//==============================================================================

// Scene-space direction from the camera through a screen UV.
vec3 viewRayFromUV(vec2 uv) {
    vec3 viewPos = screenToView(vec3(uv, 1.0));
    return normalize(viewToSceneDir(viewPos));
}

// Scene-space direction toward the fragment, given its scene position.
vec3 viewDirection(vec3 scenePos) { return normalize(-scenePos); }

#endif // ASTRA_SPACES_GLSL
