#ifndef ASTRA_SETTINGS_GLSL
#define ASTRA_SETTINGS_GLSL

/*
 * AstraRealism - Settings
 *
 * SINGLE SOURCE OF TRUTH for every user-facing option.
 *
 * Iris/OptiFine parse this file to build the in-game Shader Pack Settings
 * screen. The syntax matters:
 *
 *   #define NAME          -> boolean option, currently ON
 *   //#define NAME        -> boolean option, currently OFF
 *   #define NAME 4 // [1 2 4 8]  -> numeric option with allowed values
 *   const int name = 2048; // [1024 2048]  -> const option
 *
 * Anything listed here MUST also appear in:
 *   - shaders/shaders.properties  (screen layout + profiles)
 *   - shaders/lang/en_us.lang     (label + tooltip)
 * tools/validate_shader.py enforces that three-way consistency.
 */

//==============================================================================
// LIGHTING
//==============================================================================

#define SUN_INTENSITY 22.0 // [4.0 8.0 12.0 16.0 18.0 20.0 22.0 24.0 28.0 32.0 40.0 50.0]
/*
 * Real moonlight is around 400,000x dimmer than sunlight. Reproducing that
 * ratio at a fixed exposure leaves nights unplayably black, so the default
 * compresses it to roughly 15:1 - which is also close to how dark-adapted
 * vision actually perceives a full moon.
 */
#define MOON_INTENSITY 1.5 // [0.0 0.1 0.25 0.4 0.55 0.7 1.0 1.5 2.0 3.0 4.0]
#define SKYLIGHT_INTENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]
#define BLOCKLIGHT_INTENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]

// Correlated colour temperature of block light in Kelvin.
// 1900K is a candle flame, 2700K a warm bulb, 6500K neutral daylight.
#define BLOCKLIGHT_TEMPERATURE 2300 // [1500 1700 1900 2100 2300 2500 2700 3000 3500 4000 5000 6500]

// Falloff exponent for the vanilla block lightmap. Higher = faster decay.
#define BLOCKLIGHT_FALLOFF 2.4 // [1.0 1.4 1.8 2.0 2.2 2.4 2.6 3.0 3.5 4.0]

#define AMBIENT_INTENSITY 0.12 // [0.0 0.02 0.04 0.06 0.08 0.10 0.12 0.16 0.20 0.30 0.50]
#define EMISSIVE_INTENSITY 2.5 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 6.0 8.0]

// Night-vision-like floor so caves are dark but never pure black.
#define MINIMUM_LIGHT 0.003 // [0.0 0.001 0.002 0.003 0.005 0.008 0.012 0.020]

//==============================================================================
// SHADOWS
//==============================================================================

#define SHADOWS_ENABLED // Master toggle for the shadow pass.

const int shadowMapResolution = 2048; // [512 1024 1536 2048 3072 4096 8192]
const float shadowDistance = 160.0; // [64.0 96.0 128.0 160.0 192.0 256.0 384.0 512.0]

// Shadow map distortion. Higher values pack more texels near the camera at the
// cost of precision far away. 0.85 is a good middle ground.
const float shadowDistortionFactor = 0.85; // [0.50 0.60 0.70 0.80 0.85 0.90 0.95]

// 0 = hard, 1 = PCF (fixed radius), 2 = PCSS (contact-hardening)
#define SHADOW_FILTER 2 // [0 1 2]
#define SHADOW_SAMPLES 12 // [4 6 8 12 16 24 32 48]

// PCSS blocker search radius, in shadow-map texels.
#define SHADOW_BLOCKER_SAMPLES 8 // [4 6 8 12 16]

// Angular diameter of the sun in degrees drives penumbra width. The real sun is
// ~0.53 degrees; larger values give softer, more stylised shadows.
#define SUN_ANGULAR_RADIUS 0.60 // [0.25 0.40 0.53 0.60 0.80 1.00 1.50 2.00]

#define SHADOW_BIAS 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]

#define COLORED_SHADOWS // Stained glass and water tint the light passing through.

#define CONTACT_SHADOWS // Screen-space ray march for small-scale contact detail.
#define CONTACT_SHADOW_STEPS 12 // [4 8 12 16 24 32]
#define CONTACT_SHADOW_LENGTH 0.5 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0]

