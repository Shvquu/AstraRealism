#ifndef ASTRA_WETNESS_GLSL
#define ASTRA_WETNESS_GLSL

#include "/lib/common/common.glsl"
#include "/lib/material/material_id.glsl"

/*
 * AstraRealism - Wet surfaces, puddles and snow.
 *
 * Rain does not tint the world blue. What it actually does is deposit a thin
 * film of water on every exposed surface, and that film has three physical
 * consequences:
 *
 *   1. It is smooth, so it lowers roughness dramatically. This is why wet
 *      pavement reflects streetlights and dry pavement does not.
 *   2. It fills surface pores, raising the refractive index at the boundary and
 *      darkening the albedo. Porous stone darkens strongly; glazed tile barely
 *      changes.
 *   3. It is a dielectric with F0 near 0.02, so the specular response shifts
 *      toward water's own.
 *
 * All three follow from the same wetness value, which is why rain reads as rain
 * rather than as a filter.
 */

//==============================================================================
// EXPOSURE TO RAIN
//==============================================================================

/*
 * How wet a surface is, from 0 to 1.
 *
 * `wetness` is Minecraft's smoothed rain value, which keeps surfaces damp for a
 * while after the rain stops rather than snapping dry the instant it ends.
 *
 * Sky access gates it: rain does not reach the inside of a house. The response
 * is sharpened because the vanilla sky lightmap falls off gradually, and
 * without that a covered porch would get noticeably wet.
 */
float surfaceWetness(float skyLight, vec3 geoNormal, int materialId) {
#if !ASTRA_ENABLE_WETNESS
    return 0.0;
#else
    if (materialIgnoresWetness(materialId)) return 0.0;

    float exposure = smoothstep(0.55, 0.95, skyLight);

    // Upward-facing surfaces collect water; vertical faces only get what runs
    // down them, and overhangs stay dry.
    float facing = saturate(geoNormal.y * 0.5 + 0.5);
    facing = facing * facing;

    return saturate(wetness * exposure * mix(0.35, 1.0, facing))
         * WETNESS_STRENGTH;
#endif
}

//==============================================================================
// PUDDLES
//==============================================================================

/*
 * Puddle coverage at a world position.
 *
 * Two octaves of value noise: a large one deciding where water pools, and a
 * finer one breaking up the outline so puddles do not read as circles. The
 * result is thresholded rather than used directly, because a puddle has an
 * edge - a smooth gradient of wetness looks like a stain, not standing water.
 */
float puddleCoverage(vec3 worldPos, float skyLight, vec3 geoNormal) {
#if !ASTRA_ENABLE_PUDDLES
    return 0.0;
#else
    // Water only stands on surfaces that are close to level.
    float level = smoothstep(0.75, 0.95, geoNormal.y);
    if (level <= 0.0) return 0.0;

    float exposure = smoothstep(0.7, 0.95, skyLight);
    if (exposure <= 0.0) return 0.0;

    vec2 p = worldPos.xz / max(PUDDLE_SIZE * 6.0, 1.0);

    float shape = valueNoise(p) * 0.65 + valueNoise(p * 2.7) * 0.35;

    /*
     * The threshold moves with how long it has been raining, so puddles grow
     * outward from their deepest points instead of fading in uniformly.
     */
    float fill = saturate(wetness * 1.3);
    float coverage = smoothstep(0.62 - fill * 0.35, 0.72 - fill * 0.3, shape);

    return coverage * level * exposure;
#endif
}

//==============================================================================
// RAIN RIPPLES
//==============================================================================

/*
 * Normal perturbation from raindrops striking standing water.
 *
 * Each drop is a ring expanding from a point on a jittered grid. Cells are
 * given different phases so the impacts are not synchronised, which is what
 * separates this from a pulsing texture.
 *
 * Returns a tangent-space normal offset to add to the surface normal.
 */
vec2 rainRipples(vec3 worldPos, float wetAmount) {
#if !ASTRA_ENABLE_RAIN_RIPPLES
    return vec2(0.0);
#else
    if (rainStrength <= 0.01 || wetAmount <= 0.01) return vec2(0.0);

    // Ripples are small: roughly four per block.
    vec2 p = worldPos.xz * 4.0;
    vec2 cell = floor(p);
    vec2 local = fract(p) - 0.5;

    vec2 offset = vec2(0.0);

    // Three overlapping grids, so drops are not confined to one lattice.
    for (int i = 0; i < 3; i++) {
        vec2 shifted = cell + float(i) * 37.0;
        vec3 random = hash3(vec3(shifted, float(i)));

        // Each cell fires on its own cycle.
        float phase = fract(frameTimeCounter * 1.4 + random.x);

        // Only a fraction of cells are active at any moment.
        if (random.y > 0.35 + rainStrength * 0.4) continue;

        vec2 centre = (random.yz - 0.5) * 0.7;
        float dropDistance = length(local - centre + float(i) * 0.13);

        // Ring expands outward and fades as it grows.
        float radius = phase * 0.45;
        float ring = sin((dropDistance - radius) * 42.0);
        float envelope = exp(-abs(dropDistance - radius) * 14.0) * (1.0 - phase);

        offset += normalize(local - centre + 1e-4) * ring * envelope;
    }

    return offset * 0.06 * rainStrength * wetAmount;
#endif
}

