#ifndef ASTRA_WATER_SHADING_GLSL
#define ASTRA_WATER_SHADING_GLSL

#include "/lib/common/common.glsl"
#include "/lib/lighting/brdf.glsl"
#include "/lib/lighting/ssr.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/water/waves.glsl"
#include "/lib/water/caustics.glsl"

/*
 * AstraRealism - Water surface shading.
 *
 * Water looks like water because of four things happening at once, and getting
 * any of them wrong makes it read as coloured glass:
 *
 *   Fresnel     - it is nearly transparent looking straight down and nearly a
 *                 mirror at a grazing angle. This is the single most important
 *                 cue, and it is why still water reflects the far shore but not
 *                 the ground beneath your feet.
 *   Absorption  - water absorbs red roughly thirteen times faster than blue, so
 *                 depth shifts the colour rather than just darkening it.
 *   Scattering  - suspended particles bounce light back out, which is why deep
 *                 water glows faintly blue instead of going black.
 *   Refraction  - the surface bends the view of whatever lies below it.
 *
 * All four are driven by the water depth along the view ray, which is why the
 * depth reconstruction below matters more than it looks.
 */

struct WaterSurface {
    vec3  color;
    float alpha;
};

//==============================================================================
// DEPTH THROUGH THE WATER
//==============================================================================

/*
 * Distance the view ray travels through water before hitting something solid.
 *
 * depthtex0 includes translucents and so gives the water surface itself;
 * depthtex1 excludes them and gives the opaque geometry behind. The difference
 * along the view ray is the thickness of water being looked through.
 *
 * Returns 0 when there is nothing behind the water, such as looking at the
 * horizon, where treating it as infinitely deep is correct.
 */
float waterDepthAlongView(vec2 uv, float surfaceDepth) {
    float opaqueDepth = texture(depthtex1, uv).r;

    if (isSky(opaqueDepth)) {
        // Open water against the sky: treat as deep enough to fully absorb.
        return 64.0;
    }

    vec3 surfaceView = screenToView(vec3(uv, surfaceDepth));
    vec3 opaqueView = screenToView(vec3(uv, opaqueDepth));

    return max(length(opaqueView) - length(surfaceView), 0.0);
}

//==============================================================================
// ABSORPTION AND SCATTERING
//==============================================================================

/*
 * Beer-Lambert transmittance through a thickness of water.
 *
 * WATER_ABSORPTION_COEFF encodes measured absorption per metre, collapsed to
 * three bands. WATER_ABSORPTION_DISTANCE lets the user scale that toward
 * clearer or murkier water without changing the relative shape, so the
 * characteristic blue-green shift survives at every setting.
 */
vec3 waterTransmittance(float depth) {
    vec3 extinction = WATER_ABSORPTION_COEFF
                    * (12.0 / max(WATER_ABSORPTION_DISTANCE, 1.0));

    return exp(-extinction * depth);
}

/*
 * Light scattered back out of the water column toward the viewer.
 *
 * Without this, deep water becomes pure black as absorption completes, which is
 * wrong: real deep water is dark blue because particles keep bouncing a little
 * light back out. The term saturates with depth because light scattered from
 * far down is itself absorbed on the way back up.
 */
vec3 waterScattering(float depth, vec3 lightColor, vec3 ambient, vec3 tint) {
    vec3 scatterCoeff = WATER_SCATTER_COEFF * 40.0 * WATER_SCATTERING;

    // Saturating exponential: approaches a limit as depth grows.
    vec3 accumulated = vec3(1.0) - exp(-scatterCoeff * depth);

    /*
     * Scattered light comes from the sun filtered through the surface plus the
     * ambient sky. Weighted toward ambient because direct sun is refracted into
     * a narrow cone while skylight arrives from the whole hemisphere.
     */
    vec3 source = lightColor * 0.06 + ambient * 0.5;

    /*
     * The biome tint belongs here and nowhere else.
     *
     * Minecraft colours water per biome - swamp water is green, ocean blue.
     * That colour is a property of what is suspended in the water, so it shows
     * up in the light those particles scatter back out, not in the absorption
     * curve. Tinting the transmittance instead would wrongly make a swamp's
     * shallows green while its depths stayed the same blue as everywhere else.
     */
    return accumulated * source * tint;
}

//==============================================================================
// FOAM
//==============================================================================

/*
 * Foam where water meets solid geometry.
 *
 * Keyed on water depth rather than on proximity to a block edge, because that
 * is what actually produces foam: shallow water over an obstruction is where
 * flow is disturbed. It appears around shorelines, submerged blocks and
 * anything standing in the water, all from one test.
 */
