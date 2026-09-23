#ifndef ASTRA_CLOUDS_GLSL
#define ASTRA_CLOUDS_GLSL

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/scattering.glsl"

/*
 * AstraRealism - Volumetric clouds.
 *
 * Clouds are marched as a real density field inside a spherical shell, not
 * drawn as a texture on a plane. That is what gives them silhouettes that
 * change as you move, bases that darken, edges that glow when backlit, and
 * shadows they can cast on the ground.
 *
 * The density field follows the approach Andrew Schneider described for
 * Horizon Zero Dawn (SIGGRAPH 2015): low-frequency Perlin-Worley noise for the
 * overall shape, higher-frequency Worley noise eroding its edges, and a
 * separate weather field deciding coverage and height.
 */

//==============================================================================
// SHELL GEOMETRY
//==============================================================================

// The cloud layer as a pair of radii around the planet centre.
float cloudLayerBottom() { return ATMO_PLANET_RADIUS + CLOUD_ALTITUDE * 0.001; }
float cloudLayerTop() {
    return ATMO_PLANET_RADIUS + (CLOUD_ALTITUDE + CLOUD_THICKNESS) * 0.001;
}

/*
 * Where a view ray enters and leaves the cloud shell.
 *
 * Returns vec2(entry, exit) distances in kilometres, or vec2(-1.0) if the ray
 * misses the layer entirely - looking down at the ground, for instance.
 */
vec2 cloudShellIntersect(vec3 origin, vec3 direction) {
    vec2 bottom = raySphereIntersect(origin, direction, cloudLayerBottom());
    vec2 top = raySphereIntersect(origin, direction, cloudLayerTop());

    if (top.y < 0.0) return vec2(-1.0);

    float altitude = length(origin) - ATMO_PLANET_RADIUS;
    float layerBottom = cloudLayerBottom() - ATMO_PLANET_RADIUS;
    float layerTop = cloudLayerTop() - ATMO_PLANET_RADIUS;

    if (altitude < layerBottom) {
        // Below the clouds, the usual case: enter at the bottom shell, leave
        // at the top.
        if (bottom.y < 0.0) return vec2(-1.0);
        return vec2(bottom.y, top.y);
    }

    if (altitude > layerTop) {
        // Above the clouds, looking down.
        if (bottom.x < 0.0) return vec2(top.y, bottom.x > 0.0 ? bottom.x : top.y);
        return vec2(top.y, bottom.x);
    }

    // Inside the layer.
    return vec2(0.0, bottom.x > 0.0 ? bottom.x : top.y);
}

//==============================================================================
// WEATHER
//==============================================================================

/*
 * Coverage and cloud type at a horizontal position.
 *
 * x = coverage (0 clear, 1 overcast), y = cloud type (0 stratus, 1 cumulus).
 *
 * A weather field rather than a constant is what stops the sky looking like
 * uniform noise: real skies have clear patches and dense banks, and the two
 * drift past on different scales.
 */
vec2 cloudWeather(vec2 worldXZ) {
    // Very large scale, so a weather system spans hundreds of blocks.
    vec2 p = worldXZ * 0.00035 + vec2(frameTimeCounter * 0.0008 * CLOUD_SPEED, 0.0);

    float coverage = valueNoise(p) * 0.6 + valueNoise(p * 2.3) * 0.4;

    // Rain drives coverage toward overcast, which is what makes a storm read as
    // a storm rather than as ordinary sky with particles in front of it.
    coverage = mix(coverage, 1.0, rainStrength * 0.85);

    coverage = saturate((coverage - 0.42) * 2.2) * CLOUD_COVERAGE;

    float cloudType = valueNoise(p * 0.7 + 31.0);

    return vec2(saturate(coverage), cloudType);
}

//==============================================================================
// DENSITY FIELD
//==============================================================================

/*
 * Vertical density profile within the layer.
 *
 * `height` is 0 at the bottom of the shell and 1 at the top.
 *
 * Clouds are not slabs. A cumulus has a flat base where rising air reaches its
 * condensation level and a billowing top where it spreads out, so density rises
 * sharply from the bottom and tapers off gradually toward the top. Getting this
 * curve right does more for the silhouette than any amount of extra noise.
 */
float cloudHeightProfile(float height, float cloudType) {
    // Stratus: thin and low. Cumulus: tall with a defined base.
    float bottomFade = smoothstep(0.0, mix(0.08, 0.2, cloudType), height);
    float topFade = smoothstep(1.0, mix(0.35, 0.9, cloudType), height);

    return bottomFade * topFade;
}

/*
 * Cloud density at a point inside the shell.
 *
 * `detail` allows the expensive erosion octaves to be skipped, which the light
 * march does - it is sampling for self-shadowing, where the fine edge detail
 * contributes almost nothing but costs the same.
 */
