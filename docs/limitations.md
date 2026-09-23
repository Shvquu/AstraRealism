# Known limitations

Every entry here is a constraint of the Iris shader pipeline or of real-time
rendering in general, not something waiting to be fixed. Each one states what
the constraint is, what AstraRealism does instead, and what you will actually
see.

---

## 1. The release is a `.zip`, never a `.jar`

**Constraint.** Iris scans `.minecraft/shaderpacks/` for directories and `.zip`
archives only. `.jar` is the *mod* format and belongs in `.minecraft/mods/`.

A `.jar` is technically a ZIP container, so it is tempting to assume renaming
works. It does not — Iris filters on the file extension, and a renamed pack
simply never appears in the shader selection screen.

**What we do.** Releases ship exactly one artifact:
`AstraRealism-vX.Y.Z.zip`.

---

## 2. One shadow map, not cascaded shadow maps

**Constraint.** The Iris/OptiFine shadow pipeline provides a single shadow map
(`shadowtex0` / `shadowtex1`) rendered from one orthographic projection. There
is no mechanism to render several frustum slices at different resolutions, which
is what "cascaded shadow maps" means in an engine that supports them.

**What we do instead.** Three things together recover most of what cascades
provide:

1. **Projection distortion.** `shadowDistortFactor()` in
   `shaders/lib/common/spaces.glsl` warps the shadow projection by
   `1 / (|xy| * k + (1 - k))`, concentrating texels near the camera. At the
   default 2048 map this yields an effective near-field resolution comparable to
   a much larger uniform map.
2. **PCSS.** Penumbra width is derived from the distance between occluder and
   receiver, so contact points stay sharp while distant shadows soften — the
   same visual cue cascades are usually deployed to protect.
3. **Contact shadows.** A short screen-space ray march recovers detail below the
   shadow map's texel size, such as the gap under a slab.

**What you will see.** Shadows remain crisp near the camera. Very far from it,
at high Shadow Distance with a low Shadow Resolution, edges soften more than a
cascaded renderer would allow. Raising Shadow Resolution is the direct fix.

---

## 3. Global illumination only sees the screen

**Constraint.** AstraRealism uses screen-space GI. A ray that leaves the visible
frame has no data to sample, because off-screen geometry was never rasterised.

A voxel-based approach would solve this, at the cost of a compute-shader
voxelisation pass, an SSBO radiance cache and significant VRAM — and it would
fail outright on hardware lacking those features. That trade was evaluated and
declined for this pack.

**What we do instead.** GI is layered on top of a sky and block-light irradiance
base rather than replacing it, so indirect light never drops to zero. Rays that
escape the frame fall back to that base instead of contributing darkness.

**What you will see.** A torch lights the walls and floor around it correctly.
A bright surface just off the edge of the screen contributes less than it should,
and the contribution changes as you turn. Temporal accumulation smooths the
transition, so it reads as a gentle shift rather than a pop.

---

## 4. Reflections only see the screen

**Constraint.** Same root cause as GI. A reflected ray that leaves the frame has
nothing to hit.

**What we do instead.** Escaped rays fall back to the atmosphere and cloud model,
which is the correct answer for anything reflecting the sky — water, wet ground,
glass — and a plausible one otherwise. Rays are faded out near the screen edge so
reflections dissolve rather than terminating in a hard line.

**What you will see.** Objects visible on screen reflect correctly. Something
behind the camera does not appear in a reflection in front of you. Looking down
at water at a steep angle is the most noticeable case, because the reflected rays
travel upward out of the frame almost immediately.

---

## 5. No hardware ray tracing

**Constraint.** Iris exposes no ray-tracing API. Minecraft Java has no BVH over
world geometry to trace against.

**What we do instead.** Every "ray traced" effect here is a screen-space ray
march — shadows, reflections, GI, volumetrics. They share the limitations above.

---

## 6. Parallax requires a height map

**Constraint.** Parallax occlusion mapping ray marches a height field. Vanilla
textures do not contain one, and there is no reliable way to synthesise it:
inferring height from albedo makes dark texels into holes, which is wrong far
more often than it is right.

**What we do instead.** `ASTRA_ENABLE_POM` in
`shaders/lib/compat/fallback.glsl` resolves to 0 whenever
`MC_TEXTURE_FORMAT_LAB_PBR` is absent, regardless of the user's setting. The
option stays visible but has no effect.

**What you will see.** With a LabPBR pack, surfaces have real depth. Without one,
they are flat — but correctly lit and correctly rough.

---

## 7. Ambient occlusion can double up in corners

**Constraint.** Minecraft bakes its own vertex ambient occlusion into vertex
colour. Separating it out requires the `separateAo` directive, whose exact
semantics vary between loader versions in ways that are difficult to verify
without in-game testing on each one.

**What we do instead.** Vanilla AO is left in the albedo, and our GTAO is applied
only to indirect and ambient light, never to direct light. The two therefore
overlap only in the indirect term.