float waterFoam(float depth, vec3 worldPos) {
#if !defined(WATER_FOAM)
    return 0.0;
#else
    float edge = 1.0 - smoothstep(0.0, WATER_FOAM_DISTANCE, depth);
    if (edge <= 0.0) return 0.0;

    // Break the band up so it does not read as a uniform outline.
    //
    // Note: not named `texture` - that identifier is the built-in sampling
    // function, and shadowing it breaks every texture() call later in scope.
    vec2 p = worldPos.xz * 3.5 + vec2(frameTimeCounter * 0.35,
                                      frameTimeCounter * 0.22);
    float pattern = valueNoise(p) * 0.6 + valueNoise(p * 2.3) * 0.4;

    return saturate(edge * edge * smoothstep(0.35, 0.75, pattern + edge * 0.35));
#endif
}

//==============================================================================
// REFRACTION
//==============================================================================

/*
 * Screen-space offset for looking through the water surface.
 *
 * The wave normal tilts the view ray, which shifts what is visible beneath.
 * Scaling by depth is what sells it: a pebble just under the surface barely
 * moves, while the bottom of a deep pool wobbles noticeably.
 */
vec2 refractionOffset(vec3 waveNormalScene, float depth, float viewDistance) {
#if !ASTRA_ENABLE_REFRACTION
    return vec2(0.0);
#else
    // Deviation of the wave normal from vertical drives the bend.
    vec2 tilt = waveNormalScene.xz;

    float strength = WATER_REFRACTION_STRENGTH * 0.08
                   * saturate(depth * 0.5)
                   / max(1.0 + viewDistance * 0.05, 1.0);

    return tilt * strength;
#endif
}

/*
 * Sample the scene behind the water with refraction applied.
 *
 * The offset is rejected if it lands on a pixel that is nearer than the water
 * surface. Without that check, geometry in front of the water bleeds into it -
 * a hand or a boat smeared across the surface - because the refracted
 * coordinate has no way of knowing it walked onto a foreground object.
 */
vec3 sampleRefracted(sampler2D sceneTex, vec2 uv, vec2 offset,
                     float surfaceDepth) {
    vec2 refractedUV = clamp(uv + offset, vec2(0.001), vec2(0.999));

    float refractedOpaqueDepth = texture(depthtex1, refractedUV).r;

    // The refracted sample is in front of the water: fall back to no offset.
    if (refractedOpaqueDepth < surfaceDepth) {
        refractedUV = uv;
    }

    return texture(sceneTex, refractedUV).rgb;
}

//==============================================================================
// MAIN
//==============================================================================

/*
 * Shade a water surface fragment.
 *
 * `sceneTex` is colortex9, the copy of the lit opaque scene made by the last
 * deferred pass. Translucents cannot read colortex0 while blending into it.
 */
