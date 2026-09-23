#ifndef ASTRA_DEFERRED_GI_FSH
#define ASTRA_DEFERRED_GI_FSH

/*
 * AstraRealism - Global illumination trace.
 *
 * Gathers indirect light and accumulates it temporally into colortex6.
 *
 * Runs before the lighting pass, which consumes the result. That ordering is
 * what forces the radiance source to be the previous frame - see colortex9 in
 * lib/common/buffers.glsl.
 *
 * Only one pixel per NxN tile traces each frame, cycling so every pixel is
 * refreshed every N^2 frames. The rest reuse their reprojected history. That is
 * how GI_RESOLUTION_DIVISOR earns its name without needing a reduced-resolution
 * render target.
 */

#include "/lib/common/common.glsl"
#include "/lib/lighting/gi.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 6,7 */
layout(location = 0) out vec4 giAccumulation;
layout(location = 1) out vec4 giMoments;

void main() {
    float depth = texture(depthtex1, texcoord).r;

    // Sky needs no indirect light; it is the source, not a receiver.
    if (isSky(depth)) {
        giAccumulation = vec4(0.0);
        giMoments = vec4(0.0);
        return;
    }

#if !ASTRA_ENABLE_GI
    giAccumulation = vec4(0.0);
    giMoments = vec4(0.0);
#else
    vec3 viewPos = screenToView(vec3(texcoord, depth));
    vec3 scenePos = viewToScene(viewPos);

    /*
     * The geometric normal, not the shading normal. GI rays are traced against
     * the depth buffer, which knows nothing about normal mapping - launching
     * them from a perturbed normal sends them into geometry that is not there.
     */
    vec3 geoNormal = decodeNormalOctahedral(texture(colortex2, texcoord).ba);

    HistorySample history = sampleHistory(colortex6, colortex13, scenePos, false);

    //--------------------------------------------------------------------------
    // Interleaved refresh
    //--------------------------------------------------------------------------

    bool trace = shouldTraceThisFrame(ivec2(gl_FragCoord.xy),
                                      GI_RESOLUTION_DIVISOR);

    /*
     * A pixel with no usable history must trace regardless of whose turn it is.
     * Otherwise a freshly disoccluded region stays black for up to N^2 frames,
     * which reads as a dark smear trailing the camera.
     */
    if (!history.valid) trace = true;

    if (!trace) {
        giAccumulation = history.value;
        giMoments = texture(colortex7, texcoord);
        return;
    }

    //--------------------------------------------------------------------------
    // Trace and accumulate
    //--------------------------------------------------------------------------

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec3 gathered = gatherGI(scenePos, geoNormal, dither, frameCounter);

    vec4 accumulated = accumulateTemporal(vec4(gathered, 1.0), history,
                                          GI_TEMPORAL_FRAMES);

    giAccumulation = accumulated;

    /*
     * First and second moments of luminance, carried so the spatial filter can
     * tell noise from genuine detail: a pixel whose value varies a lot across
     * recent frames is undersampled and should be filtered harder than one that
     * has been stable.
     */
    float luma = luminance(gathered);
    vec2 currentMoments = vec2(luma, luma * luma);

    vec2 previousMoments = history.valid ? texture(colortex7, texcoord).rg
                                         : currentMoments;

    float momentBlend = history.valid ? 0.2 : 1.0;

    giMoments = vec4(mix(previousMoments, currentMoments, momentBlend),
                     0.0, accumulated.a);
#endif
}

#endif // ASTRA_DEFERRED_GI_FSH
