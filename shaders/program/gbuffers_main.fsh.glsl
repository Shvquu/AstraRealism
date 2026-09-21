#ifndef ASTRA_GBUFFERS_MAIN_FSH
#define ASTRA_GBUFFERS_MAIN_FSH

/*
 * AstraRealism - Fragment stage shared by every gbuffers program.
 *
 * Two output paths, selected by which program the stub compiled this as:
 *
 *   Deferred path - opaque geometry that runs before the deferred pass writes
 *   material properties into colortex1..4 and is shaded later.
 *
 *   Forward path - geometry that runs after the deferred pass (translucents,
 *   particles, weather) cannot use the gbuffer, because the lighting pass has
 *   already consumed it. These shade immediately and blend into colortex0.
 *
 * The sky programs write nothing at all: the vanilla sky is discarded and
 * replaced by the atmosphere model in the deferred pass.
 */

#include "/lib/common/common.glsl"
#include "/lib/material/material.glsl"
#include "/lib/material/material_id.glsl"

//==============================================================================
// PATH SELECTION
//==============================================================================

/*
 * Which path a program takes is decided entirely by whether Iris draws it
 * before or after the deferred pass. Getting this wrong is silent and severe:
 * forward-shading geometry that renders BEFORE deferred writes colour into
 * colortex0 which deferred then overwrites, so the geometry simply disappears.
 *
 * After deferred (forward):
 *   gbuffers_water, gbuffers_weather, gbuffers_hand_water - always
 *   gbuffers_textured, gbuffers_textured_lit - these draw particles, and
 *     `particles.ordering = after` in shaders.properties puts them after
 *     deferred. That directive is set explicitly rather than relying on the
 *     default, which varies with whether a deferred pass exists.
 *
 * Before deferred (gbuffer):
 *   everything else, including gbuffers_basic and gbuffers_beaconbeam.
 */
#if defined(PROGRAM_SKYBASIC) || defined(PROGRAM_SKYTEXTURED)
    #define ASTRA_PATH_SKY
#elif defined(PROGRAM_WATER) || defined(PROGRAM_WEATHER) \
   || defined(PROGRAM_HAND_WATER) \
   || defined(PROGRAM_TEXTURED) || defined(PROGRAM_TEXTURED_LIT)
    #define ASTRA_PATH_FORWARD
#else
    #define ASTRA_PATH_DEFERRED
#endif

//==============================================================================
// INPUTS
//==============================================================================

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;

in vec3 scenePos;
in vec3 viewPos;

in vec3 normal;
in vec3 tangent;
in vec3 bitangent;

flat in int materialId;

in vec2 midTexcoord;

//==============================================================================
// OUTPUTS
//==============================================================================

#if defined(ASTRA_PATH_DEFERRED)
/* RENDERTARGETS: 1,2,3,4 */
layout(location = 0) out vec4 gbufferA;
layout(location = 1) out vec4 gbufferB;
layout(location = 2) out vec4 gbufferC;
layout(location = 3) out vec4 gbufferD;

#elif defined(ASTRA_PATH_FORWARD)
/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 sceneColor;
#endif

//==============================================================================

#if !defined(ASTRA_PATH_SKY)
#include "/lib/lighting/forward.glsl"
#endif

void main() {
#if defined(ASTRA_PATH_SKY)
    /*
     * The vanilla sky dome, horizon plane and star field are all discarded.
     * Every sky pixel is regenerated from the atmosphere model in the deferred
     * pass, which gives correct extinction, a physically derived horizon and a
     * sun disc that dims as it sets.
     */
    discard;

#else
    SurfaceMaterial material = fetchMaterial(texcoord, vertexColor, materialId);

    /*
     * Alpha handling.
     *
     * Iris passes the cutoff through alphaTestRef rather than applying the test
     * itself once a shader declares its own fragment outputs, so the discard
     * has to happen here - otherwise cutout foliage renders as solid quads.
     *
     * The test only applies to the gbuffer path. Translucent geometry is not
     * cutout geometry: water sits around 70% alpha and stained glass lower
     * still, and testing them against the same reference would discard them
     * outright. They only skip fragments that are fully transparent, which is
     * a pure saving with no visual effect.
     */
    #if defined(ASTRA_PATH_DEFERRED)
        if (material.alpha < alphaTestRef) discard;
    #else
        if (material.alpha < 0.004) discard;
    #endif

    vec3 shadingNormal = applyNormalMap(material.normalTangent, normal,
                                        tangent, bitangent);

    #if defined(ASTRA_PATH_DEFERRED)
        encodeGBuffer(
            material.albedo, materialId,
            shadingNormal, normal,
            material.roughness, material.f0, material.emissive, material.porosity,
            lmcoord, material.ambientOcclusion, 0.0,
            gbufferA, gbufferB, gbufferC, gbufferD
        );

    #else
        /*
         * Forward path. These fragments are blended over an already-lit scene,
         * so they shade themselves with the same lighting model the deferred
         * pass uses - just without access to screen-space effects that need the
         * opaque gbuffer.
         */
        vec3 shaded = shadeForward(
            material, shadingNormal, normal, scenePos, lmcoord, materialId
        );

        sceneColor = vec4(shaded, material.alpha);
    #endif
#endif
}

#endif // ASTRA_GBUFFERS_MAIN_FSH
