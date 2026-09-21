#!/usr/bin/env python3
"""Compile every shader program with glslangValidator.

Iris shaders are not standalone GLSL: includes use a virtual root, and the
loader injects macros describing the Minecraft version and available features.
This script reproduces that environment so a real compiler can be pointed at
the result, which catches type errors, undeclared identifiers and bad control
flow that no amount of text inspection will.

Each program is compiled once per preset, because the presets select different
branches - a bug behind `#if ASTRA_ENABLE_GI` is invisible until GI is on.

glslangValidator is expected on PATH. On CI it comes from the glslang-tools
package; locally, if it is missing, the script says so and exits without
failing the build so that validate_shader.py remains usable on its own.

Usage:
    python tools/glsl_compile.py
    python tools/glsl_compile.py --all-presets
    python tools/glsl_compile.py --preset HIGH --program gbuffers_terrain
    python tools/glsl_compile.py --required        # fail if glslang is absent
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from program_manifest import DIMENSIONS, PROGRAMS  # noqa: E402
from shader_parser import (  # noqa: E402
    find_includes,
    parse_options,
    parse_properties,
    resolve_include,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "shaders"

# Iris/OptiFine directives that are comments to the compiler but would otherwise
# be left in the source we hand to glslang. They are already validated by
# validate_shader.py.
_DIRECTIVE_RE = re.compile(r"/\*\s*(RENDERTARGETS|DRAWBUFFERS)\s*:[^*]*\*/")


@dataclass(frozen=True)
class Target:
    """One Minecraft/Iris combination the pack supports."""

    name: str
    mc_version: int
    iris_version: int
    description: str


TARGETS: tuple[Target, ...] = (
    Target("1.21.11", 12111, 11004, "Minecraft 1.21.11 with Iris 1.10.4"),
    Target("26.3", 260300, 11106, "Minecraft 26.3 with Iris 1.11.6"),
)


def iris_macros(target: Target, labpbr: bool) -> list[str]:
    """The macros Iris defines before compiling a shader.

    MAX_COLOR_BUFFERS is deliberately omitted for the 1.21.11 target: it was
    added in Iris 1.10.5, and 1.21.11 tops out at 1.10.4. Leaving it out here
    is what exercises the fallback in lib/compat/version.glsl.
    """
    macros = [
        f"MC_VERSION {target.mc_version}",
        "IS_IRIS 1",
        f"IRIS_VERSION {target.iris_version}",
        "MC_GL_VERSION 460",
        "MC_GLSL_VERSION 460",
        "MC_RENDER_QUALITY 1.0",
        "MC_SHADOW_QUALITY 1.0",
        "MC_NORMAL_MAP 1",
        "MC_SPECULAR_MAP 1",
        "MC_HAND_DEPTH 0.125",
        "MC_GL_VENDOR_NVIDIA 1",
        # Feature flags requested as optional in shaders.properties.
        "IRIS_FEATURE_COMPUTE_SHADERS 1",
        "IRIS_FEATURE_SSBO 1",
        "IRIS_FEATURE_CUSTOM_IMAGES 1",
        "IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS 1",
        "IRIS_FEATURE_PER_BUFFER_BLENDING 1",
        "IRIS_FEATURE_ENTITY_TRANSLUCENT 1",
    ]

    if target.iris_version >= 11005:
        macros.append("MAX_COLOR_BUFFERS 16")

    if labpbr:
        macros.append("MC_TEXTURE_FORMAT_LAB_PBR 1")

    return macros


# ------------------------------------------------------------------------------
# Preprocessing
# ------------------------------------------------------------------------------


class SourceMap:
    """Maps lines of the flattened source back to the file they came from.

    Without this, a glslang error reads "line 4127" in a file that does not
    exist on disk, which makes the compiler output nearly useless.
    """

    def __init__(self) -> None:
        self.entries: list[tuple[int, str, int]] = []

    def add(self, flat_line: int, source: str, original_line: int) -> None:
        self.entries.append((flat_line, source, original_line))

    def lookup(self, flat_line: int) -> str:
        best = ("<unknown>", 0)
        for line, source, original in self.entries:
            if line <= flat_line:
                best = (source, original + (flat_line - line))
            else:
                break
        return f"{best[0]}:{best[1]}"


def flatten_includes(entry: Path, source_map: SourceMap) -> str:
    """Recursively inline every #include, the way Iris does before compiling.

    Include guards are respected by emitting each file's text as-is - the
    guards themselves survive into the output and do their job there, which
    keeps the flattened source faithful to what the driver actually sees.
    """
    output: list[str] = []

    def emit(path: Path, stack: tuple[Path, ...]) -> None:
        resolved = path.resolve()
        if resolved in stack:
            raise RuntimeError(f"circular include: {path}")

        text = path.read_text(encoding="utf-8")
        includes = dict(find_includes(text))

        rel = path.relative_to(SHADERS_DIR).as_posix()

        for lineno, line in enumerate(text.splitlines(), start=1):
            if lineno in includes:
                target = resolve_include(includes[lineno], SHADERS_DIR, path)
                if not target.is_file():
                    raise RuntimeError(
                        f"{rel}:{lineno}: unresolved include \"{includes[lineno]}\""
                    )
                emit(target, stack + (resolved,))
                source_map.add(len(output) + 1, rel, lineno + 1)
                continue

            source_map.add(len(output) + 1, rel, lineno)
            output.append(line)

    emit(entry, ())
    return "\n".join(output)


def build_translation_unit(entry: Path, target: Target, defines: list[str],
                           source_map: SourceMap) -> str:
    """Produce a self-contained GLSL translation unit for glslang."""
    flat = flatten_includes(entry, source_map)

    # The version directive must come first, so lift it out and re-emit it
    # ahead of the injected macros.
    version_line = "#version 420 compatibility"
    lines = flat.splitlines()
    kept: list[str] = []

    for line in lines:
        if line.strip().startswith("#version"):
            version_line = line.strip()
            kept.append("")  # preserve line numbering
            continue
        kept.append(line)

    macro_block = [f"#define {macro}" for macro in iris_macros(target, labpbr=True)]
    macro_block += [f"#define {d}" for d in defines]

    body = "\n".join(kept)
    body = _DIRECTIVE_RE.sub("", body)

    return "\n".join([version_line] + macro_block + [body])


# ------------------------------------------------------------------------------
# Presets
# ------------------------------------------------------------------------------


def resolve_profile(name: str) -> list[str]:
    """Flatten a profile into concrete `NAME value` / `NAME` define overrides."""
    properties = parse_properties(SHADERS_DIR / "shaders.properties")

    options = {}
    for path in sorted((SHADERS_DIR / "lib").rglob("*.glsl")):
        options.update(parse_options(path))

    settings: dict[str, str | bool] = {}

    def apply(profile_name: str, seen: tuple[str, ...]) -> None:
        if profile_name in seen:
            raise RuntimeError(f"circular profile inheritance at {profile_name}")

        entries = properties.profiles.get(profile_name)
        if entries is None:
            raise RuntimeError(f"unknown profile '{profile_name}'")

        for entry in entries:
            if entry.startswith("profile."):
                apply(entry[len("profile."):], seen + (profile_name,))
            elif entry.startswith("!"):
                settings[entry[1:]] = False
            elif ":" in entry:
                key, _, value = entry.partition(":")
                settings[key] = value
            else:
                settings[entry] = True

    apply(name, ())

    defines: list[str] = []
    for key, value in settings.items():
        if key.startswith("program."):
            continue
        option = options.get(key)
        if value is True:
            defines.append(key)
        elif value is False:
            # A disabled boolean must be absent, not defined to 0, because the
            # shader tests it with #ifdef.
            continue
        else:
            # const options are not #define-able; they are compiled from their
            # declaration. Only macro options are overridden here.
            if option is not None and option.kind == "const":
                continue
            defines.append(f"{key} {value}")

    # Booleans the profile turned off still need to be removed from the
    # defaults in settings.glsl, which glslang would otherwise pick up.
    undefines = [key for key, value in settings.items()
                 if value is False and not key.startswith("program.")]

    return defines + [f"__ASTRA_UNDEF_{u}" for u in undefines]


def split_defines(raw: list[str]) -> tuple[list[str], list[str]]:
    """Separate real defines from the undef markers resolve_profile emits."""
    defines = []
    undefines = []
    for item in raw:
        if item.startswith("__ASTRA_UNDEF_"):
            undefines.append(item[len("__ASTRA_UNDEF_"):])
        else:
            defines.append(item)
    return defines, undefines


# ------------------------------------------------------------------------------
# Compilation
# ------------------------------------------------------------------------------

STAGE_FOR_EXTENSION = {"vsh": "vert", "fsh": "frag", "csh": "comp"}


def find_glslang() -> str | None:
    """Locate the GLSL reference compiler.

    A project-local copy under tools/.glslang takes priority so a developer can
    pin a known version without touching the system. Upstream renamed the
    binary from glslangValidator to glslang at release 15, so both names are
    checked.
    """
    local_root = Path(__file__).resolve().parent / ".glslang"
    for relative in ("bin/glslang.exe", "bin/glslangValidator.exe",
                     "bin/glslang", "bin/glslangValidator"):
        candidate = local_root / relative
        if candidate.is_file():
            return str(candidate)

    for name in ("glslangValidator", "glslang"):
        path = shutil.which(name)
        if path:
            return path

    return None


def compile_one(glslang: str, entry: Path, target: Target, preset: str,
                defines: list[str], undefines: list[str]) -> tuple[bool, str]:
    source_map = SourceMap()

    try:
        source = build_translation_unit(entry, target, defines, source_map)
    except RuntimeError as exc:
        return False, str(exc)

    if undefines:
        # Undefs must follow the macro block but precede the shader body, so
        # they are spliced in right after the injected defines.
        lines = source.splitlines()
        insert_at = 1
        while insert_at < len(lines) and lines[insert_at].startswith("#define "):
            insert_at += 1
        for name in undefines:
            lines.insert(insert_at, f"#undef {name}")
        source = "\n".join(lines)

    stage = STAGE_FOR_EXTENSION[entry.suffix.lstrip(".")]

    with tempfile.TemporaryDirectory() as tmp:
        temp_path = Path(tmp) / f"shader.{stage}"
        temp_path.write_text(source, encoding="utf-8")

        result = subprocess.run(
            [glslang, str(temp_path)],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            return True, ""

        # Rewrite glslang's line numbers back to real files.
        output = result.stdout + result.stderr
        translated = []
        for line in output.splitlines():
            match = re.search(r"ERROR:\s*\d+:(\d+):", line)
            if match:
                flat_line = int(match.group(1))
                origin = source_map.lookup(flat_line - _injected_line_count(source))
                line = line + f"    [{origin}]"
            translated.append(line)

        return False, "\n".join(translated)


def _injected_line_count(source: str) -> int:
    """How many lines the macro block added ahead of the original source."""
    count = 0
    for line in source.splitlines()[1:]:
        if line.startswith("#define ") or line.startswith("#undef "):
            count += 1
        else:
            break
    return count + 1  # plus the version line


# ------------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preset", default="HIGH", help="quality preset to compile")
    parser.add_argument(
        "--all-presets", action="store_true",
        help="compile every preset (POTATO through CINEMATIC)",
    )
    parser.add_argument("--program", help="compile only this program")
    parser.add_argument(
        "--required", action="store_true",
        help="fail instead of skipping when glslangValidator is unavailable",
    )
    args = parser.parse_args()

    glslang = find_glslang()
    if glslang is None:
        message = (
            "glslangValidator not found on PATH.\n"
            "  Ubuntu/Debian: sudo apt-get install glslang-tools\n"
            "  macOS:         brew install glslang\n"
            "  Windows:       scoop install glslang, or download from\n"
            "                 https://github.com/KhronosGroup/glslang/releases"
        )
        if args.required:
            print(f"ERROR: {message}")
            return 1
        print(f"SKIPPED: {message}")
        return 0

    presets = (
        ["POTATO", "LOW", "MEDIUM", "HIGH", "ULTRA", "CINEMATIC"]
        if args.all_presets
        else [args.preset]
    )

    # Only the shaders/ root is compiled. The dimension folders are generated
    # stubs that differ from it by a single #define, and gen_dimension_stubs.py
    # --check already guarantees they are in sync; compiling all four would
    # quadruple the runtime for no additional coverage.
    entries: list[Path] = []
    for program in PROGRAMS:
        if args.program and program.name != args.program:
            continue
        for stage in program.stages:
            entries.append(SHADERS_DIR / f"{program.name}.{stage}")

    if not entries:
        print(f"No programs matched '{args.program}'.")
        return 1

    total = 0
    failures = 0

    for target in TARGETS:
        for preset in presets:
            try:
                raw = resolve_profile(preset)
            except RuntimeError as exc:
                print(f"ERROR: {exc}")
                return 1

            defines, undefines = split_defines(raw)

            print(f"\n=== {target.description} / preset {preset} ===")

            for entry in entries:
                total += 1
                ok, message = compile_one(
                    glslang, entry, target, preset, defines, undefines
                )

                if ok:
                    print(f"  ok      {entry.name}")
                else:
                    failures += 1
                    print(f"  FAILED  {entry.name}")
                    for line in message.splitlines():
                        if line.strip():
                            print(f"            {line}")

    print(f"\n{total - failures}/{total} compiled successfully.")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
