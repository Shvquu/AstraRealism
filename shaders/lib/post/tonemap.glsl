#ifndef ASTRA_TONEMAP_GLSL
#define ASTRA_TONEMAP_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Tone mapping.
 *
 * Maps unbounded scene radiance into the [0,1] range a display can show. This
 * is where an HDR renderer either looks like film or looks like a clipped mess,
 * and the differences between the operators below are mostly about what happens
 * to very bright, very saturated light.
 */

//==============================================================================
// REINHARD
//==============================================================================

/*
 * Extended Reinhard with a white point.
 *
 * The simplest operator that does not clip. Its weakness is that it desaturates
 * everything slightly and rolls off midtones as well as highlights, so images
 * look flat. Included because it is predictable and never surprises.
 */
vec3 tonemapReinhard(vec3 color) {
    const float whitePoint = 8.0;

    vec3 numerator = color * (1.0 + color / (whitePoint * whitePoint));

    return numerator / (1.0 + color);
}

//==============================================================================
// ACES
//==============================================================================

/*
 * ACES filmic, via the RRT+ODT fit from Stephen Hill.
 *
 * The full ACES pipeline is a large set of transforms; this is the standard
 * approximation that captures its look in a handful of matrix multiplies. It
 * has a strong shoulder that keeps highlights from clipping, and a slight
 * warm shift that reads as cinematic.
 *
 * Its known weakness is hue shift: very saturated bright colours skew, most
 * visibly turning intense reds orange. AgX below addresses that.
 */
const mat3 ACES_INPUT = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777
);

const mat3 ACES_OUTPUT = mat3(
     1.60475, -0.10208, -0.00327,
    -0.53108,  1.10813, -0.07276,
    -0.07367, -0.00605,  1.07602
);

vec3 rrtAndOdtFit(vec3 v) {
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

vec3 tonemapACES(vec3 color) {
    color = ACES_INPUT * color;
    color = rrtAndOdtFit(color);
    color = ACES_OUTPUT * color;

    return saturate(color);
}

//==============================================================================
// AGX
//==============================================================================

/*
 * AgX, following Troy Sobotka's design as implemented in Blender.
 *
 * Works by compressing the image into a wide-gamut space first, applying a
 * sigmoid in log space, then rotating back. The key property is that as light
 * gets brighter it desaturates toward white rather than skewing hue - the way
 * film and human vision behave. A bright red lava flow stays red instead of
 * turning orange.
 */
const mat3 AGX_INPUT = mat3(
    0.842479062253094,  0.0423282422610123, 0.0423756549057051,
    0.0784335999999992, 0.878468636469772,  0.0784336,
    0.0792237451477643, 0.0791661274605434, 0.879142973793104
);

const mat3 AGX_OUTPUT = mat3(
     1.19687900512017,   -0.0528968517574562, -0.0529716355144438,
    -0.0980208811401368,  1.15190312990417,   -0.0980434501171241,
    -0.0990297440797205, -0.0989611768448433,  1.15107367264116
);

/*
 * Polynomial fit to the AgX contrast curve, from Filament's implementation.
 * Operates on log-encoded values already normalised to [0,1].
 */
vec3 agxContrast(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;

    return   15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           -  6.868   * x2 * x
           +  0.4298  * x2
           +  0.1191  * x
           -  0.00232;
}

vec3 tonemapAgX(vec3 color) {
    // Dynamic range AgX maps, in stops either side of middle grey.
    const float MIN_EV = -12.47393;
    const float MAX_EV = 4.026069;

    color = AGX_INPUT * max(color, vec3(0.0));

    // Log2 encode and normalise into the working range.
    color = clamp(log2(max(color, vec3(1e-10))), MIN_EV, MAX_EV);
    color = (color - MIN_EV) / (MAX_EV - MIN_EV);

    color = agxContrast(color);

    color = AGX_OUTPUT * color;

    /*
     * AgX deliberately desaturates as part of its transform. Pushing a little
     * saturation back in afterwards is the standard "punchy" look, and without
     * it the result reads as washed out next to ACES.
     */
    float luma = luminance(color);
    color = mix(vec3(luma), color, 1.18);

    return saturate(color);
}

//==============================================================================
// KHRONOS PBR NEUTRAL
//==============================================================================

/*
 * The Khronos PBR Neutral tone mapper.
 *
 * Designed for cases where the material's actual colour must survive: it leaves
 * everything below a threshold completely untouched and only compresses above
 * it, desaturating gradually. The most faithful of the four, and the best
 * choice for judging whether the lighting itself is right.
 */
vec3 tonemapNeutral(vec3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;

    float peak = maxComponent(color);
    if (peak < startCompression) return color;

    // Pull the darkest channel up slightly to avoid a hue shift on the way in.
    float minChannel = minComponent(color);
    float offset = minChannel < 0.08
        ? minChannel - 6.25 * minChannel * minChannel
        : 0.04;
    color -= offset;
    peak -= offset;

    float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;

    float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);

    return mix(color, vec3(newPeak), g);
}

//==============================================================================
// DISPATCH
//==============================================================================

vec3 applyToneMapping(vec3 color) {
    color = max(color, vec3(0.0));

#if TONEMAP == 0
    return tonemapReinhard(color);
#elif TONEMAP == 1
    return tonemapACES(color);
#elif TONEMAP == 2
    return tonemapAgX(color);
#else
    return tonemapNeutral(color);
#endif
}

#endif // ASTRA_TONEMAP_GLSL
