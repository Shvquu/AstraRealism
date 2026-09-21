#ifndef ASTRA_SSR_GLSL
#define ASTRA_SSR_GLSL

#include "/lib/common/common.glsl"
#include "/lib/lighting/brdf.glsl"
#include "/lib/atmosphere/sky.glsl"

/*
 * AstraRealism - Screen-space reflections.
 *
 * Marches a reflected ray through the depth buffer looking for what it hits.
 * One implementation serves both callers: opaque surfaces in the deferred pass,
 * and water and glass in the forward translucent pass.
 *
 * The fundamental limitation is in the name. The depth buffer only contains
 * what the camera can see, so a ray that leaves the frame, or that needs
 * geometry hidden behind something else, has nothing to hit. Those rays fall
 * back to the atmosphere model, which is the correct answer for anything
 * reflecting sky and a plausible one otherwise.
 */

struct ReflectionResult {
    vec3  color;
    float confidence;  // 1.0 for a solid screen-space hit, 0.0 for sky fallback
};

//==============================================================================
// RAY MARCH
//==============================================================================

/*
 * March a reflected ray and return where it hit, in screen space.
 *
 * Marching in view space and projecting each step, rather than interpolating
 * in screen space, keeps step sizes uniform in world units. A screen-space
 * march spends most of its steps near the camera where perspective compresses
 * distance, and skips over geometry further out.
 *
 * `sceneDepthTex` is depthtex1 for opaque callers, so water does not reflect
 * itself, and for water it is also depthtex1 so the surface reflects the world
 * rather than its own plane.
 *
 * Returns true on a hit, writing the screen-space hit position.
 */
bool traceReflectionRay(vec3 viewPos, vec3 viewReflectDir, float dither,
                        out vec3 hitScreenPos) {
    hitScreenPos = vec3(0.0);

    // Rays pointing back toward the camera cannot be resolved in screen space.
    if (viewReflectDir.z > 0.0 && -viewPos.z < 1.0) return false;

    /*
     * Ray length is capped rather than run to the far plane. A long ray spends
     * its whole step budget crossing empty sky, which both misses nearby
     * geometry and costs the same as a useful trace.
     */
    float maxDistance = min(far * 0.5, 96.0);

    float stepSize = maxDistance / float(SSR_STEPS);

    // Offset the start along the ray so the surface does not hit itself, and
    // vary it per pixel so the residual error is noise rather than banding.
    vec3 rayPos = viewPos + viewReflectDir * stepSize * (0.5 + dither * 0.5);

    vec3 previousRayPos = rayPos;
    float previousDelta = 0.0;

    for (int i = 0; i < SSR_STEPS; i++) {
        previousRayPos = rayPos;

        /*
         * Steps grow as the ray travels. Perspective means a fixed world-space
         * step covers fewer and fewer pixels with distance, so uniform steps
         * oversample the far end and undersample the near end.
         */
        rayPos += viewReflectDir * stepSize * (1.0 + float(i) * 0.08);

        vec3 screenPos = viewToScreen(rayPos);

        if (any(lessThan(screenPos.xy, vec2(0.0)))
            || any(greaterThan(screenPos.xy, vec2(1.0)))
            || screenPos.z > 1.0) {
            return false;
        }

        float sceneDepth = texture(depthtex1, screenPos.xy).r;
        if (isSky(sceneDepth)) continue;

        float sceneDistance = linearizeDepth(sceneDepth);
        float rayDistance = -rayPos.z;

        float delta = rayDistance - sceneDistance;

        if (delta > 0.0) {
            /*
             * The depth buffer stores only front surfaces, so a ray passing
             * behind one might be inside it or far beyond it with empty space
             * between. The thickness bound distinguishes the two; without it,
             * a distant wall reflects everything in front of it.
             *
             * The bound grows with distance because perspective compresses
             * depth differences further from the camera.
             */
            float thickness = SSR_THICKNESS * (1.0 + sceneDistance * 0.05)
                            + stepSize;

            if (delta > thickness) return false;

            //------------------------------------------------------------------
            // Binary refinement
            //
            // The march overshoots by up to one step. Bisecting between the
            // last miss and the first hit converges on the true intersection,
            // which is what removes the staircase along reflected edges.
            //------------------------------------------------------------------

            vec3 low = previousRayPos;
            vec3 high = rayPos;

            for (int r = 0; r < SSR_REFINE_STEPS; r++) {
                vec3 mid = (low + high) * 0.5;
                vec3 midScreen = viewToScreen(mid);

                float midSceneDepth = texture(depthtex1, midScreen.xy).r;
                float midSceneDistance = linearizeDepth(midSceneDepth);

                if (-mid.z > midSceneDistance) {
                    high = mid;
                } else {
                    low = mid;
                }
            }

            hitScreenPos = viewToScreen((low + high) * 0.5);

            // The refinement may have walked the hit off-screen.
            if (any(lessThan(hitScreenPos.xy, vec2(0.0)))
                || any(greaterThan(hitScreenPos.xy, vec2(1.0)))) {
                return false;
            }

            return true;
        }

        previousDelta = delta;
    }

    return false;
}

