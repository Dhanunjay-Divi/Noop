#!/usr/bin/env python3
"""Reject non-monotonic Apple or Android release versions and build numbers."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple


ROOT = Path(__file__).resolve().parent.parent
ANDROID_GRADLE = Path("android/app/build.gradle.kts")
APPLE_PROJECT = Path("project.yml")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TAG_PATTERN = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")


class GateError(RuntimeError):
    """A release version or build-number invariant failed."""


class VersionState(NamedTuple):
    version: tuple[int, int, int]
    android_build: int
    apple_build: int


def parse_version(value: str, label: str) -> tuple[int, int, int]:
    if VERSION_PATTERN.fullmatch(value) is None:
        raise GateError(f"{label} must use numeric semantic version x.y.z")
    return tuple(int(component) for component in value.split("."))  # type: ignore[return-value]


def _extract(pattern: str, text: str, label: str) -> str:
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        raise GateError(f"{label} is missing")
    return match.group(1)


def parse_state(android_text: str, apple_text: str) -> VersionState:
    android_version_text = _extract(
        r'^\s*versionName\s*=\s*"([^"]+)"',
        android_text,
        "Android versionName",
    )
    apple_version_text = _extract(
        r'^\s*MARKETING_VERSION:\s*"([^"]+)"',
        apple_text,
        "Apple MARKETING_VERSION",
    )
    if android_version_text != apple_version_text:
        raise GateError("Apple and Android marketing versions differ")
    version = parse_version(android_version_text, "source version")
    android_build = int(
        _extract(
            r"^\s*versionCode\s*=\s*([0-9]+)",
            android_text,
            "Android versionCode",
        )
    )
    apple_build = int(
        _extract(
            r'^\s*CURRENT_PROJECT_VERSION:\s*"([0-9]+)"',
            apple_text,
            "Apple CURRENT_PROJECT_VERSION",
        )
    )
    if android_build <= 0 or apple_build <= 0:
        raise GateError("platform build numbers must be positive")
    return VersionState(version, android_build, apple_build)


def _git_show(root: Path, ref: str, path: Path) -> str:
    result = subprocess.run(
        ["git", "show", f"{ref}:{path.as_posix()}"],
        cwd=root,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise GateError(f"previous release source is unavailable for {path}")
    return result.stdout


def current_state(root: Path) -> VersionState:
    try:
        android_text = (root / ANDROID_GRADLE).read_text(encoding="utf-8")
        apple_text = (root / APPLE_PROJECT).read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("current platform version source is unavailable") from error
    return parse_state(android_text, apple_text)


def previous_state(root: Path, ref: str) -> VersionState:
    match = TAG_PATTERN.fullmatch(ref)
    if match is None:
        raise GateError("previous release ref must be a production vX.Y.Z tag")
    state = parse_state(
        _git_show(root, ref, ANDROID_GRADLE),
        _git_show(root, ref, APPLE_PROJECT),
    )
    if state.version != parse_version(match.group(1), "previous release tag"):
        raise GateError("previous release tag and source version differ")
    return state


def validate_transition(
    current: VersionState,
    expected_version: str,
    previous: VersionState | None,
) -> None:
    expected = parse_version(expected_version, "confirmed version")
    if current.version != expected:
        raise GateError("confirmed version does not match reviewed source")
    if previous is None:
        return
    if current.version <= previous.version:
        raise GateError("release version must advance beyond the previous release")
    if current.android_build <= previous.android_build:
        raise GateError(
            "Android versionCode must advance beyond the previous release"
        )
    if current.apple_build <= previous.apple_build:
        raise GateError(
            "Apple CURRENT_PROJECT_VERSION must advance beyond the previous release"
        )


def validate_existing_tag(
    existing_commit: str | None,
    release_sha: str,
) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", release_sha) is None:
        raise GateError("release SHA must be a full lowercase commit SHA")
    if existing_commit is None:
        return
    if re.fullmatch(r"[0-9a-f]{40}", existing_commit) is None:
        raise GateError("existing release tag target is invalid")
    if existing_commit != release_sha:
        raise GateError("existing release tag points to a different source commit")


def existing_tag_commit(root: Path, version: str) -> str | None:
    tag = f"v{version}"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}"],
        cwd=root,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        raise GateError("existing release tag could not be resolved")
    return result.stdout.strip()


def command_check(args: argparse.Namespace) -> None:
    root = Path(args.root).resolve()
    current = current_state(root)
    previous = (
        previous_state(root, args.previous_ref)
        if args.previous_ref is not None
        else None
    )
    validate_transition(current, args.expected_version, previous)
    if args.release_sha is not None:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        if head.returncode != 0:
            raise GateError("reviewed source commit could not be resolved")
        head_sha = head.stdout.strip()
        if head_sha != args.release_sha:
            raise GateError("release SHA does not match the reviewed checkout")
        validate_existing_tag(
            existing_tag_commit(root, args.expected_version),
            args.release_sha,
        )
    if previous is None:
        print("release-version: first reviewed version and build numbers verified")
    else:
        print(
            "release-version: reviewed version and both platform build numbers "
            "advance"
        )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check")
    check.add_argument("--root", default=str(ROOT))
    check.add_argument("--expected-version", required=True)
    check.add_argument("--release-sha")
    previous = check.add_mutually_exclusive_group(required=True)
    previous.add_argument("--previous-ref")
    previous.add_argument("--first-release", action="store_true")
    check.set_defaults(handler=command_check)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except GateError as error:
        print(f"release-version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
