#ifndef ASTRA_COMPAT_FALLBACK_GLSL
#define ASTRA_COMPAT_FALLBACK_GLSL

#include "/lib/compat/version.glsl"

/*
 * AstraRealism - Graceful degradation.
 *
 * Resolves the user's requested settings against what the running hardware and
 * loader actually support, producing a single set of ASTRA_ENABLE_* macros.
 *
 * The rule: a missing capability disables the feature or swaps in a cheaper
 * implementation. It never produces a compile error, and it never silently
 * produces a broken image.
 *
 * Every program should test ASTRA_ENABLE_*, never the raw user setting.
 */

//==============================================================================
// SHADOWS
//==============================================================================

#ifdef SHADOWS_ENABLED
    #define ASTRA_ENABLE_SHADOWS 1
#else
    #define ASTRA_ENABLE_SHADOWS 0
#endif

// PCSS needs a blocker-search loop; below that it degrades to fixed PCF.
#if ASTRA_ENABLE_SHADOWS && SHADOW_FILTER == 2
    #define ASTRA_SHADOW_FILTER_MODE 2
#elif ASTRA_ENABLE_SHADOWS && SHADOW_FILTER == 1
    #define ASTRA_SHADOW_FILTER_MODE 1
#else
    #define ASTRA_SHADOW_FILTER_MODE 0
#endif

#if ASTRA_ENABLE_SHADOWS && defined(COLORED_SHADOWS)
    #define ASTRA_ENABLE_COLORED_SHADOWS 1
#else
    #define ASTRA_ENABLE_COLORED_SHADOWS 0
#endif

// Contact shadows are pure screen space and need no shadow map, but they only
// make sense as a complement to one.
#if ASTRA_ENABLE_SHADOWS && defined(CONTACT_SHADOWS)
    #define ASTRA_ENABLE_CONTACT_SHADOWS 1
#else
    #define ASTRA_ENABLE_CONTACT_SHADOWS 0
#endif

//==============================================================================
// AMBIENT OCCLUSION
//==============================================================================

#if AO_MODE == 2
    #define ASTRA_AO_MODE 2  // GTAO
#elif AO_MODE == 1
    #define ASTRA_AO_MODE 1  // SSAO
#else
    #define ASTRA_AO_MODE 0
#endif

//==============================================================================
// GLOBAL ILLUMINATION
//==============================================================================

#ifdef GI_ENABLED
    #define ASTRA_ENABLE_GI 1
#else
    #define ASTRA_ENABLE_GI 0
#endif

#if ASTRA_ENABLE_GI && defined(GI_DENOISER)
    #define ASTRA_ENABLE_GI_DENOISER 1
#else
    #define ASTRA_ENABLE_GI_DENOISER 0
#endif

//==============================================================================
// REFLECTIONS
//==============================================================================

#ifdef SSR_ENABLED
    #define ASTRA_ENABLE_SSR 1
#else
    #define ASTRA_ENABLE_SSR 0
#endif

#if ASTRA_ENABLE_SSR && defined(SSR_ROUGH_REFLECTIONS)
    #define ASTRA_ENABLE_ROUGH_SSR 1
#else
    #define ASTRA_ENABLE_ROUGH_SSR 0
#endif

#if ASTRA_ENABLE_SSR && defined(SSR_TEMPORAL)
    #define ASTRA_ENABLE_SSR_TEMPORAL 1
#else
    #define ASTRA_ENABLE_SSR_TEMPORAL 0
#endif

//==============================================================================
// MATERIALS
//
// Parallax and subsurface scattering both read LabPBR channels. Without a
// LabPBR pack there is no height map and no SSS channel, so they switch off
// regardless of what the user selected - enabling them anyway would sample
// undefined texture data.
//==============================================================================

#if ASTRA_HAS_LABPBR && defined(POM_ENABLED)
    #define ASTRA_ENABLE_POM 1
#else
    #define ASTRA_ENABLE_POM 0
#endif

#if ASTRA_ENABLE_POM && defined(POM_SHADOW)
    #define ASTRA_ENABLE_POM_SHADOW 1
#else
    #define ASTRA_ENABLE_POM_SHADOW 0
#endif

// SSS still works without LabPBR: the fallback path infers it from material id
// (foliage, snow, ice) instead of the porosity channel.
#ifdef SUBSURFACE_SCATTERING
    #define ASTRA_ENABLE_SSS 1
#else
    #define ASTRA_ENABLE_SSS 0
#endif

//==============================================================================
// WEATHER & WATER
//==============================================================================

#ifdef WETNESS_ENABLED
    #define ASTRA_ENABLE_WETNESS 1
#else
    #define ASTRA_ENABLE_WETNESS 0
#endif

#if ASTRA_ENABLE_WETNESS && defined(PUDDLES)
    #define ASTRA_ENABLE_PUDDLES 1
