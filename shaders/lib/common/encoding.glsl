#ifndef ASTRA_ENCODING_GLSL
#define ASTRA_ENCODING_GLSL

#include "/lib/common/math.glsl"

/*
 * AstraRealism - GBuffer encoding.
 *
 * The gbuffer layout is fixed here and nowhere else. Any pass that reads or
 * writes gbuffer data must go through these functions so the layout can change
 * in exactly one place.
 *
 *   colortex1  RGBA16   A: albedo.rgb              | materialId
 *   colortex2  RGBA16   B: normal.xy (octahedral)  | geoNormal.xy (octahedral)
 *   colortex3  RGBA8    C: roughness | f0/metallic | emissive | porosity/sss
 *   colortex4  RGBA16F  D: blockLight | skyLight   | ao | wetness
 */

//==============================================================================
// OCTAHEDRAL NORMALS
//
// Maps a unit vector to a [0,1]^2 pair. At 16 bits per channel the worst-case
// angular error is well under a tenth of a degree, which is far better than
// the classic "store xy, reconstruct z" scheme and, unlike it, survives normals
// that point away from the camera (needed for translucents and back faces).
//==============================================================================

vec2 encodeNormalOctahedral(vec3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));

    // Fold the lower hemisphere outward onto the corners of the square.
    if (n.z < 0.0) {
        vec2 signs = vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
        n.xy = (1.0 - abs(n.yx)) * signs;
    }

    return n.xy * 0.5 + 0.5;
}

vec3 decodeNormalOctahedral(vec2 e) {
    vec2 f = e * 2.0 - 1.0;
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));

    float t = saturate(-n.z);
    n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);

    return normalize(n);
}

//==============================================================================
// MATERIAL ID
//==============================================================================

float encodeMaterialId(int id) { return float(id) / 255.0; }
int   decodeMaterialId(float v) { return int(v * 255.0 + 0.5); }

//==============================================================================
// GBUFFER WRITE
//==============================================================================

/*
 * Pack the four gbuffer targets.
 *
 * `normal`    shading normal (normal-mapped), world space
 * `geoNormal` geometric face normal, world space - needed separately for
 *             shadow bias, SSR ray origins and AO, all of which go wrong if
 *             they use a perturbed normal.
 */
void encodeGBuffer(
    vec3 albedo, int materialId,
    vec3 normal, vec3 geoNormal,
    float roughness, float f0, float emissive, float porosity,
    vec2 lightmap, float ao, float wetness,
    out vec4 gbufferA, out vec4 gbufferB, out vec4 gbufferC, out vec4 gbufferD
) {
    gbufferA = vec4(albedo, encodeMaterialId(materialId));

    gbufferB = vec4(encodeNormalOctahedral(normal),
                    encodeNormalOctahedral(geoNormal));

    gbufferC = vec4(roughness, f0, emissive, porosity);

    gbufferD = vec4(lightmap, ao, wetness);
}

//==============================================================================
// GBUFFER READ
//==============================================================================

struct GBufferData {
    vec3  albedo;
    int   materialId;
    vec3  normal;
    vec3  geoNormal;
    float roughness;
    float f0;          // normal-incidence reflectance, or metalness >= 229/255
    float emissive;
    float porosity;    // doubles as subsurface strength for organic materials
    vec2  lightmap;    // x = block light, y = sky light
    float ao;
    float wetness;
};

GBufferData decodeGBuffer(vec4 a, vec4 b, vec4 c, vec4 d) {
    GBufferData g;

    g.albedo     = a.rgb;
    g.materialId = decodeMaterialId(a.a);

    g.normal     = decodeNormalOctahedral(b.rg);
    g.geoNormal  = decodeNormalOctahedral(b.ba);

    g.roughness  = c.r;
    g.f0         = c.g;
    g.emissive   = c.b;
    g.porosity   = c.a;

    g.lightmap   = d.rg;
    g.ao         = d.b;
    g.wetness    = d.a;

    return g;
}

//==============================================================================
// METALLIC CONVENTION
//
// LabPBR 1.3 overloads the specular green channel: values 0-229 are a
// dielectric F0 in linear space, values 230-255 are indices into a table of
// metals. We collapse that to a boolean plus an F0 colour.
//==============================================================================

bool isMetal(float f0Encoded) { return f0Encoded * 255.0 >= 229.5; }

/*
 * F0 for the surface. Metals tint their specular reflection with the albedo;
 * dielectrics reflect white at normal incidence.
 */
vec3 computeF0(vec3 albedo, float f0Encoded) {
    return isMetal(f0Encoded) ? albedo : vec3(f0Encoded);
}

#endif // ASTRA_ENCODING_GLSL
