# Architecture

How the pack is laid out and why.

---

## Directory layout

```
shaders/
├── shaders.properties      option screens, sliders, presets, feature flags
├── dimension.properties    dimension -> folder mapping
├── block.properties        block -> material id mapping
├── version.txt             written from the git tag at release time
├── lang/                   option labels and tooltips
│
├── lib/                    all logic
│   ├── common/             settings, math, encoding, spaces, buffers, debug
│   ├── compat/             version gating and graceful degradation
│   ├── material/           material acquisition and classification
│   ├── lighting/           BRDF, shadows, AO, GI, reflections, composition
│   ├── atmosphere/         scattering, sky, sun/moon, fog, volumetrics, clouds
│   ├── water/              waves, shading, caustics
│   ├── dimension/          overworld, nether, end
│   └── post/               tone mapping, grading, TAA jitter
│
├── program/                the actual program bodies, one copy each
│
├── world0/                 generated stubs - overworld and modded dimensions
├── world-1/                generated stubs - the nether
├── world1/                 generated stubs - the end
└── *.vsh / *.fsh           generated stubs - fallback if dimension mapping fails
```

---

## Why the dimension folders hold generated stubs

Iris loads programs **only** from a dimension folder once that folder exists.
There is no per-file fallback to `shaders/`. A pack with three dimension folders
therefore needs four complete sets of program files — 192 files at present.

Maintaining four copies of every shader by hand guarantees they drift. Instead:

- the real code lives once in `shaders/program/*.glsl`
- every file in a dimension folder is a three-line stub

```glsl
#version 420 compatibility

#define DIM_NETHER
#define PROGRAM_TERRAIN

#include "/program/gbuffers_main.fsh.glsl"
```

`tools/gen_dimension_stubs.py` generates all 192 from the manifest in
`tools/program_manifest.py`. `--check` verifies they match and runs as a CI gate,
so a stub can never silently fall out of date.

Adding a program means adding one entry to the manifest and running the
generator. Nothing else.

---

## Why one body serves every gbuffers program

`gbuffers_main.vsh.glsl` and `gbuffers_main.fsh.glsl` handle all thirteen
gbuffers programs. The stub's `PROGRAM_*` macro selects behaviour:

```glsl
#if defined(PROGRAM_SKYBASIC) || defined(PROGRAM_SKYTEXTURED)
    #define ASTRA_PATH_SKY        // discard; the atmosphere model replaces it
#elif defined(PROGRAM_WATER) || defined(PROGRAM_WEATHER) || ...
    #define ASTRA_PATH_FORWARD    // shade now, blend into colortex0
#else
    #define ASTRA_PATH_DEFERRED   // write material properties to the gbuffer
#endif
```

The alternative — thirteen near-identical files — means a fix to the tangent
basis has to be applied thirteen times, and will be applied to twelve.

Programs whose behaviour is genuinely identical to a relative are not shipped at
all. Iris falls back on its own: `gbuffers_damagedblock` inherits
`gbuffers_terrain`, `gbuffers_spidereyes` and `gbuffers_armor_glint` inherit
`gbuffers_textured`, `gbuffers_hand_water` inherits `gbuffers_hand`.

---

## Options have exactly one definition

`shaders/lib/common/settings.glsl` declares every user-facing option. Nothing
else may declare one.

Three files must agree about them:

| File | Holds |
|---|---|
| `lib/common/settings.glsl` | the option, its default and its legal values |
| `shaders.properties` | where it appears on screen, and what each preset sets it to |
| `lang/en_us.lang` | its label and tooltip |

`tools/validate_shader.py` enforces all three directions: an option referenced
by a screen that does not exist, a preset assigning a value outside an option's
list, a missing label, a leftover translation for a deleted option. Each is an
error, not a warning.

---

## Dimensions branch in exactly two places

`lib/dimension/dimension.glsl` dispatches on the `DIM_*` macro every generated
stub has carried since Phase 0, selecting one of `overworld.glsl`,
`nether.glsl` or `end.glsl`. Each supplies the same six functions, so the
lighting and fog code never tests which world it is in.

