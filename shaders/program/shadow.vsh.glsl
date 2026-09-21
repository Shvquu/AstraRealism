#ifndef ASTRA_SHADOW_VSH
#define ASTRA_SHADOW_VSH

/*
 * AstraRealism - Shadow map vertex stage.
 *
 * Renders the scene from the light's point of view. The distortion applied here
 * must match distortShadowClip() in lib/common/spaces.glsl exactly - the
 * lookup side undoes this transform, and any disagreement shows up as shadows
 * sliding away from their casters.
 */

#include "/lib/common/common.glsl"
#include "/lib/material/material_id.glsl"

in vec4 mc_Entity;
in vec2 mc_midTexCoord;

out vec2 texcoord;
out vec4 vertexColor;
flat out int materialId;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vertexColor = gl_Color;
    materialId = classifyMaterial(int(mc_Entity.x + 0.5));

    vec4 shadowClip = ftransform();

    // Perspective divide is a no-op for the orthographic shadow projection, but
    // doing it explicitly keeps this correct if Iris ever supplies something
    // else.
    shadowClip.xyz = distortShadowClip(shadowClip.xyz / shadowClip.w);
    shadowClip.w = 1.0;

    gl_Position = shadowClip;
}

#endif // ASTRA_SHADOW_VSH
