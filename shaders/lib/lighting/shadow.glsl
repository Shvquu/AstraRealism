#ifndef ASTRA_SHADOW_GLSL
#define ASTRA_SHADOW_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Shadow map sampling.
 *
 * Iris exposes a single shadow map, not a cascade, so crispness near the camera
 * comes from the distortion in lib/common/spaces.glsl rather than from
 * splitting the frustum. See docs/limitations.md.
 *
 * Three filters are available:
 *   0  single tap, hard edges
 *   1  PCF over a fixed disc
 *   2  PCSS - the blur width is derived from how far the occluder is from the
 *      receiver, so contact points stay sharp and distant shadows soften, which
 *      is what real penumbrae do
 */

struct ShadowResult {
    float visibility;  // 0 fully shadowed, 1 fully lit
    vec3  tint;        // colour transmitted through stained glass or water
};

//==============================================================================
// BIAS
//==============================================================================

/*
 * Normal-offset bias.
 *
 * Moving the sample point along the surface normal before projecting is far
 * more effective than offsetting the compared depth: it scales naturally with
 * texel size and, unlike depth bias, does not detach shadows from their casters
 * on surfaces facing the light.
 *
 * The slope term widens the offset on surfaces at grazing angles to the light,
 * where a single texel covers the most depth range and acne is worst.
 */
vec3 applyShadowBias(vec3 scenePos, vec3 geoNormal, float ndotl) {
    vec3 shadowClip = sceneToShadowClip(scenePos);
    float texelSize = shadowTexelWorldSize(shadowClip.xy);

    float slopeScale = sqrt(1.0 - saturate(ndotl * ndotl)) / max(ndotl, 0.05);
    float offset = texelSize * (1.0 + min(slopeScale, 8.0)) * SHADOW_BIAS;

    return scenePos + geoNormal * offset;
}

//==============================================================================
// RAW SAMPLING
//==============================================================================

// One depth comparison. Returns 1.0 when lit.
float sampleShadowDepth(vec2 uv, float compareDepth) {
    return step(compareDepth, texture(shadowtex1, uv).r);
}

/*
 * Colour transmitted at a point where an opaque test passes but a
 * translucent-inclusive test does not - that is, where the only thing blocking
 * the light is stained glass, water or ice.
 */
vec3 sampleShadowTint(vec2 uv, float compareDepth) {
#if ASTRA_ENABLE_COLORED_SHADOWS
    float opaqueLit = step(compareDepth, texture(shadowtex1, uv).r);
    float anyLit = step(compareDepth, texture(shadowtex0, uv).r);

    // Lit through opaque but blocked in the full map: a translucent caster.
    float translucentBlocked = opaqueLit * (1.0 - anyLit);
    if (translucentBlocked < 0.5) return vec3(1.0);

    vec4 caster = texture(shadowcolor0, uv);

    // The shadow pass stores the caster's albedo with its alpha as opacity.
    // Light emerges tinted toward the caster's colour, in proportion to how
    // opaque it is.
    return mix(vec3(1.0), caster.rgb, caster.a);
#else
    return vec3(1.0);
#endif
}

//==============================================================================
// PCSS BLOCKER SEARCH
//==============================================================================

/*
 * Average depth of occluders within a search radius.
 *
 * Returns -1.0 when nothing blocks, which the caller uses to skip filtering
 * entirely - a meaningful saving because most of a sunlit scene is unoccluded.
 */
float findAverageBlockerDepth(vec2 uv, float receiverDepth, float searchRadiusUV,
                              float rotation) {
    float blockerSum = 0.0;
    int blockerCount = 0;

    for (int i = 0; i < SHADOW_BLOCKER_SAMPLES; i++) {
        vec2 offset = vogelDisc(i, SHADOW_BLOCKER_SAMPLES, rotation) * searchRadiusUV;
        float depth = texture(shadowtex1, uv + offset).r;

        if (depth < receiverDepth) {
            blockerSum += depth;
            blockerCount++;
        }
    }

    if (blockerCount == 0) return -1.0;

    return blockerSum / float(blockerCount);
}

//==============================================================================
// FILTERED LOOKUP
//==============================================================================

float pcfFilter(vec2 uv, float compareDepth, float radiusUV, float rotation,
                int sampleCount) {
    float sum = 0.0;

    for (int i = 0; i < sampleCount; i++) {
        vec2 offset = vogelDisc(i, sampleCount, rotation) * radiusUV;
        sum += sampleShadowDepth(uv + offset, compareDepth);
    }

    return sum / float(sampleCount);
}

