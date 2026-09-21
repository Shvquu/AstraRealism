#ifndef ASTRA_GRADING_GLSL
#define ASTRA_GRADING_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Colour grading.
 *
 * Applied in linear light before tone mapping, which is the correct order:
 * grading after tone mapping operates on already-compressed values and pushes
 * highlights into clipping.
 *
 * Every default is neutral. The pack should look right with all of these at
 * their identity values - grading is here for taste, not to rescue the
 * lighting.
 */

//==============================================================================
// WHITE BALANCE
//==============================================================================

/*
 * Shift the white point to a given colour temperature.
 *
 * Implemented as a ratio of blackbody spectra: dividing by the target's colour
 * and multiplying by neutral 6500 K produces exactly the correction that makes
 * a source at that temperature render as white.
 */
vec3 applyWhiteBalance(vec3 color, float targetKelvin, float tint) {
    if (abs(targetKelvin - 6500.0) < 1.0 && abs(tint) < 0.001) return color;

    vec3 neutral = blackbodyToRGB(6500.0);
    vec3 target = blackbodyToRGB(targetKelvin);

    vec3 balanced = color * (neutral / max(target, vec3(ASTRA_EPSILON)));

    /*
     * Tint runs along the green-magenta axis, perpendicular to temperature.
     * Green is raised and red/blue lowered together so overall luminance is
     * roughly preserved.
     */
    if (abs(tint) > 0.001) {
        vec3 tintDirection = vec3(-0.5, 1.0, -0.5);
        balanced *= vec3(1.0) + tintDirection * tint * 0.1;
    }

    return balanced;
}

//==============================================================================
// TONAL ADJUSTMENTS
//==============================================================================

/*
 * Contrast around a fixed pivot.
 *
 * Middle grey in linear light is 0.18, not 0.5. Pivoting at 0.5 - as a naive
 * implementation does - brightens the whole image whenever contrast is raised,
 * because most of a scene sits well below that point.
 */
vec3 applyContrast(vec3 color, float contrast) {
    if (abs(contrast - 1.0) < 0.001) return color;

    const float MIDDLE_GREY = 0.18;

    return max(vec3(0.0), (color - MIDDLE_GREY) * contrast + MIDDLE_GREY);
}

vec3 applyGamma(vec3 color, float gamma) {
    if (abs(gamma - 1.0) < 0.001) return color;

    return pow(max(color, vec3(0.0)), vec3(1.0 / gamma));
}

//==============================================================================
// COLOUR ADJUSTMENTS
//==============================================================================

vec3 applySaturation(vec3 color, float saturation) {
    if (abs(saturation - 1.0) < 0.001) return color;

    float luma = luminance(color);

    return max(vec3(0.0), mix(vec3(luma), color, saturation));
}

/*
 * Vibrance: saturation weighted by how unsaturated a pixel already is.
 *
 * Raising plain saturation on an image that already has strong colour pushes
 * those areas straight into clipping. Vibrance lifts the muted parts and leaves
 * the vivid ones alone, which is nearly always what is actually wanted.
 */
vec3 applyVibrance(vec3 color, float vibrance) {
    if (abs(vibrance - 1.0) < 0.001) return color;

    float luma = luminance(color);

    // Current saturation, as the spread between the extreme channels.
    float currentSaturation = maxComponent(color) - minComponent(color);

    // Muted pixels get the full adjustment; saturated ones get almost none.
    float weight = 1.0 - saturate(currentSaturation);
    float amount = mix(1.0, vibrance, weight);

    return max(vec3(0.0), mix(vec3(luma), color, amount));
}

//==============================================================================
// PIPELINE
//==============================================================================

/*
 * Full grading chain, in linear light.
 *
 * Order matters: white balance first because it corrects the light source,
 * then exposure, then tonal shape, then colour. Reordering produces visibly
 * different results for the same parameter values.
 */
vec3 applyColorGrading(vec3 color) {
    color = applyWhiteBalance(color, float(POST_TEMPERATURE), POST_TINT);

    color *= POST_EXPOSURE;

    color = applyContrast(color, POST_CONTRAST);
    color = applyGamma(color, POST_GAMMA);

    color = applyVibrance(color, POST_VIBRANCE);
    color = applySaturation(color, POST_SATURATION);

    return color;
}

#endif // ASTRA_GRADING_GLSL
