#ifndef ASTRA_SKY_GLSL
#define ASTRA_SKY_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/scattering.glsl"

/*
 * AstraRealism - Sky rendering.
 *
 * Composes the final sky from the scattering model plus the celestial bodies.
 * The vanilla sky dome, sun and moon quads and star field are all discarded in
 * the gbuffers pass and rebuilt here, which is what allows the sun to dim and
 * redden through its own atmosphere and the stars to fade correctly as the sky
 * brightens.
 */

//==============================================================================
// STARS
//==============================================================================

/*
 * Procedural star field.
 *
 * Stars are placed by hashing a coarse grid on the sky sphere and keeping the
 * brightest few per cell, which gives an irregular distribution without a
 * texture. The field is built in a fixed celestial frame so it rotates with the
 * sky rather than with the player's head.
 */
vec3 renderStars(vec3 rayDir) {
#if !defined(STARS_ENABLED)
    return vec3(0.0);
#else
    // Rotate with the day cycle so the sky wheels overhead.
    float skyRotation = sunAngle * ASTRA_TAU;
    vec3 celestial = rotateAroundAxis(rayDir, normalize(vec3(0.3, 0.0, 1.0)),
                                      skyRotation);

    // Grid density. Higher values give more, smaller stars.
    const float STAR_GRID = 180.0;

    vec3 cell = floor(celestial * STAR_GRID);
    vec3 local = fract(celestial * STAR_GRID) - 0.5;

    vec3 random = hash3(cell);

    // Only a small fraction of cells contain a star.
    if (random.x > 0.014) return vec3(0.0);

    // Position within the cell, so stars are not on a visible lattice.
    vec2 offset = (random.yz - 0.5) * 0.7;
    float distance = length(local.xy - offset);

    // Star brightness follows a steep distribution: many faint, few bright.
    float magnitude = pow(fract(random.x * 71.0), 3.0);

    float intensity = smoothstep(0.09, 0.0, distance) * magnitude;

    /*
     * Colour by temperature. Real stars run from cool red dwarfs to hot blue
     * giants, and the brighter ones skew hotter, so brightness and colour are
     * correlated rather than independent.
     */
    float temperature = mix(3200.0, 11000.0, fract(random.y * 37.0));
    vec3 color = blackbodyToRGB(temperature);

    // Slow twinkle from atmospheric turbulence. Faster near the horizon, where
    // the light passes through more air.
    float horizonFactor = 1.0 - abs(rayDir.y);
    float twinkle = 0.75 + 0.25 * sin(frameTimeCounter * 3.0
                                      + random.z * ASTRA_TAU) * horizonFactor;

    return color * intensity * twinkle * STARS_INTENSITY * 40.0;
#endif
}

//==============================================================================
// CELESTIAL BODIES
//==============================================================================

/*
 * The sun disc.
 *
 * Rendered as a sharp-edged disc with limb darkening: the sun's edge is
 * genuinely dimmer than its centre because light from the limb leaves at a
 * shallow angle and escapes from a cooler, higher layer of the photosphere.
 */
vec3 renderSunDisc(vec3 rayDir) {
    vec3 sunDir = sunDirection();

    float cosAngle = dot(rayDir, sunDir);
    float angularRadius = radians(SUN_ANGULAR_RADIUS);
    float cosRadius = cos(angularRadius);

    if (cosAngle < cosRadius) return vec3(0.0);

    // Normalised distance from the centre of the disc, 0 to 1.
    float angle = acos(clamp(cosAngle, -1.0, 1.0));
    float r = saturate(angle / angularRadius);

    // Eddington limb darkening, the standard first-order approximation.
    float mu = sqrt(max(0.0, 1.0 - r * r));
    float limb = 0.4 + 0.6 * mu;

    // Soften the very edge so the disc is not aliased.
    float edge = smoothstep(1.0, 0.96, r);

    vec3 color = blackbodyToRGB(SUN_TEMPERATURE_K)
               * atmosphericTransmittance(sunElevation());

    return color * limb * edge * SUN_INTENSITY * 30.0;
}

