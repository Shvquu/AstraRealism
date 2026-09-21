"""Tests for tools/generate_changelog.py.

Covers the situations the release workflow actually encounters, including the
awkward ones called out as requirements: a first release with no previous tag,
a range with no commits, commits that ignore the convention, and breaking
changes declared either way.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

from generate_changelog import (  # noqa: E402
    build_notes,
    format_entry,
    parse_commit,
)


def commit(subject: str, body: str = "", sha: str = "abc1234def5678"):
    return parse_commit(sha, subject, body)


class ParseCommitTests(unittest.TestCase):
    def test_parses_type_and_subject(self):
        result = commit("feat: add volumetric clouds")

        self.assertEqual(result.commit_type, "feat")
        self.assertEqual(result.description, "add volumetric clouds")
        self.assertIsNone(result.scope)
        self.assertFalse(result.breaking)

    def test_parses_scope(self):
        result = commit("fix(water): stop reflections flickering")

        self.assertEqual(result.commit_type, "fix")
        self.assertEqual(result.scope, "water")
        self.assertEqual(result.description, "stop reflections flickering")

    def test_bang_marks_breaking(self):
        result = commit("feat!: restructure shader configuration")

        self.assertTrue(result.breaking)
        self.assertEqual(result.commit_type, "feat")

    def test_bang_with_scope_marks_breaking(self):
        result = commit("refactor(config)!: rename every option")

        self.assertTrue(result.breaking)
        self.assertEqual(result.scope, "config")

    def test_footer_marks_breaking(self):
        result = commit(
            "feat: rework the buffer layout",
            "BREAKING CHANGE: colortex indices have all shifted.",
        )

        self.assertTrue(result.breaking)
        self.assertEqual(
            result.breaking_notes, ["colortex indices have all shifted."]
        )

    def test_hyphenated_footer_also_recognised(self):
        # Both spellings appear in the wild and the spec allows each.
        result = commit("fix: something", "BREAKING-CHANGE: it moved.")

        self.assertTrue(result.breaking)

    def test_non_conventional_commit_keeps_its_subject(self):
        result = commit("Update the readme a bit")

        self.assertIsNone(result.commit_type)
        self.assertEqual(result.description, "Update the readme a bit")
        self.assertFalse(result.breaking)

    def test_colon_in_prose_is_not_a_type(self):
        # "Note" is capitalised, so it must not be mistaken for a commit type.
        result = commit("Note: this is not conventional")

        self.assertIsNone(result.commit_type)


class FormatEntryTests(unittest.TestCase):
    def test_capitalises_and_appends_short_sha(self):
        line = format_entry(commit("feat: add clouds", sha="0123456789abcdef"))

        self.assertEqual(line, "- Add clouds (0123456)")

    def test_includes_scope_in_bold(self):
        line = format_entry(commit("fix(ssr): reduce noise", sha="0123456789abcdef"))

        self.assertEqual(line, "- **ssr**: Reduce noise (0123456)")

    def test_leaves_acronyms_alone(self):
        line = format_entry(commit("fix: SSR ghosting", sha="0123456789abcdef"))

        self.assertIn("SSR ghosting", line)


class BuildNotesTests(unittest.TestCase):
    def test_first_release_has_no_compare_link(self):
        notes = build_notes(
            "v1.0.0", None, [commit("feat: initial release")], "owner/repo"
        )

        self.assertIn("This is the first release.", notes)
        self.assertNotIn("compare", notes)

    def test_compare_link_uses_repository(self):
        notes = build_notes(
            "v1.4.0", "v1.3.0", [commit("feat: clouds")], "owner/repo"
        )

        self.assertIn(
            "https://github.com/owner/repo/compare/v1.3.0...v1.4.0", notes
        )

    def test_empty_commit_range_still_produces_valid_notes(self):
        notes = build_notes("v1.0.1", "v1.0.0", [], "owner/repo")

        self.assertIn("No code changes since the previous release.", notes)
        self.assertIn("# AstraRealism v1.0.1", notes)
        self.assertIn("Downloads", notes)

    def test_empty_categories_are_omitted(self):
        notes = build_notes("v1.1.0", "v1.0.0", [commit("feat: clouds")], "owner/repo")

        self.assertIn("Features", notes)
        self.assertNotIn("Bug Fixes", notes)
        self.assertNotIn("Performance", notes)

    def test_breaking_changes_come_first(self):
        commits = [
            commit("fix: a small fix"),
            commit("feat!: a breaking feature"),
        ]

        notes = build_notes("v2.0.0", "v1.9.0", commits, "owner/repo")

        breaking_index = notes.index("Breaking Changes")
        fixes_index = notes.index("Bug Fixes")

        self.assertLess(breaking_index, fixes_index)

    def test_breaking_footer_text_is_used_verbatim(self):
        commits = [
            commit(
                "feat: rework buffers",
                "BREAKING CHANGE: colortex indices have shifted.",
            )
        ]

        notes = build_notes("v2.0.0", "v1.0.0", commits, "owner/repo")

        self.assertIn("colortex indices have shifted.", notes)

    def test_unknown_types_land_in_other(self):
        notes = build_notes(
            "v1.1.0", "v1.0.0", [commit("Random unstructured commit")], "owner/repo"
        )

        self.assertIn("Other Changes", notes)
        self.assertIn("Random unstructured commit", notes)

    def test_categories_appear_in_declared_order(self):
        commits = [
            commit("chore: tidy up"),
            commit("feat: a feature"),
            commit("fix: a fix"),
        ]

        notes = build_notes("v1.1.0", "v1.0.0", commits, "owner/repo")

        self.assertLess(notes.index("Features"), notes.index("Bug Fixes"))
        self.assertLess(notes.index("Bug Fixes"), notes.index("Maintenance"))

    def test_download_section_names_the_zip_not_a_jar(self):
        # Iris does not load .jar files; the notes must not imply otherwise.
        notes = build_notes("v1.0.0", None, [commit("feat: x")], "owner/repo")

        self.assertIn("AstraRealism-v1.0.0.zip", notes)
        self.assertNotIn(".jar", notes)

    def test_notes_end_with_a_single_newline(self):
        notes = build_notes("v1.0.0", None, [commit("feat: x")], "owner/repo")

        self.assertTrue(notes.endswith("\n"))
        self.assertFalse(notes.endswith("\n\n"))


if __name__ == "__main__":
    unittest.main()
