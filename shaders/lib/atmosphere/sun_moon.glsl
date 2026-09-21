#ifndef ASTRA_SUN_MOON_GLSL
#define ASTRA_SUN_MOON_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Sun and moon position, colour and intensity.
 *
 * Light colour is never selected from a table of presets. It falls out of
 * atmospheric extinction: the low sun's light travels through far more air, so
 * short wavelengths scatter away and what reaches the ground is red. Sunrise
 * and sunset are therefore continuous consequences of geometry rather than
 * keyframed colour ramps.
 */

//==============================================================================
// DIRECTIONS
//==============================================================================

// Scene-space up. Minecraft's world axes are fixed, so this is a constant.
const vec3 ASTRA_UP = vec3(0.0, 1.0, 0.0);

vec3 sunDirection() {
    return normalize(viewToSceneDir(sunPosition));
}

vec3 moonDirection() {
    return normalize(viewToSceneDir(moonPosition));
}

/*
 * Direction of whichever body is currently casting shadows. Minecraft hands
 * the shadow pass over from sun to moon at dusk, and this uniform follows that
 * handover - deriving it from sunAngle instead would desynchronise the lighting
 * from the shadow map for a few frames at the transition.
 */
vec3 shadowLightDirection() {
    return normalize(viewToSceneDir(shadowLightPosition));
}

// Sine of the sun's elevation: +1 at zenith, 0 at the horizon, -1 at nadir.
float sunElevation() {
    return dot(sunDirection(), ASTRA_UP);
}

/*
 * How much of the lighting comes from the sun rather than the moon.
 *
 * The blend is centred slightly below the horizon and spread over a few
 * degrees, which matches civil twilight: the sun is already down while the sky
 * is still lit. A hard switch at elevation 0 produces a visible pop.
 */
float dayFactor() {
    return smoothstep(-0.06, 0.06, sunElevation());
}

//==============================================================================
// ATMOSPHERIC EXTINCTION ALONG THE LIGHT PATH
//==============================================================================

/*
 * Relative air mass for a given elevation.
 *
 * A flat-earth 1/cos(zenith) model diverges at the horizon, which is exactly
 * where sunset colour is decided. Kasten & Young (1989) fit the real curved
 * atmosphere and stays finite, peaking near 38 air masses at the horizon.
 */
float airMass(float cosZenith) {
    float elevationDeg = degrees(asin(clamp(cosZenith, -1.0, 1.0)));
    float denom = cosZenith + 0.50572 * pow(max(elevationDeg + 6.07995, 0.0), -1.6364);
    return 1.0 / max(denom, 0.001);
}

/*
 * Transmittance of the atmosphere along the path to a light at the given
 * elevation, via Beer-Lambert over Rayleigh, Mie and ozone extinction.
 *
 * Phase 1 replaces this with a sample from the precomputed transmittance LUT.
 * The analytic form is kept because it is what the shadow and sky passes fall
 * back to before the LUT exists, and the two agree closely enough that the
 * switch is not visible.
 */
vec3 atmosphericTransmittance(float cosZenith) {
    float mass = airMass(max(cosZenith, -0.05));

    // Optical depth is the coefficient times the scale height times air mass.
    vec3 rayleighDepth = ATMO_RAYLEIGH_SCATTER * ATMO_RAYLEIGH_HEIGHT * mass;
    vec3 mieDepth = (ATMO_MIE_SCATTER + ATMO_MIE_ABSORB) * ATMO_MIE_HEIGHT * mass;

    // Ozone sits in a layer well above the scattering bulk, so its contribution
    // grows more slowly with air mass than the others.
    vec3 ozoneDepth = ATMO_OZONE_ABSORB * ATMO_OZONE_WIDTH * min(mass, 8.0);

    return exp(-(rayleighDepth + mieDepth + ozoneDepth));
}

//==============================================================================
// LIGHT COLOUR
//==============================================================================

/*
 * Colour of direct sunlight reaching the ground.
 *
 * Starts from the sun's 5778 K blackbody spectrum, then applies the extinction
 * above. The result warms and dims continuously as the sun descends, and the
 * ozone term keeps the last light of twilight blue rather than brown.
 */
vec3 sunlightColor() {
    vec3 base = blackbodyToRGB(SUN_TEMPERATURE_K);
    vec3 transmittance = atmosphericTransmittance(sunElevation());

    return base * transmittance * SUN_INTENSITY;
}

/*
 * Colour of direct moonlight.
 *
 * Physically this is sunlight reflected off a dark grey regolith, so it should
 * be warm; it looks blue to us because at low light levels the eye switches to
 * rod-dominated vision, which peaks at a shorter wavelength. MOON_ALBEDO_TINT
 * encodes that perceptual shift, not a reflectance.
 *
 * Intensity follows the illuminated fraction of the disc. moonPhase 0 is full
 * moon and 4 is new moon.
 */
vec3 moonlightColor() {
    vec3 base = blackbodyToRGB(SUN_TEMPERATURE_K) * MOON_ALBEDO_TINT;
    vec3 transmittance = atmosphericTransmittance(dot(moonDirection(), ASTRA_UP));

    // Cosine of the phase angle, remapped to an illuminated fraction. The new
    // moon keeps a small floor so nights never go completely lightless.
    float phase = cos(float(moonPhase) * ASTRA_TAU / 8.0) * 0.5 + 0.5;
    float illumination = mix(0.35, 1.0, phase);

    return base * transmittance * illumination * MOON_INTENSITY;
}

/*
 * Colour and intensity of whichever body is currently casting shadows,
 * cross-faded through twilight so there is no discontinuity at the handover.
 */
vec3 shadowLightColor() {
    return mix(moonlightColor(), sunlightColor(), dayFactor());
}

//==============================================================================
// WEATHER
//==============================================================================

/*
 * Attenuation of direct light by cloud cover during rain.
 *
 * Overcast skies cut direct sun by roughly an order of magnitude, but the sky
 * itself stays bright because the light is diffused rather than absorbed - so
 * this applies to direct light only, never to skylight.
 */
float weatherDirectAttenuation() {
    return mix(1.0, 0.12, rainStrength);
}

#endif // ASTRA_SUN_MOON_GLSL
