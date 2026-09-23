# Changelog

All notable changes to AstraRealism are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Release notes on GitHub are generated automatically from Conventional Commits
by `tools/generate_changelog.py`. This file is the curated, human-facing
summary.

## [Unreleased]

### Added

- Project foundation: option system, validation tooling, CI/CD pipeline.
- Physically based lighting core with a Cook-Torrance GGX BRDF, height-correlated
  Smith visibility and Burley diffuse.
- Shadow mapping with projection distortion, PCF and PCSS filtering, normal-offset
  bias, coloured shadows through translucent casters, and screen-space contact
  shadows.
- Atmospheric scattering with Rayleigh, Mie and ozone terms, plus a multiple-
  scattering approximation. Sun and moon colour are derived from atmospheric
  extinction rather than from colour presets.
- Procedural sky: sun disc with limb darkening, phase-correct moon, and a
  temperature-coloured star field attenuated by the atmosphere.
- Fog as a scattering and extinction pair, inheriting its colour from the sky,
  with height, cave, underwater, lava and powder-snow variants.
- LabPBR 1.3 material decoding with a heuristic fallback driven by
  `block.properties` when no PBR resource pack is present.
- Four tone mapping operators (ACES, AgX, Khronos Neutral, Reinhard) and a
  neutral-by-default colour grading chain.
- Sixteen debug views that bypass tone mapping.
- Six quality presets from Potato to Cinematic.
- Support for Minecraft 26.3 and 1.21.11 from a single pack.

[Unreleased]: https://github.com/OWNER/AstraRealism/commits/main

### Added — Phase 2

- Parallax occlusion mapping with self-shadowing, wrapped to atlas sprite bounds
  so the march cannot walk into a neighbouring texture.
- Ground-truth ambient occlusion (GTAO) with an SSAO fallback, filtered by a
  depth- and normal-weighted bilateral kernel as it is read.
- Screen-space reflections with binary refinement, a thickness test, GGX
  importance-sampled rough reflections and temporal accumulation. Rays that
  leave the screen fall back to the atmosphere model.
- Water: travelling wave octaves with vertex displacement on upward faces,
  Fresnel, refraction, Beer-Lambert absorption, particle scattering carrying the
  biome tint, shoreline foam and caustics.
- Wet surfaces: rain lowers roughness, darkens albedo in proportion to porosity
  and shifts F0 toward water's own. Noise-driven puddles form on exposed level
  surfaces, with animated rain ripples.
- Snow material response: high albedo, soft sheen and strong subsurface
  transport.

### Fixed

- `distance` and `texture` were used as local variable names in four files,
  shadowing GLSL built-in functions. The validator now rejects any local named
  after a built-in.

### Added — Phase 3

- Screen-space global illumination with cosine-weighted ray gathering, temporal
  accumulation and a two-iteration à-trous denoiser guided by luminance
  variance. Radiance is gathered from the previous frame's lit scene, held in an
  uncleared buffer that already existed for translucent refraction.
- Volumetric light and fog as a single shadow-map ray march, with
  Henyey-Greenstein anisotropy and a separate model for looking through water.
  Replaces the analytic in-scattering where it runs; the analytic version
  remains for the lower presets and beyond the shadow distance.
- Volumetric clouds: Perlin-Worley density in a spherical shell, a weather field
  driving coverage, dual-lobe scattering for the silver lining, Beer-powder
  energy for bright cores, and self-shadowing via a light march.
- Cloud shadows, sampled from the density field rather than a second render.
- Dedicated Nether rendering: ambient light arriving from below where the lava
  is, dense uniform haze that absorbs blue, and biome tint carried through.
- Dedicated End rendering: violet dome, void below, unattenuated stars and
  almost no fog, so distance reads as emptiness.
- Temporal interleaving shared by GI, volumetrics and clouds: one pixel per NxN
  tile is retraced each frame, the rest reuse reprojected history.

### Changed

- `GI_DENOISER_PASSES` now scales the denoiser's tap stride rather than the pass
  count, which is fixed at two because à-trous needs one render pass per
  iteration. Its range narrowed from 1–5 to 1–3.
- The three resolution divisor options now control temporal interleaving rather
  than render resolution. Tooltips updated to describe what they actually do.

### Fixed

- `step` was used as a local variable name in the cloud light march, shadowing a
  GLSL built-in.
