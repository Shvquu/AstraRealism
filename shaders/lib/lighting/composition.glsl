#ifndef ASTRA_COMPOSITION_GLSL
#define ASTRA_COMPOSITION_GLSL

#include "/lib/common/common.glsl"
#include "/lib/lighting/brdf.glsl"
#include "/lib/lighting/shadow.glsl"
#include "/lib/lighting/contact_shadow.glsl"
#include "/lib/lighting/blocklight.glsl"
#include "/lib/atmosphere/sun_moon.glsl"
#include "/lib/atmosphere/scattering.glsl"
#include "/lib/material/material_id.glsl"

/*
 * AstraRealism - Lighting composition.
 *
 * The single place where all light contributions are summed. Both the deferred
 * pass and the forward-shaded translucents call this, so a change to the
 * lighting model applies everywhere rather than having to be mirrored.
 *
 * Contributions, in the order they are added:
 *
 *   direct      sun or moon, occluded by the shadow map
 *   transmitted light through thin surfaces (leaves, snow, ice)
 *   sky         hemispherical irradiance from the atmosphere
 *   block       torches and other emitters, via the vanilla lightmap
 *   held        the light source in the player's hand
 *   emission    the surface's own light
 *   floor       a small constant so caves stay readable
 */

struct LightingInputs {
    vec3  albedo;
    vec3  normal;       // shading normal, normal-mapped
    vec3  geoNormal;    // geometric normal, for shadow bias and back-face tests
    vec3  scenePos;

    float roughness;
    float f0Encoded;
    float emissive;
    float porosity;

    vec2  lightmap;     // x = block, y = sky
    float ao;
    int   materialId;

    // Indirect bounce radiance from the GI pass. Zero when GI is off, in which
    // case the sky ambient term carries the whole indirect load.
    vec3  indirect;

    float dither;       // per-pixel rotation for shadow filtering
};

//==============================================================================