//==============================================================================
// AMBIENT OCCLUSION
//==============================================================================

// 0 = off, 1 = SSAO, 2 = GTAO
#define AO_MODE 2 // [0 1 2]
#define AO_SAMPLES 8 // [4 6 8 12 16 24]
#define AO_RADIUS 1.2 // [0.4 0.6 0.8 1.0 1.2 1.6 2.0 3.0]
#define AO_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0]

//==============================================================================
// GLOBAL ILLUMINATION
//==============================================================================

#define GI_ENABLED // Screen-space indirect bounce lighting.
#define GI_SAMPLES 8 // [2 4 6 8 12 16 24]
#define GI_STEPS 12 // [4 8 12 16 24 32]
#define GI_RADIUS 12.0 // [2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0]
#define GI_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]

// Render GI at a fraction of screen resolution, then upsample. 2 = half res.
#define GI_RESOLUTION_DIVISOR 2 // [1 2 3 4]

// Frames of temporal history to blend. Higher = cleaner but more lag.
#define GI_TEMPORAL_FRAMES 24 // [4 8 12 16 24 32 48]

#define GI_DENOISER // Variance-guided a-trous spatial filter.
#define GI_DENOISER_PASSES 2 // [1 2 3]

//==============================================================================
// REFLECTIONS
//==============================================================================

#define SSR_ENABLED // Screen-space reflections.
#define SSR_STEPS 24 // [8 12 16 24 32 48 64]
#define SSR_REFINE_STEPS 6 // [0 2 4 6 8 12]
#define SSR_THICKNESS 0.4 // [0.1 0.2 0.3 0.4 0.6 1.0 2.0]

#define SSR_ROUGH_REFLECTIONS // Cone-traced blur for non-mirror surfaces.
#define SSR_ROUGH_SAMPLES 4 // [1 2 3 4 6 8]

// Reflections are disabled above this roughness to save time; they contribute
// almost nothing visually but cost a full trace.
#define SSR_ROUGHNESS_CUTOFF 0.6 // [0.2 0.3 0.4 0.5 0.6 0.8 1.0]

#define SSR_TEMPORAL // Accumulate reflections across frames to cut noise.

//==============================================================================
// MATERIALS / PBR
//==============================================================================

// 0 = always use the vanilla heuristic, 1 = always assume LabPBR,
// 2 = auto-detect via MC_TEXTURE_FORMAT_LAB_PBR
#define PBR_MODE 2 // [0 1 2]

#define NORMAL_MAP_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0]

#define POM_ENABLED // Parallax occlusion mapping (needs a LabPBR height map).
#define POM_DEPTH 0.20 // [0.05 0.10 0.15 0.20 0.25 0.35 0.50 0.75 1.00]
#define POM_STEPS 24 // [8 12 16 24 32 48 64 128]
#define POM_DISTANCE 24.0 // [8.0 16.0 24.0 32.0 48.0 64.0]
#define POM_SHADOW // Self-shadowing of parallax surfaces.

#define SUBSURFACE_SCATTERING // Light transmission through foliage and similar.
#define SSS_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0]

//==============================================================================
// WETNESS / WEATHER
//==============================================================================

#define WETNESS_ENABLED // Rain darkens albedo and smooths roughness.
#define WETNESS_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5]
#define PUDDLES // Noise-driven puddles on upward-facing surfaces.
#define PUDDLE_SIZE 1.0 // [0.5 0.75 1.0 1.5 2.0 3.0]
#define RAIN_RIPPLES // Animated ripple normals on wet horizontal surfaces.

#define SNOW_MATERIAL // Snow gets higher albedo, sheen and subsurface response.

//==============================================================================
// WATER
//==============================================================================

#define WATER_WAVES
#define WATER_WAVE_HEIGHT 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define WATER_WAVE_SPEED 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define WATER_WAVE_OCTAVES 5 // [2 3 4 5 6 8]

#define WATER_REFRACTION
#define WATER_REFRACTION_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0]

// Beer-Lambert absorption distance in blocks. Lower = water darkens faster.
#define WATER_ABSORPTION_DISTANCE 12.0 // [2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0]
#define WATER_SCATTERING 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0]

