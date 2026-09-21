#ifndef ASTRA_DEFERRED_REFLECTIONS_FSH
#define ASTRA_DEFERRED_REFLECTIONS_FSH

/*
 * AstraRealism - Reflections, and the scene copy for translucents.
 *
 * The last pass before translucent geometry is drawn. It does two jobs that
 * both have to happen at exactly this point in the frame:
 *
 *   1. Adds screen-space reflections to opaque surfaces. This needs the scene
 *      to be fully lit, so it cannot run earlier; and it must not include
 *      water, so it cannot run later.
 *
 *   2. Copies the finished opaque scene into colortex9. Translucent geometry
 *      needs the colour behind it for refraction and absorption, and cannot
 *      read colortex0 while blending into it - Iris does not flip buffers
 *      within a gbuffers pass, so that would be a read-write hazard.
 *
 * It also records this frame's depth for the next frame's temporal
 * reprojection.
 */

#include "/lib/common/common.glsl"
#include "/lib/lighting/ssr.glsl"
#include "/lib/lighting/brdf.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0,8,9,13 */
layout(location = 0) out vec4 sceneColor;
layout(location = 1) out vec4 reflectionHistory;
layout(location = 2) out vec4 opaqueSceneCopy;
layout(location = 3) out vec4 previousFrameData;

void main() {
    vec3 color = texture(colortex0, texcoord).rgb;

    float depth = texture(depthtex1, texcoord).r;

    //--------------------------------------------------------------------------
    // Record this frame's depth for the next frame
    //
    // Written for every pixel including sky, because temporal reprojection has
    // to be able to tell "this was sky" from "there is no data here".
    //--------------------------------------------------------------------------

    float linearDistance = isSky(depth) ? far : length(screenToView(vec3(texcoord, depth)));
    previousFrameData = vec4(linearDistance, 0.0, 0.0, 1.0);

    //--------------------------------------------------------------------------
    // Sky needs no reflection, but still needs copying
    //--------------------------------------------------------------------------

    if (isSky(depth)) {
        sceneColor = vec4(color, 1.0);
        opaqueSceneCopy = vec4(color, 1.0);
        reflectionHistory = vec4(0.0);
        return;
    }

#if !ASTRA_ENABLE_SSR
    sceneColor = vec4(color, 1.0);
    opaqueSceneCopy = vec4(color, 1.0);
    reflectionHistory = vec4(0.0);
#else
    GBufferData g = decodeGBuffer(
        texture(colortex1, texcoord),
        texture(colortex2, texcoord),
        texture(colortex3, texcoord),
        texture(colortex4, texcoord)
    );

    /*
     * Water is shaded in the forward pass with its own reflection, and the
     * gbuffer here describes opaque geometry only. Rough surfaces are skipped
     * because their reflection is indistinguishable from the ambient term the
     * lighting pass already applied.
     */
    if (g.roughness > SSR_ROUGHNESS_CUTOFF) {
        sceneColor = vec4(color, 1.0);
        opaqueSceneCopy = vec4(color, 1.0);
        reflectionHistory = vec4(0.0);
        return;
    }

    vec3 scenePos = viewToScene(screenToView(vec3(texcoord, depth)));
    vec3 viewDir = normalize(-scenePos);

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    ReflectionResult reflection = computeReflection(
        scenePos, g.normal, g.roughness, colortex0, dither, frameCounter);

    vec3 reflected = accumulateReflection(
        reflection.color, scenePos, g.roughness, colortex8, colortex13);

    reflectionHistory = vec4(reflected, 1.0);

    //--------------------------------------------------------------------------
    // Weight the reflection by Fresnel
    //
    // The same reflectance curve the direct lighting uses, so a surface's
    // reflection and its highlight agree. Without this, reflections either
    // overwhelm the surface at normal incidence or fail to appear at grazing
    // angles where they should dominate.
    //--------------------------------------------------------------------------

    vec3 f0 = computeF0(g.albedo, g.f0);
    float ndotv = clampedDot(g.normal, viewDir);

    vec3 fresnel = fresnelSchlickRoughness(ndotv, f0, g.roughness);

    /*
     * Added, not blended.
     *
     * The two specular sources are kept mutually exclusive by roughness rather
     * than being reconciled here: computeLighting() skips its sky ambient
     * specular for any surface below SSR_ROUGHNESS_CUTOFF, which is exactly the
     * set this pass handles. Each surface therefore receives its specular from
     * one source only, and no energy is counted twice.
     */
    color += reflected * fresnel * g.ao;

    sceneColor = vec4(color, 1.0);
    opaqueSceneCopy = vec4(color, 1.0);
#endif
}

#endif // ASTRA_DEFERRED_REFLECTIONS_FSH
