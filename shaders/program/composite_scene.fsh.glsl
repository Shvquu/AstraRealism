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
#include "/lib/water/caustics.glsl"

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

    /*
     * Caustics while submerged.
     *
     * Looking into water from above, caustics are applied in the water pass
     * itself, to the light that reached the bottom. From below there is no
     * water surface in front of the geometry to hang them off, so they are
     * applied here - and here they can be, because isEyeInWater says
     * unambiguously that everything visible is underwater.
     *
     * Depth below the surface is approximated from eye altitude: the exact
     * surface height is not available, but caustic strength varies slowly
     * enough with depth that the approximation is not visible.
     */
#if ASTRA_ENABLE_CAUSTICS
    if (isEyeInWater == 1) {
        vec3 worldPos = worldPosition(scenePos);

        // Distance from the surface, clamped to the range where caustics are
        // still coherent rather than fully scattered.
        float submergedDepth = clamp(eyeAltitude - worldPos.y + 2.0, 0.5, 16.0);

        color *= waterCaustics(worldPos, submergedDepth, shadowLightDirection());
    }
#endif

    /*
     * Volumetric light and fog.
     *
     * When the volumetric march ran, it already integrated both the extinction
     * and the in-scattering along this ray, including shadowing - so it
     * replaces the analytic fog entirely rather than being added to it.
     * Applying both would count the same air twice.
     *
     * With volumetrics disabled the march writes a fully transmissive result,
     * this branch contributes nothing, and the analytic fog below handles the
     * atmosphere on its own.
     */
#if ASTRA_ENABLE_VOLUMETRICS
    vec4 volumetric = texture(colortex10, texcoord);

    color = color * volumetric.a + volumetric.rgb;

    /*
     * Beyond the shadow distance the march stops, because there is no occlusion
     * data to march against. The analytic fog covers that remainder.
     *
     * It ramps in only past the march's range rather than across the whole
     * distance - applying it from the camera would re-fog the near stretch the
     * volumetric pass has already accounted for, darkening everything close by.
     */
    float beyondMarch = saturate((length(scenePos) - shadowDistance)
                                 / max(shadowDistance * 0.5, 1.0));

    if (beyondMarch > 0.0) {
        vec3 fogged = applyFog(color, scenePos, skyAccess);
        color = mix(color, fogged, beyondMarch);
    }

    sceneColor = vec4(color, 1.0);
#else
    sceneColor = vec4(applyFog(color, scenePos, skyAccess), 1.0);
#endif
}

#endif // ASTRA_COMPOSITE_SCENE_FSH
