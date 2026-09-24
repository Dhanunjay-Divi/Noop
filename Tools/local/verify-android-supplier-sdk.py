#!/usr/bin/env python3
"""Verify external Android supplier AARs without copying them into Git."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import subprocess
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile, ZipInfo


CONFIG_RELATIVE_PATH = Path("android/noop-supplier-sdk.properties")
ALLOWED_TRACKED_BINARY = "android/gradle/wrapper/gradle-wrapper.jar"
FORBIDDEN_TRACKED_SUFFIXES = {".aar", ".aab", ".apk", ".jar", ".so"}
FORBIDDEN_ARCHIVE_SUFFIXES = {
    ".aar",
    ".aab",
    ".apk",
    ".dex",
    ".dll",
    ".dylib",
    ".exe",
    ".jar",
    ".so",
    ".zip",
}
CLASS_NAME = re.compile(
    r"[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)+"
)
NATIVE_LIBRARY_NAME = re.compile(r"lib[A-Za-z0-9_.+-]+\.so")
ABI_NAME = re.compile(r"[A-Za-z0-9_.+-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")


class VerificationError(RuntimeError):
    pass


@dataclass(frozen=True)
class ArtifactConfig:
    relative_path: str
    expected_sha256: str
    required_classes: tuple[str, ...]
    native_abis: tuple[str, ...]
    native_libraries: tuple[str, ...]


@dataclass(frozen=True)
class SupplierConfig:
    enabled: bool
    sdk_root: Path | None
    artifacts: tuple[ArtifactConfig, ...]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _strict_properties(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise VerificationError("local supplier config is not readable UTF-8") from error

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise VerificationError(
                f"config line {line_number} must use an unescaped key=value entry"
            )
        raw_key, raw_value = line.split("=", 1)
        key = raw_key.strip()
        value = raw_value.strip()
        if not key or any(character.isspace() for character in key) or "\\" in key:
            raise VerificationError(f"config line {line_number} has an invalid key")
        if key in values:
            raise VerificationError(f"config line {line_number} duplicates {key}")
        values[key] = value
    return values


def _csv(value: str, key: str, pattern: re.Pattern[str]) -> tuple[str, ...]:
    if not value:
        return ()
    entries = tuple(part.strip() for part in value.split(","))
    if any(not entry or pattern.fullmatch(entry) is None for entry in entries):
        raise VerificationError(f"{key} has an invalid comma-separated entry")
    if len(entries) != len(set(entries)):
        raise VerificationError(f"{key} contains a duplicate entry")
    return entries


def load_config(path: Path) -> SupplierConfig:
    if not path.exists():
        return SupplierConfig(enabled=False, sdk_root=None, artifacts=())
    if not path.is_file() or path.is_symlink():
        raise VerificationError("local supplier config must be a regular file")

    values = _strict_properties(path)
    enabled = values.get("enabled")
    if enabled not in {"true", "false"}:
        raise VerificationError("enabled must be exactly true or false")
    if enabled == "false":
        if set(values) != {"enabled"}:
            raise VerificationError("disabled config must contain only enabled=false")
        return SupplierConfig(enabled=False, sdk_root=None, artifacts=())

    root_value = values.get("sdk.root", "")
    sdk_root = Path(root_value)
    if not root_value or not sdk_root.is_absolute():
        raise VerificationError("sdk.root must be an absolute path")

    raw_count = values.get("artifact.count", "")
    try:
        artifact_count = int(raw_count)
    except ValueError as error:
        raise VerificationError("artifact.count must be an integer") from error
    if artifact_count <= 0 or str(artifact_count) != raw_count:
        raise VerificationError("artifact.count must be a canonical positive integer")

    expected_keys = {"enabled", "sdk.root", "artifact.count"}
    artifacts: list[ArtifactConfig] = []
    configured_paths: set[str] = set()
    for index in range(artifact_count):
        prefix = f"artifact.{index}"
        keys = {
            f"{prefix}.path",
            f"{prefix}.sha256",
            f"{prefix}.requiredClasses",
            f"{prefix}.nativeAbis",
            f"{prefix}.nativeLibraries",
        }
        expected_keys.update(keys)
        missing = keys - set(values)
        if missing:
            raise VerificationError(f"missing config key: {sorted(missing)[0]}")

        relative = values[f"{prefix}.path"]
        pure_path = PurePosixPath(relative)
        if (
            not relative
            or pure_path.is_absolute()
            or ".." in pure_path.parts
            or "\\" in relative
            or pure_path.suffix.lower() != ".aar"
        ):
            raise VerificationError(f"{prefix}.path must be a relative AAR path")
        if relative in configured_paths:
            raise VerificationError(f"duplicate configured artifact path: {relative}")
        configured_paths.add(relative)

        expected_digest = values[f"{prefix}.sha256"]
        if SHA256.fullmatch(expected_digest) is None:
            raise VerificationError(f"{prefix}.sha256 must be lowercase SHA-256")

        required_classes = _csv(
            values[f"{prefix}.requiredClasses"],
            f"{prefix}.requiredClasses",
            CLASS_NAME,
        )
        if not required_classes:
            raise VerificationError(f"{prefix}.requiredClasses must not be empty")
        native_abis = _csv(
            values[f"{prefix}.nativeAbis"],
            f"{prefix}.nativeAbis",
            ABI_NAME,
        )
        native_libraries = _csv(
            values[f"{prefix}.nativeLibraries"],
            f"{prefix}.nativeLibraries",
            NATIVE_LIBRARY_NAME,
        )
        if bool(native_abis) != bool(native_libraries):
            raise VerificationError(
                f"{prefix} must configure nativeAbis and nativeLibraries together"
            )

        artifacts.append(
            ArtifactConfig(
                relative_path=relative,
                expected_sha256=expected_digest,
                required_classes=required_classes,
                native_abis=native_abis,
                native_libraries=native_libraries,
            )
        )

    unexpected_keys = set(values) - expected_keys
    if unexpected_keys:
        raise VerificationError(f"unexpected config key: {sorted(unexpected_keys)[0]}")
    return SupplierConfig(
        enabled=True,
        sdk_root=sdk_root,
        artifacts=tuple(artifacts),
    )


def _reject_symlink_path(path: Path, label: str) -> None:
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            continue
        except OSError as error:
            raise VerificationError(f"{label} path is not inspectable") from error
        if stat.S_ISLNK(mode):
            raise VerificationError(f"{label} path must not contain symlinks")


def _git_tracked_paths(repository_root: Path) -> set[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "ls-files", "-z"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError("repository Git index is not inspectable") from error
    if result.returncode != 0:
        raise VerificationError("repository root must be a Git worktree")
    try:
        return {
            entry.decode("utf-8", errors="strict")
            for entry in result.stdout.split(b"\0")
            if entry
        }
    except UnicodeError as error:
        raise VerificationError("repository Git index contains a non-UTF-8 path") from error


def verify_repository_boundary(repository_root: Path) -> None:
    repository_root = repository_root.resolve()
    tracked = _git_tracked_paths(repository_root)
    if CONFIG_RELATIVE_PATH.as_posix() in tracked:
        raise VerificationError("local supplier config must not be tracked")
    if any(path.startswith("android/local-supplier-sdk/") for path in tracked):
        raise VerificationError("local supplier staging files must not be tracked")

    prohibited = sorted(
        path
        for path in tracked
        if PurePosixPath(path).suffix.lower() in FORBIDDEN_TRACKED_SUFFIXES
        and path != ALLOWED_TRACKED_BINARY
    )
    if prohibited:
        raise VerificationError(
            f"prohibited binary artifact is tracked: {prohibited[0]}"
        )


def _validated_members(archive: ZipFile, label: str) -> dict[str, ZipInfo]:
    members: dict[str, ZipInfo] = {}
    for member in archive.infolist():
        name = member.filename
        pure_path = PurePosixPath(name)
        if (
            not name
            or pure_path.is_absolute()
            or ".." in pure_path.parts
            or "\\" in name
            or name in members
        ):
            raise VerificationError(f"{label} has an invalid or duplicate archive path")
        unix_mode = member.external_attr >> 16
        if stat.S_ISLNK(unix_mode):
            raise VerificationError(f"{label} must not contain symlinks")
        members[name] = member
    return members


def _inspect_aar(path: Path, artifact: ArtifactConfig) -> dict[str, object]:
    try:
        with ZipFile(path) as aar:
            members = _validated_members(aar, artifact.relative_path)
            classes_info = members.get("classes.jar")
            if classes_info is None or classes_info.is_dir():
                raise VerificationError(
                    f"{artifact.relative_path} must contain classes.jar"
                )

            unexpected_payloads = sorted(
                name
                for name, member in members.items()
                if not member.is_dir()
                and PurePosixPath(name).suffix.lower() in FORBIDDEN_ARCHIVE_SUFFIXES
                and name != "classes.jar"
                and not name.lower().endswith(".so")
            )
            if unexpected_payloads:
                raise VerificationError(
                    f"{artifact.relative_path} contains an unexpected binary/archive: "
                    f"{unexpected_payloads[0]}"
                )

            actual_native_entries = {
                name
                for name, member in members.items()
                if not member.is_dir() and name.lower().endswith(".so")
            }
            expected_native_entries = {
                f"jni/{abi}/{library}"
                for abi in artifact.native_abis
                for library in artifact.native_libraries
            }
            if actual_native_entries != expected_native_entries:
                raise VerificationError(
                    f"{artifact.relative_path} native binary inventory does not match config"
                )

            try:
                with ZipFile(BytesIO(aar.read(classes_info))) as classes_jar:
                    class_members = _validated_members(
                        classes_jar,
                        f"{artifact.relative_path}!classes.jar",
                    )
            except BadZipFile as error:
                raise VerificationError(
                    f"{artifact.relative_path} classes.jar is invalid"
                ) from error
    except BadZipFile as error:
        raise VerificationError(f"{artifact.relative_path} is not a valid AAR") from error

    required_paths = {
        class_name.replace(".", "/") + ".class"
        for class_name in artifact.required_classes
    }
    missing_classes = sorted(required_paths - set(class_members))
    if missing_classes:
        raise VerificationError(
            f"{artifact.relative_path} is missing required class "
            f"{missing_classes[0].removesuffix('.class').replace('/', '.')}"
        )

    return {
        "path": artifact.relative_path,
        "sha256": artifact.expected_sha256,
        "bytes": path.stat().st_size,
        "classCount": sum(name.endswith(".class") for name in class_members),
        "nativeAbis": sorted(artifact.native_abis),
        "nativeLibraries": sorted(artifact.native_libraries),
    }


def verify(
    config_path: Path,
    repository_root: Path,
    *,
    repository_only: bool = False,
) -> dict[str, object]:
    repository_root = repository_root.resolve()
    verify_repository_boundary(repository_root)
    if repository_only:
        return {"enabled": False, "artifacts": []}

    expected_config_path = repository_root / CONFIG_RELATIVE_PATH
    if config_path.resolve(strict=False) != expected_config_path.resolve(strict=False):
        raise VerificationError(
            f"config must be {CONFIG_RELATIVE_PATH.as_posix()} in the worktree"
        )
    _reject_symlink_path(config_path, "local supplier config")
    config = load_config(config_path)
    if not config.enabled:
        return {"enabled": False, "artifacts": []}

    assert config.sdk_root is not None
    _reject_symlink_path(config.sdk_root, "supplier SDK root")
    if not config.sdk_root.is_dir():
        raise VerificationError("supplier SDK root must be a directory")
    resolved_sdk_root = config.sdk_root.resolve()
    try:
        resolved_sdk_root.relative_to(repository_root)
    except ValueError:
        pass
    else:
        raise VerificationError("supplier SDK root must remain outside the repository")

    inventory: list[dict[str, object]] = []
    resolved_artifacts: set[Path] = set()
    for artifact in config.artifacts:
        path = config.sdk_root / artifact.relative_path
        _reject_symlink_path(path, artifact.relative_path)
        if not path.is_file():
            raise VerificationError(f"missing supplier artifact: {artifact.relative_path}")
        resolved_path = path.resolve()
        try:
            resolved_path.relative_to(resolved_sdk_root)
        except ValueError as error:
            raise VerificationError(
                f"supplier artifact escapes sdk.root: {artifact.relative_path}"
            ) from error
        if resolved_path in resolved_artifacts:
            raise VerificationError("multiple config entries resolve to one artifact")
        resolved_artifacts.add(resolved_path)

        actual_digest = _sha256(path)
        if actual_digest != artifact.expected_sha256:
            raise VerificationError(
                f"supplier artifact digest mismatch: {artifact.relative_path}"
            )
        inventory.append(_inspect_aar(path, artifact))

    return {"enabled": True, "artifacts": inventory}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_RELATIVE_PATH,
    )
    parser.add_argument("--repository-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    config_path = args.config
    if not config_path.is_absolute():
        config_path = args.repo_root / config_path
    try:
        result = verify(
            config_path,
            args.repo_root,
            repository_only=args.repository_only,
        )
    except VerificationError as error:
        print(f"Android supplier SDK verification failed: {error}")
        return 1

    if args.json:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    elif result["enabled"]:
        artifacts = result["artifacts"]
        print(f"Android supplier SDK verified: {len(artifacts)} exact AARs")
        for artifact in artifacts:
            print(
                f"{artifact['path']} sha256={artifact['sha256']} "
                f"bytes={artifact['bytes']} classes={artifact['classCount']} "
                f"abis={','.join(artifact['nativeAbis']) or 'none'}"
            )
    else:
        print("Android supplier SDK disabled; repository binary boundary verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
