#ifndef ASTRA_TEMPORAL_GLSL
#define ASTRA_TEMPORAL_GLSL

#include "/lib/common/math.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/spaces.glsl"

/*
 * AstraRealism - Temporal interleaving and history reuse.
 *
 * Three systems in this pack are far too expensive to evaluate for every pixel
 * every frame: global illumination, volumetrics and volumetric clouds. All
 * three share the same solution, so it lives here once rather than being
 * reimplemented with slightly different bugs in each.
 *
 * The idea: divide the screen into NxN tiles and refresh one pixel of each tile
 * per frame, cycling through all N^2 positions. Every pixel is therefore
 * retraced every N^2 frames, and the rest of the time it reuses its own
 * reprojected history.
 *
 * Why this rather than Iris's `scale.<program>` directive, which renders a pass
 * at reduced resolution: `scale` takes a fixed value in shaders.properties and
 * cannot follow a user setting, and it renders into a sub-rectangle that every
 * later pass then has to account for. Interleaving honours the runtime option,
 * keeps full-resolution detail where the history is valid, and needs no
 * coordinate bookkeeping downstream.
 *
 * The cost is latency: a surface that has just come into view has no history,
 * and takes up to N^2 frames to converge.
 */

//==============================================================================
// INTERLEAVING
//==============================================================================

/*
 * Whether this pixel should do the expensive trace this frame.
 *
 * `divisor` of 1 means every pixel every frame.
 *
 * The cycle position is derived from the pixel's index within its tile, offset
 * by the frame counter, so the refreshed set sweeps the tile rather than
 * jumping about - a random order would cluster refreshes and leave visible
 * patches stale for longer than the cycle length suggests.
 */
bool shouldTraceThisFrame(ivec2 pixel, int divisor) {
    if (divisor <= 1) return true;

    int cycleLength = divisor * divisor;

    int indexInTile = (pixel.x % divisor) + (pixel.y % divisor) * divisor;

    return indexInTile == (frameCounter % cycleLength);
}

//==============================================================================
// HISTORY VALIDATION
//==============================================================================

struct HistorySample {
    vec4  value;
    bool  valid;
    float confidence;  // 1.0 for a solid match, falling off toward the edges
};

/*
 * Fetch a pixel's value from the previous frame, rejecting it where it no
 * longer describes the same surface.
 *
 * Two independent rejection tests, because they catch different failures:
 *
 *   Off-screen   the surface was not visible last frame, so there is nothing to
 *                reuse. Common when turning the camera.
 *   Depth        the pixel at that location last frame was at a different
 *                distance, meaning a different surface. This is what stops
 *                history trailing behind moving objects as a ghost.
 *
 * `previousDepthTex` holds last frame's linear view distance, written by the
 * reflections pass.
 */
HistorySample sampleHistory(sampler2D historyTex, sampler2D previousDepthTex,
                            vec3 scenePos, bool screenAnchored) {
    HistorySample result;
    result.value = vec4(0.0);
    result.valid = false;
    result.confidence = 0.0;

    vec3 previousScreen = reprojectScene(scenePos, screenAnchored);

    if (any(lessThan(previousScreen.xy, vec2(0.0)))
        || any(greaterThan(previousScreen.xy, vec2(1.0)))) {
        return result;
    }

    float previousDistance = texture(previousDepthTex, previousScreen.xy).r;
    float currentDistance = length(sceneToView(scenePos));

    /*
     * Tolerance scales with distance because depth precision does, and because
     * a fixed tolerance would reject valid history on distant surfaces where
     * reprojection is least accurate but most needed.
     */
    float tolerance = 0.06 + currentDistance * 0.03;

    if (abs(previousDistance - currentDistance) > tolerance) {
        return result;
    }

    result.value = texture(historyTex, previousScreen.xy);
    result.valid = true;

    /*
     * Fade confidence near the frame edge. A pixel reprojecting to within a few
     * texels of the border is partly sampling outside the previous frame, and
     * trusting it fully produces a bright or dark rim that creeps inward as the
     * camera turns.
     */
    vec2 edgeDistance = min(previousScreen.xy, 1.0 - previousScreen.xy);
    result.confidence = smoothstep(0.0, 0.02, min(edgeDistance.x, edgeDistance.y));

    return result;
}

//==============================================================================
// ACCUMULATION
//==============================================================================

/*
 * Blend a new sample into an exponential moving average, with the history
 * length carried alongside.
 *
 * The blend weight starts at 1 and falls toward 1/maxFrames as history builds.
 * That is what makes a freshly disoccluded pixel converge quickly - taking the
 * full new sample immediately - while a long-lived one stays stable. A fixed
 * weight cannot do both.
 *
 * `history.a` carries the accumulated frame count.
 */
vec4 accumulateTemporal(vec4 current, HistorySample history, int maxFrames) {
    if (!history.valid) {
        return vec4(current.rgb, 1.0);
    }

    float historyLength = min(history.value.a, float(maxFrames));

    // Shorten the effective history where confidence is low.
    historyLength *= history.confidence;

    float newLength = historyLength + 1.0;
    float blend = 1.0 / newLength;

    return vec4(mix(history.value.rgb, current.rgb, blend), newLength);
}

#endif // ASTRA_TEMPORAL_GLSL
