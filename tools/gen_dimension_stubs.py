#!/usr/bin/env python3
"""Generate (or verify) the per-dimension shader program stubs.

Iris loads programs only from a dimension folder once that folder exists, so
every dimension needs a full set of program files. This script writes those
files from the manifest in program_manifest.py, so the real shader code stays
in exactly one place.

Usage:
    python tools/gen_dimension_stubs.py           # write the stubs
    python tools/gen_dimension_stubs.py --check   # fail if any are out of date
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from program_manifest import (  # noqa: E402
    DIMENSIONS,
    GLSL_VERSION,
    PROGRAMS,
    Dimension,
    Program,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "shaders"

GENERATED_MARKER = "GENERATED FILE - DO NOT EDIT"


def stub_source(program: Program, stage: str, dimension: Dimension) -> str:
    """Build the contents of one stub file.

    Deliberately minimal: a version directive, the dimension and program
    macros, then the shared body. All real logic lives in the body.
    """
    body = program.body_for(stage)
    include = body if body.endswith(".glsl") else f"{body}.{stage}.glsl"

    where = dimension.folder or "shaders root"

    return (
        f"// {GENERATED_MARKER}\n"
        f"// Source: tools/gen_dimension_stubs.py + tools/program_manifest.py\n"
        f"// Program: {program.name}.{stage}  ({where}: {dimension.description})\n"
        f"//\n"
        f"// {program.note or 'see the shared body for details'}\n"
        f"\n"
        f"{GLSL_VERSION}\n"
        f"\n"
        f"#define {dimension.macro}\n"
        f"#define {program.macro}\n"
        f"\n"
        f'#include "/program/{include}"\n'
    )


def iter_stubs():
    """Yield (absolute path, expected contents) for every stub."""
    for dimension in DIMENSIONS:
        base = SHADERS_DIR / dimension.folder if dimension.folder else SHADERS_DIR
        for program in PROGRAMS:
            for stage in program.stages:
                path = base / f"{program.name}.{stage}"
                yield path, stub_source(program, stage, dimension)


def write_stubs() -> int:
    written = 0
    for path, expected in iter_stubs():
        path.parent.mkdir(parents=True, exist_ok=True)
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != expected:
            path.write_text(expected, encoding="utf-8", newline="\n")
            written += 1
    return written


def check_stubs() -> list[str]:
    """Return a list of human-readable problems; empty means everything matches."""
    problems: list[str] = []
    expected_paths = set()

    for path, expected in iter_stubs():
        expected_paths.add(path.resolve())
        if not path.exists():
            problems.append(f"missing: {path.relative_to(REPO_ROOT).as_posix()}")
        elif path.read_text(encoding="utf-8") != expected:
            problems.append(f"out of date: {path.relative_to(REPO_ROOT).as_posix()}")

    # Catch stubs left behind after a program is removed from the manifest.
    # Only files carrying the generated marker are considered, so a hand-written
    # program added outside the manifest is reported rather than silently killed.
    for folder in [SHADERS_DIR] + [
        SHADERS_DIR / d.folder for d in DIMENSIONS if d.folder
    ]:
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*.*sh")):
            if path.resolve() in expected_paths:
                continue
            head = path.read_text(encoding="utf-8")[:400]
            label = "orphaned" if GENERATED_MARKER in head else "unmanaged"
            problems.append(f"{label}: {path.relative_to(REPO_ROOT).as_posix()}")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the stubs match the manifest instead of writing them",
    )
    args = parser.parse_args()

    if args.check:
        problems = check_stubs()
        if problems:
            print("Dimension stubs are out of sync with tools/program_manifest.py:")
            for problem in problems:
                print(f"  {problem}")
            print("\nRun: python tools/gen_dimension_stubs.py")
            return 1
        total = sum(len(p.stages) for p in PROGRAMS) * len(DIMENSIONS)
        print(f"Dimension stubs OK ({total} files across {len(DIMENSIONS)} folders).")
        return 0

    written = write_stubs()
    total = sum(len(p.stages) for p in PROGRAMS) * len(DIMENSIONS)
    print(f"Generated {total} stub files ({written} changed).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
