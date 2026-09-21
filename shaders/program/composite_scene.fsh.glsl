#ifndef ASTRA_COMPOSITE_SCENE_FSH
#define ASTRA_COMPOSITE_SCENE_FSH

/*
 * AstraRealism - Scene-space composite.
 *
 * Runs after translucent geometry. At this point colortex0 holds the fully lit
 * scene including water and particles, so this is where effects that need the
 * complete image belong.
 *
 * Currently applies atmospheric fog. Volumetric light, water refraction and
 * reflections join this stage in later phases, which is why the fog is applied
 * from a shared library rather than inlined here.
 */

#include "/lib/common/common.glsl"
#include "/lib/atmosphere/fog.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 sceneColor;

void main() {
    vec3 color = texture(colortex0, texcoord).rgb;

    float depth = texture(depthtex0, texcoord).r;

    /*
     * Sky pixels already contain a full atmospheric integration from the
     * deferred pass, so applying fog to them would double-count the scattering
     * and wash the sky out.
     */
    if (isSky(depth)) {
        sceneColor = vec4(color, 1.0);
        return;
    }

    vec3 viewPos = screenToView(vec3(texcoord, depth));
    vec3 scenePos = viewToScene(viewPos);

    /*
     * Sky access comes from the opaque gbuffer. Translucent geometry has
     * overwritten nothing here because it took the forward path, so this value
     * describes the surface behind the water rather than the water itself -
     * which is the right choice for deciding whether the fog is cave fog.
     */
    float skyAccess = texture(colortex4, texcoord).g;

    sceneColor = vec4(applyFog(color, scenePos, skyAccess), 1.0);
}

#endif // ASTRA_COMPOSITE_SCENE_FSH
