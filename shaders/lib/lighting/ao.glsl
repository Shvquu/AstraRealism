#ifndef ASTRA_AO_GLSL
#define ASTRA_AO_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Ambient occlusion.
 *
 * Ambient light arrives from the whole sky hemisphere, but geometry blocks most
 * of it in creases, under overhangs and between blocks. Without modelling that,
 * every surface receives the same ambient term and the scene looks flat and
 * washed out no matter how good the direct lighting is.
 *
 * Two implementations:
 *
 *   SSAO  - counts how many nearby samples fall behind the depth buffer. Cheap,
 *           but it only approximates occlusion and tends to darken flat
 *           surfaces that happen to sit near geometry.
 *
 *   GTAO  - Jimenez et al., "Practical Real-Time Strategies for Accurate
 *           Indirect Occlusion" (2016). Searches for the actual horizon angle
 *           in each direction and integrates the visible arc analytically, so
 *           the result converges on the ground-truth answer rather than
 *           approximating it. Slightly more expensive, clearly better.
 *
 * Both are applied to indirect light only. Multiplying direct light by AO is a
 * common shortcut and it is what makes PBR scenes look muddy: a surface in
 * direct sunlight is lit regardless of how enclosed it is.
 */

//==============================================================================
// SHARED SAMPLING
//==============================================================================

/*
 * View-space position at a screen coordinate.
 *
 * depthtex1 excludes translucents deliberately - water should not cast ambient
 * occlusion onto the riverbed beneath it.
 */
vec3 aoViewPosition(vec2 uv) {
    float depth = texture(depthtex1, uv).r;
    return screenToView(vec3(uv, depth));
}

/*
 * Screen-space radius corresponding to a world-space radius at this depth.
 *
 * Without the perspective divide, AO would have a fixed pixel radius and so
 * cover a large world area up close and a tiny one far away, which reads as the
 * effect sliding across surfaces as the camera moves.
 */
float aoScreenRadius(float viewDistance) {
    // gbufferProjection[0][0] is the horizontal projection scale.
    return AO_RADIUS * gbufferProjection[0][0] / max(viewDistance, 0.1);
}

//==============================================================================
// SSAO
//==============================================================================

/*
 * Hemisphere-sampled SSAO.
 *
 * Samples are distributed in the hemisphere around the normal, not a full
 * sphere: a full sphere puts half the samples inside the surface and requires
 * halving the result, which throws away half the sample budget.
 */
float computeSSAO(vec2 uv, vec3 viewPos, vec3 viewNormal, float dither) {
    float viewDistance = length(viewPos);
    float radius = aoScreenRadius(viewDistance);

    vec3 tangent, bitangent;
    buildOrthonormalBasis(viewNormal, tangent, bitangent);

    float occlusion = 0.0;
    float rotation = dither * ASTRA_TAU;

    for (int i = 0; i < AO_SAMPLES; i++) {
        vec2 disc = vogelDisc(i, AO_SAMPLES, rotation);

        // Lift the sample off the surface plane so it covers the hemisphere.
        float z = sqrt(saturate(1.0 - dot(disc, disc)));
        vec3 offset = tangent * disc.x + bitangent * disc.y + viewNormal * z;

        vec3 samplePos = viewPos + offset * AO_RADIUS;
        vec3 sampleScreen = viewToScreen(samplePos);

        if (any(lessThan(sampleScreen.xy, vec2(0.0)))
            || any(greaterThan(sampleScreen.xy, vec2(1.0)))) continue;

        float sceneDepth = -aoViewPosition(sampleScreen.xy).z;
        float sampleDepth = -samplePos.z;

        float difference = sampleDepth - sceneDepth;

        /*
         * The range check stops a distant wall behind a foreground object from
         * occluding it. Without it, silhouettes gain a dark halo.
         */
        float rangeCheck = smoothstep(0.0, 1.0,
                                      AO_RADIUS / max(abs(difference), 1e-4));

        occlusion += (difference > 0.02) ? rangeCheck : 0.0;
    }

    return saturate(1.0 - occlusion / float(AO_SAMPLES));
}

//==============================================================================
// GTAO
//==============================================================================

