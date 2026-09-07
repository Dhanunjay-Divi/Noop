#!/usr/bin/env python3
"""Reject malformed or backward Homebrew cask version updates."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CASK_VERSION = re.compile(r'^\s*version\s+"([^"]+)"\s*$', re.MULTILINE)


class GateError(RuntimeError):
    """The proposed cask update is invalid."""


def parse_version(value: str, label: str) -> tuple[int, int, int]:
    if VERSION.fullmatch(value) is None:
        raise GateError(f"{label} must be numeric major.minor.patch")
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


def existing_version(path: Path) -> str | None:
    if not path.exists():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("existing cask cannot be read") from error
    matches = CASK_VERSION.findall(text)
    if len(matches) != 1:
        raise GateError("existing cask must contain exactly one version")
    parse_version(matches[0], "existing cask version")
    return matches[0]


def validate(target: str, current: str | None) -> None:
    target_value = parse_version(target, "target version")
    if current is None:
        return
    current_value = parse_version(current, "existing cask version")
    if target_value < current_value:
        raise GateError("Homebrew cask version cannot move backward")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--cask", type=Path, required=True)
    args = parser.parse_args()
    try:
        current = existing_version(args.cask)
        validate(args.target, current)
    except GateError as error:
        print(f"homebrew-version-gate: {error}", file=sys.stderr)
        return 1
    state = "first publication" if current is None else f"current {current}"
    print(f"homebrew-version-gate: target {args.target}, {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
