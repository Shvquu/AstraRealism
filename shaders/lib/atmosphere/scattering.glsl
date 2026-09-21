#ifndef ASTRA_SCATTERING_GLSL
#define ASTRA_SCATTERING_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"

/*
 * AstraRealism - Atmospheric scattering.
 *
 * A single-scattering ray march through a spherical atmosphere with Rayleigh,
 * Mie and ozone terms, plus an approximation of multiple scattering.
 *
 * The sky colour is not painted. It is the result of integrating how much light
 * scatters toward the viewer along a ray through the air, which is why the
 * horizon reddens at sunset, why the zenith stays blue longest, and why
 * twilight is blue rather than brown - all without a single hand-picked colour.
 *
 * Structure follows Bruneton & Neyret (2008) and the simplifications in
 * Hillaire, "A Scalable and Production Ready Sky and Atmosphere Rendering
 * Technique" (2020).
 */

//==============================================================================
// ATMOSPHERE SAMPLING
//==============================================================================

/*
 * Density of each scattering species at a given altitude above sea level, in
 * kilometres. Returns (rayleigh, mie, ozone).
 *
 * Rayleigh and Mie fall off exponentially with their own scale heights. Ozone
 * does not: it is concentrated in a layer around 25 km, modelled here as a
 * tent function, which is what keeps the sky blue during deep twilight.
 */
vec3 atmosphereDensity(float altitudeKm) {
    float rayleigh = exp(-altitudeKm / ATMO_RAYLEIGH_HEIGHT);
    float mie = exp(-altitudeKm / ATMO_MIE_HEIGHT);

    float ozone = max(0.0, 1.0 - abs(altitudeKm - ATMO_OZONE_CENTER) / ATMO_OZONE_WIDTH);

    return vec3(rayleigh, mie, ozone);
}

// Extinction coefficient at a point, summed over all species.
vec3 atmosphereExtinction(vec3 density) {
    return ATMO_RAYLEIGH_SCATTER * density.x
         + (ATMO_MIE_SCATTER + ATMO_MIE_ABSORB) * density.y
         + ATMO_OZONE_ABSORB * density.z;
}

/*
 * Transmittance from a point along a direction to the top of the atmosphere.
 *
 * Marched rather than looked up. Eight steps is plenty because the integrand is
 * smooth and monotonic, and this is only evaluated once per sample of the outer
 * march rather than per pixel.
 */
vec3 transmittanceToSpace(vec3 position, vec3 direction) {
    vec2 hit = raySphereIntersect(position, direction, ATMO_ATMOSPHERE_RADIUS);
    if (hit.y < 0.0) return vec3(1.0);

    // If the ray dives into the planet, nothing gets through.
    vec2 groundHit = raySphereIntersect(position, direction, ATMO_PLANET_RADIUS);
    if (groundHit.x > 0.0) return vec3(0.0);

    const int STEPS = 8;
    float stepSize = hit.y / float(STEPS);

    vec3 opticalDepth = vec3(0.0);

    for (int i = 0; i < STEPS; i++) {
        vec3 samplePos = position + direction * (float(i) + 0.5) * stepSize;
        float altitude = length(samplePos) - ATMO_PLANET_RADIUS;

        opticalDepth += atmosphereExtinction(atmosphereDensity(altitude)) * stepSize;
    }

    return exp(-opticalDepth);
}

//==============================================================================
// MULTIPLE SCATTERING
//==============================================================================

/*
 * Approximation of light that scatters more than once before reaching the eye.
 *
 * A single-scattering-only sky is noticeably too dark near the horizon and goes
 * almost black during twilight, because in reality a large fraction of the
 * light arriving from those directions has bounced several times.
 *
 * Rather than precompute the full second-order integral, this uses the
 * geometric-series closed form from Hillaire (2020): if each scattering event
 * returns a fraction f of the energy, the total over infinite orders is
 * 1/(1-f). The isotropic factor below is a tuned stand-in for f.
 */
vec3 multipleScatteringApproximation(vec3 density, vec3 sunTransmittance) {
    vec3 scattering = ATMO_RAYLEIGH_SCATTER * density.x + ATMO_MIE_SCATTER * density.y;
    vec3 extinction = max(atmosphereExtinction(density), vec3(ASTRA_EPSILON));

    // Single-scattering albedo: the fraction of interactions that scatter
    // rather than absorb.
    vec3 albedo = scattering / extinction;

    // Geometric series for repeated isotropic scattering.
    vec3 seriesSum = albedo / max(vec3(1.0) - albedo * 0.72, vec3(0.05));

    // Isotropic phase function, times the light that reaches this altitude.
    return seriesSum * sunTransmittance * (1.0 / (4.0 * ASTRA_PI));
}

//==============================================================================
// SKY RADIANCE
//==============================================================================

/*
 * Radiance arriving from a direction in the sky.
 *
 * `rayDir` is a scene-space unit vector. `lightDir` and `lightColor` describe
 * whichever body is dominant, so the same function renders both the day sky and
 * moonlit night.
 */
