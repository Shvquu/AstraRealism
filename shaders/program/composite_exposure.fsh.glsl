#ifndef ASTRA_COMPOSITE_EXPOSURE_FSH
#define ASTRA_COMPOSITE_EXPOSURE_FSH

/*
 * AstraRealism - Exposure metering and autofocus.
 *
 * Runs after TAA, so the meter reads a stable image, and before bloom, so the
 * bloom it would otherwise meter does not feed back into its own brightness.
 *
 * Both values this produces are single numbers for the whole frame, so the work
 * happens at one pixel and every other pixel copies the result forward. Metering
 * per-pixel would be the same computation repeated two million times.
 *
 * colortex0 needs a mip chain for the meter to sample from; declaring it here
 * makes Iris generate one before this pass runs.
 */

#include "/lib/common/common.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/post/dof.glsl"

// Valid GLSL, so emitted as real code rather than as a directive in a
// block comment - only the format names need that treatment.
const bool colortex0MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 15 */
layout(location = 0) out vec4 exposureState;

void main() {
    vec4 previous = readExposureState(colortex15);

    /*
     * Only the first texel is computed. The rest carry the previous state
     * forward unchanged - the buffer is not cleared, so this preserves it
     * across the ping-pong.
     */
    if (int(gl_FragCoord.x) != 0 || int(gl_FragCoord.y) != 0) {
        exposureState = previous;
        return;
    }

    //--------------------------------------------------------------------------
    // Exposure
    //--------------------------------------------------------------------------

    float exposure;

#if ASTRA_ENABLE_AUTO_EXPOSURE
    float target = meterExposure(colortex0);
    exposure = adaptExposure(previous.r, target, frameTime);
#else
    exposure = MANUAL_EXPOSURE;
#endif

    //--------------------------------------------------------------------------
    // Autofocus
    //
    // Stored alongside the exposure because it needs the same thing: a single
    // frame-wide value that has to persist and settle over time.
    //--------------------------------------------------------------------------

    float focus = previous.g;

#if ASTRA_ENABLE_DOF && DOF_FOCUS_MODE == 0
    float focusTarget = autofocusDistance(depthtex1);
    focus = adaptFocus(previous.g, focusTarget, frameTime);
#elif ASTRA_ENABLE_DOF
    focus = DOF_FOCUS_DISTANCE;
#endif

    exposureState = vec4(exposure, focus, 0.0, 1.0);
}

#endif // ASTRA_COMPOSITE_EXPOSURE_FSH