WaterSurface shadeWater(vec3 scenePos, vec3 geoNormal, vec2 screenUV,
                        float surfaceDepth, vec2 lightmap, vec3 baseAlbedo,
                        sampler2D sceneTex, float dither) {
    WaterSurface result;

    float viewDistance = length(scenePos);
    vec3 worldPos = worldPosition(scenePos);
    vec3 viewDir = normalize(-scenePos);

    //--------------------------------------------------------------------------
    // Surface normal
    //--------------------------------------------------------------------------

    vec3 normal = geoNormal;

    // Waves only make sense on the surface of the water, not on its sides.
    if (geoNormal.y > 0.5) {
        normal = waveNormal(worldPos.xz, viewDistance, WATER_WAVE_OCTAVES);
    }

    //--------------------------------------------------------------------------
    // Depth through the water
    //--------------------------------------------------------------------------

    float depth = waterDepthAlongView(screenUV, surfaceDepth);

    //--------------------------------------------------------------------------
    // What is behind the water
    //--------------------------------------------------------------------------

    vec2 offset = refractionOffset(normal, depth, viewDistance);
    vec3 behind = sampleRefracted(sceneTex, screenUV, offset, surfaceDepth);

    /*
     * Caustics are applied here, to the light that reached the bottom. This is
     * both the physically correct place - the surface focuses the light before
     * it lands - and the practical one, since the composite pass has no way to
     * know whether the translucent surface in front of a pixel was water or
     * glass.
     */
    vec3 lightDir = shadowLightDirection();
    float caustics = waterCaustics(worldPos + vec3(offset.x, 0.0, offset.y) * 10.0,
                                   depth, lightDir);
    behind *= caustics;

    //--------------------------------------------------------------------------
    // Absorption and scattering through the column
    //--------------------------------------------------------------------------

    vec3 lightColor = shadowLightColor() * weatherDirectAttenuation();
    vec3 ambient = skyAmbientIrradiance(vec3(0.0, 1.0, 0.0))
                 * saturate(lightmap.y) * ASTRA_INV_PI;

    /*
     * `baseAlbedo` is the texture colour multiplied by Minecraft's per-biome
     * water tint. Normalising it against its own luminance keeps the hue while
     * discarding the brightness, so the tint shifts the colour of the scattered
     * light without also changing how much of it there is.
     */
    vec3 tint = baseAlbedo / max(luminance(baseAlbedo), 0.08);

    vec3 transmittance = waterTransmittance(depth);
    vec3 scattered = waterScattering(depth, lightColor, ambient, tint);

    vec3 throughWater = behind * transmittance + scattered;

    //--------------------------------------------------------------------------
    // Reflection
    //--------------------------------------------------------------------------

    ReflectionResult reflection = computeReflection(
        scenePos, normal, 0.02, sceneTex, dither, frameCounter);

    //--------------------------------------------------------------------------
    // Fresnel
    //
    // The whole character of water lives here. Schlick against WATER_F0 gives
    // roughly 2% reflectance head-on rising to 100% at grazing angles, which is
    // why a lake is transparent at your feet and mirror-like at the far shore.
    //--------------------------------------------------------------------------

    float cosTheta = saturate(dot(normal, viewDir));
    float fresnel = WATER_F0 + (1.0 - WATER_F0) * pow5(1.0 - cosTheta);

    // Rain roughens the surface, which broadens the reflection and lifts the
    // head-on reflectance slightly.
    fresnel = mix(fresnel, fresnel * 0.75 + 0.06, rainStrength);

    vec3 color = mix(throughWater, reflection.color, fresnel);

    //--------------------------------------------------------------------------
    // Sun glint
    //
    // The specular highlight of the sun on the waves. Separate from the
    // reflection because the sun is a small bright source that screen-space
    // reflection cannot resolve - it is not in the depth buffer.
    //--------------------------------------------------------------------------

    vec3 halfVector = normalize(viewDir + lightDir);
    float ndoth = clampedDot(normal, halfVector);

    float glintRoughness = mix(0.02, 0.08, rainStrength);
    float specular = distributionGGX(ndoth, glintRoughness)
                   * visibilitySmithGGX(cosTheta,
                                        clampedDot(normal, lightDir),
                                        glintRoughness);

    color += lightColor * specular * fresnel * clampedDot(normal, lightDir);

    //--------------------------------------------------------------------------
    // Foam
    //--------------------------------------------------------------------------

    float foam = waterFoam(depth, worldPos);

    if (foam > 0.0) {
        // Foam is a dense scatterer, so it is bright and diffuse rather than
        // reflective - it sits on top of everything computed above.
        vec3 foamColor = (lightColor * 0.16 + ambient) * vec3(0.95, 0.97, 1.0);
        color = mix(color, foamColor, foam);
    }

    //--------------------------------------------------------------------------
    // Opacity
    //
    // Water is fully opaque as far as the blend is concerned: everything behind
    // it has already been folded in above, with correct absorption. Letting the
    // hardware blend as well would apply the background twice.
    //--------------------------------------------------------------------------

    result.color = color;
    result.alpha = 1.0;

    return result;
}

//==============================================================================
// NON-WATER TRANSLUCENTS
//==============================================================================

/*
 * Stained glass, ice and similar.
 *
 * These share the water path's access to the scene copy but not its physics:
 * glass has no depth-dependent absorption, and its tint comes from the texture
 * rather than from a transmittance curve.
 */
WaterSurface shadeTranslucent(vec3 scenePos, vec3 normal, vec2 screenUV,
                              float surfaceDepth, vec3 albedo, float alpha,
                              float roughness, float f0,
                              sampler2D sceneTex, float dither) {
    WaterSurface result;

    vec3 viewDir = normalize(-scenePos);

    vec3 behind = texture(sceneTex, screenUV).rgb;

    // Tinted transmission: the glass colours whatever passes through it.
    vec3 transmitted = behind * mix(vec3(1.0), albedo, alpha);

    ReflectionResult reflection = computeReflection(
        scenePos, normal, roughness, sceneTex, dither, frameCounter);

    float cosTheta = saturate(dot(normal, viewDir));
    float fresnel = f0 + (1.0 - f0) * pow5(1.0 - cosTheta);

    result.color = mix(transmitted, reflection.color, fresnel);
    result.alpha = 1.0;

    return result;
}

#endif // ASTRA_WATER_SHADING_GLSL
