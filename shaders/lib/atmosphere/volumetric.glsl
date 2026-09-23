#ifndef ASTRA_VOLUMETRIC_GLSL
#define ASTRA_VOLUMETRIC_GLSL

#include "/lib/common/common.glsl"
#include "/lib/lighting/shadow.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/scattering.glsl"
#include "/lib/atmosphere/clouds.glsl"

/*
 * AstraRealism - Volumetric lighting and fog.
 *
 * God rays and volumetric fog are the same integral, so they are one pass.
 * Marching the view ray and asking the shadow map at each step whether that
 * point is lit gives both: where the air is lit you see shafts, where it is not
 * you see the fog's own extinction. Implementing them separately would compute
 * the same thing twice.
 *
 * This replaces the analytic in-scattering in lib/atmosphere/fog.glsl when
 * VOLUMETRIC_LIGHT is enabled. The analytic version remains for the lower
 * presets, where it is the right answer rather than a fallback - it has no
 * shafts, but it costs almost nothing and its colour is still derived from the
 * sky rather than from a constant.
 */

struct VolumetricResult {
    vec3  inScatter;
    float transmittance;
};

//==============================================================================
// MEDIUM DENSITY
//==============================================================================

/*
 * Density of the scattering medium at a world position.
 *
 * Shares the height profile with the analytic fog so the two agree where they
 * meet - a surface at the edge of the shadow distance must not visibly change
 * appearance as it crosses from one model to the other.
 */
float volumetricDensity(vec3 worldPos, float skyAccess) {
    float density = 1.0;

#if defined(HEIGHT_FOG)
    const float FOG_BASE_HEIGHT = 62.0;
    float relative = (worldPos.y - FOG_BASE_HEIGHT) / HEIGHT_FOG_FALLOFF;
    density = exp(-max(relative, -4.0)) * HEIGHT_FOG_DENSITY;
#endif

    density *= FOG_DENSITY;

    // Rain thickens the air considerably, which is what makes light shafts
    // through a storm so much more visible than on a clear day.
    density *= 1.0 + rainStrength * 2.5;

#if defined(CAVE_FOG)
    float caveAmount = (1.0 - saturate(skyAccess)) * CAVE_FOG_DENSITY;
    density += caveAmount * caveAmount * 6.0;
#endif

    return density;
}

//==============================================================================
// MARCH
//==============================================================================

/*
 * March the view ray, accumulating in-scattered light and extinction.
 *
 * `maxDistance` is the distance to the surface, or a large value for sky
 * pixels.
 */
VolumetricResult marchVolumetrics(vec3 rayDir, float maxDistance,
                                  float skyAccess, float dither) {
    VolumetricResult result;
    result.inScatter = vec3(0.0);
    result.transmittance = 1.0;

#if !ASTRA_ENABLE_VOLUMETRICS
    return result;
#else
    /*
     * Beyond the shadow distance the shadow map has no data, so there is
     * nothing to produce shafts with. Marching further would add uniform haze
     * at full ray-march cost, which the analytic fog does for free.
     */
    float marchDistance = min(maxDistance, shadowDistance);
    if (marchDistance <= 0.5) return result;

    int steps = VL_STEPS;
    float stepSize = marchDistance / float(steps);

    vec3 lightDir = shadowLightDirection();
    vec3 lightColor = shadowLightColor() * weatherDirectAttenuation();

    /*
     * Henyey-Greenstein anisotropy. Real haze scatters strongly forward, which
     * is why shafts blaze when you look toward the sun and nearly vanish when
     * you look away. Without it, volumetrics read as uniform milk.
     */
    float cosTheta = dot(rayDir, lightDir);
    float phase = henyeyGreenstein(cosTheta, VL_ANISOTROPY);

    // Ambient scattering has no preferred direction.
    vec3 ambient = skyAmbientIrradiance(ASTRA_UP) * ASTRA_INV_PI * 0.15;

    /*
     * Base scattering coefficient per block. Matched to the analytic fog's
     * extinction so both models describe the same air.
     */
    const float SCATTER_BASE = 0.0016;

    // Offset the first step per pixel. Fixed step positions in a volumetric
    // march show up as hard banded slices through the air.
    float travelled = stepSize * dither;

    for (int i = 0; i < steps; i++) {
        vec3 scenePos = rayDir * travelled;
        vec3 worldPos = worldPosition(scenePos);

        travelled += stepSize;

        float density = volumetricDensity(worldPos, skyAccess) * SCATTER_BASE;
        if (density <= 0.0) continue;

        //----------------------------------------------------------------------
        // Is this point in light?
        //----------------------------------------------------------------------

        /*
         * The geometric normal argument is the light direction itself, and
         * ndotl is 1: a point in the air has no surface orientation, so it is
         * lit whenever the shadow map says the light reaches it.
         */
        ShadowResult shadow = sampleShadow(scenePos, lightDir, 1.0, dither);

        vec3 lit = lightColor * shadow.visibility * shadow.tint;

        // Clouds shade the air below them, not just the ground. Skipping this
        // leaves shafts blazing under an overcast sky.
        lit *= cloudShadow(worldPos);

        vec3 scattered = lit * phase + ambient;

        //----------------------------------------------------------------------
        // Integrate the segment
        //----------------------------------------------------------------------

        float stepTransmittance = exp(-density * stepSize);

        vec3 segment = (scattered * density - scattered * density * stepTransmittance)
                     / max(density, ASTRA_EPSILON);

        result.inScatter += result.transmittance * segment;
        result.transmittance *= stepTransmittance;
    }

    result.inScatter *= VL_STRENGTH;

    return result;
#endif
}

