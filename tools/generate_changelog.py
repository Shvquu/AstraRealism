#!/usr/bin/env python3
"""Generate release notes from Conventional Commits.

Reads the commits between the previous release tag and the current one,
categorises them, and emits Markdown suitable for a GitHub release body.

Handles the cases a release workflow actually hits:
  - the first release, where no previous tag exists
  - a range containing no commits at all
  - commits that do not follow the convention
  - breaking changes, flagged either with `!` or a BREAKING CHANGE footer
  - merge commits, which are noise and are dropped

Usage:
    python tools/generate_changelog.py --tag v1.2.0
    python tools/generate_changelog.py --tag v1.2.0 --repo owner/name
    python tools/generate_changelog.py --tag v1.2.0 --output notes.md
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Ordered: this is the order sections appear in the release notes.
CATEGORIES: tuple[tuple[str, str, str], ...] = (
    ("feat", "Features", "✨"),
    ("fix", "Bug Fixes", "\U0001F41B"),
    ("perf", "Performance", "⚡"),
    ("refactor", "Refactoring", "♻️"),
    ("docs", "Documentation", "\U0001F4DA"),
    ("build", "Build", "\U0001F527"),
    ("ci", "CI/CD", "\U0001F916"),
    ("test", "Tests", "\U0001F9EA"),
    ("style", "Style", "\U0001F484"),
    ("chore", "Maintenance", "\U0001F9F9"),
)

OTHER_LABEL = "Other Changes"
OTHER_EMOJI = "\U0001F4E6"

BREAKING_LABEL = "Breaking Changes"
BREAKING_EMOJI = "⚠️"

# type(optional scope)!: subject
_CONVENTIONAL_RE = re.compile(
    r"^(?P<type>[a-z]+)"
    r"(?:\((?P<scope>[^)]*)\))?"
    r"(?P<breaking>!)?"
    r":\s*(?P<subject>.+)$"
)

_BREAKING_FOOTER_RE = re.compile(
    r"^BREAKING[ -]CHANGE:\s*(?P<description>.+)$",
    re.MULTILINE,
)


@dataclass
class Commit:
    sha: str
    subject: str
    body: str
    commit_type: str | None = None
    scope: str | None = None
    description: str = ""
    breaking: bool = False
    breaking_notes: list[str] = field(default_factory=list)


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def previous_tag(current: str) -> str | None:
    """Find the release tag immediately preceding `current`.

    Returns None for the first release, which is not an error - the caller
    falls back to the whole history.
    """
    try:
        tags = run_git(
            "tag", "--list", "v*.*.*", "--sort=-version:refname"
        ).splitlines()
    except RuntimeError:
        return None

    tags = [tag.strip() for tag in tags if tag.strip()]

    if current in tags:
        index = tags.index(current)
        return tags[index + 1] if index + 1 < len(tags) else None

    # The tag may not exist yet when this runs before tagging; in that case the
    # newest existing tag is the previous release.
    return tags[0] if tags else None


def collect_commits(since: str | None, until: str) -> list[Commit]:
    """Read commits in (since, until]. With no `since`, read the whole history."""
    revision_range = f"{since}..{until}" if since else until

    # \x1e separates records, \x1f separates fields: both are control characters
    # that cannot appear in a commit message, unlike the usual newline hacks.
    try:
        raw = run_git(
            "log", revision_range,
            "--no-merges",
            "--pretty=format:%H\x1f%s\x1f%b\x1e",
        )
    except RuntimeError:
        return []

    commits: list[Commit] = []

    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue

        parts = record.split("\x1f")
        if len(parts) < 2:
            continue

        sha, subject = parts[0], parts[1]
        body = parts[2] if len(parts) > 2 else ""

        commits.append(parse_commit(sha, subject, body))

    return commits


def parse_commit(sha: str, subject: str, body: str) -> Commit:
    commit = Commit(sha=sha, subject=subject, body=body, description=subject)

    match = _CONVENTIONAL_RE.match(subject)
    if match:
        commit.commit_type = match.group("type")
        commit.scope = match.group("scope")
        commit.description = match.group("subject").strip()
        commit.breaking = bool(match.group("breaking"))

    for footer in _BREAKING_FOOTER_RE.finditer(body):
        commit.breaking = True
        commit.breaking_notes.append(footer.group("description").strip())

    return commit


def format_entry(commit: Commit) -> str:
    text = commit.description

    # Capitalise for readability without touching identifiers.
    if text and text[0].islower() and not text.split(" ")[0].isupper():
        text = text[0].upper() + text[1:]

    if commit.scope:
        text = f"**{commit.scope}**: {text}"

    return f"- {text} ({commit.sha[:7]})"


def build_notes(tag: str, previous: str | None, commits: list[Commit],
                repo: str | None) -> str:
    version = tag.lstrip("v")

    lines: list[str] = [f"# AstraRealism v{version}", ""]

    if not commits:
        lines += [
            "No code changes since the previous release.",
            "",
        ]

    # Breaking changes lead, because they are what a reader most needs to see.
    breaking = [c for c in commits if c.breaking]
    if breaking:
        lines.append(f"## {BREAKING_EMOJI} {BREAKING_LABEL}")
        lines.append("")
        for commit in breaking:
            if commit.breaking_notes:
                for note in commit.breaking_notes:
                    lines.append(f"- {note} ({commit.sha[:7]})")
            else:
                lines.append(format_entry(commit))
        lines.append("")

    grouped: dict[str, list[Commit]] = {}
    for commit in commits:
        key = commit.commit_type if commit.commit_type else "__other__"
        if key not in {name for name, _, _ in CATEGORIES}:
            key = "__other__"
        grouped.setdefault(key, []).append(commit)

    for name, label, emoji in CATEGORIES:
        entries = grouped.get(name)
        if not entries:
            continue
        lines.append(f"## {emoji} {label}")
        lines.append("")
        lines += [format_entry(commit) for commit in entries]
        lines.append("")

    other = grouped.get("__other__")
    if other:
        lines.append(f"## {OTHER_EMOJI} {OTHER_LABEL}")
        lines.append("")
        lines += [format_entry(commit) for commit in other]
        lines.append("")

    # --- downloads --------------------------------------------------------
    lines.append("## \U0001F4E5 Downloads")
    lines.append("")
    lines.append(f"- `AstraRealism-v{version}.zip`")
    lines.append("")
    lines.append(
        "Place the `.zip` in `.minecraft/shaderpacks/` without extracting it. "
        "Iris only lists folders and `.zip` archives, so do not rename it."
    )
    lines.append("")

    # --- comparison -------------------------------------------------------
    lines.append("## \U0001F517 Full Changelog")
    lines.append("")
    if previous and repo:
        lines.append(
            f"[{previous}...{tag}](https://github.com/{repo}/compare/{previous}...{tag})"
        )
    elif previous:
        lines.append(f"{previous}...{tag}")
    else:
        lines.append("This is the first release.")
    lines.append("")

    # Drop any trailing blank lines so the output ends cleanly.
    while lines and not lines[-1]:
        lines.pop()

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="the tag being released, e.g. v1.2.0")
    parser.add_argument("--previous", help="override the detected previous tag")
    parser.add_argument("--repo", help="owner/name, used to build the compare link")
    parser.add_argument("--output", help="write to this file instead of stdout")
    args = parser.parse_args()

    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        print(
            f"ERROR: tag '{args.tag}' does not match vMAJOR.MINOR.PATCH",
            file=sys.stderr,
        )
        return 1

    previous = args.previous or previous_tag(args.tag)

    # If the tag does not exist yet (the workflow may generate notes before
    # tagging), fall back to HEAD.
    try:
        run_git("rev-parse", "--verify", f"{args.tag}^{{commit}}")
        until = args.tag
    except RuntimeError:
        until = "HEAD"

    commits = collect_commits(previous, until)

    notes = build_notes(args.tag, previous, commits, args.repo)

    if args.output:
        Path(args.output).write_text(notes, encoding="utf-8", newline="\n")
        print(f"Wrote {args.output} ({len(commits)} commits since {previous or 'the start'})")
    else:
        print(notes, end="")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
