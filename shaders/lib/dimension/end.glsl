#ifndef ASTRA_DIM_END_GLSL
#define ASTRA_DIM_END_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - The End.
 *
 * Islands of stone floating in a void, under a sky with no sun and no horizon.
 *
 * Its lighting problem is the opposite of the Nether's. The Nether is enclosed
 * and lit from within; the End is open and lit from nowhere in particular. The
 * light has no source you can point at, which is what makes it feel unmoored.
 *
 * The model:
 *   - A dim violet dome that is the only illumination, so ambient light is
 *     essentially the whole lighting budget.
 *   - Almost no fog. Distance in the End is meant to read as emptiness, not as
 *     haze; the islands recede into darkness rather than into murk.
 *   - A void below that absorbs rather than reflects, so looking down gives
 *     nothing back.
 *   - Stars, unattenuated - there is no atmosphere to scatter them out.
 */

//==============================================================================
// CONSTANTS
//==============================================================================

/*
 * The End's characteristic colour.
 *
 * Violet is the one hue that cannot be produced by a single blackbody, which
 * is part of why the End reads as unnatural: no ordinary light source makes
 * this colour. It is specified directly rather than derived from a temperature,
 * because deriving it would be dishonest about what it is.
 */
const vec3 END_SKY_COLOR = vec3(0.16, 0.10, 0.28);
const vec3 END_HORIZON_COLOR = vec3(0.26, 0.16, 0.38);
const vec3 END_VOID_COLOR = vec3(0.020, 0.012, 0.038);

//==============================================================================
// INTERFACE
//==============================================================================

bool dimensionHasSky() { return true; }

bool dimensionHasClouds() { return false; }

/*
 * The End sky.
 *
 * A vertical gradient from the void below through a slightly brighter band at
 * eye level to the deep violet dome overhead, with stars throughout.
 *
 * The brighter band is not a horizon in the atmospheric sense - there is no air
 * to scatter light along a long path. It exists because the floating islands
 * are lit from all sides and the eye needs a reference plane to read depth
 * against; without it the whole view becomes an unreadable flat field.
 */
vec3 dimensionSkyRadiance(vec3 rayDir) {
    float upward = rayDir.y;

    // Void below, dome above, band at the join.
    vec3 sky = mix(END_VOID_COLOR, END_HORIZON_COLOR,
                   smoothstep(-0.6, 0.0, upward));
    sky = mix(sky, END_SKY_COLOR, smoothstep(0.0, 0.7, upward));

    /*
     * Stars, at full brightness. In the overworld they are attenuated by
     * atmospheric transmittance; here there is no atmosphere, so they stay
     * sharp all the way to the horizon. That difference is subtle but it is
     * exactly the sort of thing that makes a place feel airless.
     */
#if defined(STARS_ENABLED)
    vec3 celestial = rotateAroundAxis(rayDir, normalize(vec3(0.2, 1.0, 0.1)),
                                      frameTimeCounter * 0.004);

    vec3 cell = floor(celestial * 220.0);
    vec3 local = fract(celestial * 220.0) - 0.5;
    vec3 random = hash3(cell);

    if (random.x < 0.010 && upward > -0.35) {
        float dist = length(local.xy - (random.yz - 0.5) * 0.6);
        float magnitude = pow(fract(random.x * 83.0), 3.0);
        float intensity = smoothstep(0.10, 0.0, dist) * magnitude;

        // Cooler than overworld stars, which suits the palette and is
        // consistent with there being no warm scattering to shift them.
        sky += blackbodyToRGB(mix(5500.0, 12000.0, fract(random.y * 41.0)))
             * intensity * STARS_INTENSITY * 22.0;
    }
#endif

    return sky;
}

/*
 * Ambient irradiance reaching a surface.
 *
 * Upward-facing surfaces receive the dome; downward-facing ones receive the
 * void, which gives back almost nothing.
 *
 * Like the Nether, not gated by the sky lightmap - Minecraft reports zero sky
 * light throughout the End. Unlike the Nether, this is essentially the whole
 * lighting model: with no sun there is no direct term to fall back on, so if
 * this returned nothing the dimension would be black.
 */
vec3 dimensionAmbientLight(vec3 normal, float lightmapSky) {
    float upward = saturate(normal.y * 0.5 + 0.5);

    vec3 received = mix(END_VOID_COLOR * 0.6, END_SKY_COLOR, upward * upward);

    // Sideways-facing surfaces catch the brighter band.
    float sideways = 1.0 - abs(normal.y);
    received += END_HORIZON_COLOR * sideways * 0.28;

    return received * ASTRA_PI * 1.15;
}

vec3 dimensionFogColor(vec3 rayDir, float skyAccess) {
    return dimensionSkyRadiance(rayDir);
}

/*
 * Extinction for the End.
 *
 * Deliberately very low. The End's sense of scale comes from emptiness, and
 * filling it with haze would make it feel small. Distant islands should fade
 * because they are dim, not because there is something in the way.
 */
vec3 dimensionFogExtinction() {
    return vec3(0.0006, 0.0005, 0.0009) * FOG_DENSITY;
}

#endif // ASTRA_DIM_END_GLSL
