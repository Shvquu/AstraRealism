#ifndef ASTRA_DEFERRED_LIGHTING_FSH
#define ASTRA_DEFERRED_LIGHTING_FSH

/*
 * AstraRealism - Deferred lighting.
 *
 * Runs after all opaque geometry and before translucents. Reads the gbuffer,
 * shades every opaque pixel, and fills sky pixels with the atmosphere model.
 *
 * Doing this deferred rather than in the geometry pass means each pixel is lit
 * exactly once no matter how much overdraw the terrain had, and it gives later
 * passes a complete set of material properties to work from.
 */

#include "/lib/common/common.glsl"

// Tells the lighting composition that depthtex is readable here, which enables
// screen-space contact shadows. Forward-shaded passes cannot set this, because
// the geometry they shade has not finished writing depth yet.
#define ASTRA_HAS_SCENE_DEPTH

#include "/lib/lighting/composition.glsl"
#include "/lib/lighting/ao.glsl"
#include "/lib/atmosphere/scattering.glsl"
#include "/lib/atmosphere/sky.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 sceneColor;

void main() {
    float depth = texture(depthtex0, texcoord).r;

    //--------------------------------------------------------------------------
    // Sky
    //--------------------------------------------------------------------------

    if (isSky(depth)) {
        vec3 rayDir = viewRayFromUV(texcoord);

        // Dimension-specific: the Nether has glowing haze where the overworld
        // has an atmosphere, and the End a starlit violet dome with no sun.
        sceneColor = vec4(dimensionSkyRadiance(rayDir), 1.0);
        return;
    }

    //--------------------------------------------------------------------------
    // Opaque surfaces
    //--------------------------------------------------------------------------

    GBufferData g = decodeGBuffer(
        texture(colortex1, texcoord),
        texture(colortex2, texcoord),
        texture(colortex3, texcoord),
        texture(colortex4, texcoord)
    );

    vec3 viewPos = screenToView(vec3(texcoord, depth));
    vec3 scenePos = viewToScene(viewPos);

    LightingInputs surface;
    surface.albedo = g.albedo;
    surface.normal = g.normal;
    surface.geoNormal = g.geoNormal;
    surface.scenePos = scenePos;
    surface.roughness = g.roughness;
    surface.f0Encoded = g.f0;
    surface.emissive = g.emissive;
    surface.porosity = g.porosity;
    surface.lightmap = g.lightmap;

    /*
     * Ambient occlusion is filtered as it is read rather than in a pass of its
     * own. The bilateral kernel is nine taps either way, and folding it in here
     * saves a full-screen pass.
     *
     * The filter exists because temporal accumulation only arrives with TAA in
     * a later phase; until then the raw trace is visibly noisy at the sample
     * counts the lower presets use.
     */
    surface.ao = filterAmbientOcclusion(colortex4, texcoord, depth, g.geoNormal);

    surface.materialId = g.materialId;

    /*
     * Indirect bounce light from the GI pass. Zero when GI is disabled, in
     * which case the ambient and sky terms carry the whole indirect load.
     */
#if ASTRA_ENABLE_GI
    surface.indirect = texture(colortex6, texcoord).rgb;
#else
    surface.indirect = vec3(0.0);
#endif
    surface.dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    sceneColor = vec4(computeLighting(surface), 1.0);
}

#endif // ASTRA_DEFERRED_LIGHTING_FSH
