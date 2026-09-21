# Performance

Where the frame time goes, and which settings actually move it.

> **These are algorithmic cost models, not measurements.** No profiling has been
> done yet — there is no Minecraft in the authoring environment. The ordering
> and the scaling relationships are derived from what each pass does, and they
> are already actionable; the absolute shares are not stated because they would
> be invented. Measured figures replace this once the pipeline is complete.

---

## What each pass costs

| Pass | Dominant work | Scales with |
|---|---|---|
| **Shadow** | Rasterising the whole scene a second time | Shadow Resolution **squared**, Shadow Distance |
| **Gbuffers (opaque)** | Overdraw, parallax marching, wetness noise | Render distance, Parallax Steps, Parallax Distance |
| **deferred** (AO) | Horizon search, 4 march steps per slice | AO Samples |
| **deferred1** (lighting) | PCSS blocker search then filtering | Shadow Samples + Blocker Samples |
| **deferred2** (reflections) | Screen-space ray march per reflective pixel | Reflection Steps x Rough Samples, and what fraction of the screen is below the roughness cutoff |
| **Gbuffers (water)** | Wave noise, refraction, caustics | Wave Detail x Caustics Samples |
| **composite** | Fog integration, underwater caustics | Screen resolution |
| **final** | Tone mapping, grading | Screen resolution |

---

## The settings that matter most

Ordered by how much time they return per unit of visual loss.

### 1. Shadow Resolution

Cost scales with the **square** of the resolution. 4096 → 2048 is close to a
free quadrupling of shadow-pass throughput, and the distortion function means
the near-field difference is far smaller than the number suggests.

This is the first thing to turn down, and often the only one needed.

### 2. Caustics Samples x Wave Detail

These **multiply**. `causticConvergence()` evaluates the wave field twice per
sample, and each evaluation runs the octave loop three times for the central
difference. At 8 samples and 8 octaves that is nearly 200 noise evaluations per
affected pixel.

They only run on pixels seen through or from within water — but standing
underwater makes that the whole screen.

### 3. Cloud Steps x Cloud Light Steps *(Phase 3)*

Also multiplicative: every march step takes a second march toward the sun.
Doubling both quadruples the work.

### 4. Reflection Steps x Rough Samples

Multiplicative again. Rough surfaces trace `SSR_ROUGH_SAMPLES` rays, each of
`SSR_STEPS` steps.

`SSR_ROUGHNESS_CUTOFF` is the cheapest lever here: it does not make tracing
faster, it removes whole pixels from tracing at all. Surfaces above the cutoff
fall back to the ambient specular term, which is nearly free and — for genuinely
rough surfaces — visually almost identical.

### 5. Parallax Distance

Parallax costs the same whether the surface fills the screen or is four pixels
across, but it stops being resolvable long before it stops being computed.
Lowering the fade distance is close to free performance.

### 6. AO Samples

GTAO runs a horizon search per slice, each of four march steps. It is linear in
the sample count, so it is a predictable dial rather than a cliff.

Dropping to SSAO is cheaper still, but the quality difference is visible in
exactly the creases AO exists to darken.

---

## Settings that cost almost nothing

Worth knowing so they are not turned off in a panic:

- **Tone mapping choice.** ACES, AgX, Neutral and Reinhard are all a handful of
  arithmetic operations per pixel. Pick on looks alone.
- **Colour grading.** Same.
- **Coloured shadows.** Two extra shadow map samples on pixels that are already
  being filtered.
- **Contact shadows** at the default 12 steps. Short rays that terminate early
  on most pixels.
- **Minimum light, block light temperature, all intensity sliders.** Arithmetic.
- **Stars.** A few hash evaluations, and only on sky pixels.

---

## Preset design

Each preset changes many settings at once; these are the ones that account for
most of the difference between them.

| | Potato | Low | Medium | High | Ultra | Cinematic |
|---|---|---|---|---|---|---|
| Shadow Resolution | 512 | 1024 | 2048 | 2048 | 4096 | 8192 |
| Shadow Filter | Hard | PCF | PCSS | PCSS | PCSS | PCSS |
| Shadow Samples | 4 | 6 | 8 | 12 | 24 | 48 |
| AO | off | SSAO 4 | GTAO 6 | GTAO 8 | GTAO 16 | GTAO 24 |
| Reflections | off | off | 12 steps | 24 steps, rough | 32, rough | 64, rough |
| Parallax | off | 8 steps | 12 steps | 24 + shadow | 48 | 128 |
| Caustics | off | off | 2 samples | 4 | 6 | 8 |
| Wave Detail | 2 | 3 | 4 | 5 | 6 | 8 |

**Cinematic is not intended to be playable.** It exists for screenshots and
recording, where frame time does not matter and the last few percent of quality
does.

---

## If the frame rate is bad

1. **Switch to a lower preset first.** The presets move a dozen correlated
   settings together; changing one at a time from Ultra rarely finds the one
   that matters.
2. **Then raise Shadow Resolution back up** if that was the setting you cared
   about. It is usually the single biggest contributor, so it is also the one
   most worth spending budget on deliberately.
3. **Check whether you are underwater.** Caustics apply to the whole screen
   there.
4. **Check the render distance.** The shadow pass rasterises the scene a second
   time, so Minecraft's own render distance multiplies into the shader cost.
