#ifndef ASTRA_WAVES_GLSL
#define ASTRA_WAVES_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Water wave simulation.
 *
 * A sum of travelling noise octaves over world position. Each octave moves in
 * its own direction at its own speed, which is what stops the surface reading
 * as one scrolling texture: real water has a large slow swell with faster, finer
 * chop riding on top, and the two do not move together.
 *
 * The height field is evaluated in world space rather than in texture space, so
 * waves are continuous across chunk boundaries and do not repeat per block.
 */

//==============================================================================
// HEIGHT FIELD
//==============================================================================

/*
 * Wave height at a world position.
 *
 * Returns a value centred on zero, in blocks.
 *
 * Octaves alternate direction rather than all drifting the same way. A single
 * direction makes the whole surface look like it is being dragged; opposing
 * directions produce interference, which is what real open water does.
 */
float waveHeight(vec2 worldXZ, int octaves) {
    float time = frameTimeCounter * WATER_WAVE_SPEED;

    float height = 0.0;
    float amplitude = 1.0;
    float frequency = 0.12;
    float normalization = 0.0;

    for (int i = 0; i < octaves; i++) {
        // Each octave travels in a different direction, rotated by an angle
        // that does not divide evenly into a full turn, so the pattern never
        // aligns with itself.
        float angle = float(i) * 2.399963;
        vec2 direction = vec2(cos(angle), sin(angle));

        // Finer octaves travel faster, matching the dispersion of real waves
        // where short wavelengths propagate more slowly in deep water but are
        // dominated here by wind drift.
        float speed = 0.35 + float(i) * 0.22;

        vec2 p = worldXZ * frequency + direction * time * speed;

        // Centre the noise so octaves cancel rather than accumulate a bias.
        height += (valueNoise(p) - 0.5) * amplitude;
        normalization += amplitude;

        amplitude *= 0.55;
        frequency *= 1.9;
    }

    return (height / max(normalization, ASTRA_EPSILON))
         * WATER_WAVE_HEIGHT * 0.22;
}

//==============================================================================
// SURFACE NORMAL
//==============================================================================

/*
 * Normal of the wave surface at a world position.
 *
 * Central differences rather than an analytic derivative: value noise is not
 * smoothly differentiable in closed form, and the sample spacing doubles as a
 * low-pass filter that keeps distant water from aliasing into sparkle.
 *
 * The epsilon grows with view distance for exactly that reason - fine wave
 * detail beyond a few dozen blocks lands below one pixel and would shimmer.
 */
vec3 waveNormal(vec2 worldXZ, float viewDistance, int octaves) {
#if !ASTRA_ENABLE_WATER_WAVES
    return vec3(0.0, 1.0, 0.0);
#else
    float epsilon = 0.08 + viewDistance * 0.004;

    float centre = waveHeight(worldXZ, octaves);
    float dx = waveHeight(worldXZ + vec2(epsilon, 0.0), octaves) - centre;
    float dz = waveHeight(worldXZ + vec2(0.0, epsilon), octaves) - centre;

    /*
     * The gradient gives the tangent plane. Dividing by epsilon converts the
     * height difference into a slope; the cross product of the two tangents is
     * then the normal, which simplifies to this form for a height field.
     */
    vec3 normal = normalize(vec3(-dx / epsilon, 1.0, -dz / epsilon));

    /*
     * Flatten with distance. Beyond the point where individual waves are
     * smaller than a pixel, keeping full slope produces specular aliasing that
     * no amount of anti-aliasing removes.
     */
    float flatten = smoothstep(24.0, 120.0, viewDistance);

    return normalize(mix(normal, vec3(0.0, 1.0, 0.0), flatten));
#endif
}

//==============================================================================
// VERTEX DISPLACEMENT
//==============================================================================

/*
 * Vertical displacement applied to water vertices.
 *
 * Applied only to upward-facing surfaces. Displacing the side faces of a water
 * block would pull them away from the neighbouring column and open visible
 * gaps at chunk boundaries, where the two sides are transformed by different
 * draw calls and cannot be kept in agreement.
 *
 * `geoNormal` is the geometric normal in scene space.
 */
float waveDisplacement(vec3 worldPos, vec3 geoNormal) {
#if !ASTRA_ENABLE_WATER_WAVES
    return 0.0;
#else
    // Only the top surface moves.
    if (geoNormal.y < 0.9) return 0.0;

    return waveHeight(worldPos.xz, WATER_WAVE_OCTAVES);
#endif
}

#endif // ASTRA_WAVES_GLSL
