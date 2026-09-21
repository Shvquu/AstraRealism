#ifndef ASTRA_CAUSTICS_GLSL
#define ASTRA_CAUSTICS_GLSL

#include "/lib/common/common.glsl"
#include "/lib/water/waves.glsl"

/*
 * AstraRealism - Water caustics.
 *
 * The wave surface acts as a lens. Where it is concave it focuses sunlight into
 * a bright line on whatever lies beneath; where it is convex it spreads the
 * light out. The result is the moving web of light on the bottom of a pool.
 *
 * The physically exact computation is photon mapping through a refracting
 * surface, which is far outside a real-time budget. This instead measures how
 * much the wave surface converges light at a point, which is the quantity that
 * produces the pattern, and is cheap enough to evaluate per pixel.
 */

//==============================================================================
// CONVERGENCE ESTIMATE
//==============================================================================

/*
 * How strongly the wave surface focuses light at a world position.
 *
 * Light entering the water is refracted by the surface normal. Two rays that
 * start parallel converge if the surface between their entry points curves
 * toward them, so measuring how much the refracted positions of neighbouring
 * samples move together measures convergence directly.
 *
 * Returns roughly 1.0 for neutral, above for focused, below for dispersed.
 */
float causticConvergence(vec2 worldXZ, float depth, vec3 lightDir) {
    // The offset used to probe convergence. Too small and it measures noise;
    // too large and it blurs the pattern into a uniform glow.
    float epsilon = 0.16;

    /*
     * How far a refracted ray travels sideways before reaching the depth in
     * question. Deeper water lets the rays separate further, which is why
     * caustics are tight and sharp in shallow water and broad and soft in deep
     * water.
     */
    float spread = clamp(depth, 0.1, 6.0) * 0.55;

    // Direction light travels across the surface, from the light's azimuth.
    vec2 lightXZ = normalize(lightDir.xz + vec2(1e-4));

    float area = 0.0;

    for (int i = 0; i < WATER_CAUSTICS_SAMPLES; i++) {
        // Offset each sample around the point so the estimate averages over a
        // small neighbourhood rather than depending on one probe.
        float angle = float(i) * ASTRA_TAU / float(WATER_CAUSTICS_SAMPLES);
        vec2 sampleOffset = vec2(cos(angle), sin(angle)) * epsilon;

        vec2 p = worldXZ + sampleOffset;

        // Wave normals at two nearby points.
        vec3 n0 = waveNormal(p, 0.0, min(WATER_WAVE_OCTAVES, 4));
        vec3 n1 = waveNormal(p + lightXZ * epsilon, 0.0,
                             min(WATER_WAVE_OCTAVES, 4));

        /*
         * Where the two refracted rays land, relative to where they entered.
         * Snell's law at a near-vertical interface reduces to a horizontal
         * displacement proportional to the normal's tilt, which is all that is
         * needed to compare two neighbouring rays.
         */
        vec2 hit0 = p + n0.xz * spread / WATER_IOR;
        vec2 hit1 = p + lightXZ * epsilon + n1.xz * spread / WATER_IOR;

        /*
         * If the rays land closer together than they started, light has been
         * concentrated. The ratio of the two separations is the intensity
         * multiplier, since the same energy now covers a smaller area.
         */
        float separation = length(hit1 - hit0);
        area += epsilon / max(separation, 0.01);
    }

    return area / float(WATER_CAUSTICS_SAMPLES);
}

//==============================================================================
// ENTRY POINT
//==============================================================================

/*
 * Caustic intensity multiplier for a submerged point.
 *
 * `worldPos`   world position of the lit surface under the water
 * `waterDepth` how much water is above it, in blocks
 * `lightDir`   direction toward the sun or moon, in scene space
 *
 * Returns a multiplier around 1.0 to apply to light reaching that point.
 */
float waterCaustics(vec3 worldPos, float waterDepth, vec3 lightDir) {
#if !ASTRA_ENABLE_CAUSTICS
    return 1.0;
#else
    if (waterDepth <= 0.0) return 1.0;

    float convergence = causticConvergence(worldPos.xz, waterDepth, lightDir);

    /*
     * Raised to a power to sharpen the pattern. The raw convergence is a broad
     * gradient; caustics in reality are high-contrast because the focused
     * regions are genuinely many times brighter than the dispersed ones.
     */
    float pattern = pow(saturate(convergence), 3.0);

    /*
     * Caustics need light to reach the surface at a workable angle. A low sun
     * enters at a grazing angle, reflects most of its energy away and refracts
     * what remains almost horizontally, so the pattern washes out.
     */
    float incidence = saturate(lightDir.y);

    // The pattern also dissipates with depth as the rays scatter.
    float depthFade = exp(-waterDepth * 0.12);

    float strength = pattern * incidence * depthFade * WATER_CAUSTICS_STRENGTH;

    /*
     * Centred on 1.0 rather than added: caustics redistribute light, they do
     * not create it. Focused areas brighten and the rest dims slightly, which
     * is what makes the effect read as light being moved around rather than a
     * glowing overlay.
     */
    return mix(0.72, 2.4, saturate(strength));
#endif
}

#endif // ASTRA_CAUSTICS_GLSL
