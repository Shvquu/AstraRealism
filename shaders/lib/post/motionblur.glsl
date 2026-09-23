#ifndef ASTRA_MOTIONBLUR_GLSL
#define ASTRA_MOTIONBLUR_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Motion blur.
 *
 * A camera shutter is open for a finite time, so anything moving during that
 * window smears along its path. Sampling along each pixel's screen-space motion
 * vector reproduces that.
 *
 * Off by default. It is a camera artifact rather than something the eye does,
 * and at interactive framerates many people find it obscures more than it adds.
 */

/*
 * Shutter fraction per quality level.
 *
 * Expressed as a fraction of the frame interval, which is what a real shutter
 * angle describes: 0.5 is a 180-degree shutter, the film standard. Higher
 * values smear further.
 */
float motionBlurShutter() {
#if MOTION_BLUR == 1
    return 0.25;
#elif MOTION_BLUR == 2
    return 0.5;
#elif MOTION_BLUR == 3
    return 0.85;
#else
    return 0.0;
#endif
}

int motionBlurSamples() {
#if MOTION_BLUR == 1
    return 5;
#elif MOTION_BLUR == 2
    return 9;
#elif MOTION_BLUR == 3
    return 15;
#else
    return 1;
#endif
}

/*
 * Blur along the screen-space motion vector.
 *
 * `scenePos` is the shaded point, so the motion vector accounts for both camera
 * movement and the point's own displacement.
 *
 * `screenAnchored` must be true for the held item, which does not move with the
 * world - without it the hand smears violently whenever the player walks.
 */
vec3 applyMotionBlur(sampler2D sceneTex, vec2 uv, vec3 scenePos,
                     bool screenAnchored, float dither) {
#if !ASTRA_ENABLE_MOTION_BLUR
    return texture(sceneTex, uv).rgb;
#else
    vec3 previousScreen = reprojectScene(scenePos, screenAnchored);

    vec2 motion = (uv - previousScreen.xy) * motionBlurShutter()
                * MOTION_BLUR_STRENGTH;

    /*
     * Cap the smear length. A pixel that reprojects far away - a fast pan, or a
     * disocclusion - would otherwise sample halfway across the screen and drag
     * unrelated colour into place.
     */
    float maxLength = 0.05;
    float motionLength = length(motion);

    if (motionLength < 1e-5) {
        return texture(sceneTex, uv).rgb;
    }

    if (motionLength > maxLength) {
        motion *= maxLength / motionLength;
    }

    int samples = motionBlurSamples();

    vec3 total = vec3(0.0);
    float weightSum = 0.0;

    for (int i = 0; i < samples; i++) {
        /*
         * Sample positions spread symmetrically around the current pixel, so
         * the blur straddles the shutter interval rather than trailing behind
         * it. Dithered to break up the banding a fixed spacing produces at low
         * sample counts.
         */
        float t = (float(i) + dither) / float(samples) - 0.5;

        vec2 sampleUV = uv + motion * t;

        if (any(lessThan(sampleUV, vec2(0.0)))
            || any(greaterThan(sampleUV, vec2(1.0)))) continue;

        // Slight centre weighting keeps the pixel's own colour dominant, which
        // preserves more detail than a flat box average.
        float weight = 1.0 - abs(t);

        total += texture(sceneTex, sampleUV).rgb * weight;
        weightSum += weight;
    }

    if (weightSum <= 0.0) return texture(sceneTex, uv).rgb;

    return total / weightSum;
#endif
}

#endif // ASTRA_MOTIONBLUR_GLSL