//==============================================================================
// MAIN ENTRY POINT
//==============================================================================

/*
 * Shadow visibility for a surface point.
 *
 * `ndotl` is the cosine between the geometric normal and the light. Surfaces
 * facing away are shadowed by their own geometry and skip the lookup entirely.
 */
ShadowResult sampleShadow(vec3 scenePos, vec3 geoNormal, float ndotl, float dither) {
    ShadowResult result;
    result.visibility = 1.0;
    result.tint = vec3(1.0);

#if !ASTRA_ENABLE_SHADOWS
    return result;
#else
    // Back faces are self-shadowed. Testing the geometric normal rather than
    // the mapped one avoids normal-mapped surfaces punching holes in shadows.
    if (ndotl <= 0.0) {
        result.visibility = 0.0;
        return result;
    }

    vec3 biased = applyShadowBias(scenePos, geoNormal, ndotl);
    vec3 shadowClip = sceneToShadowClip(biased);
    vec3 shadowScreen = distortShadowClip(shadowClip) * 0.5 + 0.5;

    // Outside the shadow volume there is no information, so treat it as lit.
    // Fading out at the boundary avoids a hard line at the shadow distance.
    if (any(lessThan(shadowScreen.xyz, vec3(0.0)))
        || any(greaterThan(shadowScreen.xyz, vec3(1.0)))) {
        return result;
    }

    float rotation = dither * ASTRA_TAU;
    float texelUV = 1.0 / float(shadowMapResolution);

    #if ASTRA_SHADOW_FILTER_MODE == 0
        result.visibility = sampleShadowDepth(shadowScreen.xy, shadowScreen.z);
        result.tint = sampleShadowTint(shadowScreen.xy, shadowScreen.z);

    #elif ASTRA_SHADOW_FILTER_MODE == 1
        // Fixed-radius PCF. Two texels is enough to hide aliasing without
        // visibly detaching the shadow from its caster.
        float radiusUV = texelUV * 2.0;
        result.visibility = pcfFilter(shadowScreen.xy, shadowScreen.z, radiusUV,
                                      rotation, SHADOW_SAMPLES);
        result.tint = sampleShadowTint(shadowScreen.xy, shadowScreen.z);

    #else
        // --- PCSS -----------------------------------------------------------
        //
        // The penumbra of a shadow cast by a light of angular radius theta
        // widens by 2*tan(theta) per unit of caster-receiver separation. That
        // relationship is the whole of the technique; everything else is
        // converting between the spaces involved.

        float lightTangent = tan(radians(SUN_ANGULAR_RADIUS));

        // Search a region wide enough to contain the penumbra of an occluder
        // at a plausible distance, capped so the loop stays cache-friendly.
        float searchRadiusUV = min(lightTangent * 24.0, 24.0 * texelUV);

        float blockerDepth = findAverageBlockerDepth(
            shadowScreen.xy, shadowScreen.z, searchRadiusUV, rotation);

        if (blockerDepth < 0.0) {
            // Nothing occludes this point.
            result.visibility = 1.0;
            result.tint = sampleShadowTint(shadowScreen.xy, shadowScreen.z);
            return result;
        }

        float separationWorld = shadowDepthToWorld(shadowScreen.z - blockerDepth);
        float penumbraWorld = separationWorld * lightTangent * 2.0;

        float texelWorld = shadowTexelWorldSize(shadowClip.xy);
        float radiusUV = (penumbraWorld / max(texelWorld, ASTRA_EPSILON)) * texelUV;

        // One texel minimum keeps close-contact shadows anti-aliased rather
        // than hard-edged; the cap stops distant soft shadows from degenerating
        // into noise at low sample counts.
        radiusUV = clamp(radiusUV, texelUV, 48.0 * texelUV);

        result.visibility = pcfFilter(shadowScreen.xy, shadowScreen.z, radiusUV,
                                      rotation, SHADOW_SAMPLES);
        result.tint = sampleShadowTint(shadowScreen.xy, shadowScreen.z);
    #endif

    // Fade the shadow out as it approaches the edge of the shadow distance, so
    // the transition to unshadowed terrain is gradual.
    float edgeFade = smoothstep(0.85, 1.0, maxComponent(abs(shadowClip.xy)));
    result.visibility = mix(result.visibility, 1.0, edgeFade);

    return result;
#endif
}

#endif // ASTRA_SHADOW_GLSL
