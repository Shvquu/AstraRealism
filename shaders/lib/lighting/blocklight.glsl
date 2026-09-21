#ifndef ASTRA_BLOCKLIGHT_GLSL
#define ASTRA_BLOCKLIGHT_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"

/*
 * AstraRealism - Block light and sky light from the vanilla lightmap.
 *
 * Minecraft gives each vertex two 0-1 coordinates: how much light reaches it
 * from block sources, and how much from the sky. Vanilla feeds those into a
 * lookup texture. We ignore that texture and build the response ourselves,
 * because the vanilla curve is tuned for a non-HDR pipeline and produces
 * washed-out, uniformly grey interiors once real tone mapping is applied.
 */

//==============================================================================
// BLOCK LIGHT
//==============================================================================

/*
 * Radiance from nearby block light sources.
 *
 * The vanilla lightmap coordinate is already a distance falloff, but a linear
 * one: it steps down by a fixed amount per block. Real point-source falloff is
 * inverse-square, so raising the coordinate to a power recovers a curve much
 * closer to the real thing - bright close to the torch and dropping off fast.
 *
 * A small quadratic term is added back near the top of the range so the block
 * immediately next to a torch does not clip to flat white.
 */
vec3 blockLightRadiance(float lightmapBlock) {
    float l = saturate(lightmapBlock);

    float falloff = pow(l, BLOCKLIGHT_FALLOFF);

    // Torches have a visible bright core. Without this the light reads as a
    // flat wash rather than as something with a source.
    falloff += pow(l, BLOCKLIGHT_FALLOFF * 3.0) * 0.6;

    vec3 tint = blackbodyToRGB(float(BLOCKLIGHT_TEMPERATURE));

    return tint * falloff * BLOCKLIGHT_INTENSITY;
}

/*
 * Light from the block the player is holding.
 *
 * Minecraft reports the held light level but not its position, so this is
 * modelled as a point source at the camera. It only matters in caves, where it
 * is the difference between holding a torch and holding nothing.
 */
vec3 heldLightRadiance(vec3 scenePos, vec3 normal) {
    int level = max(heldBlockLightValue, heldBlockLightValue2);
    if (level <= 0) return vec3(0.0);

    float distance = length(scenePos);

    // Inverse-square falloff, softened near zero and cut off at the light's
    // nominal range so it does not linger as a faint glow across the room.
    float range = float(level);
    float attenuation = saturate(1.0 - distance / range);
    attenuation = attenuation * attenuation / (1.0 + distance * distance * 0.1);

    // The light sits at the camera, so its direction is the view direction.
    float ndotl = clampedDot(normal, normalize(-scenePos));

    vec3 tint = blackbodyToRGB(float(BLOCKLIGHT_TEMPERATURE));

    return tint * attenuation * ndotl * BLOCKLIGHT_INTENSITY;
}

//==============================================================================
// SKY LIGHT
//==============================================================================

/*
 * Ambient radiance from the sky dome.
 *
 * The sky light coordinate says how much of the sky the point can see. Squaring
 * it biases the response toward genuinely open areas, which stops cave mouths
 * and overhangs from receiving nearly as much light as open ground.
 *
 * `skyColor` is the ambient colour of the sky for the current conditions,
 * supplied by the atmosphere model.
 */
vec3 skyLightRadiance(float lightmapSky, vec3 skyAmbient) {
    float l = saturate(lightmapSky);

    // Squared response, with a small linear term so deep interiors are not
    // completely severed from the outdoors.
    float falloff = l * l * 0.9 + l * 0.1;

    return skyAmbient * falloff * SKYLIGHT_INTENSITY;
}

//==============================================================================
// FLOOR
//==============================================================================

/*
 * Light floor applied everywhere.
 *
 * Nothing in the world is lit by this in a physical sense; it exists so that
 * unlit caves stay navigable instead of rendering as pure black. Night vision
 * and the darkness effect both scale it.
 */
vec3 minimumLight(vec3 albedo) {
    float floorLevel = MINIMUM_LIGHT;

    // Night vision lifts the floor substantially.
    floorLevel += nightVision * 0.25;

    // The Warden's darkness effect pulls it back down.
    floorLevel *= 1.0 - saturate(darknessFactor);

    // Slightly blue, as scotopic vision is.
    return albedo * floorLevel * vec3(0.75, 0.85, 1.0);
}

#endif // ASTRA_BLOCKLIGHT_GLSL