#define WATER_CAUSTICS
#define WATER_CAUSTICS_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define WATER_CAUSTICS_SAMPLES 4 // [1 2 4 6 8]

#define WATER_FOAM
#define WATER_FOAM_DISTANCE 0.6 // [0.2 0.4 0.6 0.8 1.2 2.0]

//==============================================================================
// ATMOSPHERE
//==============================================================================

// Ray-march steps for the sky-view LUT. Affects sky quality, not scene cost.
#define ATMOSPHERE_STEPS 24 // [8 12 16 24 32 48]

// Multiple-scattering approximation makes the sky less dark at the horizon.
#define ATMOSPHERE_MULTISCATTER

#define STARS_ENABLED
#define STARS_INTENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]

//==============================================================================
// FOG
//==============================================================================

#define FOG_ENABLED
#define FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]

#define HEIGHT_FOG // Exponential density falloff with altitude.
#define HEIGHT_FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define HEIGHT_FOG_FALLOFF 24.0 // [8.0 12.0 16.0 24.0 32.0 48.0 64.0]

#define CAVE_FOG // Dense, unlit fog underground where there is no sky access.
#define CAVE_FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0]

//==============================================================================
// VOLUMETRIC LIGHTING
//==============================================================================

#define VOLUMETRIC_LIGHT // God rays / light shafts through the shadow map.
#define VL_STEPS 16 // [4 8 12 16 24 32 48 64]
#define VL_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define VL_RESOLUTION_DIVISOR 2 // [1 2 3 4]

// Henyey-Greenstein anisotropy. Higher = more forward scattering (brighter
// rays when looking toward the sun).
#define VL_ANISOTROPY 0.7 // [0.0 0.2 0.4 0.6 0.7 0.8 0.9]

//==============================================================================
// CLOUDS
//==============================================================================

// 0 = off, 1 = fast 2D layer, 2 = volumetric
#define CLOUDS_MODE 2 // [0 1 2]
#define CLOUD_STEPS 32 // [8 12 16 24 32 48 64 96]
#define CLOUD_LIGHT_STEPS 5 // [2 3 4 5 6 8]
#define CLOUD_DENSITY 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0]
#define CLOUD_COVERAGE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0]
#define CLOUD_SPEED 1.0 // [0.0 0.25 0.5 1.0 1.5 2.0 4.0]
#define CLOUD_ALTITUDE 320.0 // [160.0 220.0 260.0 320.0 400.0 500.0 700.0]
#define CLOUD_THICKNESS 180.0 // [60.0 100.0 140.0 180.0 240.0 320.0]
#define CLOUD_SHADOWS // Clouds cast shadows onto the world.
#define CLOUD_RESOLUTION_DIVISOR 2 // [1 2 3 4]

//==============================================================================
// ANTI-ALIASING
//==============================================================================

// 0 = off, 1 = FXAA, 2 = TAA
#define AA_MODE 2 // [0 1 2]

#define TAA_STRENGTH 0.92 // [0.50 0.60 0.70 0.80 0.85 0.90 0.92 0.95 0.97]
#define TAA_SHARPEN 0.45 // [0.0 0.15 0.30 0.45 0.60 0.80 1.0]

//==============================================================================
// BLOOM
//==============================================================================

#define BLOOM_ENABLED
#define BLOOM_STRENGTH 0.045 // [0.0 0.01 0.02 0.03 0.045 0.06 0.08 0.12 0.20]
#define BLOOM_MIPS 6 // [3 4 5 6 7]
#define BLOOM_RADIUS 1.0 // [0.5 0.75 1.0 1.25 1.5 2.0]

//==============================================================================
// EXPOSURE
//==============================================================================

// 0 = manual, 1 = automatic (metered eye adaptation)
#define EXPOSURE_MODE 1 // [0 1]

/*
 * Used only when EXPOSURE_MODE is Manual.
 *
 * Scene radiance is in physical-ish units: SUN_INTENSITY is a radiance value,
 * not a screen brightness. 0.25 puts a mid-grey surface in full daylight on a
 * well-exposed midtone, which makes it the right fixed value if you prefer
 * exposure not to move - at the cost of dark nights.
 */
#define MANUAL_EXPOSURE 0.25 // [0.05 0.1 0.15 0.2 0.25 0.35 0.5 0.75 1.0 1.5 2.0 4.0 8.0]

