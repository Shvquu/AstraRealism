#ifndef ASTRA_COMPOSITE_CAMERA_FSH
#define ASTRA_COMPOSITE_CAMERA_FSH

/*
 * AstraRealism - Camera effects.
 *
 * Depth of field and motion blur in one pass. Both are gather operations over
 * the finished scene, both are off by default, and separating them would mean
 * a second full-screen pass that is usually a no-op.
 *
 * Ordered depth of field first: a real camera's shutter blur acts on the image
 * the lens has already formed, so the out-of-focus disc should smear rather
 * than the smear being defocused.
 */

#include "/lib/common/common.glsl"
#include "/lib/post/dof.glsl"
#include "/lib/post/motionblur.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/material/material_id.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 sceneColor;

void main() {
#if !ASTRA_ENABLE_DOF && !ASTRA_ENABLE_MOTION_BLUR
    sceneColor = texture(colortex0, texcoord);
#else
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec3 colour = texture(colortex0, texcoord).rgb;

    //--------------------------------------------------------------------------
    // Depth of field
    //--------------------------------------------------------------------------

    #if ASTRA_ENABLE_DOF
        /*
         * The focus distance was settled in the exposure pass, where it could
         * be smoothed over time. Recomputing it here would give an instant rack
         * that no lens performs.
         */
        float focusDistance = readExposureState(colortex15).g;

        if (focusDistance <= 0.0) {
            focusDistance = (DOF_FOCUS_MODE == 0) ? far * 0.25 : DOF_FOCUS_DISTANCE;
        }

        /*
         * depthtex1 excludes the hand, so a held item never drives the blur of
         * the world behind it.
         */
        colour = gatherBokeh(colortex0, depthtex1, texcoord, focusDistance, dither);
    #endif

    //--------------------------------------------------------------------------
    // Motion blur
    //--------------------------------------------------------------------------

    #if ASTRA_ENABLE_MOTION_BLUR
        float depth = texture(depthtex0, texcoord).r;

        vec3 scenePos = isSky(depth)
            ? viewRayFromUV(texcoord) * far
            : viewToScene(screenToView(vec3(texcoord, depth)));

        int materialId = decodeMaterialId(texture(colortex1, texcoord).a);

        /*
         * Motion blur reads colortex0 rather than the defocused `colour`,
         * because a fragment shader cannot see its own writes. The two effects
         * are therefore composed rather than chained: with both enabled the
         * blur samples the pre-DOF image, which is a visible approximation but
         * only in the rare case that both are on at once.
         */
        vec3 blurred = applyMotionBlur(colortex0, texcoord, scenePos,
                                       materialIsScreenAnchored(materialId),
                                       dither);

        #if ASTRA_ENABLE_DOF
            colour = mix(colour, blurred, 0.5);
        #else
            colour = blurred;
        #endif
    #endif

    sceneColor = vec4(colour, 1.0);
#endif
}

#endif // ASTRA_COMPOSITE_CAMERA_FSH
