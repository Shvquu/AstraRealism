#ifndef ASTRA_COMPAT_VERSION_GLSL
#define ASTRA_COMPAT_VERSION_GLSL

/*
 * AstraRealism - Version and capability detection.
 *
 * This is the only file that is allowed to test MC_VERSION, IRIS_VERSION or a
 * raw feature macro. Everything else asks the ASTRA_HAS_* / ASTRA_MC_* macros
 * defined here, so adding a new Minecraft or Iris version means editing one
 * file rather than grepping the whole pack.
 *
 * Supported targets:
 *   Minecraft 1.21.11  (MC_VERSION 12111) via Iris 1.10.4
 *   Minecraft 26.3     (MC_VERSION 260300 or similar) via Iris 1.11.x
 *
 * Mojang switched from 1.MAJOR.MINOR to year-based versions in 2026, so
 * MC_VERSION jumps from five digits to six. Ordering comparisons still work
 * because the new scheme produces strictly larger numbers.
 */

//==============================================================================
// PLATFORM
//==============================================================================

#ifdef IS_IRIS
    #define ASTRA_IRIS 1
#else
    // OptiFine or an unknown loader. The pack is authored against Iris, but
    // nothing here hard-requires it; optional features degrade instead.
    #define ASTRA_IRIS 0
#endif

//==============================================================================
// MINECRAFT VERSION
//==============================================================================

#ifndef MC_VERSION
    // Extremely old or non-conforming loader. Assume the oldest target so the
    // conservative code paths are taken.
    #define MC_VERSION 12111
#endif

// The 1.x scheme tops out well below 200000; the year scheme starts at 260100.
#if MC_VERSION >= 200000
    #define ASTRA_MC_YEAR_VERSIONING 1
#else
    #define ASTRA_MC_YEAR_VERSIONING 0
#endif

#if MC_VERSION >= 12111
    #define ASTRA_MC_AT_LEAST_1_21_11 1
#else
    #define ASTRA_MC_AT_LEAST_1_21_11 0
#endif

//==============================================================================
// IRIS VERSION
//==============================================================================

#ifdef IRIS_VERSION
    #define ASTRA_IRIS_VERSION IRIS_VERSION
#else
    #define ASTRA_IRIS_VERSION 0
#endif

//==============================================================================
// COLOR BUFFER COUNT
//
// MAX_COLOR_BUFFERS was added in Iris 1.10.5. Minecraft 1.21.11 tops out at
// Iris 1.10.4, so on that target the macro is absent and we fall back to the
// value Iris has guaranteed since 1.6: sixteen colortex attachments.
//==============================================================================

#ifdef MAX_COLOR_BUFFERS
    #define ASTRA_COLOR_BUFFERS MAX_COLOR_BUFFERS
#else
    #define ASTRA_COLOR_BUFFERS 16
#endif

#if ASTRA_COLOR_BUFFERS < 16
    #error "AstraRealism requires 16 colortex attachments. Update Iris."
#endif

//==============================================================================
// PBR RESOURCE PACK FORMAT
//
// PBR_MODE: 0 = force the vanilla heuristic, 1 = force LabPBR, 2 = auto.
// MC_TEXTURE_FORMAT_LAB_PBR is defined by the loader when the active resource
// pack declares LabPBR support in its pack metadata.
//==============================================================================

#include "/lib/common/settings.glsl"

#if PBR_MODE == 0
    #define ASTRA_HAS_LABPBR 0
#elif PBR_MODE == 1
    #define ASTRA_HAS_LABPBR 1
#else
    #ifdef MC_TEXTURE_FORMAT_LAB_PBR
        #define ASTRA_HAS_LABPBR 1
    #else
        #define ASTRA_HAS_LABPBR 0
    #endif
#endif

//==============================================================================
// OPTIONAL IRIS FEATURES
//
// These correspond to the flags requested as `iris.features.optional` in
// shaders.properties. Nothing is requested as `required`, so the pack still
// loads on an Iris build that lacks them - the affected system degrades to a
// cheaper path instead of failing to compile.
//==============================================================================

#ifdef IRIS_FEATURE_COMPUTE_SHADERS
    #define ASTRA_HAS_COMPUTE 1
#else
    #define ASTRA_HAS_COMPUTE 0
#endif

#ifdef IRIS_FEATURE_SSBO
    #define ASTRA_HAS_SSBO 1
#else
    #define ASTRA_HAS_SSBO 0
#endif

#ifdef IRIS_FEATURE_CUSTOM_IMAGES
    #define ASTRA_HAS_CUSTOM_IMAGES 1
#else
    #define ASTRA_HAS_CUSTOM_IMAGES 0
#endif

#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
    #define ASTRA_HAS_HW_SHADOW_SAMPLERS 1
#else
    #define ASTRA_HAS_HW_SHADOW_SAMPLERS 0
#endif

#ifdef IRIS_FEATURE_PER_BUFFER_BLENDING
    #define ASTRA_HAS_PER_BUFFER_BLENDING 1
#else
    #define ASTRA_HAS_PER_BUFFER_BLENDING 0
#endif

#ifdef IRIS_FEATURE_ENTITY_TRANSLUCENT
    #define ASTRA_HAS_ENTITY_TRANSLUCENT 1
#else
    #define ASTRA_HAS_ENTITY_TRANSLUCENT 0
#endif

//==============================================================================
// GPU VENDOR
//
// Used only to work around known driver bugs, never to gate visual features.
// A user on any vendor must get the same image.
//==============================================================================

#if defined(MC_GL_VENDOR_INTEL)
    #define ASTRA_VENDOR_INTEL 1
#else
    #define ASTRA_VENDOR_INTEL 0
#endif

#if defined(MC_GL_VENDOR_AMD) || defined(MC_GL_VENDOR_ATI)
    #define ASTRA_VENDOR_AMD 1
#else
    #define ASTRA_VENDOR_AMD 0
#endif

#if defined(MC_GL_VENDOR_NVIDIA)
    #define ASTRA_VENDOR_NVIDIA 1
#else
    #define ASTRA_VENDOR_NVIDIA 0
#endif

#endif // ASTRA_COMPAT_VERSION_GLSL