/*
 * Analytic integral of the visible arc between two horizon angles, weighted by
 * the cosine of the angle to the normal.
 *
 * This closed form is what makes GTAO accurate: rather than counting occluded
 * samples, it integrates exactly how much of the cosine-weighted hemisphere
 * remains visible between the two horizons found by the search.
 *
 * From Jimenez et al. (2016), equation 7.
 */
float gtaoIntegrateArc(float horizon1, float horizon2, float normalAngle,
                       float cosNormalAngle, float sinNormalAngle) {
    float arc1 = -cos(2.0 * horizon1 - normalAngle) + cosNormalAngle
               + 2.0 * horizon1 * sinNormalAngle;
    float arc2 = -cos(2.0 * horizon2 - normalAngle) + cosNormalAngle
               + 2.0 * horizon2 * sinNormalAngle;

    return 0.25 * (arc1 + arc2);
}

/*
 * Ground-truth ambient occlusion.
 *
 * For each of AO_SAMPLES slices through the hemisphere, march outward in both
 * directions looking for the steepest horizon, then integrate the arc that
 * remains visible between them.
 */
float computeGTAO(vec2 uv, vec3 viewPos, vec3 viewNormal, float dither) {
    float viewDistance = length(viewPos);
    float radius = aoScreenRadius(viewDistance);

    // Clamp so a nearby surface does not march halfway across the screen.
    radius = min(radius, 0.15);

    vec3 viewDir = normalize(-viewPos);

    // Steps per direction. Splitting the budget between slice count and march
    // length trades angular accuracy against how far occluders can be found.
    const int MARCH_STEPS = 4;

    float occlusion = 0.0;

    for (int slice = 0; slice < AO_SAMPLES; slice++) {
        // Rotate slices per pixel so the pattern becomes noise rather than a
        // visible fan of streaks.
        float sliceAngle = (float(slice) + dither) * ASTRA_PI / float(AO_SAMPLES);
        vec2 sliceDir = vec2(cos(sliceAngle), sin(sliceAngle));

        /*
         * Project the normal into the plane of this slice. The integral below
         * is two-dimensional, so it needs the normal's angle within that plane
         * rather than in three dimensions.
         */
        vec3 slicePlaneDir = vec3(sliceDir, 0.0);
        vec3 sliceBitangent = normalize(cross(slicePlaneDir, viewDir));
        vec3 sliceTangent = cross(viewDir, sliceBitangent);

        vec3 projectedNormal = viewNormal
                             - sliceBitangent * dot(viewNormal, sliceBitangent);
        float projectedLength = length(projectedNormal);

        if (projectedLength < 1e-4) continue;

        vec3 projectedNormalDir = projectedNormal / projectedLength;

        float cosNormalAngle = saturate(dot(projectedNormalDir, viewDir));
        float normalAngle = sign(dot(projectedNormalDir, sliceTangent))
                          * acos(cosNormalAngle);
        float sinNormalAngle = sin(normalAngle);

        // Horizon cosines, initialised to the widest possible arc.
        float horizonCos1 = -1.0;
        float horizonCos2 = -1.0;

        for (int step = 1; step <= MARCH_STEPS; step++) {
            // Quadratic spacing: fine detail near the pixel, coarse far out,
            // which matches how occlusion falls off with distance.
            float t = float(step) / float(MARCH_STEPS);
            float offset = radius * t * t;

            // Jitter per step so undersampling becomes noise, not rings.
            offset *= (0.75 + 0.25 * dither);

            for (int side = 0; side < 2; side++) {
                vec2 sampleUV = uv + sliceDir * offset
                              * (side == 0 ? 1.0 : -1.0);

                if (any(lessThan(sampleUV, vec2(0.0)))
                    || any(greaterThan(sampleUV, vec2(1.0)))) continue;

                vec3 samplePos = aoViewPosition(sampleUV);
                vec3 toSample = samplePos - viewPos;

                float distanceToSample = length(toSample);
                if (distanceToSample < 1e-4) continue;

                float cosHorizon = dot(toSample / distanceToSample, viewDir);

                /*
                 * Attenuate distant occluders. Something twice the radius away
                 * genuinely blocks less of the hemisphere, and without this the
                 * effect extends far past AO_RADIUS.
                 */
                float falloff = saturate(1.0 - distanceToSample
                                         / max(AO_RADIUS * 2.0, 1e-4));
                cosHorizon = mix(-1.0, cosHorizon, falloff);

                if (side == 0) {
                    horizonCos1 = max(horizonCos1, cosHorizon);
                } else {
                    horizonCos2 = max(horizonCos2, cosHorizon);
                }
            }
        }

        // Convert to angles, clamped to the hemisphere around the normal.
        float horizon1 = normalAngle + max(-acos(clamp(horizonCos1, -1.0, 1.0))
                                           - normalAngle, -ASTRA_HALF_PI);
        float horizon2 = normalAngle + min(acos(clamp(horizonCos2, -1.0, 1.0))
                                           - normalAngle, ASTRA_HALF_PI);

        occlusion += projectedLength
                   * gtaoIntegrateArc(horizon1, horizon2, normalAngle,
                                      cosNormalAngle, sinNormalAngle);
    }

    return saturate(occlusion / float(AO_SAMPLES));
}