#define EXPOSURE_SPEED_UP 2.5 // [0.5 1.0 1.5 2.0 2.5 3.5 5.0 8.0]
#define EXPOSURE_SPEED_DOWN 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0 5.0]
#define EXPOSURE_MIN 0.06 // [0.01 0.02 0.04 0.06 0.10 0.20 0.50]
#define EXPOSURE_MAX 8.0 // [1.0 2.0 4.0 8.0 16.0 32.0]

// Which part of the luminance histogram to key on, as fractions.
#define EXPOSURE_LOW_PERCENT 0.55 // [0.20 0.35 0.45 0.55 0.65 0.75]
#define EXPOSURE_HIGH_PERCENT 0.92 // [0.70 0.80 0.85 0.92 0.96 0.99]

//==============================================================================
// TONE MAPPING & COLOR GRADING
//==============================================================================

// 0 = Reinhard, 1 = ACES, 2 = AgX, 3 = Khronos Neutral
#define TONEMAP 1 // [0 1 2 3]

#define POST_SATURATION 1.0 // [0.0 0.5 0.75 0.9 1.0 1.1 1.25 1.5 2.0]
#define POST_VIBRANCE 1.0 // [0.0 0.5 0.75 0.9 1.0 1.1 1.25 1.5 2.0]
#define POST_CONTRAST 1.0 // [0.5 0.75 0.9 1.0 1.1 1.25 1.5 2.0]
#define POST_GAMMA 1.0 // [0.6 0.7 0.8 0.9 1.0 1.1 1.2 1.4]
#define POST_EXPOSURE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 4.0]

// White-balance shift in Kelvin. 6500 is neutral; lower is warmer.
#define POST_TEMPERATURE 6500 // [3000 3500 4000 4500 5000 5500 6000 6500 7000 7500 8000 9000 10000]
#define POST_TINT 0.0 // [-1.0 -0.75 -0.5 -0.25 0.0 0.25 0.5 0.75 1.0]

//==============================================================================
// DEPTH OF FIELD
//==============================================================================

//#define DOF_ENABLED
#define DOF_SAMPLES 24 // [6 12 18 24 32 48 64]

// 0 = autofocus on the screen centre, 1 = fixed distance
#define DOF_FOCUS_MODE 0 // [0 1]
#define DOF_FOCUS_DISTANCE 12.0 // [1.0 2.0 4.0 8.0 12.0 24.0 48.0 96.0]
#define DOF_FOCAL_LENGTH 50.0 // [18.0 24.0 35.0 50.0 85.0 135.0 200.0]
#define DOF_APERTURE 2.8 // [1.4 1.8 2.0 2.8 4.0 5.6 8.0 11.0 16.0]
#define DOF_FOCUS_SPEED 3.0 // [0.5 1.0 2.0 3.0 5.0 8.0]

//==============================================================================
// MOTION BLUR
//==============================================================================

// 0 = off, 1 = low, 2 = medium, 3 = high
#define MOTION_BLUR 0 // [0 1 2 3]
#define MOTION_BLUR_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0]

//==============================================================================
// LENS EFFECTS
//==============================================================================

#define VIGNETTE
#define VIGNETTE_STRENGTH 0.25 // [0.0 0.1 0.15 0.25 0.35 0.5 0.75 1.0]

//#define CHROMATIC_ABERRATION
#define CA_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0]

//#define FILM_GRAIN
#define GRAIN_STRENGTH 0.4 // [0.1 0.2 0.3 0.4 0.6 0.8 1.2]

//#define LENS_FLARE
#define LENS_FLARE_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0]

//#define LENS_DIRT
#define LENS_DIRT_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0]

//==============================================================================
// DEBUG
//==============================================================================

/*
 *  0 = off              1 = albedo           2 = normals
 *  3 = depth            4 = roughness        5 = metallic / F0
 *  6 = emissive         7 = lightmap         8 = ambient occlusion
 *  9 = shadows         10 = direct lighting 11 = global illumination
 * 12 = reflections     13 = volumetrics     14 = motion vectors
 * 15 = material id
 */
#define DEBUG_MODE 0 // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15]

#endif // ASTRA_SETTINGS_GLSL
