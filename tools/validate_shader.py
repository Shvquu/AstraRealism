#!/usr/bin/env python3
"""Static validation for the AstraRealism shader pack.

Checks the things that break a shader pack at load time but are invisible while
editing: a renamed option that shaders.properties still references, an include
that does not resolve, a profile that sets a value outside an option's list, a
RENDERTARGETS directive naming a buffer that does not exist.

None of this needs a GPU. Real GLSL compilation is a separate step -
see glsl_compile.py.

Usage:
    python tools/validate_shader.py
    python tools/validate_shader.py --strict   # treat warnings as failures
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from program_manifest import DIMENSIONS, PROGRAMS  # noqa: E402
from shader_parser import (  # noqa: E402
    find_includes,
    parse_block_ids,
    parse_lang,
    parse_options,
    parse_properties,
    resolve_include,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "shaders"

MAX_COLORTEX = 15


class Report:
    """Collects problems and prints them grouped by severity."""

    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def print_summary(self, strict: bool) -> int:
        for message in self.errors:
            print(f"  ERROR   {message}")
        for message in self.warnings:
            print(f"  WARN    {message}")

        failed = bool(self.errors) or (strict and bool(self.warnings))

        print()
        if failed:
            print(
                f"FAILED: {len(self.errors)} error(s), {len(self.warnings)} warning(s)"
            )
        else:
            print(f"OK: 0 errors, {len(self.warnings)} warning(s)")

        return 1 if failed else 0


# ------------------------------------------------------------------------------
# Structure
# ------------------------------------------------------------------------------


def check_structure(report: Report) -> None:
    """Every file Iris needs must be present and in the right place."""
    required = [
        SHADERS_DIR / "shaders.properties",
        SHADERS_DIR / "dimension.properties",
        SHADERS_DIR / "block.properties",
        SHADERS_DIR / "lang" / "en_us.lang",
        SHADERS_DIR / "lib" / "common" / "settings.glsl",
    ]

    for path in required:
        if not path.is_file():
            report.error(f"missing required file: {path.relative_to(REPO_ROOT).as_posix()}")

    # A shaders.properties in the repo root is the single most common mistake
    # when porting a pack: Iris never looks there.
    stray = REPO_ROOT / "shaders.properties"
    if stray.is_file():
        report.error(
            "shaders.properties found in the repo root; Iris only reads "
            "shaders/shaders.properties"
        )

    stray_singular = REPO_ROOT / "shader.properties"
    if stray_singular.is_file():
        report.error("shader.properties is not a real file name; use shaders/shaders.properties")


# ------------------------------------------------------------------------------
# Includes
# ------------------------------------------------------------------------------


def check_includes(report: Report) -> set[Path]:
    """Walk the include graph from every program, reporting breaks and cycles.

    Returns the set of files actually reached, so unreferenced ones can be
    flagged separately.
    """
    reached: set[Path] = set()

    def walk(path: Path, stack: list[Path]) -> None:
        resolved = path.resolve()

        if resolved in stack:
            chain = " -> ".join(p.name for p in stack[stack.index(resolved):])
            report.error(f"circular include: {chain} -> {path.name}")
            return

        if resolved in reached:
            return
        reached.add(resolved)

        if not path.is_file():
            return

        text = path.read_text(encoding="utf-8")
        for lineno, include in find_includes(text):
            target = resolve_include(include, SHADERS_DIR, path)

            if not target.is_file():
                rel = path.relative_to(REPO_ROOT).as_posix()
                report.error(f"{rel}:{lineno}: unresolved include \"{include}\"")
                continue

            walk(target, stack + [resolved])

    for dimension in DIMENSIONS:
        base = SHADERS_DIR / dimension.folder if dimension.folder else SHADERS_DIR
        for program in PROGRAMS:
            for stage in program.stages:
                entry = base / f"{program.name}.{stage}"
                if entry.is_file():
                    walk(entry, [])
                else:
                    rel = entry.relative_to(REPO_ROOT).as_posix()
                    report.error(f"missing program file: {rel}")

    return reached


def check_unreferenced_libs(report: Report, reached: set[Path]) -> None:
    """Library files nothing includes are usually a rename that was half-done."""
    for path in sorted((SHADERS_DIR / "lib").rglob("*.glsl")):
        if path.resolve() not in reached:
            rel = path.relative_to(REPO_ROOT).as_posix()
            report.warn(f"library file is never included: {rel}")

    for path in sorted((SHADERS_DIR / "program").rglob("*.glsl")):
        if path.resolve() not in reached:
            rel = path.relative_to(REPO_ROOT).as_posix()
            report.warn(f"program body is never included: {rel}")


# ------------------------------------------------------------------------------
# Include guards
# ------------------------------------------------------------------------------


def check_include_guards(report: Report) -> None:
    """Every shared file must be safe to include more than once.

    Iris does not deduplicate includes, so a file without a guard that is pulled
    in twice produces duplicate definitions - an error that only appears in
    whichever program happens to include it along two paths.
    """
    for path in sorted((SHADERS_DIR / "lib").rglob("*.glsl")):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(REPO_ROOT).as_posix()

        if "#ifndef" not in text or "#define" not in text:
            report.error(f"{rel}: missing include guard")
            continue

        guard_match = re.search(r"#ifndef\s+([A-Za-z_][A-Za-z0-9_]*)", text)
        define_match = re.search(r"#define\s+([A-Za-z_][A-Za-z0-9_]*)", text)

        if not guard_match or not define_match:
            report.error(f"{rel}: malformed include guard")
        elif guard_match.group(1) != define_match.group(1):
            report.error(
                f"{rel}: include guard mismatch "
                f"({guard_match.group(1)} vs {define_match.group(1)})"
            )


# ------------------------------------------------------------------------------
# Render targets
# ------------------------------------------------------------------------------

_RENDERTARGETS_RE = re.compile(r"/\*\s*RENDERTARGETS\s*:\s*([0-9,\s]+)\*/")
_DRAWBUFFERS_RE = re.compile(r"/\*\s*DRAWBUFFERS\s*:\s*([0-9]+)\s*\*/")
_LAYOUT_RE = re.compile(r"layout\s*\(\s*location\s*=\s*(\d+)\s*\)\s*out\s")


def _final_program_bodies() -> set[str]:
    """Bodies belonging to the `final` program.

    Unlike every other pass, final writes to the default framebuffer rather
    than to a colortex, so it must not declare RENDERTARGETS.
    """
    bodies = set()
    for program in PROGRAMS:
        if program.name != "final":
            continue
        for stage in program.stages:
            body = program.body_for(stage)
            bodies.add(body if body.endswith(".glsl") else f"{body}.{stage}.glsl")
    return bodies


def check_render_targets(report: Report) -> None:
    """RENDERTARGETS must name real buffers and match the declared outputs."""
    final_bodies = _final_program_bodies()

    for path in sorted((SHADERS_DIR / "program").glob("*.fsh.glsl")):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(REPO_ROOT).as_posix()

        if path.name in final_bodies:
            if _RENDERTARGETS_RE.search(text):
                report.error(
                    f"{rel}: the final program writes to the screen and must not "
                    "declare RENDERTARGETS"
                )
            continue

        if _DRAWBUFFERS_RE.search(text):
            report.warn(
                f"{rel}: uses the legacy DRAWBUFFERS directive; "
                "RENDERTARGETS supports more than 8 buffers and is preferred"
            )

        declared_locations = sorted(
            {int(m) for m in _LAYOUT_RE.findall(text)}
        )

        matches = _RENDERTARGETS_RE.findall(text)
        if not matches:
            if declared_locations:
                report.error(
                    f"{rel}: declares fragment outputs but has no "
                    "RENDERTARGETS directive"
                )
            continue

        for raw in matches:
            targets = [t.strip() for t in raw.split(",") if t.strip()]

            for target in targets:
                index = int(target)
                if index > MAX_COLORTEX:
                    report.error(
                        f"{rel}: RENDERTARGETS references colortex{index}, "
                        f"but only 0-{MAX_COLORTEX} exist"
                    )

            if len(set(targets)) != len(targets):
                report.error(f"{rel}: RENDERTARGETS lists a buffer twice: {raw.strip()}")

        # A file can contain several RENDERTARGETS behind #if branches, so the
        # output count only has to match one of them.
        if declared_locations:
            expected_counts = {len(m.split(",")) for m in matches}
            if len(declared_locations) not in expected_counts:
                report.error(
                    f"{rel}: declares {len(declared_locations)} fragment output(s) "
                    f"but RENDERTARGETS lists {sorted(expected_counts)}"
                )
            if declared_locations != list(range(len(declared_locations))):
                report.error(
                    f"{rel}: fragment output locations must be contiguous from 0, "
                    f"got {declared_locations}"
                )


# ------------------------------------------------------------------------------
# Buffer configuration
# ------------------------------------------------------------------------------

_FORMAT_RE = re.compile(r"const\s+int\s+colortex(\d+)Format\s*=\s*(\w+)\s*;")
_CLEAR_RE = re.compile(r"const\s+bool\s+colortex(\d+)Clear\s*=\s*(\w+)\s*;")

VALID_FORMATS = {
    "R8", "RG8", "RGB8", "RGBA8",
    "R16", "RG16", "RGB16", "RGBA16",
    "R16F", "RG16F", "RGB16F", "RGBA16F",
    "R32F", "RG32F", "RGB32F", "RGBA32F",
    "R8I", "RG8I", "RGBA8I", "R16I", "RG16I", "RGBA16I",
    "R32I", "RG32I", "RGBA32I",
    "R8UI", "RG8UI", "RGBA8UI", "R16UI", "RG16UI", "RGBA16UI",
    "R32UI", "RG32UI", "RGBA32UI",
    "R11F_G11F_B10F", "RGB10_A2", "RGB5_A1", "RGBA4", "R3_G3_B2",
    "RGB9_E5", "SRGB8", "SRGB8_ALPHA8",
    "R8_SNORM", "RG8_SNORM", "RGBA8_SNORM",
    "R16_SNORM", "RG16_SNORM", "RGBA16_SNORM",
}


def _block_comment_spans(text: str) -> list[tuple[int, int]]:
    """Character ranges covered by /* */ block comments."""
    return [(m.start(), m.end()) for m in re.finditer(r"/\*.*?\*/", text, re.DOTALL)]


def _inside_block_comment(position: int, spans: list[tuple[int, int]]) -> bool:
    return any(start <= position < end for start, end in spans)


def check_buffer_config(report: Report) -> None:
    path = SHADERS_DIR / "lib" / "common" / "buffers.glsl"
    if not path.is_file():
        report.error("missing shaders/lib/common/buffers.glsl")
        return

    text = path.read_text(encoding="utf-8")
    spans = _block_comment_spans(text)

    for match in _FORMAT_RE.finditer(text):
        index, fmt = match.group(1), match.group(2)

        if int(index) > MAX_COLORTEX:
            report.error(f"buffers.glsl: colortex{index} does not exist")

        if fmt not in VALID_FORMATS:
            report.error(f"buffers.glsl: colortex{index}Format has unknown format {fmt}")

        # Format names are not GLSL identifiers. Left as real code they produce
        # "undeclared identifier: RGBA16F" and the whole pack fails to load.
        if not _inside_block_comment(match.start(), spans):
            report.error(
                f"buffers.glsl: colortex{index}Format must be inside a /* */ block "
                f"comment - '{fmt}' is an Iris directive, not a GLSL identifier"
            )

    declared_formats = {int(m.group(1)) for m in _FORMAT_RE.finditer(text)}

    for match in _CLEAR_RE.finditer(text):
        index, value = match.group(1), match.group(2)

        if int(index) > MAX_COLORTEX:
            report.error(f"buffers.glsl: colortex{index}Clear does not exist")

        if value not in ("true", "false"):
            report.error(f"buffers.glsl: colortex{index}Clear must be true or false")

        if not _inside_block_comment(match.start(), spans):
            report.warn(
                f"buffers.glsl: colortex{index}Clear should sit in the same block "
                f"comment as the format directives"
            )

    # A buffer that persists between frames but has no explicit format falls
    # back to RGBA8, which silently destroys any temporal accumulation stored
    # in it.
    for match in _CLEAR_RE.finditer(text):
        index = int(match.group(1))
        if match.group(2) == "false" and index not in declared_formats:
            report.error(
                f"buffers.glsl: colortex{index} has clear=false but no explicit "
                f"format; it would default to RGBA8 and lose precision"
            )


# ------------------------------------------------------------------------------
# Options / properties / lang consistency
# ------------------------------------------------------------------------------


def collect_options() -> dict:
    options = {}
    for path in sorted((SHADERS_DIR / "lib").rglob("*.glsl")):
        options.update(parse_options(path))
    return options


def check_option_consistency(report: Report) -> None:
    options = collect_options()
    properties = parse_properties(SHADERS_DIR / "shaders.properties")
    lang = parse_lang(SHADERS_DIR / "lang" / "en_us.lang")

    if not options:
        report.error("no options found; settings.glsl may have the wrong syntax")
        return

    # --- screens ----------------------------------------------------------
    referenced: set[str] = set()
    declared_screens = set(properties.screens.keys()) - {"__root__"}
    used_screens: set[str] = set()

    for screen_name, entries in properties.screens.items():
        for entry in entries:
            if entry in ("<empty>", "<profile>", "*"):
                continue
            if entry.startswith("[") and entry.endswith("]"):
                used_screens.add(entry[1:-1])
                continue
            if entry not in options:
                report.error(
                    f"shaders.properties: screen.{screen_name} references "
                    f"unknown option '{entry}'"
                )
            referenced.add(entry)

    for screen in sorted(used_screens - declared_screens):
        report.error(f"shaders.properties: screen [{screen}] is linked but never defined")

    for screen in sorted(declared_screens - used_screens):
        report.warn(f"shaders.properties: screen.{screen} is defined but unreachable")

    for option in sorted(set(options) - referenced):
        report.warn(f"option '{option}' is not reachable from any settings screen")

    # --- sliders ----------------------------------------------------------
    for name in properties.sliders:
        if name not in options:
            report.error(f"shaders.properties: sliders references unknown option '{name}'")
        elif options[name].is_boolean:
            report.error(f"shaders.properties: boolean option '{name}' cannot be a slider")

    # --- profiles ---------------------------------------------------------
    profile_names = set(properties.profiles)

    for profile, entries in properties.profiles.items():
        for entry in entries:
            if entry.startswith("profile."):
                parent = entry[len("profile."):]
                if parent not in profile_names:
                    report.error(
                        f"shaders.properties: profile.{profile} inherits from "
                        f"unknown profile '{parent}'"
                    )
                continue

            if entry.startswith("!"):
                name = entry[1:]
                if name.startswith("program."):
                    continue
                if name not in options:
                    report.error(
                        f"shaders.properties: profile.{profile} disables "
                        f"unknown option '{name}'"
                    )
                elif not options[name].is_boolean:
                    report.error(
                        f"shaders.properties: profile.{profile} uses '!{name}' but "
                        f"'{name}' is not a boolean"
                    )
                continue

            if ":" in entry:
                name, _, value = entry.partition(":")
                if name not in options:
                    report.error(
                        f"shaders.properties: profile.{profile} sets "
                        f"unknown option '{name}'"
                    )
                elif options[name].has_value_list and value not in options[name].values:
                    report.error(
                        f"shaders.properties: profile.{profile} sets {name}:{value}, "
                        f"which is not in its value list {options[name].values}"
                    )
                continue

            # A bare name enables a boolean.
            if entry not in options:
                report.error(
                    f"shaders.properties: profile.{profile} references "
                    f"unknown option '{entry}'"
                )
            elif not options[entry].is_boolean:
                report.error(
                    f"shaders.properties: profile.{profile} lists '{entry}' without a "
                    f"value, but it is not a boolean"
                )

    # --- language ---------------------------------------------------------
    for name, option in sorted(options.items()):
        if f"option.{name}" not in lang:
            report.error(f"en_us.lang: missing 'option.{name}'")

        if f"comment.{name}" not in lang:
            report.warn(f"en_us.lang: missing tooltip 'comment.{name}'")

        # Options shown as cycling buttons need a label per value; sliders
        # display the raw number and do not.
        if option.has_value_list and name not in properties.sliders:
            for value in option.values:
                if f"value.{name}.{value}" not in lang:
                    report.error(f"en_us.lang: missing 'value.{name}.{value}'")

    for screen in sorted(declared_screens):
        if f"screen.{screen}" not in lang:
            report.error(f"en_us.lang: missing 'screen.{screen}'")

    for profile in sorted(profile_names):
        if f"profile.{profile}" not in lang:
            report.warn(f"en_us.lang: missing 'profile.{profile}'")

    # --- orphan language keys --------------------------------------------
    known_prefixes = ("option.", "comment.", "value.", "screen.", "profile.",
                      "prefix.", "suffix.")

    for key in sorted(lang):
        if not key.startswith(known_prefixes):
            report.warn(f"en_us.lang: unrecognised key '{key}'")
            continue

        prefix, _, remainder = key.partition(".")

        if prefix in ("option", "comment", "prefix", "suffix"):
            if remainder not in options:
                report.warn(f"en_us.lang: '{key}' refers to an option that no longer exists")
        elif prefix == "value":
            option_name = remainder.rsplit(".", 1)[0]
            if option_name not in options:
                report.warn(f"en_us.lang: '{key}' refers to an option that no longer exists")
        elif prefix == "screen":
            if remainder not in declared_screens:
                report.warn(f"en_us.lang: '{key}' refers to a screen that is not defined")
        elif prefix == "profile":
            if remainder not in profile_names:
                report.warn(f"en_us.lang: '{key}' refers to a profile that is not defined")


# ------------------------------------------------------------------------------
# block.properties
# ------------------------------------------------------------------------------

_ASTRA_BLOCK_RE = re.compile(
    r"const\s+int\s+ASTRA_BLOCK_(\w+)\s*=\s*(\d+)\s*;"
)


def check_block_ids(report: Report) -> None:
    """The ids in block.properties and material_id.glsl must agree."""
    block_path = SHADERS_DIR / "block.properties"
    material_path = SHADERS_DIR / "lib" / "material" / "material_id.glsl"

    if not block_path.is_file() or not material_path.is_file():
        return

    declared = parse_block_ids(block_path)
    constants = {
        int(value): name
        for name, value in _ASTRA_BLOCK_RE.findall(
            material_path.read_text(encoding="utf-8")
        )
    }

    for block_id in sorted(declared):
        if block_id not in constants:
            report.error(
                f"block.properties defines block.{block_id} but material_id.glsl "
                f"has no ASTRA_BLOCK_* constant with that value"
            )

    for value, name in sorted(constants.items()):
        # Zero is the implicit "unclassified" default and has no entry.
        if value == 0:
            continue
        if value not in declared:
            report.error(
                f"material_id.glsl declares ASTRA_BLOCK_{name} = {value} "
                f"but block.properties has no block.{value}"
            )

    # A block listed under two ids gets whichever Iris parses last, silently.
    seen: dict[str, int] = {}
    for block_id, blocks in declared.items():
        for block in blocks:
            if block in seen:
                report.error(
                    f"block.properties: '{block}' is listed under both "
                    f"block.{seen[block]} and block.{block_id}"
                )
            seen[block] = block_id


# ------------------------------------------------------------------------------
# dimension.properties
# ------------------------------------------------------------------------------


def check_dimensions(report: Report) -> None:
    path = SHADERS_DIR / "dimension.properties"
    if not path.is_file():
        return

    properties = parse_properties(path)

    folders = []
    for key in properties.raw:
        if key.startswith("dimension."):
            folders.append(key[len("dimension."):])

    manifest_folders = {d.folder for d in DIMENSIONS if d.folder}

    for folder in folders:
        if folder not in manifest_folders:
            report.error(
                f"dimension.properties maps to folder '{folder}', which is not in "
                f"tools/program_manifest.py"
            )
        if not (SHADERS_DIR / folder).is_dir():
            report.error(f"dimension.properties maps to missing folder shaders/{folder}")

    for folder in sorted(manifest_folders - set(folders)):
        report.warn(
            f"shaders/{folder} exists but dimension.properties never maps to it"
        )

    # The wildcard has to come last or it swallows the specific entries.
    wildcard_keys = [k for k, v in properties.raw.items() if v.strip() == "*"]
    if wildcard_keys:
        keys = list(properties.raw)
        for key in wildcard_keys:
            if keys.index(key) != len(keys) - 1:
                report.error(
                    f"dimension.properties: '{key} = *' must be the last entry, "
                    f"otherwise it matches dimensions intended for later folders"
                )


# ------------------------------------------------------------------------------
# GLSL hygiene
# ------------------------------------------------------------------------------


def check_glsl_hygiene(report: Report) -> None:
    """Catch patterns that compile on NVIDIA but fail on AMD or Intel."""
    for path in sorted(SHADERS_DIR.rglob("*.glsl")):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(REPO_ROOT).as_posix()

        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue

            # `uniform sampler2D texture;` shadows the built-in texture()
            # function and fails to compile on strict drivers.
            if re.search(r"\buniform\s+sampler2D\s+texture\s*;", line):
                report.error(
                    f"{rel}:{lineno}: 'texture' collides with the built-in "
                    "texture() function; use gtexture"
                )

            # texture2D was removed in GLSL 1.40 core and is deprecated in
            # compatibility profiles.
            if re.search(r"\btexture2D\s*\(", line):
                report.warn(
                    f"{rel}:{lineno}: texture2D() is deprecated; use texture()"
                )


# ------------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict", action="store_true", help="treat warnings as failures"
    )
    args = parser.parse_args()

    report = Report()

    print("Validating AstraRealism...\n")

    check_structure(report)
    reached = check_includes(report)
    check_unreferenced_libs(report, reached)
    check_include_guards(report)
    check_render_targets(report)
    check_buffer_config(report)
    check_option_consistency(report)
    check_block_ids(report)
    check_dimensions(report)
    check_glsl_hygiene(report)

    return report.print_summary(args.strict)


if __name__ == "__main__":
    raise SystemExit(main())
