"""Parsers for the shader option, properties and language files.

Shared by validate_shader.py and glsl_compile.py so both agree on what an
option is and what values it accepts.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------


@dataclass
class Option:
    """A user-facing setting, as Iris parses it out of the GLSL source."""

    name: str
    kind: str  # "bool" | "int" | "float" | "const"
    default: str | None
    values: list[str] = field(default_factory=list)
    source: str = ""
    line: int = 0

    @property
    def is_boolean(self) -> bool:
        return self.kind == "bool"

    @property
    def has_value_list(self) -> bool:
        return bool(self.values)


# `#define NAME value // [a b c] description`  or  `#define NAME  // description`
_DEFINE_RE = re.compile(
    r"^\s*(?P<commented>//\s*)?#define\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?P<value>\s+[^/\n]+?)?\s*(?://\s*(?P<comment>.*))?$"
)

# `const int name = 2048; // [512 1024 2048]`
_CONST_RE = re.compile(
    r"^\s*const\s+(?P<type>int|float|bool)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*=\s*(?P<value>[^;]+);\s*(?://\s*(?P<comment>.*))?$"
)

_VALUE_LIST_RE = re.compile(r"\[([^\]]*)\]")

# Macros that exist for internal wiring rather than as user settings. They live
# in settings.glsl-adjacent files and must not be reported as missing a label.
INTERNAL_PREFIXES = ("ASTRA_", "PROGRAM_", "DIM_", "IRIS_", "MC_")


def _looks_like_option_name(name: str) -> bool:
    return not name.startswith(INTERNAL_PREFIXES)


def parse_options(path: Path) -> dict[str, Option]:
    """Extract every user-facing option declared in a GLSL file."""
    options: dict[str, Option] = {}
    text = path.read_text(encoding="utf-8")

    for lineno, line in enumerate(text.splitlines(), start=1):
        const_match = _CONST_RE.match(line)
        if const_match:
            name = const_match.group("name")
            comment = const_match.group("comment") or ""
            values = _extract_values(comment)
            if not values or not _looks_like_option_name(name):
                # A const without a value list is an internal constant.
                continue
            options[name] = Option(
                name=name,
                kind="const",
                default=const_match.group("value").strip(),
                values=values,
                source=path.name,
                line=lineno,
            )
            continue

        define_match = _DEFINE_RE.match(line)
        if not define_match:
            continue

        name = define_match.group("name")
        if not _looks_like_option_name(name):
            continue

        # Include guards and similar have no comment and no value.
        raw_value = (define_match.group("value") or "").strip()
        comment = define_match.group("comment") or ""
        values = _extract_values(comment)

        if raw_value:
            kind = "float" if _is_float_literal(raw_value) else "int"
            if not values:
                # A define with a value but no list is not user-configurable.
                continue
            options[name] = Option(
                name=name,
                kind=kind,
                default=raw_value,
                values=values,
                source=path.name,
                line=lineno,
            )
        else:
            # A bare #define (or a commented-out one) is a boolean toggle. Iris
            # picks these up whether or not they carry a description, so the
            # comment is not required here - INTERNAL_PREFIXES above is what
            # keeps include guards and program macros out of the option list.
            options[name] = Option(
                name=name,
                kind="bool",
                default="false" if define_match.group("commented") else "true",
                source=path.name,
                line=lineno,
            )

    return options


def _extract_values(comment: str) -> list[str]:
    match = _VALUE_LIST_RE.search(comment)
    if not match:
        return []
    return match.group(1).split()


def _is_float_literal(text: str) -> bool:
    return "." in text or "e" in text.lower()


# ------------------------------------------------------------------------------
# shaders.properties
# ------------------------------------------------------------------------------


@dataclass
class ShaderProperties:
    raw: dict[str, str] = field(default_factory=dict)
    screens: dict[str, list[str]] = field(default_factory=dict)
    sliders: list[str] = field(default_factory=list)
    profiles: dict[str, list[str]] = field(default_factory=dict)


def parse_properties(path: Path) -> ShaderProperties:
    """Read a .properties file, joining backslash continuations."""
    result = ShaderProperties()

    text = path.read_text(encoding="utf-8")

    # Join continuation lines before splitting into entries.
    text = re.sub(r"\\\s*\n\s*", " ", text)

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue

        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        result.raw[key] = value

        if key == "screen":
            result.screens["__root__"] = value.split()
        elif key.startswith("screen.") and not key.endswith(".columns"):
            result.screens[key[len("screen."):]] = value.split()
        elif key == "sliders":
            result.sliders = value.split()
        elif key.startswith("profile."):
            result.profiles[key[len("profile."):]] = value.split()

    return result


# ------------------------------------------------------------------------------
# Language files
# ------------------------------------------------------------------------------


def parse_lang(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        entries[key.strip()] = value.strip()

    return entries


# ------------------------------------------------------------------------------
# Include graph
# ------------------------------------------------------------------------------

_INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"')


def find_includes(text: str) -> list[tuple[int, str]]:
    """Return (line number, include path) for every #include in the source."""
    found = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = _INCLUDE_RE.match(line)
        if match:
            found.append((lineno, match.group(1)))
    return found


def resolve_include(include_path: str, shaders_dir: Path, current_file: Path) -> Path:
    """Resolve an #include the way Iris does.

    A leading slash means relative to the shaders/ directory; anything else is
    relative to the including file.
    """
    if include_path.startswith("/"):
        return shaders_dir / include_path.lstrip("/")
    return current_file.parent / include_path


# ------------------------------------------------------------------------------
# block.properties
# ------------------------------------------------------------------------------


def parse_block_ids(path: Path) -> dict[int, list[str]]:
    """Map each block.<n> id to the blocks assigned to it."""
    properties = parse_properties(path)

    blocks: dict[int, list[str]] = {}
    for key, value in properties.raw.items():
        if not key.startswith("block."):
            continue
        suffix = key[len("block."):]
        if not suffix.isdigit():
            continue
        blocks[int(suffix)] = value.split()

    return blocks
