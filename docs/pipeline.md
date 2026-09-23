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
deferred1         global illumination: gathers from LAST frame's lit scene
   |              -> colortex6 (irradiance), colortex7 (moments)
   v
deferred2/3       two a-trous filter iterations over the GI result
   |              -> colortex6
   v
deferred4         shade every opaque pixel; fill sky from the dimension model
   |              -> colortex0 (HDR radiance)
   v
deferred5         volumetric clouds, composited into sky pixels
   |              -> colortex0, colortex11 (history)
   |              disabled in the Nether and the End
   v
deferred6         screen-space reflections, plus the scene copy translucents read
   |              -> colortex0, colortex8, colortex9, colortex13
   v
gbuffers (trans.) water and glass: waves, refraction, absorption, reflection,
   |              caustics. particles and weather: forward shaded.
   |              -> colortex0, blended
   v
composite         volumetric light and fog march through the shadow map
   |              -> colortex10
   v
composite1        apply volumetrics, analytic fog beyond the march, caustics
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

**Global illumination before lighting, gathering from the previous frame.**
GI needs lit surfaces to bounce light from, but the lighting pass consumes GI's
output - a deferred renderer cannot have both. The resolution is that colortex9
is not cleared, so at the start of a frame it still holds the previous frame's
lit scene. Indirect light therefore lags direct light by one frame, which is
imperceptible for anything but an explosion.

**Clouds after lighting, before reflections.** They need the sky to composite
over, and they must exist before the scene copy is taken, or water would reflect
a clear sky under an overcast one.

**Volumetrics after translucents.** Light shafts should stop at a water surface
rather than passing through it, which means water has to be in the depth buffer
first.

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
| colortex0 | RGBA16F | deferred4/5/6, forward gbuffers, composite1 | composite1, final | yes |
| colortex1 | RGBA16 | gbuffers (opaque) | deferred4/6, debug | yes |
| colortex2 | RGBA16 | gbuffers (opaque) | deferred, deferred1/2/3/4/6, debug | yes |
| colortex3 | RGBA8 | gbuffers (opaque) | deferred4/6, debug | yes |
| colortex4 | RGBA16F | gbuffers (opaque), deferred | deferred4/6, composite, debug | yes |
| colortex5 | RGBA16F | *planned* TAA resolve | TAA resolve | **no** |
| colortex6 | RGBA16F | deferred1, deferred2/3 | deferred2/3/4 | **no** |
| colortex7 | RGBA16F | deferred1 | deferred2/3 | **no** |
| colortex8 | RGBA16F | deferred6 | deferred6 (previous frame) | **no** |
| colortex9 | RGBA16F | deferred6 | gbuffers_water, **deferred1 (previous frame)** | **no** |
| colortex10 | RGBA16F | composite | composite1, composite (previous frame) | **no** |
| colortex11 | RGBA16F | deferred5 | deferred5 (previous frame) | **no** |
| colortex12 | RGBA16F | *planned* bloom chain | final | yes |
| colortex13 | RGBA32F | deferred6 | deferred1/5/6, composite, *planned* TAA | **no** |
| colortex14 | RGBA16F | *planned* atmosphere LUTs | deferred4, composite1 | **no** |
| colortex15 | RGBA32F | *planned* exposure state | final | **no** |

colortex9 is the one worth a second look: it is written once per frame with the
lit opaque scene, read later that same frame by translucent geometry, and read
again at the *start of the next frame* by the GI pass. One buffer serving two
consumers a frame apart is what makes screen-space GI affordable here.

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
| Shadow | Rasterising the scene a second time | Shadow Resolution **squared**, Shadow Distance |
| Gbuffers | Overdraw, parallax marching | Render distance, Parallax Steps, Parallax Distance |
| deferred (AO) | Horizon search per slice | AO Samples |
| deferred1 (GI) | Ray march per sample | GI Samples x GI Steps, divided by GI Resolution **squared** |
| deferred2/3 (GI filter) | Nine taps each | Screen resolution |
| deferred4 (lighting) | PCSS blocker search plus filtering | Shadow Samples + Blocker Samples |
| deferred5 (clouds) | Density march, each step marching toward the sun | Cloud Steps x Cloud Light Steps, divided by Cloud Resolution **squared** |
| deferred6 (reflections) | Screen-space march per reflective pixel | Reflection Steps x Rough Samples |
| gbuffers_water | Wave noise, refraction, caustics | Wave Detail x Caustics Samples |
| composite (volumetrics) | Shadow lookup per march step | Volumetric Steps, divided by Volumetric Resolution **squared** |
| final | Tone mapping, grading | Screen resolution |

Several rows multiply rather than add, and those are the ones worth
internalising:

- **Clouds** cost `Cloud Steps x Cloud Light Steps`. Doubling both quadruples
  the work, which makes this the most expensive system in the pack.
- **GI** costs `GI Samples x GI Steps`, then divides by the square of the
  resolution divisor.
- **Caustics** cost `Caustics Samples x Wave Detail`, but only on pixels seen
  through or from within water.

The resolution divisors divide by their **square**, because they spread the
work across an NxN tile. Moving one from 1 to 2 removes three quarters of the
cost of that pass.
