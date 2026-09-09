#!/usr/bin/env python3
"""Verify that launch-gate verifier build settings are iPhone-only.

The checker deliberately retains only build-setting names. It never prints or persists values from
``xcodebuild -showBuildSettings``, which can contain the ignored verifier configuration.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


PUBLIC_SETTINGS = frozenset(
    {
        "APP_GROUP_ID",
        "NOOP_LAUNCH_GATE_REQUIRED",
        "NOOP_LAUNCH_GATE_VERSION",
    }
)
IPHONE_ONLY_SETTINGS = frozenset(
    {
        "NOOP_LAUNCH_GATE_ITERATIONS",
        "NOOP_LAUNCH_GATE_SALT_HEX",
        "NOOP_LAUNCH_GATE_VERIFIER_HEX",
    }
)
IPHONE_TARGET = "NOOPiOS"
EXTENSION_TARGETS = (
    "NOOPiOSWidgets",
    "NOOPWatch",
    "NOOPWatchComplications",
)
SETTING_PATTERN = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=", re.MULTILINE)
TARGET_HEADER_PATTERN = re.compile(
    r"^Build settings for action [^ ]+ and target (.+):$"
)
SETTING_LINE_PATTERN = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=")


def setting_names(output: str) -> frozenset[str]:
    """Return names only so callers cannot accidentally log build-setting values."""

    return frozenset(SETTING_PATTERN.findall(output))


def target_setting_names(
    output: str,
    targets: tuple[str, ...],
) -> dict[str, frozenset[str]]:
    """Group setting names by target without retaining any setting values."""

    expected = set(targets)
    grouped: dict[str, set[str]] = {}
    current_target: str | None = None
    for line in output.splitlines():
        header = TARGET_HEADER_PATTERN.match(line)
        if header:
            candidate = header.group(1)
            current_target = candidate if candidate in expected else None
            if current_target is not None:
                grouped.setdefault(current_target, set())
            continue
        if current_target is None:
            continue
        setting = SETTING_LINE_PATTERN.match(line)
        if setting:
            grouped[current_target].add(setting.group(1))
    return {target: frozenset(names) for target, names in grouped.items()}


def target_errors(
    target: str,
    names: frozenset[str],
    *,
    require_iphone_private: bool = True,
) -> list[str]:
    errors: list[str] = []
    missing_public = PUBLIC_SETTINGS - names
    if missing_public:
        errors.append(f"{target}: missing public settings: {', '.join(sorted(missing_public))}")

    if target == IPHONE_TARGET:
        if require_iphone_private:
            missing_private = IPHONE_ONLY_SETTINGS - names
            if missing_private:
                errors.append(
                    f"{target}: missing iPhone-only settings: {', '.join(sorted(missing_private))}"
                )
    else:
        leaked = IPHONE_ONLY_SETTINGS & names
        if leaked:
            errors.append(f"{target}: inherited forbidden settings: {', '.join(sorted(leaked))}")
    return errors


def build_setting_names(
    project: Path,
    configuration: str,
    targets: tuple[str, ...],
) -> dict[str, frozenset[str]]:
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(project),
            "-configuration",
            configuration,
            "-alltargets",
            "-showBuildSettings",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("xcodebuild could not resolve project build settings")
    return target_setting_names(result.stdout, targets)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, default=Path("Strand.xcodeproj"))
    parser.add_argument("--configuration", default="Release")
    parser.add_argument(
        "--allow-missing-iphone-secrets",
        action="store_true",
        help=(
            "permit an unsigned clean-checkout build to omit the ignored iPhone verifier "
            "while still rejecting verifier settings inherited by embedded targets"
        ),
    )
    args = parser.parse_args()

    if not args.project.is_dir():
        print("launch-gate isolation: generate the Xcode project first", file=sys.stderr)
        return 2

    targets = (IPHONE_TARGET, *EXTENSION_TARGETS)
    errors: list[str] = []
    try:
        names_by_target = build_setting_names(
            args.project,
            args.configuration,
            targets,
        )
    except RuntimeError as error:
        errors.append(str(error))
        names_by_target = {}

    for target in targets:
        names = names_by_target.get(target)
        if names is None:
            errors.append(f"{target}: build settings were not returned")
            continue
        errors.extend(
            target_errors(
                target,
                names,
                require_iphone_private=not args.allow_missing_iphone_secrets,
            )
        )

    if errors:
        for error in errors:
            print(f"launch-gate isolation: {error}", file=sys.stderr)
        return 1

    print("launch-gate isolation: iPhone-only verifier settings confirmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