#else
    #define ASTRA_ENABLE_PUDDLES 0
#endif

#if ASTRA_ENABLE_WETNESS && defined(RAIN_RIPPLES)
    #define ASTRA_ENABLE_RAIN_RIPPLES 1
#else
    #define ASTRA_ENABLE_RAIN_RIPPLES 0
#endif

#ifdef WATER_CAUSTICS
    #define ASTRA_ENABLE_CAUSTICS 1
#else
    #define ASTRA_ENABLE_CAUSTICS 0
#endif

#ifdef WATER_WAVES
    #define ASTRA_ENABLE_WATER_WAVES 1
#else
    #define ASTRA_ENABLE_WATER_WAVES 0
#endif

#ifdef WATER_REFRACTION
    #define ASTRA_ENABLE_REFRACTION 1
#else
    #define ASTRA_ENABLE_REFRACTION 0
#endif

//==============================================================================
// ATMOSPHERE & VOLUMETRICS
//==============================================================================

#ifdef FOG_ENABLED
    #define ASTRA_ENABLE_FOG 1
#else
    #define ASTRA_ENABLE_FOG 0
#endif

#ifdef VOLUMETRIC_LIGHT
    #define ASTRA_ENABLE_VOLUMETRICS 1
#else
    #define ASTRA_ENABLE_VOLUMETRICS 0
#endif

// Volumetric light marches the shadow map. With shadows off there is nothing
// to occlude the rays, so it would render as uniform haze - disable instead.
#if ASTRA_ENABLE_VOLUMETRICS && !ASTRA_ENABLE_SHADOWS
    #undef ASTRA_ENABLE_VOLUMETRICS
    #define ASTRA_ENABLE_VOLUMETRICS 0
#endif

#if CLOUDS_MODE == 2
    #define ASTRA_CLOUD_MODE 2  // volumetric
#elif CLOUDS_MODE == 1
    #define ASTRA_CLOUD_MODE 1  // 2D layer
#else
    #define ASTRA_CLOUD_MODE 0
#endif

#if ASTRA_CLOUD_MODE > 0 && defined(CLOUD_SHADOWS)
    #define ASTRA_ENABLE_CLOUD_SHADOWS 1
#else
    #define ASTRA_ENABLE_CLOUD_SHADOWS 0
#endif

//==============================================================================
// POST PROCESSING
//==============================================================================

#if AA_MODE == 2
    #define ASTRA_AA_MODE 2  // TAA
#elif AA_MODE == 1
    #define ASTRA_AA_MODE 1  // FXAA
#else
    #define ASTRA_AA_MODE 0
#endif

// Several temporal systems depend on TAA's reprojection and jitter.
#if ASTRA_AA_MODE == 2
    #define ASTRA_TEMPORAL_JITTER 1
#else
    #define ASTRA_TEMPORAL_JITTER 0
#endif

#ifdef BLOOM_ENABLED
    #define ASTRA_ENABLE_BLOOM 1
#else
    #define ASTRA_ENABLE_BLOOM 0
#endif

#if EXPOSURE_MODE == 1
    #define ASTRA_ENABLE_AUTO_EXPOSURE 1
#else
    #define ASTRA_ENABLE_AUTO_EXPOSURE 0
#endif

#ifdef DOF_ENABLED
    #define ASTRA_ENABLE_DOF 1
#else
    #define ASTRA_ENABLE_DOF 0
#endif

#if MOTION_BLUR > 0
    #define ASTRA_ENABLE_MOTION_BLUR 1
#else
    #define ASTRA_ENABLE_MOTION_BLUR 0
#endif

#ifdef VIGNETTE
    #define ASTRA_ENABLE_VIGNETTE 1
#else
    #define ASTRA_ENABLE_VIGNETTE 0
#endif

#ifdef CHROMATIC_ABERRATION
    #define ASTRA_ENABLE_CA 1
#else
    #define ASTRA_ENABLE_CA 0
#endif

#ifdef FILM_GRAIN
    #define ASTRA_ENABLE_GRAIN 1
#else
    #define ASTRA_ENABLE_GRAIN 0
#endif

#ifdef LENS_FLARE
    #define ASTRA_ENABLE_LENS_FLARE 1
#else
    #define ASTRA_ENABLE_LENS_FLARE 0
#endif

#ifdef LENS_DIRT
    #define ASTRA_ENABLE_LENS_DIRT 1
#else
    #define ASTRA_ENABLE_LENS_DIRT 0
#endif

//==============================================================================
// DEBUG
//==============================================================================

#if DEBUG_MODE > 0
    #define ASTRA_DEBUG 1
#else
    #define ASTRA_DEBUG 0
#endif

#endif // ASTRA_COMPAT_FALLBACK_GLSL