vec3 skyRadiance(vec3 rayDir, vec3 lightDir, vec3 lightColor, int steps) {
    // The viewer stands on the planet surface. Minecraft altitudes are tiny
    // compared with atmospheric scale, so eye height is folded in as metres
    // rather than being allowed to move the observer meaningfully.
    vec3 origin = vec3(0.0, ATMO_PLANET_RADIUS + max(eyeAltitude, 0.0) * 0.001, 0.0);

    vec2 atmosphereHit = raySphereIntersect(origin, rayDir, ATMO_ATMOSPHERE_RADIUS);
    if (atmosphereHit.y <= 0.0) return vec3(0.0);

    float rayLength = atmosphereHit.y;

    // Stop at the ground for downward rays so the lower hemisphere does not
    // accumulate a full atmosphere's worth of scattering.
    vec2 groundHit = raySphereIntersect(origin, rayDir, ATMO_PLANET_RADIUS);
    if (groundHit.x > 0.0) rayLength = min(rayLength, groundHit.x);

    float cosTheta = dot(rayDir, lightDir);
    float rayleighPhaseValue = rayleighPhase(cosTheta);
    float miePhaseValue = cornetteShanks(cosTheta, ATMO_MIE_G);

    float stepSize = rayLength / float(steps);

    vec3 radiance = vec3(0.0);
    vec3 transmittance = vec3(1.0);

    for (int i = 0; i < steps; i++) {
        vec3 samplePos = origin + rayDir * (float(i) + 0.5) * stepSize;
        float altitude = length(samplePos) - ATMO_PLANET_RADIUS;

        vec3 density = atmosphereDensity(altitude);
        vec3 extinction = atmosphereExtinction(density);

        vec3 sunTransmittance = transmittanceToSpace(samplePos, lightDir);

        // Light scattered toward the viewer at this point, weighted by each
        // species' phase function.
        vec3 inScatter =
              ATMO_RAYLEIGH_SCATTER * density.x * rayleighPhaseValue
            + ATMO_MIE_SCATTER * density.y * miePhaseValue;

        vec3 scattered = inScatter * sunTransmittance;

#if defined(ATMOSPHERE_MULTISCATTER)
        scattered += multipleScatteringApproximation(density, sunTransmittance)
                   * (ATMO_RAYLEIGH_SCATTER * density.x + ATMO_MIE_SCATTER * density.y);
#endif

        /*
         * Analytic integration of the segment rather than a rectangle rule.
         * Treating extinction as constant across the step and solving exactly
         * removes the banding that plain accumulation produces at low step
         * counts, which is what lets ATMOSPHERE_STEPS go as low as 8.
         */
        vec3 stepTransmittance = exp(-extinction * stepSize);
        vec3 segmentIntegral = (scattered - scattered * stepTransmittance)
                             / max(extinction, vec3(ASTRA_EPSILON));

        radiance += transmittance * segmentIntegral;
        transmittance *= stepTransmittance;
    }

    return radiance * lightColor;
}

/*
 * Full sky radiance including both sun and moon contributions.
 */
vec3 skyRadianceFull(vec3 rayDir) {
    vec3 result = vec3(0.0);

    float day = dayFactor();

    if (day > 0.001) {
        result += skyRadiance(rayDir, sunDirection(),
                              blackbodyToRGB(SUN_TEMPERATURE_K) * SUN_INTENSITY,
                              ATMOSPHERE_STEPS) * day;
    }

    if (day < 0.999) {
        result += skyRadiance(rayDir, moonDirection(),
                              moonlightColor(), max(ATMOSPHERE_STEPS / 2, 4))
                * (1.0 - day);
    }

    return result;
}

//==============================================================================
// AMBIENT IRRADIANCE
//==============================================================================

/*
 * Irradiance from the sky onto a surface with the given normal.
 *
 * Integrating the sky dome per pixel would be far too expensive, so this
 * samples three representative directions - zenith, and two at the horizon on
 * either side of the light - and blends them by how much of each hemisphere the
 * normal faces. That captures the two things that actually matter: the sky is
 * bluer overhead than at the horizon, and the horizon nearest the sun is much
 * brighter than the opposite one.
 */
vec3 skyAmbientIrradiance(vec3 normal) {
    vec3 lightDir = shadowLightDirection();

    // Horizon direction on the light's side.
    vec3 horizonToward = normalize(vec3(lightDir.x, 0.05, lightDir.z));
    vec3 horizonAway = normalize(vec3(-lightDir.x, 0.05, -lightDir.z));

    int steps = max(ATMOSPHERE_STEPS / 3, 4);

    vec3 zenith = skyRadiance(ASTRA_UP, lightDir, shadowLightColor(), steps);
    vec3 toward = skyRadiance(horizonToward, lightDir, shadowLightColor(), steps);
    vec3 away = skyRadiance(horizonAway, lightDir, shadowLightColor(), steps);

    // How much the surface faces up versus sideways.
    float upness = saturate(normal.y * 0.5 + 0.5);

    // Which horizon the surface faces.
    float towardness = saturate(dot(normalize(vec3(normal.x, 0.0, normal.z) + 1e-4),
                                    horizonToward) * 0.5 + 0.5);

    vec3 horizon = mix(away, toward, towardness);

    // pi converts radiance to irradiance for a cosine-weighted hemisphere.
    return mix(horizon, zenith, upness) * ASTRA_PI;
}

#endif // ASTRA_SCATTERING_GLSL
