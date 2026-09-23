#ifndef ASTRA_GI_GLSL
#define ASTRA_GI_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Screen-space global illumination.
 *
 * Direct lighting alone leaves every shadowed surface lit only by the sky and a
 * constant ambient term, which is why shadows in most shader packs read as flat
 * blue holes. In reality light bounces: a red carpet tints the wall beside it, a
 * torch lights a whole corner of a room rather than the one block it touches.
 *
 * This traces short rays from each surface into the depth buffer and gathers
 * the radiance of whatever they hit.
 *
 * The radiance source is the PREVIOUS frame's lit scene, held in colortex9.
 * This is not a shortcut - it is structurally required. GI must run before the
 * lighting pass, because lighting consumes its result, so the current frame's
 * lit colour does not exist yet. Every real-time screen-space GI does this.
 */

//==============================================================================
// RAY GENERATION
//==============================================================================

/*
 * A cosine-weighted direction in the hemisphere around `normal`.
 *
 * Cosine weighting matters for more than quality: the Lambert BRDF contains a
 * cos(theta) term and the cosine-weighted PDF is cos(theta)/pi, so the two
 * cancel exactly. The estimator reduces to a plain average of the radiance
 * gathered, with no per-sample weight at all.
 */
vec3 giRayDirection(vec3 normal, vec2 xi) {
    vec3 tangent, bitangent;
    buildOrthonormalBasis(normal, tangent, bitangent);

    vec3 local = cosineWeightedHemisphere(xi);

    return normalize(tangent * local.x + bitangent * local.y + normal * local.z);
}

//==============================================================================
// RAY MARCH
//==============================================================================

/*
 * March one GI ray and return the radiance it gathered.
 *
 * `hit` reports whether the ray found geometry. A miss contributes nothing
 * rather than falling back to the sky: skylight already reaches the surface
 * through skyLightRadiance() in the lighting pass, and adding it again here
 * would double the sky's contribution to every open surface.
 */
vec3 traceGIRay(vec3 viewPos, vec3 viewDir, float dither, out bool hit) {
    hit = false;

    /*
     * GI is a local effect. Beyond a few blocks the inverse-square falloff has
     * already reduced a bounce to nothing, and a long ray only spends its step
     * budget crossing empty space where it cannot find the nearby geometry that
     * actually matters.
     */
    float rayLength = GI_RADIUS;

    float stepSize = rayLength / float(GI_STEPS);

    // Start offset along the ray so a surface cannot gather from itself.
    vec3 rayPos = viewPos + viewDir * stepSize * (0.6 + dither * 0.4);

    for (int i = 0; i < GI_STEPS; i++) {
        vec3 previousPos = rayPos;

        // Step sizes grow: near the origin the useful occluders are close
        // together, further out they are sparse.
        rayPos += viewDir * stepSize * (1.0 + float(i) * 0.15);

        vec3 screenPos = viewToScreen(rayPos);

        if (any(lessThan(screenPos.xy, vec2(0.0)))
            || any(greaterThan(screenPos.xy, vec2(1.0)))) {
            return vec3(0.0);
        }

        float sceneDepth = texture(depthtex1, screenPos.xy).r;
        if (isSky(sceneDepth)) continue;

        float sceneDistance = linearizeDepth(sceneDepth);
        float rayDistance = -rayPos.z;

        float delta = rayDistance - sceneDistance;

        if (delta <= 0.0) continue;

        /*
         * Thickness bound, as in the reflection trace: the depth buffer holds
         * only front surfaces, so a ray passing behind one may be inside it or
         * far beyond it. Without the bound, distant geometry would donate light
         * to everything in front of it.
         *
         * The bound is generous here - GI is low-frequency and a slightly wrong
         * hit costs far less than a missed bounce.
         */
        float thickness = 1.0 + sceneDistance * 0.1 + stepSize;
        if (delta > thickness) return vec3(0.0);

        hit = true;

        //----------------------------------------------------------------------
        // Gather radiance from the hit
        //----------------------------------------------------------------------

        vec3 radiance = texture(colortex9, screenPos.xy).rgb;

        /*
         * Reject light arriving from the back of the hit surface. Without this,
         * a wall lit brightly on its far side leaks that light through to the
         * dark side - the single most recognisable screen-space GI artifact.
         */
        vec3 hitNormal = decodeNormalOctahedral(
            texture(colortex2, screenPos.xy).ba);

        if (dot(hitNormal, viewToSceneDir(viewDir)) > -0.05) {
            return vec3(0.0);
        }

        /*
         * Distance falloff. The cosine-weighted estimator assumes a hemisphere
         * of constant radiance; a nearby bright surface subtends a much larger
         * solid angle than a distant one, and this restores that relationship
         * without needing the full form factor.
         */
        float hitDistance = length(rayPos - viewPos);
        float falloff = 1.0 / (1.0 + hitDistance * hitDistance * 0.08);

        return radiance * falloff;
    }

    return vec3(0.0);
}

