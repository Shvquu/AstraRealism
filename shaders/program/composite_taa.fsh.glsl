#ifndef ASTRA_COMPOSITE_TAA_FSH
#define ASTRA_COMPOSITE_TAA_FSH

/*
 * AstraRealism - Temporal anti-aliasing resolve.
 *
 * Blends the current frame with its reprojected history and writes the result
 * to both the scene buffer and the history buffer.
 *
 * Placed immediately after the scene is complete and before anything that
 * blurs or meters it. Bloom sampling an un-resolved frame would flicker, and
 * the exposure meter would chase the aliasing.
 */

#include "/lib/common/common.glsl"
#include "/lib/post/taa.glsl"
#include "/lib/material/material_id.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0,5 */
layout(location = 0) out vec4 sceneColor;
layout(location = 1) out vec4 historyOut;

void main() {
#if ASTRA_AA_MODE == 0
    vec3 colour = texture(colortex0, texcoord).rgb;
    sceneColor = vec4(colour, 1.0);
    historyOut = vec4(colour, 1.0);

#elif ASTRA_AA_MODE == 1
    // FXAA is purely spatial; it keeps no history, but the buffer is still
    // written so that switching modes at runtime does not read stale data.
    vec3 colour = applyFXAA(colortex0, texcoord);
    sceneColor = vec4(colour, 1.0);
    historyOut = vec4(colour, 1.0);

#else
    /*
     * Reprojection uses the full scene depth, including translucents, so that
     * water and glass surfaces are themselves antialiased rather than being
     * reprojected as though the geometry behind them were in front.
     */
    float depth = texture(depthtex0, texcoord).r;

    vec3 scenePos;

    if (isSky(depth)) {
        /*
         * Sky has no position to reproject. A point far along the view ray
         * gives the right answer anyway: at that distance camera translation
         * contributes almost nothing and rotation dominates, which is exactly
         * what the sky's apparent motion consists of.
         */
        scenePos = viewRayFromUV(texcoord) * far;
    } else {
        scenePos = viewToScene(screenToView(vec3(texcoord, depth)));
    }

    /*
     * The held item does not move with the world, so it must not receive the
     * camera-delta term during reprojection - otherwise it smears whenever the
     * player walks, while remaining perfectly still on screen.
     */
    int materialId = decodeMaterialId(texture(colortex1, texcoord).a);
    bool screenAnchored = materialIsScreenAnchored(materialId);

    vec3 resolved = resolveTAA(colortex0, colortex5, texcoord,
                               scenePos, screenAnchored);

    sceneColor = vec4(resolved, 1.0);
    historyOut = vec4(resolved, 1.0);
#endif
}

#endif // ASTRA_COMPOSITE_TAA_FSH
