"""Authoritative list of shader programs and the dimensions they are emitted into.

Iris loads programs ONLY from a dimension folder when that folder exists - there
is no per-file fallback to shaders/. A pack with dimension folders therefore
needs a complete set of program files in each one.

Rather than maintaining four copies of every shader, the real code lives once in
shaders/program/*.glsl and each dimension folder gets a generated three-line
stub that defines the dimension and includes the shared body.

This module is the single source of truth for that mapping. It is imported by
gen_dimension_stubs.py, validate_shader.py and glsl_compile.py.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# GLSL version directive emitted into every stub.
#
# 420 compatibility gives us texture(), explicit binding-free samplers and the
# fixed-function gl_FragData path Iris expects, while staying within what every
# GL 4.2+ driver supports. Compute programs override this to 430.
GLSL_VERSION = "#version 420 compatibility"
GLSL_VERSION_COMPUTE = "#version 430 compatibility"


@dataclass(frozen=True)
class Dimension:
    """A shaders/world*/ folder and the macro that selects its code paths."""

    folder: str
    macro: str
    description: str


# The root folder is emitted as an overworld variant. dimension.properties maps
# every dimension to a world* folder via the world0 wildcard, so root should
# never be reached - but a malformed or ignored dimension.properties would
# otherwise leave the pack with no programs at all.
DIMENSIONS: tuple[Dimension, ...] = (
    Dimension("", "DIM_OVERWORLD", "fallback, used if dimension mapping fails"),
    Dimension("world0", "DIM_OVERWORLD", "overworld and modded dimensions"),
    Dimension("world-1", "DIM_NETHER", "the nether"),
    Dimension("world1", "DIM_END", "the end"),
)


@dataclass(frozen=True)
class Program:
    """One Iris program, and the shared body each of its stages includes."""

    name: str
    stages: tuple[str, ...]
    body: str
    macro: str
    note: str = ""
    # Stages that use a different shared body than `body`. Composite-style
    # programs all share one trivial fullscreen vertex shader.
    stage_bodies: dict[str, str] = field(default_factory=dict)
    # Extra `#define NAME value` lines the stub emits before including the body.
    # Lets one shared body serve several programs that differ only by a
    # parameter - the two a-trous iterations, which differ solely in tap stride.
    extra_defines: tuple[str, ...] = ()

    def body_for(self, stage: str) -> str:
        return self.stage_bodies.get(stage, self.body)


_GBUFFERS_STAGES = ("vsh", "fsh")
_COMPOSITE_STAGES = ("vsh", "fsh")

# Shared vertex shader for every composite-style pass: it emits a fullscreen
# triangle and nothing else.
_FULLSCREEN_VSH = "fullscreen.vsh.glsl"


def _gbuffer(name: str, macro: str, note: str = "") -> Program:
    return Program(
        name=name,
        stages=_GBUFFERS_STAGES,
        body="gbuffers_main",
        macro=macro,
        note=note,
    )


def _composite(name: str, body: str, macro: str, note: str = "",
               extra_defines: tuple[str, ...] = ()) -> Program:
    return Program(
        name=name,
        stages=_COMPOSITE_STAGES,
        body=body,
        macro=macro,
        note=note,
        stage_bodies={"vsh": _FULLSCREEN_VSH},
        extra_defines=extra_defines,
    )


# ------------------------------------------------------------------------------
# Program list
#
# Only programs whose behaviour genuinely differs are listed. Iris falls back to
# the nearest relative for anything absent, so gbuffers_damagedblock inherits
# gbuffers_terrain, gbuffers_spidereyes and gbuffers_armor_glint inherit
# gbuffers_textured, and gbuffers_hand_water inherits gbuffers_hand. Shipping
# those as separate files would only duplicate code.
# ------------------------------------------------------------------------------

PROGRAMS: tuple[Program, ...] = (
    # --- geometry ------------------------------------------------------------
    _gbuffer("gbuffers_basic", "PROGRAM_BASIC",
             "untextured geometry: selection box, hitboxes, leashes"),
    _gbuffer("gbuffers_textured", "PROGRAM_TEXTURED",
             "textured, unlit: particles, spider eyes, glint"),
    _gbuffer("gbuffers_textured_lit", "PROGRAM_TEXTURED_LIT",
             "textured and lightmapped: lit particles, world border"),
    _gbuffer("gbuffers_skybasic", "PROGRAM_SKYBASIC",
             "the vanilla sky dome and horizon quad"),
    _gbuffer("gbuffers_skytextured", "PROGRAM_SKYTEXTURED",
             "sun and moon discs"),
    _gbuffer("gbuffers_terrain", "PROGRAM_TERRAIN",
             "opaque and cutout terrain - the bulk of the frame"),
    _gbuffer("gbuffers_entities", "PROGRAM_ENTITIES",
             "mobs, items, armour stands"),
    _gbuffer("gbuffers_block", "PROGRAM_BLOCK",
             "block entities: chests, signs, beds"),
    _gbuffer("gbuffers_beaconbeam", "PROGRAM_BEACONBEAM",
             "beacon beams, which are emissive and unlit"),
    _gbuffer("gbuffers_hand", "PROGRAM_HAND",
             "held items, rendered with a compressed depth range"),
    _gbuffer("gbuffers_water", "PROGRAM_WATER",
             "translucent geometry: water, stained glass, ice"),
    # Shipped explicitly rather than inheriting gbuffers_hand, because it is
    # one of the three programs Iris draws AFTER the deferred pass. Inheriting
    # would give it the gbuffer path, which by then has already been consumed,
    # and a translucent held item would render as nothing at all.
    _gbuffer("gbuffers_hand_water", "PROGRAM_HAND_WATER",
             "translucent held items, drawn after the deferred pass"),
    _gbuffer("gbuffers_weather", "PROGRAM_WEATHER",
             "rain and snow particles"),

    # --- shadow --------------------------------------------------------------
    Program(
        name="shadow",
        stages=_GBUFFERS_STAGES,
        body="shadow",
        macro="PROGRAM_SHADOW",
        note="renders the scene from the light's point of view",
    ),

    # --- deferred ------------------------------------------------------------
    #
    # Order is fixed and load-bearing:
    #   deferred    ambient occlusion, written into the gbuffer
    #   deferred1   global illumination, gathering from the PREVIOUS frame's
    #               lit scene - it has to run before lighting, which consumes it
    #   deferred2/3 two a-trous filter iterations over the GI result
    #   deferred4   lighting, which consumes both occlusion and GI
    #   deferred5   clouds, needing the sky to composite over and running before
    #               reflections so the scene copy contains them
    #   deferred6   reflections, plus the copy of the lit scene that translucent
    #               geometry reads
    _composite("deferred", "deferred_ao", "PROGRAM_DEFERRED_AO",
               "screen-space ambient occlusion, folded into the gbuffer"),
    _composite("deferred1", "deferred_gi", "PROGRAM_DEFERRED_GI",
               "global illumination trace and temporal accumulation"),
    # Two a-trous iterations. A-trous needs one render pass per iteration and
    # the program list is fixed at compile time, so the count cannot follow
    # GI_DENOISER_PASSES - that option scales the tap stride instead.
    _composite("deferred2", "deferred_gi_filter", "PROGRAM_DEFERRED_GI_FILTER",
               "global illumination spatial filter, narrow taps",
               extra_defines=("ASTRA_GI_FILTER_STRIDE 1",)),
    _composite("deferred3", "deferred_gi_filter", "PROGRAM_DEFERRED_GI_FILTER",
               "global illumination spatial filter, wide taps",
               extra_defines=("ASTRA_GI_FILTER_STRIDE 2",)),
    _composite("deferred4", "deferred_lighting", "PROGRAM_DEFERRED_LIGHTING",
               "opaque deferred lighting composition"),
    _composite("deferred5", "deferred_clouds", "PROGRAM_DEFERRED_CLOUDS",
               "volumetric clouds, composited into the sky"),
    _composite("deferred6", "deferred_reflections", "PROGRAM_DEFERRED_REFLECTIONS",
               "screen-space reflections and the scene copy for translucents"),

    # --- composite -----------------------------------------------------------
    _composite("composite", "composite_volumetric", "PROGRAM_COMPOSITE_VOLUMETRIC",
               "volumetric light and fog march"),
    _composite("composite1", "composite_scene", "PROGRAM_COMPOSITE_SCENE",
               "translucent resolve and scene-space effects"),

    # --- final ---------------------------------------------------------------
    _composite("final", "final_output", "PROGRAM_FINAL",
               "tone mapping, grading, lens effects and debug views"),
)


def program_by_name(name: str) -> Program | None:
    for program in PROGRAMS:
        if program.name == name:
            return program
    return None


def expected_stub_paths() -> list[str]:
    """Every shader file the generator is responsible for, as posix paths
    relative to the shaders/ directory."""
    paths: list[str] = []
    for dimension in DIMENSIONS:
        for program in PROGRAMS:
            for stage in program.stages:
                filename = f"{program.name}.{stage}"
                if dimension.folder:
                    paths.append(f"{dimension.folder}/{filename}")
                else:
                    paths.append(filename)
    return paths


def shared_body_paths() -> list[str]:
    """Every shared program body the stubs include, relative to shaders/."""
    bodies: set[str] = set()
    for program in PROGRAMS:
        for stage in program.stages:
            body = program.body_for(stage)
            if body.endswith(".glsl"):
                bodies.add(f"program/{body}")
            else:
                bodies.add(f"program/{body}.{stage}.glsl")
    return sorted(bodies)
