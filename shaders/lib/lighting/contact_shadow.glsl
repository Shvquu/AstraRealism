#ifndef ASTRA_CONTACT_SHADOW_GLSL
#define ASTRA_CONTACT_SHADOW_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Screen-space contact shadows.
 *
 * The shadow map has a fixed texel size. Detail finer than that texel - the
 * gap under a slab, the seam where a fence post meets the ground, the crease
 * between two blocks - cannot be represented, so those contacts render as
 * lit when they should be dark. The effect is that objects look like they are
 * hovering slightly.
 *
 * This marches a short ray from the surface toward the light through the depth
 * buffer. It only reaches a fraction of a block, which is exactly the range the
 * shadow map cannot resolve, so the two complement rather than duplicate each
 * other.
 *
 * Requires the scene depth buffer, so it is only available to passes that run
 * after the geometry they are shading. Forward-shaded translucents cannot use
 * it and fall back to the shadow map alone.
 */

/*
 * `viewPos`      surface position in view space
 * `lightDirView` unit vector toward the light, in view space
 * `dither`       per-pixel [0,1) value used to offset the ray start
 *
 * Returns 1.0 when unoccluded, 0.0 when occluded.
 */
float contactShadow(vec3 viewPos, vec3 lightDirView, float dither) {
#if !ASTRA_ENABLE_CONTACT_SHADOWS
    return 1.0;
#else
    float rayLength = CONTACT_SHADOW_LENGTH;
    float stepSize = rayLength / float(CONTACT_SHADOW_STEPS);

    /*
     * Start the ray a fraction of a step along, varied per pixel. Without the
     * jitter the fixed step positions produce concentric banding around every
     * contact; with it, the error becomes noise that TAA resolves.
     */
    vec3 rayPos = viewPos + lightDirView * stepSize * (0.5 + dither);

    /*
     * Maximum depth difference still treated as a hit.
     *
     * The depth buffer records only the front surface, so a sample behind it
     * might be inside a nearby object or might be far beyond it with empty
     * space between. Without an upper bound, a wall in the distance shadows
     * everything in front of it. Scaling with distance keeps the test
     * consistent as perspective compresses depth.
     */
    float thickness = 0.35 + length(viewPos) * 0.02;

    for (int i = 0; i < CONTACT_SHADOW_STEPS; i++) {
        rayPos += lightDirView * stepSize;

        vec3 screenPos = viewToScreen(rayPos);

        // Left the screen: no information, so assume unoccluded.
        if (any(lessThan(screenPos.xy, vec2(0.0)))
            || any(greaterThan(screenPos.xy, vec2(1.0)))) {
            return 1.0;
        }

        /*
         * depthtex1 excludes translucents deliberately. Using depthtex0 would
         * let a water surface cast a hard contact shadow onto the riverbed
         * beneath it, which is the opposite of how water behaves.
         */
        float sceneDepth = texture(depthtex1, screenPos.xy).r;

        if (isSky(sceneDepth)) continue;

        float sceneDistance = linearizeDepth(sceneDepth);
        float rayDistance = -rayPos.z;

        float difference = rayDistance - sceneDistance;

        // A small floor prevents the surface from shadowing itself at the
        // first step, where the ray has barely left it.
        if (difference > 0.02 && difference < thickness) {
            /*
             * Occlusion found early in the march is a genuine contact and
             * shadows fully. A hit at the very end of the ray is at the limit
             * of what this technique can resolve, so it fades out - otherwise
             * every object gets a hard ring exactly CONTACT_SHADOW_LENGTH away
             * from it, where the march happens to terminate.
             */
            float progress = float(i) / float(CONTACT_SHADOW_STEPS);

            return smoothstep(0.7, 1.0, progress);
        }
    }

    return 1.0;
#endif
}

#endif // ASTRA_CONTACT_SHADOW_GLSL
