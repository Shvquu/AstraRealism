#ifndef ASTRA_MATERIAL_GLSL
#define ASTRA_MATERIAL_GLSL

#include "/lib/common/common.glsl"
#include "/lib/material/material_id.glsl"

/*
 * AstraRealism - Surface material acquisition.
 *
 * Reads material properties from a LabPBR 1.3 resource pack when one is
 * present, and derives plausible values from the base texture when one is not.
 *
 * The fallback is not a uniform default. A pack without PBR data still gets
 * per-block roughness and metalness from block.properties, and a per-texel
 * roughness estimate from the albedo itself, so stone, metal and ice keep
 * responding to light differently.
 */

struct SurfaceMaterial {
    vec3  albedo;
    float alpha;

    vec3  normalTangent;  // tangent space, +Z out of the surface
    float heightMap;      // 0 = deepest, 1 = surface

    float roughness;
    float f0;             // encoded: <229/255 is dielectric F0, above is metal
    float emissive;
    float porosity;       // doubles as subsurface strength
    float ambientOcclusion;
};

//==============================================================================
// LABPBR DECODING
//==============================================================================

/*
 * LabPBR stores perceptual smoothness, which is linear in how rough a surface
 * *looks*. The BRDF needs linear roughness. The relationship is a square,
 * which is why a texture that reads as "slightly rough" still produces a fairly
 * tight highlight.
 */
float perceptualSmoothnessToRoughness(float smoothness) {
    float r = 1.0 - smoothness;
    return max(r * r, MIN_ROUGHNESS);
}

/*
 * Reconstruct a tangent-space normal from the two stored channels.
 *
 * LabPBR stores only X and Y; Z follows from the unit-length constraint. The
 * clamp guards against packs whose XY exceed unit length after compression,
 * which would otherwise produce a NaN from the square root.
 */
vec3 decodeLabPBRNormal(vec2 packed) {
    vec2 xy = packed * 2.0 - 1.0;
    float z = sqrt(saturate(1.0 - dot(xy, xy)));
    return vec3(xy, z);
}

//==============================================================================
// VANILLA FALLBACK HEURISTICS
//==============================================================================

/*
 * Estimate roughness from the base texture when no specular map exists.
 *
 * Starts from the per-block default and modulates it by local luminance: within
 * a single material, darker texels are usually worn, dirty or in shadow, and
 * those are rougher. The effect is subtle by design - the goal is to break up
 * uniform highlights, not to invent detail that is not there.
 */
float estimateRoughness(vec3 albedo, float baseRoughness) {
    float luma = luminance(albedo);

    // +-15% around the per-block default, brighter meaning smoother.
    float modulation = mix(1.15, 0.85, saturate(luma * 1.4));

    return clamp(baseRoughness * modulation, MIN_ROUGHNESS, 1.0);
}

/*
 * Estimate emission for blocks classified as emissive when no specular map
 * supplies it.
 *
 * Uses luminance so that only the genuinely bright parts of a texture glow -
 * the dark iron frame of a lantern should not emit just because the flame
 * inside it does.
 */
float estimateEmission(vec3 albedo, int materialId) {
    if (!materialIsEmissive(materialId)) return 0.0;

    float luma = luminance(albedo);

    if (materialId == MATID_LAVA) {
        // Lava's dark crust genuinely is much cooler than its cracks, so the
        // contrast between them should be preserved rather than flattened.
        return smoothstep(0.15, 0.75, luma);
    }

    return smoothstep(0.35, 0.85, luma);
}

//==============================================================================
// ACQUISITION
//==============================================================================

/*
 * Build the material for a fragment.
 *
 * `uv` is the atlas coordinate, already displaced by parallax if enabled.
 * `vertexColor` carries the biome tint and vanilla vertex AO.
 */
SurfaceMaterial fetchMaterial(vec2 uv, vec4 vertexColor, int materialId) {
    SurfaceMaterial m;

    vec4 texel = texture(gtexture, uv);

    // Minecraft textures are authored in sRGB; all lighting maths needs linear.
    m.albedo = srgbToLinear(texel.rgb) * srgbToLinear(vertexColor.rgb);
    m.alpha = texel.a * vertexColor.a;

    MaterialDefaults defaults = defaultsForMaterial(materialId);

#if ASTRA_HAS_LABPBR
    vec4 normalSample = texture(normals, uv);
    vec4 specularSample = texture(specular, uv);

    m.normalTangent = decodeLabPBRNormal(normalSample.rg);
    m.ambientOcclusion = normalSample.b;
    m.heightMap = normalSample.a;

    m.roughness = perceptualSmoothnessToRoughness(specularSample.r);
    m.f0 = specularSample.g;

    /*
     * LabPBR blue channel: 0-64 is porosity, 65-255 is subsurface scattering.
     * Both feed the same slot here because no material uses both - a porous
     * surface absorbs water, a scattering one transmits light.
     */
    float blue = specularSample.b;
    if (blue * 255.0 <= 64.5) {
        m.porosity = blue * 255.0 / 64.0;
    } else {
        m.porosity = (blue * 255.0 - 65.0) / 190.0;
    }

    /*
     * Emission is stored with 255 meaning "no emission" so that packs which
     * leave the channel at full white are not read as fully emissive.
     */
    float emissionRaw = specularSample.a;
    m.emissive = (emissionRaw * 255.0 >= 254.5) ? 0.0 : emissionRaw;

    // Blocks classified as emissive still glow if the pack forgot to mark them.
    if (m.emissive <= 0.0 && materialIsEmissive(materialId)) {
        m.emissive = estimateEmission(m.albedo, materialId);
    }
#else
    // No PBR data: flat normal, per-block defaults, per-texel roughness guess.
    m.normalTangent = vec3(0.0, 0.0, 1.0);
    m.heightMap = 1.0;
    m.ambientOcclusion = 1.0;

    m.roughness = estimateRoughness(m.albedo, defaults.roughness);
    m.f0 = defaults.f0;
    m.porosity = defaults.porosity;
    m.emissive = max(defaults.emissive * estimateEmission(m.albedo, materialId),
                     estimateEmission(m.albedo, materialId));
#endif

    return m;
}

//==============================================================================
// NORMAL MAPPING
//==============================================================================

/*
 * Transform a tangent-space normal into scene space.
 *
 * NORMAL_MAP_STRENGTH scales the XY components before renormalising, which
 * flattens or exaggerates the bump without changing its direction.
 */
vec3 applyNormalMap(vec3 normalTangent, vec3 normal, vec3 tangent, vec3 bitangent) {
#if ASTRA_HAS_LABPBR
    normalTangent.xy *= NORMAL_MAP_STRENGTH;
    normalTangent = normalize(normalTangent);

    mat3 tbn = mat3(tangent, bitangent, normal);
    return normalize(tbn * normalTangent);
#else
    return normal;
#endif
}

#endif // ASTRA_MATERIAL_GLSL
