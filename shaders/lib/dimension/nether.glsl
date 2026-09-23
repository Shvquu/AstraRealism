#ifndef ASTRA_DIM_NETHER_GLSL
#define ASTRA_DIM_NETHER_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - The Nether.
 *
 * The Nether has no sun, no sky and no horizon. It is an enclosed space lit
 * entirely from within: lava seas below, glowstone and fire scattered through
 * it, and a thick particulate haze that scatters all of it around.
 *
 * That makes its lighting model genuinely different from the overworld's rather
 * than a recolouring. There is no directional light to cast shadows, no
 * Rayleigh scattering to make a sky, and no altitude at which the air thins.
 * What there is instead:
 *
 *   - Ambient light that comes from BELOW, because the lava does. Surfaces
 *     facing down are brighter than surfaces facing up, inverting the
 *     overworld's most basic cue and doing more than any colour choice to make
 *     the place feel wrong in the right way.
 *   - Dense, near-uniform fog that limits sight to a few dozen blocks.
 *   - No height falloff: the haze fills the whole space evenly.
 */

//==============================================================================
// CONSTANTS
//==============================================================================

/*
 * Colour of the lava glow, as a blackbody.
 *
 * Molten basalt sits around 1200 K, which is a deep orange-red. Using a real
 * temperature rather than a picked colour keeps it consistent with the
 * blockLight and sun models, which are also blackbody-derived.
 */
const float NETHER_LAVA_TEMPERATURE = 1250.0;

// Ambient haze colour: the lava glow after scattering through the particulate.
const vec3 NETHER_HAZE_TINT = vec3(1.0, 0.42, 0.20);

//==============================================================================
// INTERFACE
//==============================================================================

bool dimensionHasSky() { return false; }

bool dimensionHasClouds() { return false; }

/*
 * What a view ray returns when it hits nothing.
 *
 * There is no sky, so this is the haze itself seen at infinite depth - fully
 * saturated in-scattering with no geometry behind it. Looking up through a
 * ceiling gap should show glowing murk, not a void.
 *
 * The fogColor uniform is used as a base because Minecraft varies it per
 * biome: crimson forests are redder, warped forests distinctly teal, soul sand
 * valleys colder. Ignoring it would flatten all five biomes into one.
 */
vec3 dimensionSkyRadiance(vec3 rayDir) {
    vec3 biomeTint = srgbToLinear(fogColor);

    vec3 glow = blackbodyToRGB(NETHER_LAVA_TEMPERATURE) * NETHER_HAZE_TINT;

    /*
     * Looking down is brighter: that is the direction the lava is. This is the
     * inverted vertical gradient that gives the Nether its character.
     */
    float downward = saturate(-rayDir.y * 0.5 + 0.5);
    float gradient = mix(0.55, 1.35, downward * downward);

    return mix(glow, biomeTint * 2.2, 0.55) * gradient * 0.22;
}

/*
 * Ambient irradiance reaching a surface.
 *
 * Weighted toward downward-facing normals, because the dominant light source is
 * the lava below. A surface's underside catching more light than its top is the
 * single most distinctive thing about standing in the Nether.
 *
 * Deliberately NOT gated by the sky lightmap. Minecraft reports a sky light
 * level of zero everywhere in the Nether, because there is no sky - so gating
 * on it, as the overworld correctly does, would leave the entire dimension lit
 * by block light alone and otherwise pitch black.
 *
 * The haze here fills the whole space and glows, so every surface receives it
 * regardless of how enclosed it is. `lightmapSky` is accepted only to keep the
 * interface uniform across dimensions.
 */
vec3 dimensionAmbientLight(vec3 normal, float lightmapSky) {
    vec3 biomeTint = srgbToLinear(fogColor);
    vec3 glow = blackbodyToRGB(NETHER_LAVA_TEMPERATURE) * NETHER_HAZE_TINT;

    vec3 base = mix(glow, biomeTint * 2.0, 0.45);

    // normal.y of -1 faces the lava, +1 faces the ceiling.
    float fromBelow = saturate(-normal.y * 0.5 + 0.5);

    float weight = mix(0.35, 1.0, fromBelow * fromBelow);

    return base * weight * ASTRA_PI * 0.30;
}

/*
 * Colour distant geometry fades into.
 *
 * `skyAccess` is meaningless here - there is no sky to have access to - so it
 * is ignored rather than being repurposed into something that would make the
 * fog inconsistent between open caverns and enclosed tunnels.
 */
vec3 dimensionFogColor(vec3 rayDir, float skyAccess) {
    return dimensionSkyRadiance(rayDir) * 1.15;
}

/*
 * Extinction coefficient for the Nether haze.
 *
 * Much denser than overworld air, and uniform: there is no altitude at which it
 * thins, so a distant ceiling is as hazy as a distant floor.
 *
 * Slightly wavelength-dependent in the opposite direction to air - the
 * particulate absorbs blue, which is part of why everything trends orange with
 * distance rather than simply getting dimmer.
 */
vec3 dimensionFogExtinction() {
    return vec3(0.0075, 0.0105, 0.0150) * FOG_DENSITY;
}

#endif // ASTRA_DIM_NETHER_GLSL
