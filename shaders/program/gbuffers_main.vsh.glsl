#ifndef ASTRA_GBUFFERS_MAIN_VSH
#define ASTRA_GBUFFERS_MAIN_VSH

/*
 * AstraRealism - Vertex stage shared by every gbuffers program.
 *
 * One body serves all geometry types; the PROGRAM_* macro set by the stub
 * selects the per-program behaviour. This keeps the vertex transform, tangent
 * basis construction and material classification in a single place rather than
 * duplicated across a dozen near-identical files.
 */

#include "/lib/common/common.glsl"
#include "/lib/material/material_id.glsl"

//==============================================================================
// VERTEX ATTRIBUTES
//
// Only legal in gbuffers and shadow vertex stages, which is why they are
// declared here rather than in lib/common/uniforms.glsl.
//
// Declared with `in` rather than the legacy `attribute` keyword: `attribute`
// was removed from core GLSL at 4.20 and only survives in compatibility
// profiles, where strict drivers still warn about it.
//==============================================================================

// Tangent, with handedness in .w. Supplied by Iris for normal mapping.
in vec4 at_tangent;

// Block identity, populated from block.properties. x is the mapped id.
in vec4 mc_Entity;

// Centre of the texture tile in atlas UV space. Needed to find tile bounds for
// parallax mapping, and to detect which corner of a sprite a vertex belongs to.
in vec2 mc_midTexCoord;

//==============================================================================
// OUTPUTS
//==============================================================================

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vertexColor;

out vec3 scenePos;      // world-aligned, camera-relative
out vec3 viewPos;

out vec3 normal;        // world-aligned geometric normal
out vec3 tangent;
out vec3 bitangent;

flat out int materialId;

// Tile bounds in atlas space, used by parallax to wrap UVs inside the sprite.
out vec2 midTexcoord;

//==============================================================================

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    midTexcoord = mc_midTexCoord;

    // The lightmap arrives in [0,255] and its texture matrix maps it to the
    // [0.03125, 0.96875] range the vanilla lightmap texture expects. We want
    // a clean [0,1], so undo that remap.
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    lmcoord = saturate((lmcoord - 0.03125) * (1.0 / 0.9375));

    vertexColor = gl_Color;

    viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    scenePos = viewToScene(viewPos);

    normal = normalize(viewToSceneDir(gl_NormalMatrix * gl_Normal));

    // Tangent basis for normal mapping. at_tangent.w carries the handedness of
    // the UV winding; without it, normal maps mirror on half the faces.
    tangent = normalize(viewToSceneDir(gl_NormalMatrix * at_tangent.xyz));
    bitangent = normalize(cross(tangent, normal) * sign(at_tangent.w));

    materialId = classifyMaterial(int(mc_Entity.x + 0.5));

    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);

#if ASTRA_TEMPORAL_JITTER
    // TAA needs a sub-pixel offset per frame. Applying it here, after
    // projection, keeps the depth buffer and motion vectors consistent with the
    // jittered colour - jittering the projection matrix instead would also
    // shift the values Iris reports back to us.
    gl_Position.xy += taaJitterOffset(frameCounter) * gl_Position.w;
#endif
}

#endif // ASTRA_GBUFFERS_MAIN_VSH
