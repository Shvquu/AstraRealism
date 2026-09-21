#ifndef ASTRA_FORWARD_GLSL
#define ASTRA_FORWARD_GLSL

#include "/lib/common/common.glsl"
#include "/lib/lighting/composition.glsl"
#include "/lib/material/material.glsl"

/*
 * AstraRealism - Forward shading for geometry that renders after the deferred
 * pass.
 *
 * Translucents, particles and weather cannot go through the gbuffer, because
 * the deferred pass has already consumed and overwritten it. They call the same
 * computeLighting() as everything else, so their response to light matches; the
 * only thing they give up is access to screen-space effects that need opaque
 * gbuffer data.
 *
 * Water is handled separately in the composite pass, which has the depth and
 * colour of the scene behind it and so can do refraction and absorption
 * properly. What happens here is only the surface's own direct response.
 */

vec3 shadeForward(SurfaceMaterial material, vec3 shadingNormal, vec3 geoNormal,
                  vec3 scenePos, vec2 lightmap, int materialId) {
    LightingInputs surface;

    surface.albedo = material.albedo;
    surface.normal = shadingNormal;
    surface.geoNormal = geoNormal;
    surface.scenePos = scenePos;

    surface.roughness = material.roughness;
    surface.f0Encoded = material.f0;
    surface.emissive = material.emissive;
    surface.porosity = material.porosity;

    surface.lightmap = lightmap;
    surface.ao = material.ambientOcclusion;
    surface.materialId = materialId;

    // Forward geometry has no GI buffer to read - the pass that produces it
    // runs against the opaque gbuffer only. The sky ambient term covers it.
    surface.indirect = vec3(0.0);

    surface.dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec3 shaded = computeLighting(surface);

    /*
     * Particles and weather are small, unlit sprites in vanilla and read as
     * flat when given a full BRDF. Blending them toward their own albedo keeps
     * them visible against bright skies without making them glow.
     */
    if (materialId == MATID_PARTICLE || materialId == MATID_WEATHER) {
        shaded = mix(shaded, material.albedo * luminance(shaded) * ASTRA_PI, 0.5);
    }

    // Beacon beams and similar are pure emission; lighting them makes no sense.
    if (materialId == MATID_BEACON) {
        shaded = material.albedo * EMISSIVE_INTENSITY;
    }

    return shaded;
}

#endif // ASTRA_FORWARD_GLSL
