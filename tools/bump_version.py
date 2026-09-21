#!/usr/bin/env python3
"""Write a version string into the pack metadata.

The version has exactly one source of truth: the git tag. This script copies it
into the files that ship inside the pack, so there is never a second number to
keep in sync by hand.

Targets:
  shaders/shaders.properties   a header comment, visible when users open it
  shaders/version.txt          machine-readable, read by support tooling

Both writes are idempotent, so running this twice changes nothing.

Usage:
    python tools/bump_version.py --version 1.2.0
    python tools/bump_version.py --from-tag v1.2.0
    python tools/bump_version.py --version 1.2.0 --check
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "shaders"

PROPERTIES_PATH = SHADERS_DIR / "shaders.properties"
VERSION_PATH = SHADERS_DIR / "version.txt"

_VERSION_COMMENT_RE = re.compile(r"^# AstraRealism version .*$", re.MULTILINE)

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def version_from_tag(tag: str) -> str:
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError(f"tag '{tag}' does not match vMAJOR.MINOR.PATCH")
    return tag[1:]


def render_properties(text: str, version: str) -> str:
    comment = f"# AstraRealism version {version}"

    if _VERSION_COMMENT_RE.search(text):
        return _VERSION_COMMENT_RE.sub(comment, text)

    # Insert directly after the opening banner so it is the first thing read.
    lines = text.splitlines()
    insert_at = 0
    for index, line in enumerate(lines):
        if line.startswith("# ===") and index > 0:
            insert_at = index + 1
            break

    lines.insert(insert_at, comment)
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--version", help="semantic version without a leading 'v'")
    group.add_argument("--from-tag", help="git tag such as v1.2.0")
    parser.add_argument(
        "--check", action="store_true",
        help="verify the files already carry this version instead of writing",
    )
    args = parser.parse_args()

    if args.from_tag:
        try:
            version = version_from_tag(args.from_tag)
        except ValueError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
    else:
        version = args.version.lstrip("v")

    # 'dev' is allowed for local builds; anything else must be a real version.
    if version != "dev" and not SEMVER_RE.match(version):
        print(
            f"ERROR: '{version}' is not a semantic version (MAJOR.MINOR.PATCH)",
            file=sys.stderr,
        )
        return 1

    if not PROPERTIES_PATH.is_file():
        print(f"ERROR: {PROPERTIES_PATH} not found", file=sys.stderr)
        return 1

    current_properties = PROPERTIES_PATH.read_text(encoding="utf-8")
    updated_properties = render_properties(current_properties, version)

    current_version_file = (
        VERSION_PATH.read_text(encoding="utf-8").strip()
        if VERSION_PATH.is_file()
        else None
    )

    if args.check:
        problems = []
        if updated_properties != current_properties:
            problems.append("shaders.properties does not carry this version")
        if current_version_file != version:
            problems.append(
                f"version.txt says '{current_version_file}', expected '{version}'"
            )

        if problems:
            for problem in problems:
                print(f"ERROR: {problem}", file=sys.stderr)
            return 1

        print(f"Version {version} is present in all metadata.")
        return 0

    PROPERTIES_PATH.write_text(updated_properties, encoding="utf-8", newline="\n")
    VERSION_PATH.write_text(version + "\n", encoding="utf-8", newline="\n")

    print(f"Set version to {version}")
    print(f"  {PROPERTIES_PATH.relative_to(REPO_ROOT).as_posix()}")
    print(f"  {VERSION_PATH.relative_to(REPO_ROOT).as_posix()}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
