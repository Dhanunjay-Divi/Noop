#!/usr/bin/env python3
"""Burn-down ratchet for source lines still attributable to the shared root commit.

WHY THIS EXISTS
This repository shares its root commit (ecaabdc0) with a public upstream project that carries no
licence. Absent a licence, all rights are reserved, so those specific lines are the concrete
exposure. Everything authored after that commit is NOOP's own.

The number matters more than the argument. When this was first measured on 2026-08-26 it was
11,821 lines across 69 files, which is 2.1% of a 561,438-line tree: 97.9% of the code is already
NOOP's. That makes replacement a finite, enumerable job rather than an open-ended worry, and this
script exists so progress is measured instead of asserted.

WHAT THIS DOES AND DOES NOT PROVE
It counts surviving lines. It does NOT establish that reaching zero cures derivative-work status:

  * Rewriting a file while reading the original is a rewrite, not a clean-room reimplementation.
    Clean-room means implementers who have never seen the upstream source working from documented
    facts, with records kept. That distinction is the whole point of the exercise, and this script
    cannot tell the difference.
  * Structure, architecture, data model and naming can carry derivation even after every line
    differs. A zero here does not speak to any of that.

So treat this as a project-management instrument, not a legal one. The cheapest resolution remains
asking the upstream author for an explicit licence grant, because they currently hold all rights
and are therefore free to grant them.

USAGE
    python3 Tools/provenance_ratchet.py            # report, and fail if the count went UP
    python3 Tools/provenance_ratchet.py --list     # show every remaining file, worst first
    python3 Tools/provenance_ratchet.py --update   # lower the pin after genuine replacement work
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROOT_COMMIT = "ecaabdc0"
PIN_PATH = ROOT / "docs" / "provenance" / "root-commit-lines.json"
CODE_SUFFIXES = {".swift", ".kt", ".py", ".ts", ".js", ".rs", ".java", ".rb"}


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-P", *args], cwd=ROOT, capture_output=True, text=True
    ).stdout


def tracked_code_files() -> list[str]:
    out = git("ls-files")
    return [p for p in out.splitlines() if Path(p).suffix in CODE_SUFFIXES]


def root_lines(path: str) -> int:
    """Lines in `path` whose blame lands on the shared root commit."""
    blame = git("blame", "--line-porcelain", "--", path)
    if not blame:
        return 0
    return sum(1 for line in blame.splitlines() if line.startswith(ROOT_COMMIT))


def measure() -> tuple[int, dict[str, int]]:
    per_file: dict[str, int] = {}
    for path in tracked_code_files():
        n = root_lines(path)
        if n:
            per_file[path] = n
    return sum(per_file.values()), per_file


def load_pin() -> dict:
    if not PIN_PATH.is_file():
        return {}
    return json.loads(PIN_PATH.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="list remaining files, worst first")
    ap.add_argument("--update", action="store_true", help="lower the pin after replacement work")
    args = ap.parse_args()

    total, per_file = measure()
    pin = load_pin()
    pinned = pin.get("maxLines")

    print(f"root-commit lines remaining: {total} across {len(per_file)} file(s)")
    if pinned is not None:
        print(f"pinned ceiling:              {pinned}")

    if args.list:
        print("\nremaining, worst first:")
        for path, n in sorted(per_file.items(), key=lambda kv: -kv[1]):
            print(f"  {n:6d}  {path}")

    if args.update:
        PIN_PATH.parent.mkdir(parents=True, exist_ok=True)
        PIN_PATH.write_text(
            json.dumps(
                {
                    "rootCommit": ROOT_COMMIT,
                    "maxLines": total,
                    "fileCount": len(per_file),
                    "note": (
                        "Ceiling for source lines still attributable to the shared root commit. "
                        "May only decrease. Reaching zero does not by itself cure derivative-work "
                        "status: see the header of Tools/provenance_ratchet.py."
                    ),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"\npin updated to {total}")
        return 0

    if pinned is None:
        print("\nno pin recorded yet; run with --update to establish one")
        return 0

    if total > pinned:
        print(
            f"\nFAIL: root-commit lines went UP ({pinned} -> {total}). "
            "Reintroducing upstream expression moves the wrong way; revert or justify."
        )
        return 1

    if total < pinned:
        print(
            f"\nProgress: {pinned - total} line(s) replaced since the pin. "
            "Run with --update to lower the ceiling and lock the gain in."
        )
    else:
        print("\nOK: unchanged, at the pinned ceiling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
