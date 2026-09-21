#ifndef ASTRA_DEBUG_GLSL
#define ASTRA_DEBUG_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Debug visualisations.
 *
 * Replaces the final image with a single intermediate buffer so a problem can
 * be traced to the pass that produced it. Every mode outputs display-ready
 * sRGB and bypasses tone mapping entirely - a debug view that has been graded
 * is not telling you what the buffer contains.
 *
 * Modes whose buffers do not exist yet in the current build render as a flat
 * mid-grey rather than as noise, so it is obvious the data is absent rather
 * than wrong.
 */

const vec3 ASTRA_DEBUG_UNAVAILABLE = vec3(0.25, 0.25, 0.28);

/*
 * Map a scalar to a perceptually ordered colour ramp.
 *
 * Greyscale hides detail at both ends; this ramp runs dark blue to cyan to
 * yellow to red, which keeps small differences legible across the whole range.
 */
vec3 debugRamp(float x) {
    x = saturate(x);

    vec3 c = vec3(0.0);
    c += vec3(0.05, 0.05, 0.35) * smoothstep(0.00, 0.25, 1.0 - abs(x - 0.00) * 4.0);
    c += vec3(0.00, 0.60, 0.80) * smoothstep(0.00, 0.25, 1.0 - abs(x - 0.33) * 4.0);
    c += vec3(0.95, 0.85, 0.10) * smoothstep(0.00, 0.25, 1.0 - abs(x - 0.66) * 4.0);
    c += vec3(0.95, 0.15, 0.10) * smoothstep(0.00, 0.25, 1.0 - abs(x - 1.00) * 4.0);

    return c;
}

// Distinct colour per integer id, for material classification views.
vec3 debugIdColor(int id) {
    // Golden-ratio hue stepping keeps neighbouring ids visually far apart.
    float hue = fract(float(id) * 0.61803398875);

    vec3 rgb = saturate(vec3(
        abs(hue * 6.0 - 3.0) - 1.0,
        2.0 - abs(hue * 6.0 - 2.0),
        2.0 - abs(hue * 6.0 - 4.0)
    ));

    return id == 0 ? vec3(0.15) : rgb;
}

//==============================================================================

/*
 * Produce the debug image for the current mode.
 *
 * Returns false when DEBUG_MODE is 0, so the caller proceeds with normal
 * output. The out-parameter is only written when true is returned.
 */
bool renderDebugView(vec2 uv, out vec3 debugColor) {
#if !ASTRA_DEBUG
    debugColor = vec3(0.0);
    return false;
#else
    float depth = texture(depthtex0, uv).r;

    GBufferData g = decodeGBuffer(
        texture(colortex1, uv),
        texture(colortex2, uv),
        texture(colortex3, uv),
        texture(colortex4, uv)
    );

    bool sky = isSky(depth);

    #if DEBUG_MODE == 1
        debugColor = sky ? vec3(0.0) : linearToSrgb(g.albedo);

    #elif DEBUG_MODE == 2
        // Remap from [-1,1] so a flat upward face reads as pale green.
        debugColor = sky ? vec3(0.0) : g.normal * 0.5 + 0.5;

    #elif DEBUG_MODE == 3
        // Linear distance, ramped. Raw hardware depth is almost entirely white
        // past a few blocks and shows nothing useful.
        float dist = sky ? far : linearizeDepth(depth);
        debugColor = debugRamp(dist / far);

    #elif DEBUG_MODE == 4
        debugColor = sky ? vec3(0.0) : debugRamp(g.roughness);

    #elif DEBUG_MODE == 5
        // Metals are flagged; dielectrics show their F0 on the ramp.
        debugColor = sky ? vec3(0.0)
                   : (isMetal(g.f0) ? vec3(1.0, 0.85, 0.2)
                                    : debugRamp(g.f0 * 4.0));

    #elif DEBUG_MODE == 6
        debugColor = sky ? vec3(0.0) : debugRamp(g.emissive);

    #elif DEBUG_MODE == 7
        // Red is block light, green is sky light.
        debugColor = sky ? vec3(0.0) : vec3(g.lightmap, 0.0);

    #elif DEBUG_MODE == 8
        debugColor = sky ? vec3(1.0) : vec3(g.ao);

    #elif DEBUG_MODE == 15
        debugColor = sky ? vec3(0.0) : debugIdColor(g.materialId);

    #else
        /*
         * Modes 9-14 read buffers produced by passes that arrive in later
         * phases (shadows, GI, reflections, volumetrics, motion vectors).
         * Flat grey makes it clear the buffer is not yet written rather than
         * showing whatever happens to be in memory.
         */
        debugColor = ASTRA_DEBUG_UNAVAILABLE;
    #endif

    return true;
#endif
}

#endif // ASTRA_DEBUG_GLSL
