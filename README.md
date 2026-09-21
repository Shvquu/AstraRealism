# AstraRealism

A physically based shader pack for Minecraft Java Edition, built for Iris.

AstraRealism computes its image rather than tinting it. Sunlight colour comes
out of atmospheric scattering, not a table of presets. Shadow softness comes
from the angular size of the sun. Wet stone reflects more because rain lowers
its roughness, not because a blue filter was applied. The goal is an image that
reads as real while staying unmistakably Minecraft.

> **Status: Phase 2 of 5.** Lighting, shadows, atmosphere, fog, PBR materials,
> parallax, ambient occlusion, reflections, water and wet surfaces are
> implemented and compile clean. Global illumination, volumetrics, clouds and
> the full post-processing chain land in later phases. See
> [Roadmap](#roadmap).

---

## Requirements

| | |
|---|---|
| **Minecraft** | 26.3 *or* 1.21.11 (Java Edition) |
| **Loader** | Fabric or NeoForge |
| **Mods** | [Iris](https://modrinth.com/mod/iris) + [Sodium](https://modrinth.com/mod/sodium) |
| **OpenGL** | 4.2 or newer |

Minecraft moved to year-based versions in 2026, so the sequence runs
1.21.11 → 26.1 → 26.2 → 26.3. There is no 1.22.

| Minecraft | Iris | Sodium |
|---|---|---|
| 26.3 | 1.11.6 | matching 26.3 build |
| 1.21.11 | 1.10.4 | 0.8.1 |

Iris and Sodium versions must match your Minecraft version exactly — a mismatch
is the most common cause of a crash on startup.

OptiFine is **not** supported and cannot be installed alongside Iris.

---

## Installation

1. Install Fabric (or NeoForge) for your Minecraft version.
2. Put the **Iris** and **Sodium** `.jar` files in `.minecraft/mods/`.
3. Download `AstraRealism-vX.Y.Z.zip` from
   [Releases](../../releases).
4. Put the `.zip` in `.minecraft/shaderpacks/` — **do not extract it**.
5. Launch Minecraft, then **Options → Video Settings → Shader Packs**, and
   select AstraRealism.

> **The release is a `.zip`, not a `.jar`.** Iris only lists folders and `.zip`
> archives in the shaderpacks folder. `.jar` is the *mod* format and belongs in
> `mods/`. Renaming the zip to `.jar` will make it disappear from the shader
> list. See [docs/limitations.md](docs/limitations.md).

On macOS, Safari may unzip the download automatically. If you end up with a
folder, either move the whole folder into `shaderpacks/` or re-compress it.

---

## Quality presets

Open **Shader Packs → AstraRealism → Settings** and pick a preset from the
profile button at the top. Every individual setting can still be adjusted
afterwards.

| Preset | Intended for | What it does |
|---|---|---|
| **Potato** | Integrated graphics | No GI, no reflections, hard shadows at 512, 2D clouds, minimal post |
| **Low** | Entry-level GPUs | 1024 shadows with PCF, SSAO, parallax, TAA, bloom |
| **Medium** | GTX 1060 / RX 580 class | PCSS shadows, GTAO, GI and reflections at reduced rates, volumetric clouds |
| **High** | RTX 3060 / RX 6600 class | Full shadow filtering, rough reflections, half-res GI and volumetrics |
| **Ultra** | RTX 4070 / RX 7800 class | 4K shadows, full-resolution GI and volumetrics |
| **Cinematic** | Screenshots and video | 8K shadows, maximum sample counts everywhere. Not intended to be playable |

**High** is the default. If you are unsure, start there and move down if your
frame rate is not where you want it.

---

## Tuning performance

Settings are listed roughly in order of how much time they cost. Turning down
the first entry is worth more than turning off the last five.

| Setting | Where | Notes |
|---|---|---|
| Shadow Resolution | Shadows | The single largest lever. 4096 → 2048 is close to a free doubling of shadow-pass throughput |
| Cloud Steps | Clouds | Volumetric clouds are the most expensive single feature; Cloud Quality → 2D removes them entirely |
| GI Resolution | GI & AO | 2 (half resolution) costs about a quarter of 1, and indirect light is too soft for the difference to show |
| Volumetric Steps | Atmosphere | Light shafts are soft; half resolution is usually invisible |
| Reflection Steps | Reflections | Lower this before disabling reflections outright |
| Caustics Samples | Water | Cost is Caustics Samples x Wave Detail, so the two multiply |
| AO Samples | GI & AO | GTAO traces a horizon search per sample |
| Parallax Distance | Materials | Parallax costs full price at any range; fading it out early is nearly free performance |
| Shadow Distance | Shadows | Scales cost roughly linearly, and spreads the same texels over more ground |
| Parallax Steps | Materials | Only matters with a PBR resource pack loaded |

A per-pass cost breakdown is in
[docs/performance.md](docs/performance.md).

---

## PBR resource packs

AstraRealism reads [LabPBR 1.3](https://wiki.shaderlabs.org/wiki/LabPBR_Material_Standard)
material data when a resource pack provides it: normal maps, roughness,
metalness, emission, porosity, subsurface scattering and height maps for
parallax.

Without one, the pack still works. Material properties are then derived from
`block.properties` — iron blocks are metal, leaves scatter light, sand is rough
— combined with a per-texel roughness estimate from the base texture. You lose
parallax and fine normal detail, not correct material response.

Set **Materials → PBR Mode** to `Auto` (the default) to use LabPBR data when
present and fall back automatically when it is not.

---

## Debugging

**Debug → Debug View** replaces the final image with a single intermediate
buffer: albedo, normals, depth, roughness, metalness, emission, lightmap,
ambient occlusion, material IDs and more. These bypass tone mapping entirely, so
what you see is what the buffer contains.

If the pack fails to load, Iris writes the compile error to
`.minecraft/logs/latest.log`. Please include that in any bug report, along with
your GPU, driver version, Minecraft version and Iris version.

More in [docs/debugging.md](docs/debugging.md).

---

## Known limitations

Summarised here; reasoning and workarounds in
[docs/limitations.md](docs/limitations.md).

- **Single shadow map, not cascades.** Iris exposes one shadow map. Near-field
  sharpness comes from a distortion function plus contact shadows instead.
- **Screen-space GI and reflections.** Light and reflections from geometry
  outside the frame do not contribute. Mitigated by a sky and block-light
  irradiance base, and by falling back to the sky model for escaped rays.
- **No hardware ray tracing.** Not available through Iris.
- **Parallax needs a height map**, so it switches off without a LabPBR pack.
- **`.zip` only.** Iris does not load `.jar` shader packs.

---

## Roadmap

| Phase | Contents | Status |
|---|---|---|
| 0 | Project structure, options, validation, CI | Done |
| 1 | GBuffer, shadows, sun/moon, atmosphere, fog | Done |
| 2 | LabPBR, parallax, GTAO, reflections, water, wetness | Done |
| 3 | Global illumination, volumetrics, clouds, Nether, End | Planned |
| 4 | TAA, bloom, auto exposure, tone mapping, colour grading | Planned |
| 5 | Preset tuning, debug views, docs, release | Planned |

---

## Building from source

Users do not need this — download a release instead.

```bash
python tools/gen_dimension_stubs.py --check   # dimension folders in sync
python tools/validate_shader.py --strict      # structure, options, properties
python -m unittest discover -s tests          # tooling tests
python tools/glsl_compile.py --all-presets    # real GLSL compilation
python tools/build_pack.py --version dev      # produces dist/
```

`glsl_compile.py` needs `glslangValidator` on `PATH` (Debian/Ubuntu:
`apt-get install glslang-tools`). Without it the step is skipped rather than
failing, so the other checks stay usable.

Architecture notes are in [docs/architecture.md](docs/architecture.md); the
render pass order is in [docs/pipeline.md](docs/pipeline.md).

---

## Releasing

Releases are fully automated. Push a semantic version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions then validates, compiles, builds, generates a changelog from the
commits since the previous tag, publishes the release and attaches the pack. The
version comes from the tag alone — there is no second number to maintain.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `ci:`, `chore:`), which is what
the changelog generator categorises on.

---

## License

MIT — see [LICENSE](LICENSE).
