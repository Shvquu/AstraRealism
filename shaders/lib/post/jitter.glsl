#ifndef ASTRA_JITTER_GLSL
#define ASTRA_JITTER_GLSL

#include "/lib/common/constants.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/uniforms.glsl"

/*
 * AstraRealism - TAA sub-pixel jitter.
 *
 * Lives outside lib/post/taa.glsl because both ends of the pipeline need it:
 * the gbuffers vertex stage applies the offset, and the TAA resolve has to
 * remove it again. Keeping the sequence in one file guarantees they agree.
 */

/*
 * Halton(2,3) gives a low-discrepancy set of sub-pixel positions: each new
 * sample lands in the largest remaining gap, so after N frames the pixel has
 * been sampled far more evenly than N random offsets would manage.
 *
 * Returned in NDC units. NDC spans 2.0 across viewWidth pixels, hence the
 * factor of two.
 */
vec2 taaJitterOffset(int frame) {
    int index = (frame % TAA_JITTER_COUNT) + 1;

    vec2 offset = vec2(halton(index, 2), halton(index, 3)) - 0.5;

    return offset * 2.0 / vec2(viewWidth, viewHeight);
}

// The same offset expressed in UV units, for undoing the jitter when sampling.
vec2 taaJitterUV(int frame) {
    return taaJitterOffset(frame) * 0.5;
}

#endif // ASTRA_JITTER_GLSL