//==============================================================================
// EDGE FADE
//==============================================================================

/*
 * Attenuation for hits near the edge of the screen.
 *
 * Reflections that terminate at the frame boundary cut off along a hard line
 * that moves with the camera, which is far more distracting than the reflection
 * simply fading out. Screen-space reflection is always incomplete; the goal is
 * to make the incompleteness gradual.
 */
float reflectionEdgeFade(vec2 uv) {
    vec2 distanceToEdge = min(uv, 1.0 - uv);
    float edge = min(distanceToEdge.x, distanceToEdge.y);

    return smoothstep(0.0, 0.12, edge);
}

//==============================================================================
// ROUGH REFLECTIONS
//==============================================================================

/*
 * Perturb the reflection direction to account for surface roughness.
 *
 * A rough surface does not reflect a single direction; it reflects a lobe.
 * Importance-sampling the GGX distribution that the direct lighting already
 * uses keeps the two consistent - a surface's blurry reflection and its broad
 * highlight then come from the same microfacet model rather than being tuned
 * separately.
 *
 * Returns a sampled half-vector in world space.
 */
vec3 importanceSampleGGX(vec2 xi, vec3 normal, float roughness) {
    float a = roughness * roughness;

    float phi = ASTRA_TAU * xi.x;

    // Inverse CDF of the GGX normal distribution.
    float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    float sinTheta = sqrt(saturate(1.0 - cosTheta * cosTheta));

    vec3 halfTangent = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);

    vec3 tangent, bitangent;
    buildOrthonormalBasis(normal, tangent, bitangent);

    return normalize(tangent * halfTangent.x
                   + bitangent * halfTangent.y
                   + normal * halfTangent.z);
}

//==============================================================================
// ENTRY POINT
//==============================================================================

/*
 * Reflected radiance arriving at a surface.
 *
 * `sceneColorTex` is the buffer holding the lit scene to sample on a hit -
 * colortex9 for translucents, or the reflection pass's own input for opaques.
 */
