#ifndef ASTRA_PARALLAX_GLSL
#define ASTRA_PARALLAX_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Parallax occlusion mapping.
 *
 * Minecraft textures are flat quads. A height map plus a ray march through it
 * makes them read as genuinely recessed: mortar lines sink between bricks,
 * planks separate, cobblestone gains rounded stones. Unlike a normal map, the
 * effect survives moving the camera, because the displacement is computed per
 * view direction rather than baked into the shading.
 *
 * Requires a LabPBR resource pack - the height map lives in the alpha channel
 * of the normal texture. Without one, ASTRA_ENABLE_POM is 0 and every function
 * here compiles away.
 *
 * Two things make this harder in Minecraft than in a typical engine:
 *
 *   1. Textures live in one large atlas, so marching UVs freely would walk into
 *      a neighbouring sprite. Every sample has to be wrapped back inside the
 *      tile, which is what `tileSize` and `tileBase` are for.
 *
 *   2. Mipmapping breaks once UVs are computed rather than interpolated, so the
 *      derivatives have to be carried explicitly through textureGrad.
 */

//==============================================================================
// TILE WRAPPING
//==============================================================================

/*
 * Bottom-left corner of the sprite containing this fragment.
 *
 * `tileSize` is supplied by the vertex stage as abs(texcoord - midTexcoord) * 2,
 * which is exact because every vertex sits on a corner of its tile.
 */
vec2 parallaxTileBase(vec2 midTexcoord, vec2 tileSize) {
    return midTexcoord - tileSize * 0.5;
}

// Wrap a marched coordinate back inside its sprite.
vec2 parallaxWrap(vec2 uv, vec2 tileBase, vec2 tileSize) {
    return tileBase + mod(uv - tileBase, tileSize);
}

//==============================================================================
// HEIGHT SAMPLING
//==============================================================================

/*
 * LabPBR stores height in the alpha of the normal texture: 0 is the deepest
 * point, 1 is the original surface.
 *
 * textureGrad rather than texture, because the UV is computed inside a loop.
 * The hardware would otherwise derive mip level from neighbouring fragments
 * whose loops may have diverged, producing a visible seam along every edge
 * where the march happened to take a different number of steps.
 */
float sampleHeight(vec2 uv, vec2 dx, vec2 dy) {
    return textureGrad(normals, uv, dx, dy).a;
}

//==============================================================================
// PARALLAX MARCH
//==============================================================================

struct ParallaxResult {
    vec2  uv;           // displaced texture coordinate
    float height;       // height at the hit, for self-shadowing
    bool  hit;          // false when parallax was skipped entirely
};

/*
 * March the height field along the view ray and return the displaced UV.
 *
 * `viewDirTangent` points from the surface toward the eye, in tangent space.
 *
 * The step count scales with the view angle: at a grazing angle the ray covers
 * far more texture per unit of depth, so it needs more samples to avoid
 * stepping straight over thin features. At a head-on angle almost nothing is
 * displaced and the extra samples would be wasted.
 */
ParallaxResult applyParallax(vec2 uv, vec2 midTexcoord, vec2 tileSize,
                             vec3 viewDirTangent, float viewDistance,
                             float dither) {
    ParallaxResult result;
    result.uv = uv;
    result.height = 1.0;
    result.hit = false;

#if !ASTRA_ENABLE_POM
    return result;
#else
    // Parallax detail is invisible at range but costs the same, so it fades
    // out well before it stops being resolvable.
    float distanceFade = 1.0 - smoothstep(POM_DISTANCE * 0.65, POM_DISTANCE,
                                          viewDistance);
    if (distanceFade <= 0.0) return result;

    // A ray nearly parallel to the surface would march an unbounded distance.
    float nDotV = max(viewDirTangent.z, 0.05);

    vec2 tileBase = parallaxTileBase(midTexcoord, tileSize);

    // Derivatives of the *original* coordinate, carried through the loop.
    vec2 dx = dFdx(uv);
    vec2 dy = dFdy(uv);

    float depthScale = POM_DEPTH * distanceFade;

    // Total UV travel if the ray descended the full height of the field.
    vec2 maxOffset = (viewDirTangent.xy / nDotV) * depthScale * tileSize;

    int steps = int(mix(float(POM_STEPS) * 0.5, float(POM_STEPS),
                        saturate(1.0 - nDotV)));
    steps = max(steps, 4);

    float stepDepth = 1.0 / float(steps);
    vec2 stepOffset = maxOffset * stepDepth;

    // Start a fraction of a step in, varied per pixel. Without it the fixed
    // step positions show up as terracing on shallow slopes.
    float currentDepth = stepDepth * dither;
    vec2 currentUV = uv - stepOffset * dither;

    float currentHeight = sampleHeight(parallaxWrap(currentUV, tileBase, tileSize),
                                       dx, dy);

    // Descend until the ray passes below the height field.
    for (int i = 0; i < steps; i++) {
        if (1.0 - currentDepth <= currentHeight) break;

        currentUV -= stepOffset;
        currentDepth += stepDepth;
        currentHeight = sampleHeight(parallaxWrap(currentUV, tileBase, tileSize),
                                     dx, dy);
    }

    /*
     * Linear interpolation between the last step above the surface and the
     * first below it. Taking the crossing point rather than the last sample is
     * what removes the stair-stepping that plain steep parallax produces on
     * gentle slopes.
     */
    vec2 previousUV = currentUV + stepOffset;
    float previousDepth = currentDepth - stepDepth;
    float previousHeight = sampleHeight(parallaxWrap(previousUV, tileBase, tileSize),
                                        dx, dy);

    float afterGap = (1.0 - currentDepth) - currentHeight;
    float beforeGap = (1.0 - previousDepth) - previousHeight;

    float weight = afterGap / max(afterGap - beforeGap, ASTRA_EPSILON);
    weight = saturate(weight);

    result.uv = parallaxWrap(mix(currentUV, previousUV, weight),
                             tileBase, tileSize);
    result.height = mix(currentHeight, previousHeight, weight);
    result.hit = true;

    return result;
#endif
}