//==============================================================================
// MATERIAL MODIFICATION
//==============================================================================

/*
 * Apply wetness to a surface's material properties.
 *
 * `porosity` drives how strongly the albedo darkens. A porous material absorbs
 * water into its surface, which traps light by internal reflection and makes it
 * visibly darker; a non-porous one only carries a film on top and barely
 * changes colour. That single parameter is why wet sandstone and wet glass
 * behave so differently.
 */
void applyWetness(inout vec3 albedo, inout float roughness, inout float f0,
                  inout vec3 normal, vec3 tangent, vec3 bitangent,
                  vec3 worldPos, vec3 geoNormal, float skyLight,
                  float porosity, int materialId) {
#if !ASTRA_ENABLE_WETNESS
    return;
#else
    float wet = surfaceWetness(skyLight, geoNormal, materialId);
    if (wet <= 0.001) return;

    float puddle = puddleCoverage(worldPos, skyLight, geoNormal) * saturate(wetness);

    // A puddle is standing water, so it is wetter than a damp surface can be.
    float totalWet = max(wet, puddle);

    //--------------------------------------------------------------------------
    // Albedo
    //--------------------------------------------------------------------------

    // Up to 30% darker at full saturation for a highly porous material.
    float darkening = 1.0 - totalWet * mix(0.08, 0.30, saturate(porosity));
    albedo *= darkening;

    //--------------------------------------------------------------------------
    // Roughness
    //--------------------------------------------------------------------------

    /*
     * The film smooths the surface toward open water. Interpolating roughness
     * directly rather than squaring or averaging keeps the transition
     * perceptually even, since roughness is already a perceptual parameter
     * here.
     */
    float wetRoughness = mix(0.12, 0.02, saturate(puddle));
    roughness = mix(roughness, wetRoughness, totalWet);

    //--------------------------------------------------------------------------
    // Reflectance
    //--------------------------------------------------------------------------

    // Metals keep their own F0; a film of water does not make copper less
    // metallic.
    if (!isMetal(f0)) {
        f0 = mix(f0, WATER_F0, totalWet * 0.8);
    }

    //--------------------------------------------------------------------------
    // Ripples
    //--------------------------------------------------------------------------

    vec2 ripple = rainRipples(worldPos, totalWet);

    if (dot(ripple, ripple) > 0.0) {
        normal = normalize(normal + tangent * ripple.x + bitangent * ripple.y);
    }

    /*
     * A puddle's surface is flat regardless of what lies beneath it. Blending
     * the normal toward vertical is what makes puddles read as water sitting on
     * cobblestone rather than as shiny cobblestone.
     */
    if (puddle > 0.0) {
        normal = normalize(mix(normal, vec3(0.0, 1.0, 0.0), puddle * 0.85));
    }
#endif
}

//==============================================================================
// SNOW
//==============================================================================

/*
 * Snow's optical behaviour.
 *
 * Snow is not white paint. It is a dense pack of ice crystals that scatters
 * light many times before it re-emerges, which produces three things a normal
 * diffuse surface does not have: very high albedo, a soft forward sheen from
 * the crystal facets, and strong subsurface transport that makes thin snow glow
 * when backlit.
 */
void applySnowMaterial(inout vec3 albedo, inout float roughness,
                       inout float f0, inout float porosity, int materialId) {
#if !defined(SNOW_MATERIAL)
    return;
#else
    if (materialId != MATID_SNOW) return;

    // Fresh snow reflects around 80-90% of visible light, far more than almost
    // any other natural surface.
    albedo = mix(albedo, vec3(0.92, 0.94, 0.98), 0.35);

    // Rough at the macro scale, but the packed surface has a faint sheen.
    roughness = min(roughness, 0.62);

    // Ice crystals are dielectric with a slightly higher index than most
    // minerals.
    f0 = max(f0, 0.035);

    // Drives the subsurface term in the BRDF.
    porosity = max(porosity, 0.9);
#endif
}

#endif // ASTRA_WETNESS_GLSL
