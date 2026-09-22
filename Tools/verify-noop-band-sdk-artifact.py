#!/usr/bin/env python3
"""Verify the exact source-only NoopBandSDK artifact consumed by the apps."""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
import subprocess
from pathlib import Path, PurePosixPath
from typing import Any


EXPECTED_MANIFEST_SHA256 = (
    "150c3d918b23a27fb49da701e0021f718fba6b2384943fa736cade08ac4b5c53"
)
EXPECTED_SOURCE_REPOSITORY = "Dhanunjay-Divi/NoopBandSDK"
EXPECTED_SOURCE_REVISION = "9bc2eedce34c61d49f68001a973fbbda793d04ed"
EXPORT_DIRECTORIES = ("contract", "production", "test-support")
EXPECTED_INTEGRATION_FILES = {
    "Package.swift": "16fdef516135df5e4df8dd6c260e910e41ca3a6091e9151ba058e8ce2da95053",
    "Tests/NoopBandSDKTests/NoopBandSDKArtifactTests.swift": (
        "6fbf791315521028e9cafd2407f21bfe559912631ef5c716f77dbf35b3f92ce3"
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


def _reject_symlinked_artifact_path(root: Path) -> None:
    absolute_root = root if root.is_absolute() else Path.cwd() / root
    current = Path(absolute_root.anchor)

    for part in absolute_root.parts[1:]:
        if part == "..":
            current = current.parent
            continue
        current /= part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            continue
        except OSError as error:
            raise VerificationError("artifact path ancestors are not inspectable") from error
        if stat.S_ISLNK(mode):
            if current == absolute_root:
                raise VerificationError("artifact root must not be a symlink")
            raise VerificationError("artifact path ancestor must not be a symlink")


def _git_index_paths(root: Path) -> set[str]:
    try:
        repository_result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError("artifact Git worktree is not inspectable") from error
    if repository_result.returncode != 0:
        raise VerificationError("artifact must be inside a Git worktree")

    try:
        repository_root = Path(
            repository_result.stdout.decode("utf-8", errors="strict").strip()
        ).resolve()
        artifact_relative = root.relative_to(repository_root).as_posix()
    except (UnicodeError, ValueError) as error:
        raise VerificationError("artifact Git worktree is invalid") from error

    try:
        index_result = subprocess.run(
            [
                "git",
                "-C",
                str(repository_root),
                "--literal-pathspecs",
                "ls-files",
                "--stage",
                "-z",
                "--",
                artifact_relative,
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError("artifact Git index is not inspectable") from error
    if index_result.returncode != 0:
        raise VerificationError("artifact Git index is not inspectable")

    prefix = f"{artifact_relative.rstrip('/')}/"
    indexed_paths: set[str] = set()
    for raw_entry in index_result.stdout.split(b"\0"):
        if not raw_entry:
            continue
        try:
            metadata, encoded_path = raw_entry.split(b"\t", 1)
            mode, _object_id, stage = metadata.split(b" ", 2)
            indexed_path = encoded_path.decode("utf-8", errors="strict")
        except (UnicodeError, ValueError) as error:
            raise VerificationError("artifact Git index entry is malformed") from error
        if mode != b"100644" or stage != b"0":
            raise VerificationError(
                "artifact Git index must contain only stage-0 regular files"
            )
        if not indexed_path.startswith(prefix):
            raise VerificationError("artifact Git index path escapes the artifact root")
        relative = indexed_path[len(prefix) :]
        pure_path = PurePosixPath(relative)
        if (
            not relative
            or pure_path.is_absolute()
            or ".." in pure_path.parts
            or relative in indexed_paths
        ):
            raise VerificationError("artifact Git index entry is malformed")
        indexed_paths.add(relative)
    return indexed_paths


def verify_artifact(root: Path) -> dict[str, Any]:
    _reject_symlinked_artifact_path(root)
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

    expected_index_paths = (
        {"noop-band-sdk-manifest.json"}
        | set(EXPECTED_INTEGRATION_FILES)
        | listed_paths
    )
    if _git_index_paths(root) != expected_index_paths:
        raise VerificationError("artifact Git index layout is not exact")

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
