#ifndef ASTRA_EXPOSURE_GLSL
#define ASTRA_EXPOSURE_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Automatic exposure.
 *
 * Scene radiance in this pack is in physical-ish units: SUN_INTENSITY is a
 * radiance value, not a screen brightness. The ratio between a sunlit field and
 * a torchlit cave is enormous, and no single fixed exposure can serve both -
 * which is why the pack looked correct outdoors and black in caves until this
 * existed.
 *
 * The eye solves this by adapting, and so does this: meter the scene, then move
 * toward that reading over time rather than snapping to it. Walking out of a
 * cave should briefly overexpose and then settle, because that is what actually
 * happens.
 *
 * Metering runs at a single pixel. Exposure is one number for the whole frame,
 * so computing it per-pixel would be the same work repeated two million times;
 * every other pixel simply copies the result forward.
 */

//==============================================================================
// METERING
//==============================================================================

// How many samples the meter takes. Enough to be stable, few enough that the
// percentile search over them stays trivial.
const int EXPOSURE_SAMPLES = 32;

/*
 * Gather scene luminance from across the frame.
 *
 * Sampled from a high mip level rather than the full-resolution image: each tap
 * then represents the average of a large region instead of one pixel, so a
 * single bright speck cannot swing the meter. It also makes 32 taps enough to
 * characterise the whole frame.
 *
 * The R2 sequence distributes the taps evenly without the clustering that
 * random sampling would produce at this count.
 */
void gatherLuminance(sampler2D sceneTex, out float samples[EXPOSURE_SAMPLES]) {
    // Roughly a 32x32 region per tap at 1080p.
    const float MIP_LEVEL = 5.0;

    for (int i = 0; i < EXPOSURE_SAMPLES; i++) {
        vec2 uv = r2Sequence(i);

        /*
         * Centre weighting. What the player is looking at matters more than the
         * corners of the frame, so taps are pulled toward the middle. Without
         * this, turning to face a bright sky darkens the subject in the centre.
         */
        uv = mix(uv, vec2(0.5), 0.35);

        vec3 colour = textureLod(sceneTex, uv, MIP_LEVEL).rgb;

        samples[i] = luminance(colour);
    }
}

/*
 * Value below which `fraction` of the samples fall.
 *
 * Found by bisecting on the threshold and counting, rather than by sorting.
 * Sorting 32 values in GLSL means either a bubble sort or a sorting network,
 * both of which are far more code than ten bisection steps - and this runs at
 * exactly one pixel, so the loop cost is irrelevant.
 */
float luminancePercentile(float samples[EXPOSURE_SAMPLES], float fraction) {
    float low = 0.0;
    float high = 0.0;

    for (int i = 0; i < EXPOSURE_SAMPLES; i++) {
        high = max(high, samples[i]);
    }

    float target = fraction * float(EXPOSURE_SAMPLES);

    for (int iteration = 0; iteration < 10; iteration++) {
        float mid = (low + high) * 0.5;

        float count = 0.0;
        for (int i = 0; i < EXPOSURE_SAMPLES; i++) {
            count += step(samples[i], mid);
        }

        if (count < target) {
            low = mid;
        } else {
            high = mid;
        }
    }

    return (low + high) * 0.5;
}

/*
 * The exposure this frame's content calls for, before adaptation.
 *
 * Metering on a percentile band rather than the mean is what makes it robust.
 * A mean is dragged around by the sky, by a lava pool, by any large bright or
 * dark region; the band between EXPOSURE_LOW_PERCENT and EXPOSURE_HIGH_PERCENT
 * describes the part of the image the viewer is actually looking at.
 */
float meterExposure(sampler2D sceneTex) {
    float samples[EXPOSURE_SAMPLES];
    gatherLuminance(sceneTex, samples);

    float low = luminancePercentile(samples, EXPOSURE_LOW_PERCENT);
    float high = luminancePercentile(samples, EXPOSURE_HIGH_PERCENT);

    /*
     * Geometric rather than arithmetic mean of the two. Luminance is perceived
     * logarithmically, so the midpoint between a dark and a bright reading
     * should be their geometric mean - the arithmetic one sits far too close to
     * the brighter value and underexposes every high-contrast scene.
     */
    float keyLuminance = sqrt(max(low * high, 1e-8));

    /*
     * Map the metered luminance onto middle grey. 0.18 is the reflectance of a
     * standard grey card and the value photographic metering is built around;
     * a correctly exposed mid-tone lands there.
     */
    const float MIDDLE_GREY = 0.18;

    float exposure = MIDDLE_GREY / max(keyLuminance, 1e-5);

    return clamp(exposure, EXPOSURE_MIN, EXPOSURE_MAX);
}

//==============================================================================
// ADAPTATION
//==============================================================================

/*
 * Move the stored exposure toward the target.
 *
 * Framerate-independent: the rate is per second, so adaptation takes the same
 * wall-clock time at 30 fps as at 144.
 *
 * Brightening and darkening have separate rates because the eye does too. Light
 * adaptation takes seconds; dark adaptation takes minutes. The defaults
 * compress that difference enormously - a faithful ratio would leave a player
 * blind for far too long - but keeping the asymmetry is what makes stepping out
 * of a cave feel different from stepping into one.
 */
float adaptExposure(float current, float target, float deltaTime) {
#if !ASTRA_ENABLE_AUTO_EXPOSURE
    return MANUAL_EXPOSURE;
#else
    // A stored value of zero means the buffer has not been written yet.
    if (current <= 0.0) return target;

    float rate = (target > current) ? EXPOSURE_SPEED_UP : EXPOSURE_SPEED_DOWN;

    /*
     * Interpolate in log space. Exposure is a multiplicative quantity, so a
     * linear approach from 0.1 to 8.0 would spend almost all its time in the
     * bright end and appear to stall in the dark end.
     */
    float logCurrent = log2(max(current, 1e-5));
    float logTarget = log2(max(target, 1e-5));

    float blended = mix(logCurrent, logTarget,
                        1.0 - exp(-rate * max(deltaTime, 0.0)));

    return clamp(exp2(blended), EXPOSURE_MIN, EXPOSURE_MAX);
#endif
}

//==============================================================================
// STORAGE
//==============================================================================

/*
 * The exposure buffer is a single meaningful texel at (0,0). These wrap that so
 * no caller has to remember the convention.
 *
 * Channels: r = exposure, g = autofocus distance for depth of field.
 */
vec4 readExposureState(sampler2D exposureTex) {
    return texelFetch(exposureTex, ivec2(0), 0);
}

float readExposure(sampler2D exposureTex) {
#if ASTRA_ENABLE_AUTO_EXPOSURE
    float stored = readExposureState(exposureTex).r;
    return stored > 0.0 ? stored : MANUAL_EXPOSURE;
#else
    return MANUAL_EXPOSURE;
#endif
}

#endif // ASTRA_EXPOSURE_GLSL
