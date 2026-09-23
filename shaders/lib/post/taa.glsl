#ifndef ASTRA_TAA_GLSL
#define ASTRA_TAA_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Temporal anti-aliasing.
 *
 * Each frame the projection is nudged by a sub-pixel offset (lib/post/jitter.glsl),
 * so over several frames a pixel samples several positions within its own area.
 * Blending those samples is a genuine increase in sampling rate rather than a
 * blur - which is why TAA resolves edges that no amount of post-process
 * smoothing can, and why several systems in this pack depend on it to clean up
 * their own noise.
 *
 * The entire difficulty is deciding when the history is still valid. Blend too
 * eagerly and moving objects trail ghosts; reject too eagerly and the
 * accumulation never builds and the image shimmers. Neighbourhood clamping is
 * the standard answer and is what the bulk of this file implements.
 */

//==============================================================================
// COLOUR SPACE
//==============================================================================

/*
 * YCoCg conversion.
 *
 * Clamping is done in YCoCg rather than RGB because the axes are perceptually
 * meaningful there: luma separated from two chroma channels. An RGB bounding
 * box is badly shaped for real colour distributions and clips far more history
 * than necessary, which shows up as flicker on textured surfaces.
 */
vec3 rgbToYCoCg(vec3 c) {
    return vec3(
         0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
         0.5  * c.r              - 0.5  * c.b,
        -0.25 * c.r + 0.5 * c.g - 0.25 * c.b
    );
}

vec3 yCoCgToRGB(vec3 c) {
    float t = c.x - c.z;
    return vec3(t + c.y, c.x + c.z, t - c.y);
}

//==============================================================================
// TONE WEIGHTING
//==============================================================================

/*
 * Reversible tonemap applied before blending.
 *
 * Averaging HDR values directly lets a single very bright sample dominate the
 * result, which appears as a persistent bright speck that takes many frames to
 * fade - the classic TAA firefly. Compressing to a bounded range first weights
 * all samples comparably; the inverse restores the range afterwards.
 *
 * Karis, "High Quality Temporal Supersampling" (SIGGRAPH 2014).
 */
vec3 tonemapForBlend(vec3 c) {
    return c / (1.0 + luminance(c));
}

vec3 untonemapAfterBlend(vec3 c) {
    return c / max(1.0 - luminance(c), 1e-4);
}

//==============================================================================
// NEIGHBOURHOOD CLAMPING
//==============================================================================

struct NeighbourhoodBounds {
    vec3 minimum;
    vec3 maximum;
    vec3 average;
};

/*
 * Bounding box of the 3x3 neighbourhood around a pixel, in YCoCg.
 *
 * This is what makes TAA usable. If the history lies outside the range of
 * colours currently present around this pixel, it describes something that is
 * no longer there, and clamping it into the box removes the ghost while
 * retaining as much temporal information as remains valid.
 *
 * The variance-based bounds (Salvi, "An Excursion in Temporal Supersampling")
 * are used rather than the raw min/max: a single outlier neighbour would
 * otherwise widen the box enough to let a ghost through.
 */
NeighbourhoodBounds sampleNeighbourhood(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec3 moment1 = vec3(0.0);
    vec3 moment2 = vec3(0.0);

    vec3 boxMin = vec3(1e6);
    vec3 boxMax = vec3(-1e6);

    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(float(x), float(y)) * texelSize;

            vec3 c = rgbToYCoCg(tonemapForBlend(
                texture(tex, uv + offset).rgb));

            moment1 += c;
            moment2 += c * c;

            boxMin = min(boxMin, c);
            boxMax = max(boxMax, c);
        }
    }

    const float SAMPLES = 9.0;

    vec3 mean = moment1 / SAMPLES;
    vec3 variance = sqrt(max(moment2 / SAMPLES - mean * mean, 0.0));

    /*
     * Width of the box in standard deviations. Wider keeps more history and so
     * antialiases better; narrower rejects ghosts sooner. 1.25 is the usual
     * compromise, tightened slightly here because several other systems rely on
     * this pass and their noise should not be mistaken for detail.
     */
    const float VARIANCE_WIDTH = 1.25;

    NeighbourhoodBounds bounds;
    bounds.average = mean;
    bounds.minimum = max(mean - variance * VARIANCE_WIDTH, boxMin);
    bounds.maximum = min(mean + variance * VARIANCE_WIDTH, boxMax);

    return bounds;
}

/*
 * Clip the history toward the centre of the neighbourhood box.
 *
 * Clipping along the line from the box centre rather than clamping each channel
 * independently. A per-channel clamp moves the colour to a corner of the box,
 * which changes its hue; clipping preserves the direction and only shortens the
 * vector, so a rejected history desaturates toward the current frame instead of
 * shifting colour.
 */
vec3 clipToNeighbourhood(vec3 history, NeighbourhoodBounds bounds) {
    vec3 centre = 0.5 * (bounds.maximum + bounds.minimum);
    vec3 extent = 0.5 * (bounds.maximum - bounds.minimum) + 1e-5;

    vec3 offset = history - centre;
    vec3 units = abs(offset / extent);

    float maxUnit = maxComponent(units);

    if (maxUnit <= 1.0) return history;

    return centre + offset / maxUnit;
}

//==============================================================================
// SHARPENING
//==============================================================================