//==============================================================================
// SELF-SHADOWING
//==============================================================================

/*
 * Shadowing of the height field by itself.
 *
 * Without this, parallax reads as an odd smearing of the texture rather than as
 * depth: the geometry appears recessed but nothing darkens inside it, which the
 * eye reads as wrong. A second march toward the light fixes that, and it is the
 * single biggest contributor to parallax looking real.
 *
 * Returns 1.0 for fully lit, 0.0 for fully shadowed.
 */
float parallaxSelfShadow(vec2 uv, vec2 midTexcoord, vec2 tileSize,
                         vec3 lightDirTangent, float surfaceHeight,
                         float viewDistance, float dither) {
#if !ASTRA_ENABLE_POM_SHADOW
    return 1.0;
#else
    // Light coming from below the surface cannot illuminate it at all.
    if (lightDirTangent.z <= 0.05) return 0.0;

    float distanceFade = 1.0 - smoothstep(POM_DISTANCE * 0.65, POM_DISTANCE,
                                          viewDistance);
    if (distanceFade <= 0.0) return 1.0;

    vec2 tileBase = parallaxTileBase(midTexcoord, tileSize);

    vec2 dx = dFdx(uv);
    vec2 dy = dFdy(uv);

    // Half the view march: shadow rays terminate as soon as anything blocks
    // them, so they rarely run to completion.
    int steps = max(POM_STEPS / 2, 4);

    float depthScale = POM_DEPTH * distanceFade;

    // Travel from the hit point up to the top of the height field.
    float remaining = 1.0 - surfaceHeight;
    if (remaining <= 0.001) return 1.0;

    vec2 stepOffset = (lightDirTangent.xy / lightDirTangent.z)
                    * depthScale * tileSize * (remaining / float(steps));
    float stepHeight = remaining / float(steps);

    vec2 currentUV = uv + stepOffset * dither;
    float currentHeight = surfaceHeight + stepHeight * dither;

    float shadow = 1.0;

    for (int i = 0; i < steps; i++) {
        currentUV += stepOffset;
        currentHeight += stepHeight;

        float sampled = sampleHeight(parallaxWrap(currentUV, tileBase, tileSize),
                                     dx, dy);

        if (sampled > currentHeight) {
            /*
             * Soft rather than binary occlusion. How far the blocker rises
             * above the ray, weighted by how early in the march it was found,
             * approximates a penumbra - a binary test produces hard aliased
             * shadow edges inside every crevice.
             */
            float penetration = (sampled - currentHeight) * float(steps - i)
                              / float(steps);
            shadow = min(shadow, 1.0 - saturate(penetration * 8.0));

            if (shadow <= 0.0) break;
        }
    }

    return mix(1.0, shadow, distanceFade);
#endif
}

//==============================================================================
// TANGENT SPACE HELPERS
//==============================================================================

/*
 * Project a scene-space direction into the surface's tangent basis.
 *
 * The TBN matrix built in the vertex stage maps tangent space to scene space;
 * for an orthonormal basis the inverse is the transpose, which is what the
 * reversed multiplication order below expresses.
 */
vec3 toTangentSpace(vec3 sceneDir, vec3 tangent, vec3 bitangent, vec3 normal) {
    return normalize(vec3(dot(sceneDir, tangent),
                          dot(sceneDir, bitangent),
                          dot(sceneDir, normal)));
}

#endif // ASTRA_PARALLAX_GLSL