//==============================================================================
// UNDERWATER
//==============================================================================

/*
 * Volumetric light through water.
 *
 * Worth handling separately because the medium is completely different: water
 * scatters far more than air and absorbs red preferentially, so the shafts are
 * shorter, much brighter and distinctly blue-green. Using the air parameters
 * underwater produces grey shafts in blue water, which reads as fog rather than
 * as light through liquid.
 */
VolumetricResult marchUnderwater(vec3 rayDir, float maxDistance, float dither) {
    VolumetricResult result;
    result.inScatter = vec3(0.0);
    result.transmittance = 1.0;

#if !ASTRA_ENABLE_VOLUMETRICS
    return result;
#else
    float marchDistance = min(maxDistance, min(shadowDistance, 48.0));
    if (marchDistance <= 0.5) return result;

    int steps = max(VL_STEPS / 2, 4);
    float stepSize = marchDistance / float(steps);

    vec3 lightDir = shadowLightDirection();
    vec3 lightColor = shadowLightColor() * weatherDirectAttenuation();

    float cosTheta = dot(rayDir, lightDir);

    // Water scatters more isotropically than air; suspended particles are
    // larger relative to the wavelength.
    float phase = henyeyGreenstein(cosTheta, VL_ANISOTROPY * 0.55);

    vec3 scatterCoeff = WATER_SCATTER_COEFF * 40.0 * WATER_SCATTERING;
    vec3 absorption = WATER_ABSORPTION_COEFF
                    * (12.0 / max(WATER_ABSORPTION_DISTANCE, 1.0));
    vec3 extinction = scatterCoeff + absorption;

    float travelled = stepSize * dither;

    for (int i = 0; i < steps; i++) {
        vec3 scenePos = rayDir * travelled;
        travelled += stepSize;

        ShadowResult shadow = sampleShadow(scenePos, lightDir, 1.0, dither);

        vec3 lit = lightColor * shadow.visibility * shadow.tint * 0.09;

        vec3 scattered = lit * phase * scatterCoeff;

        vec3 stepTransmittance = exp(-extinction * stepSize);

        vec3 segment = (scattered - scattered * stepTransmittance)
                     / max(extinction, vec3(ASTRA_EPSILON));

        result.inScatter += result.transmittance * segment;

        // Collapse to a scalar: the caller applies the coloured absorption
        // separately through the fog model, and carrying it twice would
        // double-count it.
        result.transmittance *= exp(-maxComponent(extinction) * stepSize);
    }

    result.inScatter *= VL_STRENGTH;

    return result;
#endif
}

#endif // ASTRA_VOLUMETRIC_GLSL