vec3 computeLighting(LightingInputs surface) {
    vec3 viewDir = normalize(-surface.scenePos);

    bool metal = isMetal(surface.f0Encoded);
    vec3 f0 = computeF0(surface.albedo, surface.f0Encoded);

    float ndotv = clampedDot(surface.normal, viewDir);

    vec3 result = vec3(0.0);

    //--------------------------------------------------------------------------
    // Direct light from the sun or moon
    //--------------------------------------------------------------------------

    vec3 lightDir = shadowLightDirection();
    vec3 lightColor = shadowLightColor() * weatherDirectAttenuation();

    // Shadow bias and back-face rejection use the geometric normal; a
    // normal-mapped surface must not be able to shadow or unshadow itself.
    float geoNdotL = dot(surface.geoNormal, lightDir);
    float ndotl = clampedDot(surface.normal, lightDir);

    ShadowResult shadow = sampleShadow(surface.scenePos, surface.geoNormal,
                                       geoNdotL, surface.dither);

    /*
     * Contact shadows recover detail below the shadow map's texel size. They
     * need the scene depth buffer, so they are only available to passes that
     * run after the geometry being shaded - forward-shaded translucents make do
     * with the shadow map alone.
     *
     * Skipped where the shadow map already reports full occlusion, since there
     * is nothing left to darken.
     */
#if ASTRA_ENABLE_CONTACT_SHADOWS && defined(ASTRA_HAS_SCENE_DEPTH)
    if (shadow.visibility > 0.0 && geoNdotL > 0.0) {
        shadow.visibility *= contactShadow(
            sceneToView(surface.scenePos),
            normalize(shadowLightPosition),
            surface.dither
        );
    }
#endif

    if (shadow.visibility > 0.0 && ndotl > 0.0) {
        BRDFResult brdf = evaluateBRDF(surface.normal, viewDir, lightDir,
                                       surface.albedo, f0, surface.roughness, metal);

        result += (brdf.diffuse + brdf.specular)
                * lightColor * shadow.tint * shadow.visibility * ndotl;
    }

    //--------------------------------------------------------------------------
    // Transmission through thin surfaces
    //
    // Deliberately outside the shadow test above: the whole point is light
    // arriving from behind the surface, where NdotL is negative and the
    // geometry is self-shadowed.
    //--------------------------------------------------------------------------

#if ASTRA_ENABLE_SSS
    if (materialHasSubsurface(surface.materialId)) {
        // The shadow map still matters - a leaf inside a building is not
        // backlit - but transmission survives the surface's own back-facing.
        ShadowResult transmissionShadow = sampleShadow(
            surface.scenePos, surface.geoNormal, abs(geoNdotL), surface.dither);

        vec3 transmitted = subsurfaceTransmission(
            surface.albedo, viewDir, lightDir, surface.porosity);

        result += transmitted * lightColor * transmissionShadow.tint
                * transmissionShadow.visibility;
    }
#endif

    //--------------------------------------------------------------------------
    // Sky irradiance
    //--------------------------------------------------------------------------

    vec3 skyIrradiance = skyAmbientIrradiance(surface.normal);
    vec3 skyLight = skyLightRadiance(surface.lightmap.y, skyIrradiance);

    // Ambient occlusion applies to indirect light only. Applying it to direct
    // light is the single most common way to make a PBR scene look muddy.
    float occlusion = mix(1.0, surface.ao, AO_STRENGTH);

    if (!metal) {
        result += surface.albedo * skyLight * occlusion * ASTRA_INV_PI;
    }

    /*
     * Ambient specular from the sky.
     *
     * Smooth surfaces get a real reflection from the reflections pass instead,
     * so they are excluded here. The two are kept mutually exclusive by the
     * same roughness threshold that pass uses, which is what stops the energy
     * being counted twice and making every wet or metallic surface too bright.
     *
     * Rough surfaces are never traced - their reflection would be blurred into
     * something indistinguishable from this term anyway - so they keep it.
     */
#if ASTRA_ENABLE_SSR
    if (surface.roughness > SSR_ROUGHNESS_CUTOFF) {
        result += ambientSpecular(skyLight, f0, ndotv, surface.roughness) * occlusion;
    }
#else
    result += ambientSpecular(skyLight, f0, ndotv, surface.roughness) * occlusion;
#endif

    //--------------------------------------------------------------------------
    // Indirect bounce from the GI pass
    //--------------------------------------------------------------------------

#if ASTRA_ENABLE_GI
    if (!metal) {
        result += surface.albedo * surface.indirect * occlusion * GI_STRENGTH;
    }
#endif

    //--------------------------------------------------------------------------
    // Uniform ambient
    //
    // Not physically motivated, and deliberately small. It exists so that a
    // user who turns global illumination off is not left with pitch-black
    // shadow interiors. Raising it flattens the image, which is why the
    // tooltip says so and the default is low.
    //--------------------------------------------------------------------------

    if (!metal) {
        vec3 ambient = mix(blackbodyToRGB(float(BLOCKLIGHT_TEMPERATURE)),
                           skyIrradiance * ASTRA_INV_PI,
                           saturate(surface.lightmap.y));

        result += surface.albedo * ambient * AMBIENT_INTENSITY * occlusion;
    }

    //--------------------------------------------------------------------------
    // Block light
    //--------------------------------------------------------------------------

    vec3 blockLight = blockLightRadiance(surface.lightmap.x);

    if (!metal) {
        result += surface.albedo * blockLight * occlusion;
    }
    result += ambientSpecular(blockLight, f0, ndotv, surface.roughness) * occlusion;

    result += surface.albedo
            * heldLightRadiance(surface.scenePos, surface.normal);

    //--------------------------------------------------------------------------
    // Emission
    //--------------------------------------------------------------------------

    if (surface.emissive > 0.0) {
        // Emission replaces rather than adds to the surface's reflectance: an
        // emissive texel is a light source, not a lit surface.
        result += surface.albedo * surface.emissive * EMISSIVE_INTENSITY;
    }

    //--------------------------------------------------------------------------
    // Floor and vision effects
    //--------------------------------------------------------------------------

    result += minimumLight(surface.albedo);

    // Blindness collapses everything to near black regardless of light.
    result *= 1.0 - saturate(blindness);

    return min(result, vec3(ASTRA_MAX_RADIANCE));
}

#endif // ASTRA_COMPOSITION_GLSL
