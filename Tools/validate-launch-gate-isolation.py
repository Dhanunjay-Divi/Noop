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


def setting_names(output: str) -> frozenset[str]:
    """Return names only so callers cannot accidentally log build-setting values."""

    return frozenset(SETTING_PATTERN.findall(output))


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


def build_setting_names(project: Path, configuration: str, target: str) -> frozenset[str]:
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(project),
            "-target",
            target,
            "-configuration",
            configuration,
            "-showBuildSettings",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"xcodebuild could not resolve build settings for {target}")
    return setting_names(result.stdout)


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

    errors: list[str] = []
    for target in (IPHONE_TARGET, *EXTENSION_TARGETS):
        try:
            names = build_setting_names(args.project, args.configuration, target)
        except RuntimeError as error:
            errors.append(str(error))
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
