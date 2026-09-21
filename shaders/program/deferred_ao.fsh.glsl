#ifndef ASTRA_DEFERRED_AO_FSH
#define ASTRA_DEFERRED_AO_FSH

/*
 * AstraRealism - Ambient occlusion pass.
 *
 * The first deferred pass. Computes screen-space occlusion and folds it into
 * the ambient occlusion channel of the gbuffer, so the lighting pass that runs
 * next picks it up without needing to know where it came from.
 *
 * This must run before the lighting pass, which consumes the result.
 *
 * Writing back into colortex4 rather than into a buffer of its own costs
 * nothing: Iris ping-pongs colour attachments, so a pass reads the front copy
 * and writes the back one. It also keeps a buffer free for a later phase.
 */

#include "/lib/common/common.glsl"
#include "/lib/lighting/ao.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 gbufferD;

void main() {
    vec4 current = texture(colortex4, texcoord);

    float depth = texture(depthtex1, texcoord).r;

    // Sky has nothing to occlude it.
    if (isSky(depth)) {
        gbufferD = current;
        return;
    }

#if ASTRA_AO_MODE == 0
    gbufferD = current;
#else
    /*
     * The geometric normal, not the shading normal. Normal mapping perturbs the
     * surface to fake detail that is not in the depth buffer, so using it here
     * would search for horizons in directions the geometry does not actually
     * face and produce occlusion that does not match the silhouette.
     */
    vec3 geoNormal = decodeNormalOctahedral(texture(colortex2, texcoord).ba);

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    float ao = computeAmbientOcclusion(texcoord, depth, geoNormal, dither);

    /*
     * Combine with the material's own occlusion rather than replacing it.
     * A LabPBR pack ships baked occlusion for detail far below the resolution
     * of the depth buffer - the recesses between individual bricks - which
     * screen-space tracing can never recover. The two describe different
     * scales and multiply.
     */
    gbufferD = vec4(current.rg, current.b * ao, current.a);
#endif
}

#endif // ASTRA_DEFERRED_AO_FSH