**What you will see.** Tight interior corners may be slightly darker than
strictly correct. Lowering **GI & AO → AO Strength** compensates. This is
flagged for revision once in-game testing can confirm `separateAo` behaviour on
both target versions.

---

## 8. `separateEntityDraws` is not used

**Constraint.** The `separateEntityDraws` directive, which defers translucent
entity and block-entity rendering until after the deferred pass, is documented
by Iris as broken in recent versions.

**What we do instead.** Translucent entities are forward-shaded through
`shaders/lib/lighting/forward.glsl`, using the same lighting model as everything
else.

**What you will see.** Translucent entities are lit consistently with the world,
but do not receive screen-space reflections.

---

## 9. `MAX_COLOR_BUFFERS` is unavailable on Minecraft 1.21.11

**Constraint.** The `MAX_COLOR_BUFFERS` macro was added in Iris 1.10.5.
Minecraft 1.21.11 tops out at Iris 1.10.4, so the macro is absent there.

**What we do instead.** `shaders/lib/compat/version.glsl` defines
`ASTRA_COLOR_BUFFERS` to 16 when the macro is missing, which Iris has guaranteed
since 1.6, and raises a compile-time `#error` if a future version reports fewer.

**What you will see.** Nothing. This is noted because the compile harness
deliberately omits the macro for the 1.21.11 target so the fallback is exercised
on every CI run.

---

## 10. Buffer format directives must live in a block comment

**Constraint.** Format names such as `RGBA16F` are Iris directive vocabulary,
not GLSL identifiers. Written as real code they produce
`undeclared identifier: RGBA16F` and the pack fails to load.

**What we do instead.** They sit inside a `/* */` block comment in
`shaders/lib/common/buffers.glsl`, one declaration per line, where Iris reads
them and the GLSL compiler does not. `tools/validate_shader.py` fails the build
if one escapes the comment.

**What you will see.** Nothing — this is recorded because it is an easy mistake
to reintroduce when editing the buffer layout.

---

## 11. Automatic exposure is not implemented yet

**Status.** Phase 4. Until then, **Exposure Mode** defaults to Manual, and
selecting Automatic behaves as Manual rather than doing nothing visible.

**Why it matters more than it sounds.** Scene radiance in this pack is in
physical-ish units — `SUN_INTENSITY` is a radiance value, not a screen
brightness. A single fixed exposure therefore cannot suit both a sunlit field
and a moonlit one, because the real ratio between them is enormous.

**What we do instead.** `MANUAL_EXPOSURE` defaults to 0.25, calibrated so a
mid-grey surface (albedo 0.18) in full daylight lands on a well-exposed midtone.
`MOON_INTENSITY` is compressed to roughly a 15:1 ratio against the sun rather
than the physical 400,000:1, which is also close to how dark-adapted vision
actually perceives a full moon.

**What you will see.** Daylight is correctly exposed. Nights are dark — playable,
but darker than they will be once the eye-adaptation pass exists. Raising
**Post Processing → Exposure → Manual Exposure** is the immediate workaround, at
the cost of overexposing daytime.

---

## 12. Parallax does not correct depth

**Constraint.** Correct parallax writes an adjusted `gl_FragDepth` so displaced
geometry occludes properly at silhouettes. Writing that value disables early
depth rejection for the entire gbuffers pass, which is the most overdrawn pass
in the frame.

**What we do instead.** Only the texture coordinate is displaced. Interior depth,
self-shadowing and the way the surface shifts with the camera are all correct.

**What you will see.** Looking at a wall edge-on, the displaced stones do not
break the straight silhouette of the block. At any other angle the effect is
complete.

---

## 13. Wave displacement applies only to upward-facing water

**Constraint.** Water blocks at a chunk boundary are transformed by different
draw calls. Displacing their side faces independently opens visible gaps,
because nothing keeps the two sides in agreement.

**What we do instead.** `waveDisplacement()` returns zero unless the geometric
normal points up. Side faces stay put; the top surface still receives full wave
normals and displacement.

**What you will see.** The water surface undulates correctly. The vertical faces
at the edge of a water body stay flat, which is only noticeable looking directly
at a one-block waterfall.

---

## 14. Rough reflections are cone-traced, not prefiltered

**Constraint.** A correct rough reflection integrates the whole GGX lobe against
the environment, normally via a prefiltered mip pyramid. Screen-space data has
no such pyramid — the "environment" is a single frame with no mip chain that
respects the surface.

**What we do instead.** `SSR_ROUGH_SAMPLES` rays are importance-sampled from the
same GGX distribution the direct lighting uses, then accumulated across frames
in `colortex8`.

**What you will see.** Rough metal and wet stone reflect correctly but show some
noise until the temporal accumulation converges, which takes a few frames after
the camera stops. This improves substantially once TAA lands in Phase 4.

