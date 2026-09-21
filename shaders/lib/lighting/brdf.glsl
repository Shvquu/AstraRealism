#ifndef ASTRA_BRDF_GLSL
#define ASTRA_BRDF_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Physically based BRDF.
 *
 * Cook-Torrance specular with the GGX/Trowbridge-Reitz distribution, paired
 * with a diffuse term that accounts for the energy the specular lobe removes.
 * This is the same model used by film and modern game renderers, which is what
 * makes materials respond correctly to light rather than all looking like
 * tinted plastic.
 */

//==============================================================================
// NORMAL DISTRIBUTION
//==============================================================================

/*
 * GGX / Trowbridge-Reitz.
 *
 * Chosen over Blinn-Phong for its long tail: real rough surfaces have a wide
 * dim halo around the highlight that Blinn-Phong cuts off too sharply.
 */
float distributionGGX(float ndoth, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;

    float d = ndoth * ndoth * (a2 - 1.0) + 1.0;

    return a2 / max(ASTRA_PI * d * d, ASTRA_EPSILON);
}

//==============================================================================
// GEOMETRY / VISIBILITY
//==============================================================================

/*
 * Height-correlated Smith visibility (Heitz 2014), returned already divided by
 * the 4*NdotL*NdotV denominator of the Cook-Torrance form.
 *
 * The height-correlated variant accounts for shadowing and masking happening on
 * the same surface rather than independently, which matters at grazing angles -
 * the separable form is noticeably too dark there.
 */
float visibilitySmithGGX(float ndotv, float ndotl, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;

    float lambdaV = ndotl * sqrt(ndotv * ndotv * (1.0 - a2) + a2);
    float lambdaL = ndotv * sqrt(ndotl * ndotl * (1.0 - a2) + a2);

    return 0.5 / max(lambdaV + lambdaL, ASTRA_EPSILON);
}

//==============================================================================
// FRESNEL
//==============================================================================

// Schlick's approximation. Accurate enough for dielectrics and cheap.
vec3 fresnelSchlick(float cosTheta, vec3 f0) {
    return f0 + (1.0 - f0) * pow5(1.0 - saturate(cosTheta));
}

/*
 * Roughness-aware Fresnel for image-based and ambient lighting.
 *
 * A rough surface averages the Fresnel term over many microfacet orientations,
 * which caps how bright its grazing-angle reflection can get. Using plain
 * Schlick for ambient makes rough surfaces develop an unnatural bright rim.
 */
vec3 fresnelSchlickRoughness(float cosTheta, vec3 f0, float roughness) {
    vec3 ceiling = max(vec3(1.0 - roughness), f0);
    return f0 + (ceiling - f0) * pow5(1.0 - saturate(cosTheta));
}

//==============================================================================
// DIFFUSE
//==============================================================================

/*
 * Burley (Disney) diffuse.
 *
 * Lambert assumes light enters and leaves a surface without any view
 * dependence. Real rough surfaces retro-reflect: they brighten when the light
 * comes from behind the viewer. Burley models that, and it is why rough stone
 * and cloth read as rough rather than as flat matte paint.
 */
vec3 diffuseBurley(vec3 albedo, float ndotv, float ndotl, float ldoth,
                   float roughness) {
    float fd90 = 0.5 + 2.0 * ldoth * ldoth * roughness;

    float lightScatter = 1.0 + (fd90 - 1.0) * pow5(1.0 - ndotl);
    float viewScatter  = 1.0 + (fd90 - 1.0) * pow5(1.0 - ndotv);

    return albedo * ASTRA_INV_PI * lightScatter * viewScatter;
}

//==============================================================================
// COMBINED DIRECT LIGHTING
//==============================================================================

struct BRDFResult {
    vec3 diffuse;
    vec3 specular;
};

/*
 * Evaluate the full BRDF for one light direction.
 *
 * All vectors must be normalised and in the same space. The caller multiplies
 * the result by incoming radiance and by NdotL.
 *
 * `f0` is the normal-incidence reflectance: around 0.04 for dielectrics, or the
 * albedo for metals. Metals have no diffuse lobe because their free electrons
 * absorb transmitted light rather than re-emitting it.
 */
BRDFResult evaluateBRDF(vec3 normal, vec3 viewDir, vec3 lightDir,
                        vec3 albedo, vec3 f0, float roughness, bool metal) {
    BRDFResult result;

    vec3 halfway = normalize(viewDir + lightDir);

    float ndotv = clampedDot(normal, viewDir) + ASTRA_EPSILON;
    float ndotl = clampedDot(normal, lightDir);
    float ndoth = clampedDot(normal, halfway);
    float ldoth = clampedDot(lightDir, halfway);

    roughness = max(roughness, MIN_ROUGHNESS);

    float d = distributionGGX(ndoth, roughness);
    float vis = visibilitySmithGGX(ndotv, ndotl, roughness);
    vec3 f = fresnelSchlick(ldoth, f0);

    result.specular = d * vis * f;

    if (metal) {
        result.diffuse = vec3(0.0);
    } else {
        // Energy that was not reflected specularly is available to the diffuse
        // lobe. Without this coupling, glossy dielectrics end up brighter than
        // the light falling on them.
        vec3 kd = vec3(1.0) - f;
        result.diffuse = kd * diffuseBurley(albedo, ndotv, ndotl, ldoth, roughness);
    }

    return result;
}

//==============================================================================
// SUBSURFACE TRANSMISSION
//==============================================================================

/*
 * Light passing through a thin translucent surface toward the viewer.
 *
 * A full subsurface scattering solution needs thickness information we do not
 * have for arbitrary blocks. This is the standard wrap-lighting approximation:
 * a forward-scattering lobe that peaks when the light is directly behind the
 * surface, which captures the effect that actually reads - backlit leaves and
 * grass glowing green at sunrise.
 */
vec3 subsurfaceTransmission(vec3 albedo, vec3 viewDir, vec3 lightDir,
                            float strength) {
#if !ASTRA_ENABLE_SSS
    return vec3(0.0);
#else
    if (strength <= 0.0) return vec3(0.0);

    // Peaks when looking straight into the light through the surface.
    float forward = clampedDot(viewDir, -lightDir);

    // The exponent controls how tight the transmission lobe is. Thin materials
    // scatter over a wide angle, so this is deliberately low.
    float lobe = pow(forward, 4.0) * 0.6 + forward * 0.4;

    // Transmitted light picks up the material's colour twice over, having
    // passed through it, so the albedo is squared.
    return albedo * albedo * lobe * strength * SSS_STRENGTH * ASTRA_INV_PI;
#endif
}

//==============================================================================
// AMBIENT SPECULAR
//==============================================================================

/*
 * Analytic fit to the split-sum environment BRDF (Karis 2014, as refined by
 * Lazarov). Replaces the usual precomputed LUT with a polynomial, which saves
 * a texture binding and a sampler for accuracy differences invisible in motion.
 *
 * Returns the scale and bias to apply to f0 when lighting from an environment
 * probe or the sky.
 */
vec2 environmentBRDF(float ndotv, float roughness) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);

    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * ndotv)) * r.x + r.y;

    return vec2(-1.04, 1.04) * a004 + r.zw;
}

// Ambient specular contribution from a uniform incoming radiance.
vec3 ambientSpecular(vec3 radiance, vec3 f0, float ndotv, float roughness) {
    vec2 ab = environmentBRDF(ndotv, roughness);
    return radiance * (f0 * ab.x + ab.y);
}

#endif // ASTRA_BRDF_GLSL