The interesting decision is that **ambient gating belongs to the dimension**,
not to the caller. The overworld gates ambient light on the sky lightmap,
because there ambient light *is* skylight — a block deep in a cave genuinely
receives none. The Nether and the End cannot do that: Minecraft reports a sky
light level of zero throughout both, so the same gate would render them
entirely black.

Putting `dimensionAmbientLight(normal, lightmapSky)` behind the interface lets
each dimension answer correctly. It is also why the Nether's ambient arrives
from *below* — the lava is down there — which inverts the overworld's most
basic lighting cue and does more for the place's character than any colour
choice.

---

## Temporal interleaving is one mechanism, used three times

GI, volumetrics and clouds are all far too expensive per-pixel per-frame. All
three share `lib/common/temporal.glsl`: divide the screen into NxN tiles,
retrace one pixel per tile per frame, and let the rest reuse reprojected
history.

Implementing this once rather than three times matters because the subtle part
is history *rejection* — an off-screen reprojection and a depth mismatch fail
differently, and getting either wrong produces ghosting that is hard to
attribute. One implementation means one place to fix it.

Iris offers `scale.<program>` to render a pass at reduced resolution instead.
It was not used because its value is fixed in `shaders.properties` and cannot
follow a user setting, and because it renders into a sub-rectangle that every
later pass has to account for.

---

## Capability resolution is centralised

Programs never test `MC_VERSION`, `IRIS_VERSION` or a raw feature macro.

- `lib/compat/version.glsl` is the only file that reads them, and translates
  them into `ASTRA_HAS_*`.
- `lib/compat/fallback.glsl` combines those with the user's settings into
  `ASTRA_ENABLE_*`.
- Everything else tests `ASTRA_ENABLE_*`.

So supporting a new Minecraft version means editing one file. And a feature whose
prerequisites are missing degrades in one place rather than needing a guard at
every call site — parallax switches itself off without a height map; volumetric
light switches itself off when shadows are disabled, because with nothing to
occlude the rays it would render as uniform haze.

---

## The gbuffer layout is encoded in one place

`lib/common/encoding.glsl` owns the packing. Every read and write goes through
`encodeGBuffer()` / `decodeGBuffer()`, so changing the layout means editing one
file rather than auditing every pass.

| Buffer | Format | Contents |
|---|---|---|
| colortex1 | RGBA16 | albedo.rgb, material id |
| colortex2 | RGBA16 | shading normal (octahedral), geometric normal (octahedral) |
| colortex3 | RGBA8 | roughness, F0/metalness, emission, porosity |
| colortex4 | RGBA16F | block light, sky light, AO, wetness |

Two normals are stored deliberately. The shading normal is normal-mapped; the
geometric one is not. Shadow bias, back-face rejection, ambient occlusion and
reflection ray origins all need the unperturbed face normal — using the mapped
one makes surfaces shadow themselves and reflection rays start inside geometry.

Normals are octahedral at 16 bits per channel. The common "store XY, reconstruct
Z" scheme cannot represent normals facing away from the camera, which
translucents and back faces require, and at 8 bits it bands visibly in smooth
specular highlights.

---

## Temporal state lives in unclear buffers

Buffers declared `clear = false` survive into the next frame. That is the entire
mechanism behind TAA, GI accumulation, reflection accumulation and auto exposure:
a pass reads its own previous output.

The validator enforces the companion rule — a buffer with `clear = false` must
declare an explicit format, because the RGBA8 default silently destroys anything
being accumulated in it.

---

## Verification

| Tool | Checks |
|---|---|
| `gen_dimension_stubs.py --check` | all four dimension folders match the manifest |
| `validate_shader.py --strict` | includes resolve, no cycles, guards present, options/properties/lang agree, render targets valid, block ids consistent |
| `glsl_compile.py --all-presets` | real compilation: 2 Minecraft versions x 6 presets x 2 PBR modes x 48 files = 1152 |
| `unittest discover tests` | changelog parsing, version handling, build reproducibility, option parsing |

The compile matrix is the one that matters most. Compiling only the default
preset leaves every `#if`-guarded branch unchecked, and a bug behind
`#if ASTRA_ENABLE_GI` is invisible until someone turns GI on.
