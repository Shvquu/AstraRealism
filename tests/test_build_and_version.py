"""Tests for tools/build_pack.py, tools/bump_version.py and the option parser."""

from __future__ import annotations

import sys
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from build_pack import collect_files, should_include, write_archive  # noqa: E402
from bump_version import render_properties, version_from_tag  # noqa: E402
from shader_parser import parse_options, parse_properties  # noqa: E402


class ShouldIncludeTests(unittest.TestCase):
    def test_includes_shader_sources(self):
        self.assertTrue(should_include(Path("lib/common/math.glsl")))
        self.assertTrue(should_include(Path("gbuffers_terrain.fsh")))
        self.assertTrue(should_include(Path("shaders.properties")))
        self.assertTrue(should_include(Path("lang/en_us.lang")))

    def test_excludes_python(self):
        self.assertFalse(should_include(Path("tools/validate_shader.py")))

    def test_excludes_caches_and_vcs(self):
        self.assertFalse(should_include(Path("__pycache__/x.pyc")))
        self.assertFalse(should_include(Path(".git/config")))
        self.assertFalse(should_include(Path("a/.git/b")))

    def test_excludes_dotfiles(self):
        self.assertFalse(should_include(Path(".gitignore")))
        self.assertFalse(should_include(Path(".DS_Store")))


class ArchiveTests(unittest.TestCase):
    def test_archive_contains_shaders_properties_at_expected_path(self):
        names = [arcname for _, arcname in collect_files()]

        # Iris looks for shaders/shaders.properties relative to the archive
        # root. Any other nesting makes the pack load as an empty entry.
        self.assertIn("shaders/shaders.properties", names)

    def test_archive_excludes_development_files(self):
        names = [arcname for _, arcname in collect_files()]

        for name in names:
            self.assertFalse(name.startswith("tools/"), name)
            self.assertFalse(name.startswith("tests/"), name)
            self.assertFalse(name.startswith(".github/"), name)
            self.assertFalse(name.endswith(".py"), name)

    def test_entries_are_sorted(self):
        names = [arcname for _, arcname in collect_files()]

        self.assertEqual(names, sorted(names))

    def test_build_is_byte_reproducible(self):
        import tempfile

        entries = collect_files()

        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "first.zip"
            second = Path(tmp) / "second.zip"

            write_archive(first, entries)
            write_archive(second, entries)

            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_all_timestamps_are_fixed(self):
        import tempfile

        entries = collect_files()

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pack.zip"
            write_archive(path, entries)

            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))


class VersionTests(unittest.TestCase):
    def test_strips_leading_v(self):
        self.assertEqual(version_from_tag("v1.2.3"), "1.2.3")

    def test_rejects_malformed_tags(self):
        for tag in ("1.2.3", "v1.2", "v1.2.3.4", "release-1.2.3", "vx.y.z"):
            with self.subTest(tag=tag):
                with self.assertRaises(ValueError):
                    version_from_tag(tag)

    def test_inserts_version_comment(self):
        text = (
            "# ==========\n"
            "# AstraRealism\n"
            "# ==========\n"
            "\n"
            "clouds = off\n"
        )

        result = render_properties(text, "1.2.3")

        self.assertIn("# AstraRealism version 1.2.3", result)
        self.assertIn("clouds = off", result)

    def test_replacing_the_version_is_idempotent(self):
        text = "# ==========\n# X\n# ==========\nclouds = off\n"

        once = render_properties(text, "1.2.3")
        twice = render_properties(once, "1.2.3")

        self.assertEqual(once, twice)

    def test_updating_replaces_rather_than_appends(self):
        text = "# ==========\n# X\n# ==========\nclouds = off\n"

        first = render_properties(text, "1.0.0")
        second = render_properties(first, "2.0.0")

        self.assertIn("# AstraRealism version 2.0.0", second)
        self.assertNotIn("# AstraRealism version 1.0.0", second)
        self.assertEqual(second.count("# AstraRealism version"), 1)


class OptionParserTests(unittest.TestCase):
    """The parser decides what Iris will treat as a user setting, so its
    behaviour on each declaration form is worth pinning down."""

    def setUp(self):
        self.settings = REPO_ROOT / "shaders" / "lib" / "common" / "settings.glsl"
        self.options = parse_options(self.settings)

    def test_finds_boolean_without_a_comment(self):
        # WATER_WAVES is declared as a bare `#define` with no trailing comment.
        self.assertIn("WATER_WAVES", self.options)
        self.assertTrue(self.options["WATER_WAVES"].is_boolean)

    def test_commented_out_boolean_defaults_to_off(self):
        self.assertIn("DOF_ENABLED", self.options)
        self.assertEqual(self.options["DOF_ENABLED"].default, "false")

    def test_plain_boolean_defaults_to_on(self):
        self.assertEqual(self.options["SHADOWS_ENABLED"].default, "true")

    def test_numeric_option_captures_its_value_list(self):
        option = self.options["SHADOW_FILTER"]

        self.assertEqual(option.values, ["0", "1", "2"])
        self.assertEqual(option.default, "2")

    def test_const_option_is_recognised(self):
        option = self.options["shadowMapResolution"]

        self.assertEqual(option.kind, "const")
        self.assertIn("2048", option.values)

    def test_include_guards_are_not_options(self):
        for name in self.options:
            self.assertFalse(
                name.startswith("ASTRA_"),
                f"{name} is internal and must not be exposed as an option",
            )

    def test_every_option_default_is_in_its_own_value_list(self):
        for name, option in self.options.items():
            if not option.has_value_list or option.default is None:
                continue
            with self.subTest(option=name):
                self.assertIn(
                    option.default.strip(),
                    option.values,
                    f"{name} defaults to {option.default} which is not selectable",
                )


class PropertiesParserTests(unittest.TestCase):
    def test_joins_backslash_continuations(self):
        properties = parse_properties(REPO_ROOT / "shaders" / "shaders.properties")

        # The root screen is written across several continued lines.
        self.assertIn("__root__", properties.screens)
        self.assertIn("[LIGHTING]", properties.screens["__root__"])
        self.assertIn("[DEBUG]", properties.screens["__root__"])

    def test_every_preset_is_defined(self):
        properties = parse_properties(REPO_ROOT / "shaders" / "shaders.properties")

        for preset in ("POTATO", "LOW", "MEDIUM", "HIGH", "ULTRA", "CINEMATIC"):
            self.assertIn(preset, properties.profiles)


if __name__ == "__main__":
    unittest.main()
