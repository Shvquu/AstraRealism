#ifndef ASTRA_FINAL_OUTPUT_FSH
#define ASTRA_FINAL_OUTPUT_FSH

/*
 * AstraRealism - Final output.
 *
 * The last pass. Takes linear HDR scene radiance and produces the sRGB image
 * the display receives.
 *
 * Order is deliberate and not interchangeable:
 *   exposure -> grading -> tone mapping -> vignette -> encode
 *
 * Grading before tone mapping means it operates on real radiance ratios rather
 * than on already-compressed values. The vignette comes after tone mapping
 * because it models light falloff in the lens, which happens in display space.
 */

#include "/lib/common/common.glsl"
#include "/lib/common/debug.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/grading.glsl"

in vec2 texcoord;

layout(location = 0) out vec4 fragColor;

//==============================================================================
// VIGNETTE
//==============================================================================

/*
 * Lens falloff.
 *
 * Real optical vignetting follows roughly a cos^4 law with the angle from the
 * optical axis. Using that shape rather than a linear radial fade is what keeps
 * it from reading as a dark ring pasted over the corners.
 */
float vignetteFactor(vec2 uv) {
#if !ASTRA_ENABLE_VIGNETTE
    return 1.0;
#else
    vec2 centered = (uv - 0.5) * 2.0;

    // Correct for aspect ratio so the falloff is circular, not elliptical.
    centered.x *= aspectRatio;

    float r2 = dot(centered, centered);

    // cos^4 falloff, expressed directly in terms of r^2.
    float falloff = 1.0 / (1.0 + r2 * 0.5);
    falloff *= falloff;

    return mix(1.0, falloff, VIGNETTE_STRENGTH);
#endif
}

//==============================================================================
// DITHER
//==============================================================================

/*
 * Triangular-distribution dither applied before quantising to 8 bits.
 *
 * Smooth gradients - most visibly a clear sky - band badly at 8 bits without
 * it. A triangular distribution rather than uniform makes the residual noise
 * independent of the signal level, which is what makes it invisible.
 */
vec3 quantisationDither(vec2 pixel) {
    float r0 = hash1(uvec2(pixel).x + uvec2(pixel).y * 4096u
                     + uint(frameCounter) * 16777216u);
    float r1 = hash1(uvec2(pixel).x + uvec2(pixel).y * 4096u
                     + uint(frameCounter) * 16777216u + 7919u);

    // Difference of two uniforms is triangular on [-1,1].
    return vec3(r0 - r1) / 255.0;
}

//==============================================================================

void main() {
    //--------------------------------------------------------------------------
    // Debug views bypass the entire grading chain.
    //--------------------------------------------------------------------------

    vec3 debugColor;
    if (renderDebugView(texcoord, debugColor)) {
        fragColor = vec4(debugColor, 1.0);
        return;
    }

    //--------------------------------------------------------------------------
    // Normal output
    //--------------------------------------------------------------------------

    vec3 color = texture(colortex0, texcoord).rgb;

    /*
     * Exposure. Automatic metering arrives in a later phase and will replace
     * this with a value read from the histogram buffer; until then the manual
     * value applies in both modes so the image is correctly exposed either way.
     */
    color *= MANUAL_EXPOSURE;

    color = applyColorGrading(color);

    color = applyToneMapping(color);

    color *= vignetteFactor(texcoord);

    // Scene maths is linear; the framebuffer expects sRGB.
    color = linearToSrgb(saturate(color));

    color += quantisationDither(gl_FragCoord.xy);

    fragColor = vec4(saturate(color), 1.0);
}

#endif // ASTRA_FINAL_OUTPUT_FSH
