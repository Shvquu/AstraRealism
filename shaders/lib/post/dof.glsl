#ifndef ASTRA_DOF_GLSL
#define ASTRA_DOF_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Depth of field.
 *
 * A real lens focuses one plane sharply; everything else projects as a disc
 * rather than a point, and the further from focus the larger the disc. That
 * disc is the circle of confusion, and computing it from an actual thin-lens
 * model rather than a depth-based blur factor is what makes the falloff behave
 * correctly - near and far blur at different rates, and the effect responds to
 * aperture and focal length the way a camera does.
 *
 * Off by default. It is a cinematic tool that costs gameplay readability.
 */

//==============================================================================
// CIRCLE OF CONFUSION
//==============================================================================

/*
 * Diameter of the circle of confusion, in millimetres on the sensor.
 *
 * The thin-lens relation: for a lens of focal length f at aperture N focused at
 * distance S1, an object at S2 images as a disc of
 *
 *     C = |S2 - S1| / S2  *  f^2 / (N * (S1 - f))
 *
 * Distances arrive in blocks and are treated as metres, which makes a
 * Minecraft block a metre - a reasonable reading of the scale and the one that
 * makes the focal length settings mean what a photographer expects.
 */
float circleOfConfusion(float sceneDistance, float focusDistance) {
    // Millimetres.
    float focalLength = DOF_FOCAL_LENGTH;
    float aperture = DOF_APERTURE;

    // Metres to millimetres.
    float subject = max(focusDistance, 0.1) * 1000.0;
    float target = max(sceneDistance, 0.1) * 1000.0;

    // The denominator vanishes when focused at the focal length itself.
    float denominator = aperture * max(subject - focalLength, 1.0);

    float coc = abs(target - subject) / target
              * (focalLength * focalLength) / denominator;

    return coc;
}

/*
 * Convert the sensor-space circle of confusion into a screen-space radius.
 *
 * A 36 mm sensor width is the 35 mm full-frame standard, which is the frame the
 * focal length values are quoted against - a 50 mm lens is "normal" only
 * relative to that format.
 */
float cocToScreenRadius(float coc) {
    const float SENSOR_WIDTH_MM = 36.0;

    float fraction = coc / SENSOR_WIDTH_MM;

    /*
     * Capped. A very out-of-focus background would otherwise produce a radius
     * of hundreds of pixels, which at any sane sample count degenerates into
     * visible overlapping discs rather than smooth bokeh.
     */
    return min(fraction * 0.5, 0.035);
}

//==============================================================================
// AUTOFOCUS
//==============================================================================

/*
 * Distance to whatever is at the centre of the screen.
 *
 * Sampled from a small region rather than a single texel, taking the nearest
 * hit. A single texel lands on a gap between leaves or a distant wall seen
 * through a fence and racks focus to infinity; taking the nearest of several
 * taps keeps focus on the object the player is actually aiming at.
 */
float autofocusDistance(sampler2D depthTex) {
    const int TAPS = 5;
    const float SPREAD = 0.012;

    float nearest = 1e6;

    for (int i = 0; i < TAPS; i++) {
        vec2 offset = (r2Sequence(i) - 0.5) * SPREAD;
        vec2 uv = vec2(0.5) + offset;

        float depth = texture(depthTex, uv).r;

        // The sky is not a focus target.
        if (isSky(depth)) continue;

        nearest = min(nearest, length(screenToView(vec3(uv, depth))));
    }

    return (nearest > 1e5) ? far * 0.5 : nearest;
}

/*
 * Smooth the focus distance over time.
 *
 * Instant refocusing looks wrong; real lenses take time to rack, and the eye
 * expects to see that. Interpolated in log space because focus distance is
 * perceptually multiplicative - a metre matters enormously at two metres and
 * not at all at two hundred.
 */
float adaptFocus(float current, float target, float deltaTime) {
    if (current <= 0.0) return target;

    float blend = 1.0 - exp(-DOF_FOCUS_SPEED * max(deltaTime, 0.0));

    return exp2(mix(log2(max(current, 0.1)), log2(max(target, 0.1)), blend));
}

//==============================================================================
// BOKEH GATHER
//==============================================================================

/*
 * Gather the circle of confusion around a pixel.
 *
 * A scatter-as-gather approach: rather than splatting each pixel's disc
 * outward, each pixel collects from the neighbourhood and accepts only those
 * samples whose own circle of confusion is large enough to reach it. That test
 * is what prevents a sharp foreground object bleeding into a blurred
 * background, which is the most obvious failure of a naive depth-weighted blur.
 */
vec3 gatherBokeh(sampler2D sceneTex, sampler2D depthTex, vec2 uv,
                 float focusDistance, float dither) {
#if !ASTRA_ENABLE_DOF
    return texture(sceneTex, uv).rgb;
#else
    float centreDepth = texture(depthTex, uv).r;

    float centreDistance = isSky(centreDepth)
        ? far
        : length(screenToView(vec3(uv, centreDepth)));

    float centreRadius = cocToScreenRadius(
        circleOfConfusion(centreDistance, focusDistance));

    // In focus and with nothing nearby large enough to reach here.
    if (centreRadius < 0.0008) {
        return texture(sceneTex, uv).rgb;
    }

    // Keep the disc circular regardless of window shape.
    vec2 aspectCorrection = vec2(1.0, aspectRatio);

    vec3 total = texture(sceneTex, uv).rgb;
    float weightSum = 1.0;

    float rotation = dither * ASTRA_TAU;

    for (int i = 0; i < DOF_SAMPLES; i++) {
        vec2 offset = vogelDisc(i, DOF_SAMPLES, rotation);

        vec2 sampleUV = uv + offset * centreRadius * aspectCorrection;

        if (any(lessThan(sampleUV, vec2(0.0)))
            || any(greaterThan(sampleUV, vec2(1.0)))) continue;

        float sampleDepth = texture(depthTex, sampleUV).r;
        float sampleDistance = isSky(sampleDepth)
            ? far
            : length(screenToView(vec3(sampleUV, sampleDepth)));

        float sampleRadius = cocToScreenRadius(
            circleOfConfusion(sampleDistance, focusDistance));

        /*
         * Accept the sample only if its own disc is wide enough to cover this
         * pixel. A sharp object in front of a blurred one therefore does not
         * contribute to the blur behind it, and keeps its own hard edge.
         */
        float reach = length(offset) * centreRadius;
        float weight = saturate((sampleRadius - reach) / max(centreRadius, 1e-4) + 1.0);

        // Nearer samples may legitimately bleed over farther ones, never the
        // other way around.
        if (sampleDistance > centreDistance) {
            weight *= saturate(sampleRadius / max(centreRadius, 1e-4));
        }

        total += texture(sceneTex, sampleUV).rgb * weight;
        weightSum += weight;
    }

    return total / max(weightSum, 1e-4);
#endif
}

#endif // ASTRA_DOF_GLSL
