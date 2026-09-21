# Debugging

How to find out what a wrong-looking image is actually doing.

---

## Debug views

**Shader Packs → AstraRealism → Settings → Debug → Debug View** replaces the
final image with a single intermediate buffer.

Every mode bypasses tone mapping, exposure and grading entirely. A debug view
that has been graded is not telling you what the buffer contains, so what you
see is the raw value.

| Mode | Shows | Looks wrong if |
|---|---|---|
| Albedo | Base colour with no lighting | Tinted or dark — the texture or biome tint is being modified before the gbuffer |
| Normals | Shading normal, remapped from [-1,1] | Flat mid-grey on all faces — normal mapping is not reaching the gbuffer. Harsh discontinuities — the tangent basis is wrong |
| Depth | Linear distance on a colour ramp | Uniform — the depth buffer is not being read correctly |
| Roughness | Blue smooth, red rough | Uniform — no PBR data and the fallback heuristic is not running |
| Metallic / F0 | Yellow for metal, ramp for dielectrics | Everything yellow — the metalness threshold is misreading the specular map |
| Emissive | Emission strength | Black on glowstone — emissive classification is not reaching the material |
| Lightmap | Red block light, green sky light | Black indoors — lightmap coordinates are not arriving |
| Ambient Occlusion | White unoccluded, dark occluded | Pure white — the AO pass is not writing, or `AO_MODE` is off |
| Material ID | One colour per material class | Everything one colour — `block.properties` is not being applied |

Modes 9 through 14 (shadows, direct lighting, GI, reflections, volumetrics,
motion vectors) render as flat grey until the passes that produce those buffers
exist. That is deliberate: flat grey says "not yet written", where noise would
suggest a bug.

---

## The pack does not appear in the shader list

In order of likelihood:

1. **It is a `.jar`.** Iris only lists folders and `.zip` archives. Renaming a
   zip to `.jar` makes it vanish from the list entirely.
2. **It is double-nested** — a zip containing a folder containing the pack.
   Opening the zip should show `shaders/` at the top level.
3. **Wrong folder.** Use *Options → Video Settings → Shader Packs → Open Shader
   Pack Folder* to get the directory Iris actually reads. Launchers with
   per-instance folders often surprise people here.
4. **Iris did not load.** If there is no *Shader Packs* button at all, the
   problem is the mod, not the pack. Check that Iris and Sodium match your
   Minecraft version exactly.

---

## The pack loads but the screen is broken

Iris writes shader compile errors to `.minecraft/logs/latest.log`. Search for
`ERROR` or the name of a program such as `gbuffers_terrain`.

The log gives a line number in the *preprocessed* source, which includes every
`#include` expanded inline, so it will not match the line numbers in any file
you can open. `tools/glsl_compile.py` maps those numbers back to real files —
running it locally on the same preset usually reproduces the error with a
usable location.

---

## Reproducing a compile error locally

```bash
python tools/glsl_compile.py --preset HIGH --program gbuffers_terrain
```

This compiles one program with the real GLSL compiler and reports errors against
the original file and line, not the flattened source.

To check every configuration — both Minecraft versions, all six presets, with
and without a PBR resource pack:

```bash
python tools/glsl_compile.py --all-presets
```

A bug behind `#if ASTRA_ENABLE_GI` is invisible until GI is enabled, which is
why the full matrix matters before shipping anything.

---

## Isolating a visual problem

Work down the pipeline, since each stage consumes the one before it:

1. **Debug View → Albedo.** If this is wrong, the problem is in
   `gbuffers_main.fsh.glsl` or `lib/material/`, and everything downstream is
   innocent.
2. **Debug View → Normals.** Wrong normals break shadows, reflections and AO
   simultaneously, which tends to look like several unrelated bugs at once.
3. **Debug View → Ambient Occlusion.** Isolates `lib/lighting/ao.glsl`.
4. **Disable systems one at a time** in the settings — shadows, reflections,
   parallax, wetness. The one that changes the symptom owns it.
5. **Compare presets.** A problem that appears only at Ultra points at a sample
   count or a resolution divisor; one that appears at every preset points at the
   algorithm.

---

## Common symptoms

| Symptom | Likely cause |
|---|---|
| Striped self-shadowing (acne) | `SHADOW_BIAS` too low |
| Shadows detached from their casters | `SHADOW_BIAS` too high |
| Whole image blown out or black | Exposure — auto exposure is not implemented yet, so `MANUAL_EXPOSURE` carries the whole load |
| Grain in creases | `AO_SAMPLES` too low; TAA in Phase 4 will absorb the rest |
| Reflections trailing behind motion | Temporal reflection accumulation — disable `SSR_TEMPORAL` to confirm |
| Foreground smeared into water | Refraction sampling past the water surface; reduce `WATER_REFRACTION_STRENGTH` |
| Texture bleeding between blocks | Parallax escaping its atlas tile — reduce `POM_DEPTH` |
| Sky renders black or garbled | Sky detection via `depth >= 1.0` failing, meaning the vanilla sky is writing depth |

---

## Reporting a bug

Include:

- Minecraft, Iris and Sodium versions
- GPU and driver version
- The preset, and any settings changed from it
- Whether a PBR resource pack is loaded, and which
- The relevant section of `.minecraft/logs/latest.log`
- A screenshot, plus the matching Debug View if the problem is visual

The GPU vendor matters more than it looks: AMD and Intel drivers reject GLSL
that NVIDIA accepts, so "works on mine" is not evidence the code is correct.
