#ifndef ASTRA_SHADOW_FSH
#define ASTRA_SHADOW_FSH

/*
 * AstraRealism - Shadow map fragment stage.
 *
 * Depth is written automatically. The only thing this stage produces is the
 * colour a translucent caster imparts to the light passing through it, which
 * the lookup side reads to tint shadows cast through stained glass, water
 * and ice.
 */

#include "/lib/common/common.glsl"
#include "/lib/material/material_id.glsl"

in vec2 texcoord;
in vec4 vertexColor;
flat in int materialId;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 shadowColorOut;

void main() {
    vec4 texel = texture(gtexture, texcoord);
    vec4 color = texel * vertexColor;

    // Cutout geometry must not cast a shadow where it is transparent, or
    // leaves and grass cast solid square shadows.
    if (color.a < alphaTestRef) discard;

#if ASTRA_ENABLE_COLORED_SHADOWS
    if (materialIsTranslucent(materialId)) {
        /*
         * Store the caster's colour and how much it blocks. The lookup side
         * mixes toward this colour in proportion to alpha, so a nearly clear
         * pane barely tints and a dense one tints strongly.
         *
         * Kept in sRGB: the lookup converts once, after filtering, which is
         * both cheaper and avoids filtering in linear space where the result
         * would be biased toward the brighter samples.
         */
        shadowColorOut = vec4(texel.rgb * vertexColor.rgb, color.a);
        return;
    }
#endif

    // Opaque casters block light entirely. White with zero alpha means "no
    // tint", matching shadowcolor0ClearColor.
    shadowColorOut = vec4(1.0, 1.0, 1.0, 0.0);
}

#endif // ASTRA_SHADOW_FSH