//==============================================================================
// ENTRY POINT
//==============================================================================

/*
 * Ambient occlusion for one pixel. Returns 1.0 where nothing is occluded.
 */
float computeAmbientOcclusion(vec2 uv, float depth, vec3 sceneNormal,
                              float dither) {
#if ASTRA_AO_MODE == 0
    return 1.0;
#else
    if (isSky(depth)) return 1.0;

    vec3 viewPos = screenToView(vec3(uv, depth));
    vec3 viewNormal = normalize(sceneToViewDir(sceneNormal));

    float ao;

    #if ASTRA_AO_MODE == 2
        ao = computeGTAO(uv, viewPos, viewNormal, dither);
    #else
        ao = computeSSAO(uv, viewPos, viewNormal, dither);
    #endif

    /*
     * Fade out with distance. AO is a contact cue; at range the screen-space
     * radius collapses to a few pixels and produces noise rather than shape.
     */
    float distanceFade = smoothstep(far * 0.5, far * 0.85, length(viewPos));

    return mix(ao, 1.0, distanceFade);
#endif
}

//==============================================================================
// SPATIAL FILTER
//==============================================================================

/*
 * Bilateral blur over the AO buffer.
 *
 * Temporal accumulation arrives with TAA in a later phase. Until then the raw
 * result at low sample counts is visibly noisy, so it is filtered here.
 *
 * Bilateral rather than a plain box blur: weighting neighbours by how close
 * their depth and normal are stops occlusion bleeding across silhouettes, which
 * would produce dark halos around every object.
 */
float filterAmbientOcclusion(sampler2D aoBuffer, vec2 uv, float centreDepth,
                             vec3 centreNormal) {
#if ASTRA_AO_MODE == 0
    return 1.0;
#else
    vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

    float total = 0.0;
    float weightSum = 0.0;

    float centreDistance = linearizeDepth(centreDepth);

    // 5x5 would be smoother but costs 25 taps; 3x3 plus the dither pattern
    // already used by the trace is enough to break up the noise.
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(float(x), float(y)) * texelSize;
            vec2 sampleUV = uv + offset;

            float sampleDepth = texture(depthtex1, sampleUV).r;
            if (isSky(sampleDepth)) continue;

            vec4 sampleGBufferB = texture(colortex2, sampleUV);
            vec3 sampleNormal = decodeNormalOctahedral(sampleGBufferB.ba);

            // Reject neighbours on a different surface.
            float depthWeight = exp(-abs(linearizeDepth(sampleDepth)
                                         - centreDistance) * 4.0);
            float normalWeight = pow(saturate(dot(sampleNormal, centreNormal)), 16.0);

            float weight = depthWeight * normalWeight;

            total += texture(aoBuffer, sampleUV).b * weight;
            weightSum += weight;
        }
    }

    if (weightSum <= 0.0) return texture(aoBuffer, uv).b;

    return total / weightSum;
#endif
}

#endif // ASTRA_AO_GLSL
