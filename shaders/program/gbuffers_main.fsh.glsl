#ifndef ASTRA_GBUFFERS_MAIN_FSH
#define ASTRA_GBUFFERS_MAIN_FSH

/*
 * AstraRealism - Fragment stage shared by every gbuffers program.
 *
 * Three output paths, selected by which program the stub compiled this as:
 *
 *   Deferred path - opaque geometry that runs before the deferred pass writes
 *   material properties into colortex1..4 and is shaded later.
 *
 *   Forward path - geometry that runs after the deferred pass (translucents,
 *   particles, weather) cannot use the gbuffer, because the lighting pass has
 *   already consumed it. These shade immediately and blend into colortex0.
 *   Water and glass additionally read colortex9, the copy of the lit opaque
 *   scene, so they can refract and absorb what is behind them.
 *
 *   Sky path - writes nothing at all: the vanilla sky is discarded and replaced
 *   by the atmosphere model in the deferred pass.
 */

#include "/lib/common/common.glsl"
#include "/lib/material/material.glsl"
#include "/lib/material/material_id.glsl"
#include "/lib/material/parallax.glsl"
#include "/lib/material/wetness.glsl"

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
#elif defined(PROGRAM_WATER) || defined(PROGRAM_HAND_WATER)
    // Translucent surfaces with access to the scene behind them.
    #define ASTRA_PATH_TRANSLUCENT
    #define ASTRA_PATH_FORWARD
#elif defined(PROGRAM_WEATHER) \
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
flat in vec2 tileSize;

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

#if defined(ASTRA_PATH_TRANSLUCENT)
#include "/lib/water/water_shading.glsl"
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
    float viewDistance = length(scenePos);
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    //--------------------------------------------------------------------------
    // Parallax
    //
    // Runs before the material is fetched, because it decides which texel the
    // material is fetched from. Self-shadowing needs the height at the hit, so
    // the result is kept rather than only its UV.
    //--------------------------------------------------------------------------

    vec2 sampleUV = texcoord;
    ParallaxResult parallax;
    parallax.uv = texcoord;
    parallax.height = 1.0;
    parallax.hit = false;

    #if ASTRA_ENABLE_POM && !defined(ASTRA_PATH_TRANSLUCENT)
        vec3 viewDirTangent = toTangentSpace(normalize(-scenePos),
                                             tangent, bitangent, normal);

        parallax = applyParallax(texcoord, midTexcoord, tileSize,
                                 viewDirTangent, viewDistance, dither);
        sampleUV = parallax.uv;
    #endif

    SurfaceMaterial material = fetchMaterial(sampleUV, vertexColor, materialId);

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

    //--------------------------------------------------------------------------
    // Surface response to weather
    //--------------------------------------------------------------------------

    #if !defined(ASTRA_PATH_TRANSLUCENT)
        applySnowMaterial(material.albedo, material.roughness, material.f0,
                          material.porosity, materialId);

        applyWetness(material.albedo, material.roughness, material.f0,
                     shadingNormal, tangent, bitangent,
                     worldPosition(scenePos), normal, lmcoord.y,
                     material.porosity, materialId);
    #endif

    //--------------------------------------------------------------------------
    // Parallax self-shadowing
    //
    // Folded into the ambient occlusion channel rather than applied to the
    // albedo. Baking it into albedo would make the shadow survive into the
    // reflection and the indirect bounce, where it does not belong.
    //--------------------------------------------------------------------------

    #if ASTRA_ENABLE_POM_SHADOW && defined(ASTRA_PATH_DEFERRED)
        if (parallax.hit) {
            vec3 lightDirTangent = toTangentSpace(
                normalize(viewToSceneDir(shadowLightPosition)),
                tangent, bitangent, normal);

            material.ambientOcclusion *= parallaxSelfShadow(
                sampleUV, midTexcoord, tileSize, lightDirTangent,
                parallax.height, viewDistance, dither);
        }
    #endif

    //--------------------------------------------------------------------------
    // Output
    //--------------------------------------------------------------------------

    #if defined(ASTRA_PATH_DEFERRED)
        float wet = surfaceWetness(lmcoord.y, normal, materialId);

        encodeGBuffer(
            material.albedo, materialId,
            shadingNormal, normal,
            material.roughness, material.f0, material.emissive, material.porosity,
            lmcoord, material.ambientOcclusion, wet,
            gbufferA, gbufferB, gbufferC, gbufferD
        );

    #elif defined(ASTRA_PATH_TRANSLUCENT)
        /*
         * Water and glass. Both read colortex9, the copy of the lit opaque
         * scene written by the last deferred pass, and fold everything behind
         * them into their own colour - so they emerge fully opaque and the
         * hardware blend does not apply the background a second time.
         */
        vec2 screenUV = gl_FragCoord.xy / vec2(viewWidth, viewHeight);

        WaterSurface surface;

        if (materialId == MATID_WATER) {
            surface = shadeWater(scenePos, normal, screenUV, gl_FragCoord.z,
                                 lmcoord, material.albedo, colortex9, dither);
        } else {
            surface = shadeTranslucent(scenePos, shadingNormal, screenUV,
                                       gl_FragCoord.z, material.albedo,
                                       material.alpha, material.roughness,
                                       material.f0, colortex9, dither);
        }

        sceneColor = vec4(surface.color, surface.alpha);

    #else
        /*
         * Particles and weather. These blend over an already-lit scene and use
         * the same lighting model as everything else, minus the screen-space
         * effects that need opaque gbuffer data.
         */
        vec3 shaded = shadeForward(
            material, shadingNormal, normal, scenePos, lmcoord, materialId
        );

        sceneColor = vec4(shaded, material.alpha);
    #endif
#endif
}

#endif // ASTRA_GBUFFERS_MAIN_FSH
