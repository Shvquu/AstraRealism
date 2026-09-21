# Render pipeline

The order passes execute in, what each consumes and produces, and why it sits
where it does.

Passes marked *planned* are not yet implemented; the slot is reserved so the
ordering constraints are visible now.

---

## Pass order

```
shadow            scene from the light's point of view
   |              -> shadowtex0/1 (depth), shadowcolor0 (translucent tint)
   v
gbuffers (opaque) terrain, entities, block entities, hand
   |              -> colortex1..4 (material properties), depthtex
   v
deferred          shade every opaque pixel; fill sky pixels with the atmosphere
   |              -> colortex0 (HDR radiance)
   v
gbuffers (trans.) water, glass, particles, weather - forward shaded
   |              -> colortex0, blended
   v
composite         atmospheric fog over the complete scene
   |              -> colortex0
   v
final             exposure, grading, tone mapping, vignette, dither
                  -> the screen
```

---

## Why the order is what it is

**Shadow before everything.** Shading cannot start until occlusion is known.
The shadow pass is also the cheapest place to capture translucent caster colour,
since those fragments are being rasterised anyway.

**Opaque geometry before deferred.** The point of deferring is that each pixel is
shaded exactly once regardless of overdraw. Terrain overdraws heavily, so this
matters more in Minecraft than in most scenes.

**Deferred before translucents.** Translucents blend over a lit scene, so that
scene must exist first. The consequence is that translucents cannot use the
gbuffer — the lighting pass has already consumed it — which is why they take the
forward path in `lib/lighting/forward.glsl`.

**Fog after translucents.** Fog attenuates everything between the camera and the
surface, including water and particles. Applying it before they are drawn leaves
them unfogged and floating in front of the haze.

**Sky pixels are skipped by fog.** The deferred pass already integrates a full
atmosphere for them. Applying fog on top would count the same scattering twice
and wash the sky out.

---

## Buffer roles

| Buffer | Format | Written by | Read by | Clear |
|---|---|---|---|---|
| colortex0 | RGBA16F | deferred, forward gbuffers, composite | composite, final | yes |
| colortex1 | RGBA16 | gbuffers (opaque) | deferred, debug | yes |
| colortex2 | RGBA16 | gbuffers (opaque) | deferred, debug | yes |
| colortex3 | RGBA8 | gbuffers (opaque) | deferred, debug | yes |
| colortex4 | RGBA16F | gbuffers (opaque) | deferred, composite, debug | yes |
| colortex5 | RGBA16F | *planned* TAA resolve | TAA resolve | **no** |
| colortex6 | RGBA16F | *planned* GI accumulate | deferred, denoiser | **no** |
| colortex7 | RGBA16F | *planned* GI moments | denoiser | **no** |
| colortex8 | RGBA16F | *planned* SSR accumulate | composite | **no** |
| colortex9 | RGBA16F | *planned* volumetrics | composite | yes |
| colortex10 | RGBA16F | *planned* clouds | deferred, composite | **no** |
| colortex11-12 | RGBA16F | *planned* bloom chain | final | yes |
| colortex13 | RGBA32F | *planned* previous depth and motion | TAA, GI, SSR | **no** |
| colortex14 | RGBA16F | *planned* atmosphere LUTs | deferred, composite | **no** |
| colortex15 | RGBA32F | *planned* exposure state | final | **no** |

`clear = no` is what makes a buffer temporal: it survives into the next frame so
a pass can read its own previous output. Every such buffer declares an explicit
format, because the RGBA8 default would quantise away whatever is accumulating
in it.

---

## Depth textures

| Texture | Contents | Used for |
|---|---|---|
| `depthtex0` | everything, including translucents | sky detection, scene position |
| `depthtex1` | opaque only | the surface behind water — needed for absorption and refraction |
| `depthtex2` | opaque, excluding the hand | effects that must ignore the held item |

Water depth comes from comparing `depthtex0` against `depthtex1`: where they
differ, something translucent is in front.

---

## Shadow textures

| Texture | Contents |
|---|---|
| `shadowtex0` | all casters, including translucents |
| `shadowtex1` | opaque casters only |
| `shadowcolor0` | caster albedo and opacity, for coloured shadows |

Coloured shadows need no separate flag. A point that passes the `shadowtex1`
test but fails `shadowtex0` is lit through something translucent, and
`shadowcolor0` says what colour it picked up on the way.

---

## Approximate cost

Measured shares of frame time will be filled in from real profiling once the
pipeline is complete. The ordering below reflects the algorithmic cost of each
pass and is already actionable.

| Pass | Dominant cost | Scales with |
|---|---|---|
| Shadow | Rasterising the scene a second time | Shadow Resolution squared, Shadow Distance |
| Gbuffers | Overdraw, parallax ray marching | Render distance, Parallax Steps |
| Deferred | PCSS blocker search plus filtering | Shadow Samples, Blocker Samples |
| GI *(planned)* | Ray marching the depth buffer | GI Samples x GI Steps, divided by GI Resolution squared |
| Reflections *(planned)* | Ray marching per reflective pixel | Reflection Steps, fraction of screen that is reflective |
| Volumetrics *(planned)* | Shadow lookups per march step | Volumetric Steps, divided by resolution squared |
| Clouds *(planned)* | Cloud Steps x Cloud Light Steps per pixel | The product — raising both is multiplicative |
| Post *(planned)* | Bloom chain, TAA resolve | Screen resolution |

The clouds row is the one worth internalising: cloud cost is the *product* of the
two step counts, not their sum. Doubling both quadruples the work.