/*
 * The moon disc.
 *
 * Drawn as a lit sphere rather than a flat disc, so the terminator curves the
 * way a real crescent does. The phase comes from Minecraft's moonPhase.
 */
vec3 renderMoonDisc(vec3 rayDir) {
    vec3 moonDir = moonDirection();

    // The moon reads as noticeably larger than the sun in Minecraft.
    float angularRadius = radians(SUN_ANGULAR_RADIUS * 1.8);
    float cosAngle = dot(rayDir, moonDir);

    if (cosAngle < cos(angularRadius)) return vec3(0.0);

    float angle = acos(clamp(cosAngle, -1.0, 1.0));
    float r = saturate(angle / angularRadius);

    // Build a local frame on the disc to find the surface normal of the sphere
    // it represents.
    vec3 right, up;
    buildOrthonormalBasis(moonDir, right, up);

    vec3 offset = rayDir - moonDir * cosAngle;
    vec2 discPos = vec2(dot(offset, right), dot(offset, up)) / angularRadius;

    float z = sqrt(max(0.0, 1.0 - dot(discPos, discPos)));
    vec3 surfaceNormal = normalize(right * discPos.x + up * discPos.y + moonDir * z);

    /*
     * Direction to the sun as seen from the moon. Minecraft's moon phase is a
     * discrete 0-7; converting it to an angle and placing a virtual sun at that
     * bearing reproduces the correct crescent shape and orientation.
     */
    float phaseAngle = float(moonPhase) * ASTRA_TAU / 8.0;
    vec3 moonSunDir = normalize(right * sin(phaseAngle) + moonDir * cos(phaseAngle));

    float illumination = saturate(dot(surfaceNormal, moonSunDir));

    // The lunar surface is back-scattering, which is why a full moon looks
    // like a flat disc rather than a shaded ball.
    illumination = pow(illumination, 0.35);

    // Faint mare patterning so the disc is not a featureless circle.
    float mare = 0.82 + 0.18 * valueNoise(surfaceNormal * 7.0);

    float edge = smoothstep(1.0, 0.97, r);

    vec3 color = blackbodyToRGB(SUN_TEMPERATURE_K) * MOON_ALBEDO_TINT
               * atmosphericTransmittance(dot(moonDir, ASTRA_UP));

    return color * illumination * mare * edge * MOON_INTENSITY * 6.0;
}

//==============================================================================
// COMPOSITE
//==============================================================================

/*
 * Full sky radiance for a view direction.
 *
 * Stars and celestial bodies are attenuated by the same atmospheric
 * transmittance as everything else, which is what makes stars disappear as the
 * sky brightens instead of needing an explicit fade.
 */
vec3 renderSky(vec3 rayDir) {
    vec3 result = skyRadianceFull(rayDir);

    // Only the upper hemisphere shows celestial objects; below the horizon the
    // planet blocks them.
    if (rayDir.y > -0.02) {
        vec3 background = renderStars(rayDir) + renderMoonDisc(rayDir)
                        + renderSunDisc(rayDir);

        /*
         * Attenuate by the transmittance along the view ray. Faint objects
         * disappear into a bright sky because the scattered light in front of
         * them outshines them, which is exactly what this ratio expresses.
         */
        vec3 viewTransmittance = atmosphericTransmittance(max(rayDir.y, 0.0));

        result += background * viewTransmittance;
    }

    // Rain thickens the atmosphere and flattens it toward the fog colour.
    if (rainStrength > 0.0) {
        vec3 overcast = vec3(luminance(result)) * vec3(0.92, 0.95, 1.0);
        result = mix(result, overcast, rainStrength * 0.75);
    }

    return result;
}

#endif // ASTRA_SKY_GLSL
