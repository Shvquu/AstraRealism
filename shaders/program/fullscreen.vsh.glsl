#ifndef ASTRA_FULLSCREEN_VSH
#define ASTRA_FULLSCREEN_VSH

/*
 * AstraRealism - Vertex stage shared by every composite-style program.
 *
 * Iris draws a single quad covering the render target for deferred, composite
 * and final passes, so there is nothing to transform: pass the position
 * straight through and hand the fragment stage its UV.
 *
 * ftransform() is used rather than a manual matrix multiply because Iris sets
 * up an identity-ish orthographic projection for these passes and ftransform()
 * is guaranteed to match whatever it chose.
 */

#include "/lib/common/common.glsl"

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}

#endif // ASTRA_FULLSCREEN_VSH
