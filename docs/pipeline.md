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
   |              parallax displacement, wetness, snow response
   |              -> colortex1..4 (material properties), depthtex
   v
deferred          ambient occlusion, folded into the gbuffer's AO channel
   |              -> colortex4
   v
deferred1         shade every opaque pixel; fill sky pixels with the atmosphere
   |              -> colortex0 (HDR radiance)
   v
deferred2         screen-space reflections, plus the scene copy translucents read
   |              -> colortex0, colortex8 (history), colortex9 (copy),
   |                 colortex13 (depth for next frame)
   v
gbuffers (trans.) water and glass: waves, refraction, absorption, reflection,
   |              caustics. particles and weather: forward shaded.
   |              -> colortex0, blended
   v
composite         atmospheric fog, underwater caustics
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

**Occlusion before lighting.** The lighting pass consumes the AO channel, so it
has to be filled first. Writing it back into colortex4 rather than into a buffer
of its own works because Iris ping-pongs colour attachments: a pass reads the
front copy and writes the back one.

**Reflections after lighting, before translucents.** Reflections need the scene
to be lit, so they cannot run earlier. They must not include water, so they
cannot run later. That leaves exactly one slot, which is also the only correct
place to copy the opaque scene for translucents to read.

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
| colortex0 | RGBA16F | deferred1/2, forward gbuffers, composite | composite, final | yes |
| colortex1 | RGBA16 | gbuffers (opaque) | deferred1/2, debug | yes |
| colortex2 | RGBA16 | gbuffers (opaque) | deferred, deferred1/2, debug | yes |
| colortex3 | RGBA8 | gbuffers (opaque) | deferred1/2, debug | yes |
| colortex4 | RGBA16F | gbuffers (opaque), deferred | deferred1/2, composite, debug | yes |
| colortex5 | RGBA16F | *planned* TAA resolve | TAA resolve | **no** |
| colortex6 | RGBA16F | *planned* GI accumulate | deferred1, denoiser | **no** |
| colortex7 | RGBA16F | *planned* GI moments | denoiser | **no** |
| colortex8 | RGBA16F | deferred2 | deferred2 (previous frame) | **no** |
| colortex9 | RGBA16F | deferred2 | gbuffers_water, gbuffers_hand_water | yes |
| colortex10 | RGBA16F | *planned* volumetrics | composite | yes |
| colortex11 | RGBA16F | *planned* clouds | deferred1, composite | **no** |
| colortex12 | RGBA16F | *planned* bloom chain | final | yes |
| colortex13 | RGBA32F | deferred2 | deferred2 (previous frame), *planned* TAA/GI | **no** |
| colortex14 | RGBA16F | *planned* atmosphere LUTs | deferred1, composite | **no** |
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
| Gbuffers | Overdraw, parallax ray marching | Render distance, Parallax Steps, Parallax Distance |
| deferred (AO) | Horizon search per slice | AO Samples, and 4 march steps each |
| deferred1 (lighting) | PCSS blocker search plus filtering | Shadow Samples, Blocker Samples |
| deferred2 (reflections) | Ray marching per reflective pixel | Reflection Steps x Rough Samples, fraction of screen below the roughness cutoff |
| gbuffers_water | Wave noise, refraction, caustics | Wave Detail, Caustics Samples — these multiply |
| GI *(planned)* | Ray marching the depth buffer | GI Samples x GI Steps, divided by GI Resolution squared |
| Volumetrics *(planned)* | Shadow lookups per march step | Volumetric Steps, divided by resolution squared |
| Clouds *(planned)* | Cloud Steps x Cloud Light Steps per pixel | The product — raising both is multiplicative |
| Post *(planned)* | Bloom chain, TAA resolve | Screen resolution |

Two rows multiply rather than add, and are worth internalising:

- **Caustics** evaluate the wave field several times per sample, so their cost is
  `Caustics Samples x Wave Detail`. They only run on pixels seen through or from
  within water, but on those pixels they are expensive.
- **Clouds** cost `Cloud Steps x Cloud Light Steps`. Doubling both quadruples the
  work.

The clouds row is the one worth internalising: cloud cost is the *product* of the
two step counts, not their sum. Doubling both quadruples the work.
