#ifndef ASTRA_DIM_OVERWORLD_GLSL
#define ASTRA_DIM_OVERWORLD_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/lighting/blocklight.glsl"
#include "/lib/atmosphere/scattering.glsl"

/*
 * AstraRealism - Overworld.
 *
 * Thin wrappers over the atmosphere model built in Phase 1. They exist so the
 * lighting and fog code can call the same four functions in every dimension
 * rather than branching on macros at each call site.
 */

bool dimensionHasSky() { return true; }

bool dimensionHasClouds() { return true; }

vec3 dimensionSkyRadiance(vec3 rayDir) {
    return renderSky(rayDir);
}

/*
 * Ambient irradiance reaching a surface.
 *
 * Gated by the sky lightmap, because in the overworld ambient light IS
 * skylight: a block deep in a cave genuinely receives none of it.
 */
vec3 dimensionAmbientLight(vec3 normal, float lightmapSky) {
    return skyLightRadiance(lightmapSky, skyAmbientIrradiance(normal));
}

vec3 dimensionFogColor(vec3 rayDir, float skyAccess) {
    vec3 skyColour = skyRadianceFull(rayDir);

    /*
     * Cave fog has no sky contribution. Its colour is block light bouncing
     * around the cave - warm and dim. Blending toward the sky colour
     * underground is what makes most packs' caves look full of grey smoke.
     */
    vec3 caveColour = blackbodyToRGB(float(BLOCKLIGHT_TEMPERATURE)) * 0.015;

    return mix(caveColour, skyColour, saturate(skyAccess));
}

/*
 * Extinction coefficient per block.
 *
 * Chosen so that at default density the horizon a few hundred blocks out is
 * visibly hazy without being obscured. Slightly stronger in blue than red, like
 * a thin atmosphere - which is what it is.
 */
vec3 dimensionFogExtinction() {
    const float FOG_EXTINCTION_BASE = 0.0012;

    return vec3(FOG_EXTINCTION_BASE) * vec3(0.92, 1.0, 1.15) * FOG_DENSITY;
}

#endif // ASTRA_DIM_OVERWORLD_GLSL