/*
 * Counteract the softening that temporal blending introduces.
 *
 * An unsharp mask against the 3x3 average. Applied after the resolve so it
 * operates on the accumulated result rather than on a single noisy frame, which
 * would amplify noise rather than detail.
 */
vec3 sharpenResolved(vec3 resolved, vec3 neighbourhoodAverage) {
    if (TAA_SHARPEN <= 0.0) return resolved;

    return resolved + (resolved - neighbourhoodAverage) * TAA_SHARPEN;
}

//==============================================================================
// RESOLVE
//==============================================================================

/*
 * Blend the current frame with its reprojected history.
 *
 * `motionLength` is how far this pixel moved on screen, in UV units. Fast
 * motion reduces the blend weight, because reprojection error grows with
 * distance and a long history is more likely to be stale.
 */
vec3 resolveTAA(sampler2D currentTex, sampler2D historyTex,
                vec2 uv, vec3 scenePos, bool screenAnchored) {
    vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

    vec3 current = texture(currentTex, uv).rgb;

#if ASTRA_AA_MODE != 2
    return current;
#else
    vec3 previousScreen = reprojectScene(scenePos, screenAnchored);

    // Nothing to blend with on the first frame or after a camera cut.
    if (any(lessThan(previousScreen.xy, vec2(0.0)))
        || any(greaterThan(previousScreen.xy, vec2(1.0)))) {
        return current;
    }

    NeighbourhoodBounds bounds = sampleNeighbourhood(currentTex, uv, texelSize);

    vec3 history = rgbToYCoCg(tonemapForBlend(
        texture(historyTex, previousScreen.xy).rgb));

    history = clipToNeighbourhood(history, bounds);

    vec3 currentCompressed = rgbToYCoCg(tonemapForBlend(current));

    //--------------------------------------------------------------------------
    // Blend weight
    //--------------------------------------------------------------------------

    float blend = TAA_STRENGTH;

    /*
     * Reduce the history weight under fast motion. Reprojection assumes the
     * surface moved rigidly; over a large screen-space distance that assumption
     * degrades, and holding a long history through it smears.
     */
    float motionLength = length(previousScreen.xy - uv);
    blend *= exp(-motionLength * 24.0);

    /*
     * Also reduce it near the frame edge, where part of the history was
     * sampled from outside the previous frame.
     */
    vec2 edgeDistance = min(previousScreen.xy, 1.0 - previousScreen.xy);
    blend *= smoothstep(0.0, 0.015, min(edgeDistance.x, edgeDistance.y));

    vec3 blended = mix(currentCompressed, history, saturate(blend));

    vec3 resolved = untonemapAfterBlend(yCoCgToRGB(blended));

    resolved = sharpenResolved(resolved,
                               untonemapAfterBlend(yCoCgToRGB(bounds.average)));

    return max(resolved, vec3(0.0));
#endif
}

//==============================================================================
// FXAA
//==============================================================================

/*
 * FXAA 3.11, reduced to its luma-edge core.
 *
 * Offered as the alternative for anyone who cannot tolerate temporal artifacts.
 * It is a spatial filter: it finds edges by luma contrast and blurs along them,
 * which softens aliasing without adding sampling rate. Systems in this pack
 * that rely on temporal accumulation will look noisier with this selected, and
 * the tooltip says so.
 */
vec3 applyFXAA(sampler2D tex, vec2 uv) {
#if ASTRA_AA_MODE != 1
    return texture(tex, uv).rgb;
#else
    vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

    float lumaCentre = luminance(texture(tex, uv).rgb);
    float lumaNW = luminance(texture(tex, uv + vec2(-1.0, -1.0) * texelSize).rgb);
    float lumaNE = luminance(texture(tex, uv + vec2( 1.0, -1.0) * texelSize).rgb);
    float lumaSW = luminance(texture(tex, uv + vec2(-1.0,  1.0) * texelSize).rgb);
    float lumaSE = luminance(texture(tex, uv + vec2( 1.0,  1.0) * texelSize).rgb);

    float lumaMin = min(lumaCentre, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaCentre, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    // Flat areas need no work, and filtering them would only soften texture.
    float range = lumaMax - lumaMin;
    if (range < max(0.03, lumaMax * 0.125)) {
        return texture(tex, uv).rgb;
    }

    // Edge direction from the luma gradient across the quad.
    vec2 direction = vec2(
        -((lumaNW + lumaNE) - (lumaSW + lumaSE)),
         ((lumaNW + lumaSW) - (lumaNE + lumaSE))
    );

    float reduction = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.03125, 1.0 / 128.0);
    float scale = 1.0 / (min(abs(direction.x), abs(direction.y)) + reduction);

    direction = clamp(direction * scale, vec2(-8.0), vec2(8.0)) * texelSize;

    // Two pairs of taps along the edge: a narrow pair that preserves detail and
    // a wide pair that smooths, with the wide pair rejected if it strays
    // outside the local luma range.
    vec3 narrow = 0.5 * (
        texture(tex, uv + direction * (1.0 / 3.0 - 0.5)).rgb +
        texture(tex, uv + direction * (2.0 / 3.0 - 0.5)).rgb);

    vec3 wide = narrow * 0.5 + 0.25 * (
        texture(tex, uv + direction * -0.5).rgb +
        texture(tex, uv + direction *  0.5).rgb);

    float lumaWide = luminance(wide);

    return (lumaWide < lumaMin || lumaWide > lumaMax) ? narrow : wide;
#endif
}

#endif // ASTRA_TAA_GLSL
