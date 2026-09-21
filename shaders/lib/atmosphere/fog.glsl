#ifndef ASTRA_FOG_GLSL
#define ASTRA_FOG_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/scattering.glsl"

/*
 * AstraRealism - Fog.
 *
 * Fog here is an extinction and in-scattering pair, not a blend toward a grey
 * constant. The colour a distant object fades into is the sky radiance in that
 * direction, so haze over a sunset is orange near the sun and blue away from
 * it - the thing a uniform overlay can never do.
 */

struct FogResult {
    vec3 inScatter;      // light added along the path
    vec3 transmittance;  // fraction of the original colour that survives
};

//==============================================================================
// DENSITY
//==============================================================================

/*
 * Fog density at a given altitude.
 *
 * Exponential falloff with height, which is how real aerosol layers behave:
 * mist collects in valleys and thins out above them.
 */
float fogDensityAtHeight(float worldY) {
#if !defined(HEIGHT_FOG)
    return 1.0;
#else
    // Sea level is the reference altitude for the falloff.
    const float FOG_BASE_HEIGHT = 62.0;

    float relative = (worldY - FOG_BASE_HEIGHT) / HEIGHT_FOG_FALLOFF;

    return exp(-max(relative, -4.0)) * HEIGHT_FOG_DENSITY;
#endif
}

/*
 * Average density along a path, integrated analytically.
 *
 * For an exponential height profile the integral along a straight line has a
 * closed form, so this needs no ray march. The near-horizontal case is handled
 * separately because the general form divides by the vertical extent.
 */
float averageFogDensity(vec3 startWorld, vec3 endWorld) {
#if !defined(HEIGHT_FOG)
    return HEIGHT_FOG_DENSITY;
#else
    float dy = endWorld.y - startWorld.y;

    if (abs(dy) < 0.5) {
        return fogDensityAtHeight(startWorld.y);
    }

    float a = fogDensityAtHeight(startWorld.y);
    float b = fogDensityAtHeight(endWorld.y);

    // Integral of exp(-y/H) along the segment, divided by its length.
    return (a - b) * HEIGHT_FOG_FALLOFF / dy;
#endif
}

//==============================================================================
// FOG COLOUR
//==============================================================================

/*
 * Colour fog scatters toward the viewer.
 *
 * This is the sky radiance along the view ray, so fog inherits the atmosphere's
 * colour automatically. Underground and underwater cases substitute their own
 * source because there is no sky to sample.
 */
vec3 fogScatterColor(vec3 rayDir, float skyAccess) {
    vec3 skyColour = skyRadianceFull(rayDir);

    /*
     * Cave fog has no sky contribution at all. Its colour comes from block
     * light bouncing around the cave, which is warm and dim - blending toward
     * the sky colour underground is what makes most packs' caves look like they
     * are filled with grey smoke.
     */
    vec3 caveColour = blackbodyToRGB(float(BLOCKLIGHT_TEMPERATURE)) * 0.015;

    return mix(caveColour, skyColour, skyAccess);
}

//==============================================================================
// MAIN
//==============================================================================

/*
 * Fog over the path from the camera to a scene point.
 *
 * `skyAccess` is the surface's sky lightmap value, used to decide how much of
 * the fog is lit by the sky rather than by cave light.
 */
FogResult computeFog(vec3 scenePos, float skyAccess) {
    FogResult result;
    result.inScatter = vec3(0.0);
    result.transmittance = vec3(1.0);

#if !ASTRA_ENABLE_FOG
    return result;
#else
    float distance = length(scenePos);
    vec3 rayDir = scenePos / max(distance, ASTRA_EPSILON);

    vec3 startWorld = cameraPosition;
    vec3 endWorld = cameraPosition + scenePos;

    //--------------------------------------------------------------------------
    // Underwater
    //
    // Water absorbs red first and scatters blue, so the two must be modelled
    // separately - a single "blue fog" gets the near field wrong.
    //--------------------------------------------------------------------------

    if (isEyeInWater == 1) {
        vec3 absorption = WATER_ABSORPTION_COEFF
                        * (12.0 / max(WATER_ABSORPTION_DISTANCE, 1.0));
        vec3 scatter = WATER_SCATTER_COEFF * 40.0 * WATER_SCATTERING;

        vec3 extinction = absorption + scatter;

        result.transmittance = exp(-extinction * distance);

        // Light scattered into the path, lit by whatever reaches this depth.
        vec3 waterLight = shadowLightColor() * 0.04 + skyAmbientIrradiance(ASTRA_UP) * 0.02;
        result.inScatter = (waterLight * scatter / max(extinction, vec3(ASTRA_EPSILON)))
                         * (1.0 - result.transmittance);

        return result;
    }

    if (isEyeInWater == 2) {
        // Lava is effectively opaque within a block or two.
        vec3 extinction = vec3(1.4, 2.6, 4.2);
        result.transmittance = exp(-extinction * distance);
        result.inScatter = vec3(2.2, 0.55, 0.08) * (1.0 - result.transmittance);
        return result;
    }

    if (isEyeInWater == 3) {
        // Powder snow: dense, bright, near-white scattering.
        float extinction = 1.1;
        result.transmittance = vec3(exp(-extinction * distance));
        result.inScatter = vec3(0.85, 0.90, 1.0) * (1.0 - result.transmittance);
        return result;
    }

    //--------------------------------------------------------------------------
    // Atmospheric fog
    //--------------------------------------------------------------------------

    float density = averageFogDensity(startWorld, endWorld) * FOG_DENSITY;

    // Rain and thunder thicken the air considerably.
    density *= 1.0 + rainStrength * 2.5;

    /*
     * Base extinction coefficient, in inverse blocks. Chosen so that at default
     * density the horizon at a few hundred blocks is visibly hazy but not
     * obscured.
     */
    const float FOG_EXTINCTION_BASE = 0.0012;

    // Fog scatters slightly more blue than red, like a thin atmosphere.
    vec3 extinction = vec3(FOG_EXTINCTION_BASE) * vec3(0.92, 1.0, 1.15) * density;

#if defined(CAVE_FOG)
    /*
     * Underground, density rises sharply as sky access falls. This restores the
     * depth cue that caves lose without it - a long tunnel reads as long.
     */
    float caveAmount = (1.0 - saturate(skyAccess)) * CAVE_FOG_DENSITY;
    extinction += vec3(0.010) * caveAmount * caveAmount;
#endif

    result.transmittance = exp(-extinction * distance);

    vec3 scatterColor = fogScatterColor(rayDir, saturate(skyAccess));

    /*
     * In-scattered light is boosted toward the sun by the Mie phase function,
     * which is why haze glows when you look into a low sun. Without this the
     * fog is flat and reads as an overlay.
     */
    float cosSun = dot(rayDir, shadowLightDirection());
    float forwardGain = 1.0 + cornetteShanks(cosSun, 0.6) * 6.0;

    result.inScatter = scatterColor * forwardGain * (1.0 - result.transmittance);

    // Blindness collapses visibility to a few blocks.
    if (blindness > 0.0) {
        float blindExtinction = blindness * 0.35;
        vec3 blindTransmittance = vec3(exp(-blindExtinction * distance));
        result.transmittance *= blindTransmittance;
        result.inScatter *= blindTransmittance;
    }

    return result;
#endif
}

// Convenience wrapper: apply fog to an already-shaded colour.
vec3 applyFog(vec3 color, vec3 scenePos, float skyAccess) {
    FogResult fog = computeFog(scenePos, skyAccess);
    return color * fog.transmittance + fog.inScatter;
}

#endif // ASTRA_FOG_GLSL
