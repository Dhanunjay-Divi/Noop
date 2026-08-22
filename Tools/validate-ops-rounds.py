#!/usr/bin/env python3
"""Validate NOOP's checked-in operations record without modifying it."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


REQUIRED_FILES = (
    "docs/ops/README.md",
    "docs/ops/ACTIVE.md",
    "docs/ops/HISTORY.md",
    "docs/ops/DECISIONS.md",
    "docs/ops/ROUND_TEMPLATE.md",
    "docs/ops/rounds/INDEX.md",
)

REQUIRED_HEADINGS = (
    "## Status",
    "## Objective",
    "## Scope",
    "## Starting evidence",
    "## Delivered",
    "## Data, privacy, and medical truth",
    "## Evidence",
    "## Physical device and deployment",
    "## Git and release state",
    "## Decisions",
    "## Open risks and honest limitations",
    "## Next round",
    "## Privacy check",
)

PRIVATE_PATTERNS = (
    (re.compile(r"/Users/[^/\s]+/"), "absolute macOS user path"),
    (
        re.compile(r"[A-Z]:\\\\Users\\\\[^\\\s]+\\\\", re.IGNORECASE),
        "absolute Windows user path",
    ),
    (
        re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
        "email address",
    ),
    (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "private key"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"), "GitHub token"),
)


def git_root(start: Path) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=start,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"not inside a Git repository: {start}")
    return Path(result.stdout.strip())


def validate_privacy(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    for pattern, label in PRIVATE_PATTERNS:
        if pattern.search(text):
            errors.append(f"{path}: contains {label}")
    return errors


def validate_round(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    if not text.startswith("# Round:"):
        errors.append(f"{path}: first heading must start with '# Round:'")
    for heading in REQUIRED_HEADINGS:
        if heading not in text:
            errors.append(f"{path}: missing heading {heading!r}")
    if "YYYY-MM-DD" in text or "planned | in progress" in text:
        errors.append(f"{path}: unresolved template placeholder")
    return errors


def validate_index(root: Path, rounds: list[Path]) -> list[str]:
    errors: list[str] = []
    index = root / "docs/ops/rounds/INDEX.md"
    text = index.read_text(encoding="utf-8")
    for round_path in rounds:
        if round_path.name not in text:
            errors.append(f"{index}: missing link to {round_path.name}")
    for target in re.findall(r"\(([^)]+\.md)\)", text):
        linked = (index.parent / target).resolve()
        if not linked.is_file():
            errors.append(f"{index}: broken round link {target}")
    return errors


def changed_paths(root: Path, base: str) -> tuple[list[str], str | None]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return [], result.stderr.strip() or f"could not compare with {base}"
    return [line for line in result.stdout.splitlines() if line], None


def validate_round_changed(root: Path, base: str) -> list[str]:
    changed, failure = changed_paths(root, base)
    if failure:
        return [failure]
    if not changed:
        return []
    round_changes = [
        path
        for path in changed
        if path.startswith("docs/ops/rounds/")
        and path.endswith(".md")
        and path != "docs/ops/rounds/INDEX.md"
        and (root / path).is_file()
    ]
    if round_changes:
        return []
    return [
        "this change has no material round record under docs/ops/rounds/; "
        "create or update one and add it to INDEX.md"
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", nargs="?", default=".", help="repository root or path inside it")
    parser.add_argument("--all", action="store_true", help="validate every round instead of only the newest")
    parser.add_argument(
        "--require-round-change",
        metavar="BASE",
        help="require this branch to change a round record compared with BASE",
    )
    args = parser.parse_args()

    try:
        root = git_root(Path(args.repo).resolve())
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    errors: list[str] = []
    for relative in REQUIRED_FILES:
        path = root / relative
        if not path.is_file():
            errors.append(f"missing required file: {relative}")

    rounds_dir = root / "docs/ops/rounds"
    rounds = sorted(path for path in rounds_dir.glob("*.md") if path.name != "INDEX.md")
    if not rounds:
        errors.append("no round records found")
    else:
        selected = rounds if args.all else [rounds[-1]]
        for path in selected:
            errors.extend(validate_round(path))

    ops_docs = sorted((root / "docs/ops").rglob("*.md"))
    for path in ops_docs:
        errors.extend(validate_privacy(path))

    if (root / "docs/ops/rounds/INDEX.md").is_file():
        errors.extend(validate_index(root, rounds))

    if args.require_round_change:
        errors.extend(validate_round_changed(root, args.require_round_change))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    count = len(rounds) if args.all else min(1, len(rounds))
    print(f"OK: validated {count} round record(s) in {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
