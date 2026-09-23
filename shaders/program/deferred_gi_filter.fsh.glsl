#ifndef ASTRA_DEFERRED_GI_FILTER_FSH
#define ASTRA_DEFERRED_GI_FILTER_FSH

/*
 * AstraRealism - Global illumination spatial filter.
 *
 * One a-trous wavelet iteration. Two passes use this body, distinguished by
 * ASTRA_GI_FILTER_STRIDE, which the stub sets: the first runs with tightly
 * spaced taps, the second with taps spread twice as far. Together they cover
 * the footprint of a much larger kernel for the cost of two 3x3 passes.
 *
 * The pass count is fixed at two because a-trous needs one render pass per
 * iteration and Iris decides the program list at compile time.
 * GI_DENOISER_PASSES therefore scales the stride rather than adding passes -
 * a wider spread at the same cost, which is the useful half of what more
 * iterations would buy.
 */

#include "/lib/common/common.glsl"
#include "/lib/lighting/gi.glsl"

#ifndef ASTRA_GI_FILTER_STRIDE
    #define ASTRA_GI_FILTER_STRIDE 1
#endif

in vec2 texcoord;

/* RENDERTARGETS: 6 */
layout(location = 0) out vec4 giFiltered;

void main() {
    vec4 current = texture(colortex6, texcoord);

    float depth = texture(depthtex1, texcoord).r;

    if (isSky(depth)) {
        giFiltered = current;
        return;
    }

#if !ASTRA_ENABLE_GI || !ASTRA_ENABLE_GI_DENOISER
    giFiltered = current;
#else
    vec3 geoNormal = decodeNormalOctahedral(texture(colortex2, texcoord).ba);

    /*
     * Variance from the moments buffer. A pixel that has only accumulated a few
     * frames, or whose value has been jumping about, is undersampled and needs
     * a wider filter; a converged one should be left alone so the filter does
     * not erase detail it took many frames to resolve.
     */
    vec4 moments = texture(colortex7, texcoord);
    float variance = max(moments.g - moments.r * moments.r, 0.0);
    float historyLength = max(moments.a, 1.0);

    float noisiness = saturate(variance * 8.0 + 4.0 / historyLength);

    int stride = ASTRA_GI_FILTER_STRIDE * GI_DENOISER_PASSES;

    // Widen further where the estimate is still noisy.
    stride = int(float(stride) * mix(0.6, 1.6, noisiness) + 0.5);
    stride = max(stride, 1);

    vec3 filtered = filterGI(colortex6, texcoord, depth, geoNormal, stride);

    giFiltered = vec4(filtered, current.a);
#endif
}

#endif // ASTRA_DEFERRED_GI_FILTER_FSH
