#ifndef ASTRA_BLOOM_GLSL
#define ASTRA_BLOOM_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Bloom.
 *
 * Real lenses scatter a small fraction of incoming light across the whole
 * image. Bright sources therefore bleed into their surroundings, and the eye
 * reads that bleed as brightness beyond what the display can actually produce.
 * It is the main tool an SDR display has for suggesting HDR.
 *
 * Structure: bright pass, progressive downsample, progressive upsample with a
 * tent filter, combine. A single wide blur would be both far more expensive and
 * wrong - real scattering falls off over many scales at once, which is exactly
 * what a mip pyramid represents.
 *
 * The downsample uses the hardware mip chain rather than a chain of render
 * passes. Seven levels would otherwise mean seven passes; Iris generates the
 * pyramid in one step when a program declares colortex12MipmapEnabled. The
 * hardware filter is a box rather than the Karis-weighted 13-tap, so the
 * quality of the *upsample* matters more here than it would otherwise - hence
 * the tent filter below rather than a plain bilinear read.
 */

//==============================================================================
// BRIGHT PASS
//==============================================================================

/*
 * Extract what should bloom.
 *
 * Deliberately a soft knee rather than a hard threshold. A hard cutoff makes
 * bloom pop into existence as a surface crosses it, and the boundary is visible
 * as a moving outline on anything near the threshold.
 *
 * The threshold is in scene radiance, before exposure, so what blooms does not
 * change as the eye adapts - a torch should glow the same amount whether or not
 * you have just walked out of a cave.
 */
vec3 bloomBrightPass(vec3 colour) {
    // Roughly the radiance of a directly sunlit white surface. Below this,
    // nothing blooms.
    const float THRESHOLD = 1.0;
    const float KNEE = 0.7;

    float brightness = maxComponent(colour);

    // Quadratic knee: zero below threshold-knee, smooth through the threshold.
    float soft = brightness - THRESHOLD + KNEE;
    soft = clamp(soft, 0.0, 2.0 * KNEE);
    soft = soft * soft / (4.0 * KNEE + 1e-5);

    float contribution = max(soft, brightness - THRESHOLD) / max(brightness, 1e-5);

    /*
     * Clamped before it enters the pyramid. A single extremely bright texel -
     * the sun disc, a beacon - would otherwise dominate an entire mip level and
     * produce a large dim square instead of a glow.
     */
    return min(colour * contribution, vec3(64.0));
}

//==============================================================================
// UPSAMPLE
//==============================================================================

/*
 * 3x3 tent filter at a given mip level.
 *
 * This is where the quality comes from. Reading a mip level bilinearly
 * reproduces its box-filtered blockiness at full size, which shows as square
 * artifacts around bright sources. The tent weights neighbouring taps so that
 * the reconstruction is smooth, and applying it at every level during the
 * upward walk progressively removes the box character.
 */
vec3 bloomTentSample(sampler2D tex, vec2 uv, float level, float radius) {
    // Texel size at this mip, scaled by the user's radius setting.
    vec2 texelSize = radius / vec2(viewWidth, viewHeight) * exp2(level);

    vec3 result = vec3(0.0);

    // Weights of a 3x3 tent: centre 4, edges 2, corners 1, over 16.
    result += textureLod(tex, uv + vec2(-1.0, -1.0) * texelSize, level).rgb * 1.0;
    result += textureLod(tex, uv + vec2( 0.0, -1.0) * texelSize, level).rgb * 2.0;
    result += textureLod(tex, uv + vec2( 1.0, -1.0) * texelSize, level).rgb * 1.0;

    result += textureLod(tex, uv + vec2(-1.0,  0.0) * texelSize, level).rgb * 2.0;
    result += textureLod(tex, uv + vec2( 0.0,  0.0) * texelSize, level).rgb * 4.0;
    result += textureLod(tex, uv + vec2( 1.0,  0.0) * texelSize, level).rgb * 2.0;

    result += textureLod(tex, uv + vec2(-1.0,  1.0) * texelSize, level).rgb * 1.0;
    result += textureLod(tex, uv + vec2( 0.0,  1.0) * texelSize, level).rgb * 2.0;
    result += textureLod(tex, uv + vec2( 1.0,  1.0) * texelSize, level).rgb * 1.0;

    return result / 16.0;
}

/*
 * Walk the pyramid from the coarsest level down, accumulating.
 *
 * Each level contributes light scattered at its own scale: the coarse levels
 * give the broad halo, the fine ones the tight glow around the source. Summing
 * them is what produces a falloff that looks like real lens scatter rather than
 * a single Gaussian.
 *
 * Levels are weighted equally and the total normalised. Weighting coarse levels
 * more would give a wider, hazier bloom; the flat weighting keeps the result
 * anchored to its source.
 */
vec3 gatherBloom(sampler2D bloomTex, vec2 uv) {
#if !ASTRA_ENABLE_BLOOM
    return vec3(0.0);
#else
    vec3 total = vec3(0.0);
    float weightSum = 0.0;

    for (int level = 1; level <= BLOOM_MIPS; level++) {
        float weight = 1.0;

        total += bloomTentSample(bloomTex, uv, float(level), BLOOM_RADIUS) * weight;
        weightSum += weight;
    }

    return total / max(weightSum, 1.0);
#endif
}

//==============================================================================
// COMBINE
//==============================================================================

/*
 * Mix bloom into the scene.
 *
 * Interpolated rather than added. Adding bloom creates energy that was never in
 * the scene and progressively washes the image out as the strength rises;
 * interpolating redistributes it, which is what lens scatter physically does -
 * the light in the halo is light that did not reach its original pixel.
 */
vec3 applyBloom(vec3 scene, vec3 bloom) {
#if !ASTRA_ENABLE_BLOOM
    return scene;
#else
    return mix(scene, bloom, saturate(BLOOM_STRENGTH));
#endif
}

#endif // ASTRA_BLOOM_GLSL