float cloudDensity(vec3 worldPos, bool detail) {
    float altitude = worldPos.y;

    float height = saturate((altitude - CLOUD_ALTITUDE) / max(CLOUD_THICKNESS, 1.0));
    if (height <= 0.0 || height >= 1.0) return 0.0;

    vec2 weather = cloudWeather(worldPos.xz);
    if (weather.x <= 0.0) return 0.0;

    // Wind. The layer drifts, and higher parts drift faster.
    vec3 wind = vec3(1.0, 0.0, 0.32) * frameTimeCounter * CLOUD_SPEED * 0.6;
    vec3 p = worldPos + wind * (1.0 + height * 0.4);

    //--------------------------------------------------------------------------
    // Base shape
    //--------------------------------------------------------------------------

    /*
     * Perlin-Worley: fbm supplies connected billowy structure, inverted Worley
     * carves the rounded cauliflower edges clouds actually have. Neither alone
     * is convincing - fbm is too smooth, Worley too regular.
     */
    float perlin = fbm(p * 0.0022, 4, 2.0, 0.5);
    float worley = fbmWorley(p * 0.0016, 3, 2.0, 0.55);

    float base = remap01(perlin, worley * 0.55 - 0.1, 1.0);

    base *= cloudHeightProfile(height, weather.y);

    /*
     * Coverage is applied by raising the threshold rather than multiplying.
     * Multiplying would fade the whole sky uniformly toward transparent;
     * raising the threshold dissolves clouds from their thin edges inward,
     * which is how a sky actually clears.
     */
    float shaped = remap01(base, 1.0 - weather.x, 1.0);

    if (shaped <= 0.0) return 0.0;

    //--------------------------------------------------------------------------
    // Edge erosion
    //--------------------------------------------------------------------------

    if (detail) {
        float erosion = fbmWorley(p * 0.017, 2, 2.4, 0.5);

        /*
         * Erosion is strongest at the edges of the cloud and at its base, where
         * turbulence actually breaks the cloud up. Applying it uniformly would
         * eat holes through the middle of solid banks.
         */
        float edgeAmount = (1.0 - shaped) * saturate(1.0 - height * 0.7);

        shaped = remap01(shaped, erosion * edgeAmount * 0.6, 1.0);
    }

    return shaped * CLOUD_DENSITY * 0.06;
}

//==============================================================================
// LIGHTING
//==============================================================================

/*
 * Optical depth from a point toward the light.
 *
 * Determines self-shadowing: how much of the cloud is above this point blocking
 * the sun. It is what makes a cloud's base dark and its top bright, and why
 * clouds look like objects rather than fog.
 *
 * Steps grow in length, because density far along the ray matters much less
 * than density immediately above the sample.
 */
float cloudLightOpticalDepth(vec3 worldPos, vec3 lightDir) {
    float stepSize = CLOUD_THICKNESS / float(CLOUD_LIGHT_STEPS) * 0.6;

    float opticalDepth = 0.0;
    vec3 p = worldPos;

    for (int i = 0; i < CLOUD_LIGHT_STEPS; i++) {
        // Not named `step` - that is a GLSL built-in, and shadowing it breaks
        // every step() call later in the same scope.
        float advance = stepSize * (1.0 + float(i) * 0.5);
        p += lightDir * advance;

        // Detail octaves are skipped here: they cost the same as in the primary
        // march but change self-shadowing imperceptibly.
        opticalDepth += cloudDensity(p, false) * advance;
    }

    return opticalDepth;
}

/*
 * Energy reaching a point inside the cloud.
 *
 * Plain Beer-Lambert makes dense clouds uniformly dark, losing the bright
 * cores real clouds have. The "powder" term restores them: light that scatters
 * many times inside a dense region eventually comes back out, so a thick cloud
 * is brighter than single-scattering absorption alone predicts.
 *
 * From Schneider's Horizon Zero Dawn work; the form here is the combined
 * Beer-powder curve.
 */
float cloudEnergy(float opticalDepth, float cosTheta) {
    float beer = exp(-opticalDepth * 6.0);

    float powder = 1.0 - exp(-opticalDepth * 12.0);

    /*
     * The powder effect is a back-scattering phenomenon, so it only applies
     * when looking away from the light. Applying it uniformly darkens the
     * sunward edges that should be brightest.
     */
    float powderBlend = mix(powder, 1.0, saturate(cosTheta * 0.5 + 0.5));

    return beer * powderBlend * 2.0;
}

//==============================================================================
// MAIN MARCH
//==============================================================================

struct CloudResult {
    vec3  scattering;
    float transmittance;  // 1.0 = clear sky, 0.0 = fully opaque cloud
};

/*
 * March the cloud layer along a view ray.
 */
