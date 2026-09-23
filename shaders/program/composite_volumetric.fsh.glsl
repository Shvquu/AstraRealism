#ifndef ASTRA_COMPOSITE_VOLUMETRIC_FSH
#define ASTRA_COMPOSITE_VOLUMETRIC_FSH

/*
 * AstraRealism - Volumetric light and fog march.
 *
 * Marches the view ray through the air, asking the shadow map at each step
 * whether that point is lit. The result goes into colortex10 for the scene
 * composite to apply.
 *
 * Runs after translucent geometry so that water and glass are already in the
 * depth buffer: light shafts should stop at a water surface rather than
 * continuing through it as if it were air.
 *
 * Like GI and clouds, only one pixel per tile marches each frame - volumetrics
 * are smooth enough that the reprojected history between refreshes is
 * indistinguishable from marching every pixel.
 */

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/volumetric.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 10 */
layout(location = 0) out vec4 volumetrics;

void main() {
#if !ASTRA_ENABLE_VOLUMETRICS
    // Fully transmissive, no in-scattering: the composite pass then leaves the
    // scene untouched and the analytic fog handles atmospherics on its own.
    volumetrics = vec4(0.0, 0.0, 0.0, 1.0);
#else
    float depth = texture(depthtex0, texcoord).r;

    vec3 rayDir = viewRayFromUV(texcoord);

    /*
     * March as far as the surface, or to the shadow distance for sky pixels.
     * Beyond the shadow map there is no occlusion information, so marching
     * further would produce uniform haze at full ray-march cost - which the
     * analytic fog already provides for free.
     */
    float maxDistance = isSky(depth)
        ? shadowDistance
        : length(screenToView(vec3(texcoord, depth)));

    //--------------------------------------------------------------------------
    // History
    //--------------------------------------------------------------------------

    vec3 scenePos = isSky(depth)
        ? rayDir * shadowDistance
        : viewToScene(screenToView(vec3(texcoord, depth)));

    HistorySample history = sampleHistory(colortex10, colortex13, scenePos, false);

    bool trace = shouldTraceThisFrame(ivec2(gl_FragCoord.xy),
                                      VL_RESOLUTION_DIVISOR);

    if (!history.valid) trace = true;

    if (!trace) {
        volumetrics = history.value;
        return;
    }

    //--------------------------------------------------------------------------
    // March
    //--------------------------------------------------------------------------

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    // Sky access of the surface being looked at, used to thicken cave fog.
    float skyAccess = isSky(depth) ? 1.0 : texture(colortex4, texcoord).g;

    VolumetricResult marched;

    if (isEyeInWater == 1) {
        marched = marchUnderwater(rayDir, maxDistance, dither);
    } else {
        marched = marchVolumetrics(rayDir, maxDistance, skyAccess, dither);
    }

    vec4 current = vec4(marched.inScatter, marched.transmittance);

    //--------------------------------------------------------------------------
    // Accumulate
    //
    // Not accumulateTemporal(): that helper averages an estimator converging on
    // a fixed value, which suits GI. Volumetrics change continuously as the sun
    // moves and the camera turns, so a fixed modest blend keeps them responsive
    // while still removing the march's dither noise.
    //--------------------------------------------------------------------------

    if (history.valid) {
        volumetrics = mix(history.value, current, mix(1.0, 0.18, history.confidence));
    } else {
        volumetrics = current;
    }
#endif
}

#endif // ASTRA_COMPOSITE_VOLUMETRIC_FSH