---

## 15. Ambient occlusion filters itself until TAA exists

**Constraint.** GTAO traces a handful of slices per pixel, which is far too few
to resolve occlusion without noise. The normal solution is temporal
accumulation, which arrives with TAA in Phase 4.

**What we do instead.** The lighting pass applies a nine-tap bilateral filter
when it reads the AO channel, weighted by depth and normal so occlusion does not
bleed across silhouettes. Folding it into an existing read avoids a dedicated
full-screen pass.

**What you will see.** At `AO_SAMPLES` of 4 or 6, some residual grain in creases.
Raising the sample count or waiting for Phase 4 both resolve it.

---

## 16. Caustics are a convergence estimate, not photon transport

**Constraint.** Physically correct caustics require tracing photons through the
refracting surface and accumulating where they land. That is far outside a
real-time budget.

**What we do instead.** `causticConvergence()` measures how much the wave surface
focuses neighbouring rays at a point, which is the quantity that produces the
pattern. The result is centred on 1.0 rather than added, so focused regions
brighten and the rest dims slightly — caustics redistribute light rather than
creating it.

**What you will see.** A convincing moving web of light. It will not match a
path-traced reference, and its cost scales with `WATER_CAUSTICS_SAMPLES` times
the wave octave count, making it one of the more expensive settings per affected
pixel.

---

## 17. Global illumination lags one frame behind

**Constraint.** Screen-space GI needs lit surfaces to gather bounced light from.
The GI pass must run *before* the lighting pass, because lighting consumes its
output. The current frame's lit colour therefore does not exist when GI needs it.

**What we do instead.** `colortex9` is not cleared, so at the start of a frame it
still holds the previous frame's lit opaque scene. That is the radiance source.
Every real-time screen-space GI implementation does this.

**What you will see.** Nothing, in almost all cases. A light that changes
abruptly — TNT, lightning, a lever on a lamp — has its *indirect* contribution
appear one frame after its direct one. At 60 fps that is 16 ms.

---

## 18. Expensive systems refresh one pixel per tile per frame

**Constraint.** GI, volumetrics and clouds are all far too expensive to evaluate
for every pixel every frame.

**What we do instead.** Each divides the screen into NxN tiles and retraces one
pixel per tile per frame, cycling through all N² positions while the rest reuse
reprojected history. `GI_RESOLUTION_DIVISOR`, `VL_RESOLUTION_DIVISOR` and
`CLOUD_RESOLUTION_DIVISOR` set N.

Iris's own `scale.<program>` directive would render a pass at reduced resolution
instead, but it takes a fixed value in `shaders.properties` and cannot follow a
user setting, and it renders into a sub-rectangle every later pass must then
account for.

**What you will see.** A surface that has just come into view takes up to N²
frames to converge — visible as a brief softness trailing a fast camera turn at
divisor 3 or 4. Pixels with no valid history trace immediately regardless of
whose turn it is, so nothing ever stays unlit.

---

## 19. The GI denoiser runs a fixed two passes

**Constraint.** À-trous filtering needs one render pass per iteration, and the
program list is fixed when the shader compiles. A runtime option cannot add or
remove passes.

**What we do instead.** Two passes always run, at strides 1 and 2.
`GI_DENOISER_PASSES` scales those strides rather than changing the count, which
buys the wider footprint more iterations would have given without the extra
passes.

**What you will see.** Higher values smooth more but erase fine detail in the
bounce light. The practical range is genuinely 1–3.

---

## 20. Cloud shadows sample density, not a shadow map

**Constraint.** A correct cloud shadow renders the cloud layer a second time from
the sun's point of view. That doubles the cost of the most expensive system in
the pack.

**What we do instead.** `cloudShadow()` samples the density field once, where the
sun ray from the shaded point crosses the middle of the cloud layer.

**What you will see.** Soft, correctly-placed cloud shadows that drift with the
clouds. They do not capture a cloud's internal structure, which for a shadow cast
from several hundred blocks up is not resolvable anyway. The shadow is floored
well above black, because even under heavy overcast the ground is lit by diffused
light rather than cut off.

---

## 21. The Nether and the End ignore the sky lightmap for ambient

**Constraint.** Minecraft reports a sky light level of zero everywhere in both
dimensions, because neither has a sky. The overworld correctly gates ambient
light on that value — a block deep in a cave receives no skylight.

Applying the same gate in the Nether or the End would leave both lit by block
light alone and otherwise completely black.

**What we do instead.** `dimensionAmbientLight()` belongs to each dimension and
decides its own gating. The overworld gates on sky light; the Nether and the End
do not, because their ambient comes from lava glow and a violet dome
respectively, neither of which the sky lightmap describes.

**What you will see.** Both dimensions are lit. The Nether's ambient arrives from
*below*, inverting the overworld's basic cue — that is deliberate, and it is
where most of its character comes from.
