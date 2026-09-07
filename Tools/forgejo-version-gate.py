#!/usr/bin/env python3
"""Reject a Forgejo mirror release older than its published stable history."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TAG = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")


class GateError(RuntimeError):
    """The proposed Forgejo mirror version is invalid."""


def parse_version(value: str, label: str) -> tuple[int, int, int]:
    if VERSION.fullmatch(value) is None:
        raise GateError(f"{label} must be numeric major.minor.patch")
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


def latest_published_version(releases: Any) -> str | None:
    if not isinstance(releases, list):
        raise GateError("Forgejo release history must be a JSON array")
    latest: tuple[tuple[int, int, int], str] | None = None
    for release in releases:
        if not isinstance(release, dict):
            raise GateError("Forgejo release history contains an invalid entry")
        draft = release.get("draft")
        prerelease = release.get("prerelease")
        tag = release.get("tag_name")
        if (
            not isinstance(draft, bool)
            or not isinstance(prerelease, bool)
            or not isinstance(tag, str)
        ):
            raise GateError("Forgejo release history contains an invalid entry")
        if draft or prerelease:
            continue
        match = TAG.fullmatch(tag)
        if match is None:
            continue
        version = match.group(1)
        parsed = parse_version(version, "published Forgejo version")
        if latest is None or parsed > latest[0]:
            latest = parsed, version
    return latest[1] if latest is not None else None


def validate(target: str, current: str | None) -> None:
    target_value = parse_version(target, "target version")
    if current is None:
        return
    current_value = parse_version(current, "published Forgejo version")
    if target_value < current_value:
        raise GateError("Forgejo mirror version cannot move backward")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    try:
        releases = json.load(sys.stdin)
        current = latest_published_version(releases)
        validate(args.target, current)
    except (json.JSONDecodeError, OSError) as error:
        print(
            "forgejo-version-gate: Forgejo release history is invalid",
            file=sys.stderr,
        )
        return 1
    except GateError as error:
        print(f"forgejo-version-gate: {error}", file=sys.stderr)
        return 1
    state = "first publication" if current is None else f"current {current}"
    print(f"forgejo-version-gate: target {args.target}, {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