CloudResult marchClouds(vec3 rayDir, float dither) {
    CloudResult result;
    result.scattering = vec3(0.0);
    result.transmittance = 1.0;

#if ASTRA_CLOUD_MODE == 0
    return result;
#else
    // Looking down at the ground: no clouds below the horizon.
    if (rayDir.y < -0.12) return result;

    vec3 origin = vec3(0.0, ATMO_PLANET_RADIUS + max(eyeAltitude, 0.0) * 0.001, 0.0);

    vec2 shell = cloudShellIntersect(origin, rayDir);
    if (shell.x < 0.0 || shell.y <= shell.x) return result;

    // Convert the shell hit from kilometres back into blocks.
    float entry = shell.x * 1000.0;
    float exitDistance = shell.y * 1000.0;

    /*
     * Cap the march. At a grazing angle the ray can travel for tens of
     * kilometres inside the shell, which would consume the entire step budget
     * on distance rather than detail.
     */
    float marchLength = min(exitDistance - entry, CLOUD_THICKNESS * 12.0);

    int steps = CLOUD_STEPS;
    float stepSize = marchLength / float(steps);

    vec3 lightDir = shadowLightDirection();
    float cosTheta = dot(rayDir, lightDir);

    /*
     * Dual-lobe Henyey-Greenstein. Clouds scatter strongly forward, which is
     * why they glow when the sun is behind them, but also have a weaker
     * backward lobe that lifts the side facing the viewer. A single lobe
     * produces either a silver lining or readable shape, not both.
     */
    float phase = dualHenyeyGreenstein(cosTheta, 0.8, -0.2, 0.6);

    vec3 lightColor = shadowLightColor();

    // Ambient from the sky above and the ground below, which is what fills in
    // the shadowed undersides.
    vec3 skyAmbient = skyAmbientIrradiance(ASTRA_UP) * ASTRA_INV_PI;

    // Start offset per pixel, otherwise the fixed step positions appear as
    // concentric bands across the sky.
    vec3 worldOrigin = cameraPosition;
    float travelled = entry + stepSize * dither;

    for (int i = 0; i < steps; i++) {
        if (result.transmittance < 0.02) break;

        vec3 samplePos = worldOrigin + rayDir * travelled;
        travelled += stepSize;

        float density = cloudDensity(samplePos, true);
        if (density <= 0.0) continue;

        float lightDepth = cloudLightOpticalDepth(samplePos, lightDir);
        float energy = cloudEnergy(lightDepth, cosTheta);

        vec3 inScatter = lightColor * energy * phase + skyAmbient * 0.35;

        /*
         * Analytic integration of the segment rather than a rectangle rule.
         * Solving the transmittance across the step exactly removes the banding
         * that plain accumulation produces, which is what allows CLOUD_STEPS to
         * go as low as 16 on the lower presets.
         */
        float extinction = density * 6.0;
        float stepTransmittance = exp(-extinction * stepSize);

        vec3 segment = (inScatter * density - inScatter * density * stepTransmittance)
                     / max(extinction, ASTRA_EPSILON);

        result.scattering += result.transmittance * segment;
        result.transmittance *= stepTransmittance;
    }

    /*
     * Fade the layer out toward the horizon. Clouds there are so far away that
     * the atmosphere between has already scattered them into haze, and without
     * this they form a hard band along the skyline.
     */
    float horizonFade = smoothstep(-0.05, 0.15, rayDir.y);
    result.scattering *= horizonFade;
    result.transmittance = mix(1.0, result.transmittance, horizonFade);

    return result;
#endif
}

//==============================================================================
// CLOUD SHADOWS
//==============================================================================

/*
 * How much sunlight reaches a world position through the cloud layer.
 *
 * Deliberately not a shadow map. Rendering clouds a second time from the sun's
 * point of view would double their cost, and cloud shadows are so soft that the
 * extra accuracy would be invisible. Instead this samples the density field
 * once, where the sun ray crosses the layer.
 *
 * Returns 1.0 for full sun, falling toward 0 under a dense bank.
 */
float cloudShadow(vec3 worldPos) {
#if !ASTRA_ENABLE_CLOUD_SHADOWS
    return 1.0;
#else
    vec3 lightDir = shadowLightDirection();

    // A light below the horizon casts no cloud shadow worth computing.
    if (lightDir.y < 0.05) return 1.0;

    /*
     * Where the sun ray from this point crosses the middle of the cloud layer.
     * Sampling the middle rather than marching the whole thickness is the
     * approximation; for a layer a few hundred blocks thick seen from the
     * ground, the difference is not perceptible.
     */
    float layerMiddle = CLOUD_ALTITUDE + CLOUD_THICKNESS * 0.5;
    float travel = (layerMiddle - worldPos.y) / lightDir.y;

    if (travel <= 0.0) return 1.0;

    vec3 samplePos = worldPos + lightDir * travel;

    float density = cloudDensity(samplePos, false);

    // Scaled by the layer thickness, since a thicker layer blocks more.
    float opticalDepth = density * CLOUD_THICKNESS * 0.06;

    /*
     * Floored well above zero. Even under heavy overcast the ground is lit by
     * light diffused through the cloud rather than blocked outright, and a
     * cloud shadow that reaches black looks like an eclipse.
     */
    return mix(0.35, 1.0, exp(-opticalDepth));
#endif
}

#endif // ASTRA_CLOUDS_GLSL
