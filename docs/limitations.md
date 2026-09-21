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
