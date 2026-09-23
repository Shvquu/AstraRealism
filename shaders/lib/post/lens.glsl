#ifndef ASTRA_LENS_GLSL
#define ASTRA_LENS_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"

/*
 * AstraRealism - Lens artifacts.
 *
 * Everything here is a flaw of a physical camera rather than something the eye
 * does. They are included because film and photography have trained viewers to
 * read them as realism, but every one is off by default except the vignette -
 * the scene should be convincing without them.
 */

//==============================================================================
// CHROMATIC ABERRATION
//==============================================================================

/*
 * Transverse chromatic aberration.
 *
 * A simple lens refracts short wavelengths more than long ones, so the three
 * channels focus at slightly different magnifications. The separation is zero
 * on the optical axis and grows toward the edges - which is why this scales
 * with distance from centre rather than being uniform.
 *
 * Sampled at three different scales rather than three offsets: the effect is a
 * magnification difference, not a translation, and translating produces a
 * one-sided fringe that looks like a rendering error.
 */
vec3 applyChromaticAberration(sampler2D tex, vec2 uv) {
#if !ASTRA_ENABLE_CA
    return texture(tex, uv).rgb;
#else
    vec2 centred = uv - 0.5;

    // Quadratic growth from the centre, as a real lens shows.
    float amount = dot(centred, centred) * CA_STRENGTH * 0.004;

    // Red refracts least, blue most.
    float r = texture(tex, 0.5 + centred * (1.0 - amount)).r;
    float g = texture(tex, uv).g;
    float b = texture(tex, 0.5 + centred * (1.0 + amount)).b;

    return vec3(r, g, b);
#endif
}

//==============================================================================
// FILM GRAIN
//==============================================================================

/*
 * Photographic grain.
 *
 * Scaled by luminance in the way film actually behaves: grain comes from the
 * discrete silver halide crystals that did or did not receive a photon, so it
 * is most visible in the midtones and shadows and almost absent in blown
 * highlights. Applying it uniformly reads as digital noise instead.
 */
vec3 applyFilmGrain(vec3 colour, vec2 pixel) {
#if !ASTRA_ENABLE_GRAIN
    return colour;
#else
    float noise = hash1(uvec2(pixel).x + uvec2(pixel).y * 4096u
                        + uint(frameCounter) * 16777216u);

    // Centred on zero so grain neither brightens nor darkens on average.
    noise = noise * 2.0 - 1.0;

    float luma = luminance(colour);

    // Peaks in the midtones, falls away at both ends.
    float response = 4.0 * luma * (1.0 - luma);

    return colour * (1.0 + noise * response * GRAIN_STRENGTH * 0.06);
#endif
}

//==============================================================================
// LENS DIRT
//==============================================================================

/*
 * Dust and smudges on the front element.
 *
 * Modulates bloom rather than being drawn over the image, which is what makes
 * it read as dirt rather than as a texture overlay: real dirt is only visible
 * when something bright scatters off it, so it should appear when you look
 * toward the sun and vanish when you look away.
 */
vec3 applyLensDirt(vec3 colour, vec3 bloom, vec2 uv) {
#if !ASTRA_ENABLE_LENS_DIRT
    return colour;
#else
    // Procedural rather than a texture: a shader pack that shipped a dirt
    // texture would have to ship it at every resolution.
    vec2 p = uv * vec2(aspectRatio, 1.0);

    float dirt = valueNoise(p * 7.0) * 0.5
               + valueNoise(p * 19.0) * 0.3
               + valueNoise(p * 53.0) * 0.2;

    // Sparse: mostly clean glass with occasional specks.
    dirt = saturate((dirt - 0.55) * 3.0);

    return colour + bloom * dirt * LENS_DIRT_STRENGTH * 0.6;
#endif
}

//==============================================================================
// LENS FLARE
//==============================================================================

/*
 * Ghost images from internal reflections between lens elements.
 *
 * Each ghost is an inverted, scaled copy of the bright source, positioned along
 * the line from the source through the centre of the frame - that geometry is a
 * consequence of the reflection happening between parallel elements, and
 * getting it right is what separates a lens flare from a decorative sprite.
 */
vec3 applyLensFlare(vec3 colour, vec2 uv, vec3 sunScreenPos, float sunVisibility) {
#if !ASTRA_ENABLE_LENS_FLARE
    return colour;
#else
    if (sunVisibility <= 0.0) return colour;

    vec2 aspect = vec2(aspectRatio, 1.0);

    // Vector from the source toward the centre; ghosts lie along it.
    vec2 toCentre = vec2(0.5) - sunScreenPos.xy;

    vec3 flare = vec3(0.0);

    const int GHOSTS = 5;

    for (int i = 1; i <= GHOSTS; i++) {
        /*
         * Ghosts sit at regularly spaced fractions along the line, some beyond
         * the centre. The alternating sign is what puts a few on the far side,
         * as a real lens does.
         */
        float offset = float(i) * 0.4 * ((i % 2 == 0) ? -1.0 : 1.0);

        vec2 ghostPos = sunScreenPos.xy + toCentre * offset;

        // Not named `distance` - that is a GLSL built-in.
        float toGhost = length((uv - ghostPos) * aspect);

        // Smaller and dimmer further along the chain.
        float size = 0.06 / (1.0 + float(i) * 0.4);
        float intensity = smoothstep(size, 0.0, toGhost) / float(i);

        /*
         * Each element's coating reflects a different part of the spectrum, so
         * ghosts are tinted rather than white. Cycling the hue by index is a
         * reasonable stand-in for modelling the coatings.
         */
        vec3 tint = 0.5 + 0.5 * cos(vec3(0.0, 2.1, 4.2) + float(i) * 1.3);

        flare += tint * intensity;
    }

    return colour + flare * sunVisibility * LENS_FLARE_STRENGTH * 0.12;
#endif
}

/*
 * Whether the sun is on screen and unoccluded, and where.
 *
 * Returns visibility; writes the screen position. A flare from a sun hidden
 * behind a hill is the single most obvious way to get this effect wrong.
 */
float sunFlareVisibility(sampler2D depthTex, out vec3 sunScreenPos) {
    sunScreenPos = vec3(0.0);

#if !ASTRA_ENABLE_LENS_FLARE
    return 0.0;
#else
    vec3 sunDir = sunDirection();

    // Below the horizon.
    if (sunDir.y <= 0.0) return 0.0;

    vec3 sunView = sceneToView(sunDir * far * 0.9);

    // Behind the camera.
    if (sunView.z > 0.0) return 0.0;

    sunScreenPos = viewToScreen(sunView);

    if (any(lessThan(sunScreenPos.xy, vec2(0.0)))
        || any(greaterThan(sunScreenPos.xy, vec2(1.0)))) {
        return 0.0;
    }

    // Occluded by geometry.
    float depthAtSun = texture(depthTex, sunScreenPos.xy).r;
    if (!isSky(depthAtSun)) return 0.0;

    /*
     * Fade toward the frame edge. A flare that snaps off as the sun crosses the
     * boundary is far more noticeable than one that dims out.
     */
    vec2 edgeDistance = min(sunScreenPos.xy, 1.0 - sunScreenPos.xy);
    float edgeFade = smoothstep(0.0, 0.12, min(edgeDistance.x, edgeDistance.y));

    // Weaker in rain, when the sun is diffused by cloud.
    return edgeFade * (1.0 - rainStrength * 0.8);
#endif
}

#endif // ASTRA_LENS_GLSL