//==============================================================================
// GATHER
//==============================================================================

/*
 * Indirect radiance arriving at a surface, before temporal accumulation.
 */
vec3 gatherGI(vec3 scenePos, vec3 normal, float dither, int frame) {
#if !ASTRA_ENABLE_GI
    return vec3(0.0);
#else
    vec3 viewPos = sceneToView(scenePos);

    vec3 total = vec3(0.0);

    for (int i = 0; i < GI_SAMPLES; i++) {
        /*
         * Decorrelate across sample, pixel and frame. Using the same directions
         * every frame would make temporal accumulation converge on a biased
         * estimate rather than the true integral - it would average the same
         * few rays more precisely instead of exploring the hemisphere.
         */
        vec2 xi = r2Sequence(i + frame * GI_SAMPLES);
        xi = fract(xi + dither);

        vec3 rayDir = giRayDirection(normal, xi);
        vec3 viewRayDir = normalize(sceneToViewDir(rayDir));

        bool hit;
        total += traceGIRay(viewPos, viewRayDir, dither, hit);
    }

    // Plain average: the cosine weight and the PDF cancelled in giRayDirection.
    return total / float(GI_SAMPLES);
#endif
}

//==============================================================================
// SPATIAL FILTER
//==============================================================================

/*
 * One a-trous wavelet iteration over the GI buffer.
 *
 * A-trous is a blur whose taps spread further apart each iteration while the
 * kernel stays the same size, so two passes with strides 1 and 2 cover the
 * footprint of a much larger kernel at a fraction of the cost.
 *
 * The edge-stopping weights are what make it usable: neighbours are rejected by
 * depth, by normal, and by how much their value differs from the centre.
 * Without them the filter would smear indirect light across silhouettes and
 * through walls.
 *
 * Note the pass count is fixed at two. A-trous needs one render pass per
 * iteration and the number of passes is decided at compile time, so
 * GI_DENOISER_PASSES controls the stride rather than the count.
 */
vec3 filterGI(sampler2D giTex, vec2 uv, float centreDepth, vec3 centreNormal,
              int stride) {
#if !ASTRA_ENABLE_GI_DENOISER
    return texture(giTex, uv).rgb;
#else
    vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

    vec3 centre = texture(giTex, uv).rgb;
    float centreDistance = linearizeDepth(centreDepth);
    float centreLuma = luminance(centre);

    // 3x3 B-spline kernel, the standard a-trous weights.
    const float kernel[3] = float[3](0.375, 0.25, 0.0625);

    vec3 total = centre * kernel[0] * kernel[0];
    float weightSum = kernel[0] * kernel[0];

    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            if (x == 0 && y == 0) continue;

            vec2 offset = vec2(float(x), float(y)) * float(stride) * texelSize;
            vec2 sampleUV = uv + offset;

            if (any(lessThan(sampleUV, vec2(0.0)))
                || any(greaterThan(sampleUV, vec2(1.0)))) continue;

            float sampleDepth = texture(depthtex1, sampleUV).r;
            if (isSky(sampleDepth)) continue;

            vec3 sampleNormal = decodeNormalOctahedral(
                texture(colortex2, sampleUV).ba);
            vec3 sampleValue = texture(giTex, sampleUV).rgb;

            // Depth: reject anything on a different surface.
            float depthWeight = exp(-abs(linearizeDepth(sampleDepth) - centreDistance)
                                    / max(centreDistance * 0.08, 0.05));

            // Normal: reject anything facing a different way.
            float normalWeight = pow(saturate(dot(sampleNormal, centreNormal)), 32.0);

            /*
             * Luminance: reject outliers. A single ray that happened to hit
             * something very bright would otherwise smear across the
             * neighbourhood as a blob, which reads as a light leak.
             */
            float lumaWeight = exp(-abs(luminance(sampleValue) - centreLuma)
                                   / (centreLuma * 0.6 + 0.05));

            float spatial = kernel[abs(x)] * kernel[abs(y)];
            float weight = spatial * depthWeight * normalWeight * lumaWeight;

            total += sampleValue * weight;
            weightSum += weight;
        }
    }

    if (weightSum <= 0.0) return centre;

    return total / weightSum;
#endif
}

#endif // ASTRA_GI_GLSL
