#ifndef ASTRA_DEFERRED_CLOUDS_FSH
#define ASTRA_DEFERRED_CLOUDS_FSH

/*
 * AstraRealism - Volumetric clouds.
 *
 * Marches the cloud layer for sky pixels and composites the result into the
 * scene, accumulating temporally in colortex11.
 *
 * Runs after lighting so the sky is already there to composite over, and
 * before reflections so the copy those make for translucent geometry contains
 * the clouds - which is what lets water reflect a cloudy sky rather than a
 * clear one.
 *
 * Disabled entirely in the Nether and the End, neither of which has a sky for
 * clouds to hang in.
 */

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/clouds.glsl"
#include "/lib/dimension/dimension.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0,11 */
layout(location = 0) out vec4 sceneColor;
layout(location = 1) out vec4 cloudHistory;

void main() {
    vec3 color = texture(colortex0, texcoord).rgb;

    float depth = texture(depthtex1, texcoord).r;

    /*
     * Clouds are only drawn where the sky is visible. Geometry in front of them
     * occludes them completely - they sit hundreds of blocks up, so there is
     * never anything between the camera and a cloud except more sky.
     */
#if ASTRA_CLOUD_MODE == 0
    sceneColor = vec4(color, 1.0);
    cloudHistory = vec4(0.0);
#else
    if (!dimensionHasClouds() || !isSky(depth)) {
        sceneColor = vec4(color, 1.0);
        cloudHistory = vec4(0.0);
        return;
    }

    vec3 rayDir = viewRayFromUV(texcoord);

    //--------------------------------------------------------------------------
    // History
    //
    // Sky pixels have no scene position to reproject through, so the history is
    // fetched by reprojecting a point placed far along the view ray. At cloud
    // distances the parallax from camera translation is negligible and rotation
    // dominates, which this captures correctly.
    //--------------------------------------------------------------------------

    vec3 distantPoint = rayDir * far;

    vec3 previousScreen = reprojectScene(distantPoint, false);

    bool historyValid = all(greaterThanEqual(previousScreen.xy, vec2(0.0)))
                     && all(lessThanEqual(previousScreen.xy, vec2(1.0)));

    vec4 history = historyValid ? texture(colortex11, previousScreen.xy)
                                : vec4(0.0);

    /*
     * Whether the history holds real data.
     *
     * The alpha channel is transmittance, so it cannot double as a validity
     * flag: a fully opaque cloud stores zero there and would be mistaken for an
     * empty buffer. An untouched buffer is all zeros, which would mean "emits
     * no light and blocks everything" - a combination no real sample produces.
     * Testing both channels distinguishes the two.
     */
    bool hasHistory = historyValid
                   && (history.a > 0.0 || luminance(history.rgb) > 0.0);

    //--------------------------------------------------------------------------
    // Interleaved refresh
    //--------------------------------------------------------------------------

    bool trace = shouldTraceThisFrame(ivec2(gl_FragCoord.xy),
                                      CLOUD_RESOLUTION_DIVISOR);

    if (!hasHistory) trace = true;

    vec4 clouds;

    if (trace) {
        float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

        CloudResult marched = marchClouds(rayDir, dither);

        vec4 current = vec4(marched.scattering, marched.transmittance);

        if (hasHistory) {
            /*
             * Blend weight is deliberately generous toward history. Clouds are
             * very expensive and very smooth, so heavy accumulation costs
             * little in detail and buys a lot in stability. The transmittance
             * is blended alongside the scattering so the two stay consistent -
             * mixing a new scattering value against an old transmittance would
             * produce edges that glow or vanish.
             */
            clouds = mix(history, current, 0.12);
        } else {
            clouds = current;
        }
    } else {
        clouds = history;
    }

    cloudHistory = clouds;

    //--------------------------------------------------------------------------
    // Composite
    //
    // Transmittance-weighted: the sky behind is attenuated by how opaque the
    // cloud is, and the cloud's own scattering is added on top. This is the
    // same operator the atmosphere and fog use, so clouds sit in the same
    // scattering model as everything else rather than being pasted over it.
    //--------------------------------------------------------------------------

    sceneColor = vec4(color * clouds.a + clouds.rgb, 1.0);
#endif
}

#endif // ASTRA_DEFERRED_CLOUDS_FSH
