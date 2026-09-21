#!/usr/bin/env python3
"""Package the shader pack into a distributable ZIP.

Produces `dist/AstraRealism-v<version>.zip`, containing only what Iris needs at
runtime. Development files - the tooling, tests, docs, CI configuration and git
metadata - are excluded.

The archive is reproducible: entries are sorted, timestamps are fixed and
permissions are normalised, so building the same commit twice yields a
byte-identical file. That is what makes it possible to verify a published
release actually corresponds to its source.

Note on the format: Iris only recognises directories and `.zip` archives in
.minecraft/shaderpacks/. A `.jar` is the mod format and will not appear in the
shader selection screen at all. See docs/limitations.md.

Usage:
    python tools/build_pack.py --version 1.0.0
    python tools/build_pack.py --version dev --output-dir build
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "shaders"

PACK_NAME = "AstraRealism"

# A fixed timestamp for every entry. ZIP stores local time with no timezone, so
# any real mtime would make the archive depend on when and where it was built.
# 1980-01-01 is the earliest the format can represent.
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)

# Files shipped alongside shaders/ so the archive is self-describing.
ROOT_FILES = ("README.md", "LICENSE", "CHANGELOG.md")

# Anything matching these is development-only and never ships.
EXCLUDED_NAMES = {
    "__pycache__", ".git", ".github", ".pytest_cache", ".venv", "venv",
    "node_modules", ".DS_Store", "Thumbs.db", "desktop.ini",
}

EXCLUDED_SUFFIXES = {".py", ".pyc", ".pyo", ".zip", ".log", ".bak", ".swp"}


def should_include(path: Path) -> bool:
    """Decide whether a file belongs in the shipped pack."""
    if any(part in EXCLUDED_NAMES for part in path.parts):
        return False

    if path.suffix in EXCLUDED_SUFFIXES:
        return False

    # Editor and OS cruft.
    if path.name.startswith("."):
        return False

    return True


def collect_files() -> list[tuple[Path, str]]:
    """Return (source path, archive name) pairs, sorted for determinism."""
    entries: list[tuple[Path, str]] = []

    for path in SHADERS_DIR.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(SHADERS_DIR)
        if not should_include(relative):
            continue
        entries.append((path, f"shaders/{relative.as_posix()}"))

    for name in ROOT_FILES:
        path = REPO_ROOT / name
        if path.is_file():
            entries.append((path, name))

    return sorted(entries, key=lambda item: item[1])


def write_archive(destination: Path, entries: list[tuple[Path, str]]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)

    if destination.exists():
        destination.unlink()

    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for source, arcname in entries:
            info = zipfile.ZipInfo(arcname, date_time=FIXED_TIMESTAMP)

            # 0o644, regular file. Taking the real mode would make the archive
            # depend on the umask of whoever built it.
            info.external_attr = (0o100644 & 0xFFFF) << 16
            info.compress_type = zipfile.ZIP_DEFLATED

            archive.writestr(info, source.read_bytes())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def format_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KiB", "MiB"):
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} GiB"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version", required=True,
        help="version string without a leading 'v', e.g. 1.0.0 or dev",
    )
    parser.add_argument(
        "--output-dir", default="dist",
        help="directory to write the archive into (default: dist)",
    )
    parser.add_argument(
        "--also-latest", action="store_true",
        help=f"additionally write {PACK_NAME}-Latest.zip",
    )
    args = parser.parse_args()

    version = args.version.lstrip("v")

    entries = collect_files()
    if not entries:
        print("ERROR: no files collected; is shaders/ missing?")
        return 1

    if not any(name == "shaders/shaders.properties" for _, name in entries):
        print("ERROR: shaders/shaders.properties is missing from the archive")
        return 1

    output_dir = REPO_ROOT / args.output_dir
    archive_path = output_dir / f"{PACK_NAME}-v{version}.zip"

    write_archive(archive_path, entries)

    print(f"Built {archive_path.relative_to(REPO_ROOT).as_posix()}")
    print(f"  files   {len(entries)}")
    print(f"  size    {format_size(archive_path.stat().st_size)}")
    print(f"  sha256  {sha256(archive_path)}")

    if args.also_latest:
        latest = output_dir / f"{PACK_NAME}-Latest.zip"
        shutil.copyfile(archive_path, latest)
        print(f"  copied to {latest.relative_to(REPO_ROOT).as_posix()}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
