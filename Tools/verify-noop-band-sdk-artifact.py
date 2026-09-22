#!/usr/bin/env python3
"""Verify the exact source-only NoopBandSDK artifact consumed by the apps."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Any


EXPECTED_MANIFEST_SHA256 = (
    "cd640939de9ac2509a570081b62ed361314a25b19922d65371dfbec7a4269a14"
)
EXPECTED_SOURCE_REPOSITORY = "Dhanunjay-Divi/NoopBandSDK"
EXPECTED_SOURCE_REVISION = "44559aeb4b1b50af9e6ab8b8dc786f87821c72d9"
EXPORT_DIRECTORIES = ("contract", "production", "test-support")
EXPECTED_INTEGRATION_FILES = {
    "Package.swift": "16fdef516135df5e4df8dd6c260e910e41ca3a6091e9151ba058e8ce2da95053",
    "Tests/NoopBandSDKTests/NoopBandSDKArtifactTests.swift": (
        "316fe2b0b0c067df7a7d93370dfbf8c283a6549d06d075c986c706775652f5d9"
    ),
}
EXPECTED_TOP_LEVEL_ENTRIES = {
    "Package.swift",
    "Tests",
    "contract",
    "noop-band-sdk-manifest.json",
    "production",
    "test-support",
}
FORBIDDEN_SUFFIXES = {
    ".7z",
    ".aar",
    ".apk",
    ".bin",
    ".dfu",
    ".dll",
    ".dylib",
    ".framework",
    ".gz",
    ".hex",
    ".img",
    ".ipa",
    ".jar",
    ".so",
    ".tar",
    ".xcframework",
    ".zip",
}


class VerificationError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _load_unique_json(path: Path) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise VerificationError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        loaded = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=unique_object,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError("manifest is not readable canonical JSON") from error
    if not isinstance(loaded, dict):
        raise VerificationError("manifest root must be an object")
    return loaded


def verify_artifact(root: Path) -> dict[str, Any]:
    if root.is_symlink():
        raise VerificationError("artifact root must not be a symlink")
    root = root.resolve()
    manifest_path = root / "noop-band-sdk-manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise VerificationError("manifest must be a regular file")

    manifest_bytes = manifest_path.read_bytes()
    if sha256(manifest_bytes) != EXPECTED_MANIFEST_SHA256:
        raise VerificationError("manifest digest does not match the approved export")

    manifest = _load_unique_json(manifest_path)
    if set(manifest) != {
        "files",
        "schemaVersion",
        "sourceRepository",
        "sourceRevision",
        "supplierArtifactsIncluded",
    }:
        raise VerificationError("manifest fields do not match schema version 1")
    if manifest["schemaVersion"] != 1:
        raise VerificationError("unsupported manifest schema")
    if manifest["sourceRepository"] != EXPECTED_SOURCE_REPOSITORY:
        raise VerificationError("unexpected source repository")
    if manifest["sourceRevision"] != EXPECTED_SOURCE_REVISION:
        raise VerificationError("unexpected source revision")
    if manifest["supplierArtifactsIncluded"] is not False:
        raise VerificationError("supplier artifacts must not be included")

    for path in root.rglob("*"):
        if path.is_symlink():
            raise VerificationError("artifact tree must not contain symlinks")
        if not path.is_file():
            continue
        lowered = path.name.lower()
        if any(
            lowered.endswith(suffix)
            or f"{suffix}/" in path.as_posix().lower()
            for suffix in FORBIDDEN_SUFFIXES
        ):
            raise VerificationError(
                f"binary or archive payload is forbidden: {path.relative_to(root)}"
            )

    top_level_entries = {path.name for path in root.iterdir()}
    if top_level_entries != EXPECTED_TOP_LEVEL_ENTRIES:
        raise VerificationError("artifact top-level layout is not exact")

    integration_paths = {
        path.relative_to(root).as_posix()
        for path in (root / "Tests").rglob("*")
        if path.is_file()
    }
    integration_paths.add("Package.swift")
    if integration_paths != set(EXPECTED_INTEGRATION_FILES):
        raise VerificationError("integration wrapper tree is not exact")
    for relative, expected_digest in EXPECTED_INTEGRATION_FILES.items():
        file_path = root / relative
        if not file_path.is_file() or file_path.is_symlink():
            raise VerificationError(f"missing integration wrapper file: {relative}")
        if sha256(file_path.read_bytes()) != expected_digest:
            raise VerificationError(f"integration wrapper digest mismatch: {relative}")

    entries = manifest["files"]
    if not isinstance(entries, list) or not entries:
        raise VerificationError("manifest files must be a non-empty list")

    listed_paths: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"bytes", "path", "sha256"}:
            raise VerificationError("invalid manifest file entry")
        relative = entry["path"]
        if not isinstance(relative, str):
            raise VerificationError("manifest path must be a string")
        pure_path = PurePosixPath(relative)
        if pure_path.is_absolute() or ".." in pure_path.parts:
            raise VerificationError("manifest path escapes artifact root")
        if relative in listed_paths:
            raise VerificationError(f"duplicate manifest path: {relative}")
        listed_paths.add(relative)

        file_path = root / relative
        if not file_path.is_file() or file_path.is_symlink():
            raise VerificationError(f"missing regular artifact file: {relative}")
        data = file_path.read_bytes()
        if len(data) != entry["bytes"]:
            raise VerificationError(f"size mismatch: {relative}")
        if sha256(data) != entry["sha256"]:
            raise VerificationError(f"digest mismatch: {relative}")

    exported_paths = {
        path.relative_to(root).as_posix()
        for directory in EXPORT_DIRECTORIES
        for path in (root / directory).rglob("*")
        if path.is_file()
    }
    if exported_paths != listed_paths:
        raise VerificationError("exported source tree differs from the manifest")

    return {
        "files": len(entries),
        "sourceRevision": manifest["sourceRevision"],
        "supplierArtifactsIncluded": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path("Vendor/NoopBandSDK"),
    )
    args = parser.parse_args()
    try:
        result = verify_artifact(args.root)
    except VerificationError as error:
        print(f"NOOP Band SDK artifact verification failed: {error}")
        return 1
    print(
        "NOOP Band SDK artifact verified: "
        f"{result['files']} files, revision {result['sourceRevision']}, "
        "supplier artifacts absent"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