ReflectionResult computeReflection(vec3 scenePos, vec3 sceneNormal,
                                   float roughness, sampler2D sceneColorTex,
                                   float dither, int frame) {
    ReflectionResult result;
    result.color = vec3(0.0);
    result.confidence = 0.0;

#if !ASTRA_ENABLE_SSR
    return result;
#else
    vec3 viewDir = normalize(-scenePos);

    // Very rough surfaces scatter reflections so widely that the result is
    // indistinguishable from ambient, and tracing them is wasted work.
    if (roughness > SSR_ROUGHNESS_CUTOFF) {
        result.color = renderSky(reflect(-viewDir, sceneNormal));
        return result;
    }

    vec3 viewPos = sceneToView(scenePos);

    vec3 accumulated = vec3(0.0);
    float accumulatedConfidence = 0.0;

    #if ASTRA_ENABLE_ROUGH_SSR
        int rayCount = (roughness < 0.05) ? 1 : SSR_ROUGH_SAMPLES;
    #else
        int rayCount = 1;
    #endif

    for (int i = 0; i < rayCount; i++) {
        vec3 reflectDir;

        if (rayCount == 1) {
            reflectDir = reflect(-viewDir, sceneNormal);
        } else {
            // Decorrelate across rays, pixels and frames so temporal
            // accumulation converges instead of reinforcing one pattern.
            vec2 xi = r2Sequence(i + frame * rayCount);
            xi = fract(xi + dither);

            vec3 halfVector = importanceSampleGGX(xi, sceneNormal, roughness);
            reflectDir = reflect(-viewDir, halfVector);

            // The sampled lobe can point below the surface.
            if (dot(reflectDir, sceneNormal) <= 0.0) {
                reflectDir = reflect(-viewDir, sceneNormal);
            }
        }

        vec3 viewReflectDir = normalize(sceneToViewDir(reflectDir));

        vec3 hitScreenPos;
        bool hit = traceReflectionRay(viewPos, viewReflectDir,
                                      fract(dither + float(i) * 0.618),
                                      hitScreenPos);

        if (hit) {
            float fade = reflectionEdgeFade(hitScreenPos.xy);

            vec3 hitColor = texture(sceneColorTex, hitScreenPos.xy).rgb;
            vec3 skyColor = renderSky(reflectDir);

            // Blend toward the sky as the hit approaches the frame edge.
            accumulated += mix(skyColor, hitColor, fade);
            accumulatedConfidence += fade;
        } else {
            accumulated += renderSky(reflectDir);
        }
    }

    result.color = accumulated / float(rayCount);
    result.confidence = accumulatedConfidence / float(rayCount);

    return result;
#endif
}

//==============================================================================
// TEMPORAL ACCUMULATION
//==============================================================================

/*
 * Blend this frame's reflection with the accumulated history.
 *
 * Rough reflections trace only a handful of rays per frame, which is far too
 * few to resolve the lobe. Accumulating across frames is what makes that
 * affordable - each frame contributes new samples to the same estimate.
 *
 * The history has to be rejected where it is no longer valid, or the result
 * smears. `previousDepthTex` holds last frame's linear depth; comparing it
 * against where this pixel was last frame detects disocclusion.
 */
vec3 accumulateReflection(vec3 current, vec3 scenePos, float roughness,
                          sampler2D historyTex, sampler2D previousDepthTex) {
#if !ASTRA_ENABLE_SSR_TEMPORAL
    return current;
#else
    vec3 previousScreen = reprojectScene(scenePos, false);

    // Off-screen last frame: nothing to blend with.
    if (any(lessThan(previousScreen.xy, vec2(0.0)))
        || any(greaterThan(previousScreen.xy, vec2(1.0)))) {
        return current;
    }

    vec4 history = texture(historyTex, previousScreen.xy);

    // An empty history buffer, as on the first frame after a resize.
    if (history.a <= 0.0) return current;

    float previousDistance = texture(previousDepthTex, previousScreen.xy).r;
    float expectedDistance = length(sceneToView(scenePos));

    /*
     * Reject the history when the surface at that pixel last frame was at a
     * meaningfully different depth - it was a different surface, and blending
     * with it is what produces trailing ghosts behind moving objects.
     *
     * The tolerance scales with distance because depth precision does.
     */
    float tolerance = 0.05 + expectedDistance * 0.02;
    if (abs(previousDistance - expectedDistance) > tolerance) {
        return current;
    }

    /*
     * Mirror-like surfaces need almost no accumulation because a single ray
     * already resolves them, and blending would only add lag. Rough surfaces
     * need as much history as they can get.
     */
    float blend = mix(0.55, 0.92, saturate(roughness * 4.0));

    return mix(current, history.rgb, blend);
#endif
}

#endif // ASTRA_SSR_GLSL
