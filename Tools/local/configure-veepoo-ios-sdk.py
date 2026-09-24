#!/usr/bin/env python3
"""Verify and optionally enable the approved local Veepoo iPhoneOS SDK."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path, PurePosixPath
from typing import NamedTuple


EXPECTED_SDK_ROOT = Path(
    "/Users/divii/Downloads/SDK/iOS_Ble_SDK-master/iOS_sdk_source"
)
EXPECTED_FRAMEWORK_PATH = (
    EXPECTED_SDK_ROOT / "Framework/2.2.XX.15/VeepooBleSDK.framework"
)
EXPECTED_DEMO_ROOT = Path(
    EXPECTED_SDK_ROOT / "Demo/VeepooBleSDKDemo"
)
EXPECTED_VENDOR_FRAMEWORK_DIR = EXPECTED_DEMO_ROOT / "VeepooBleSDKDemo"
EXPECTED_PODS_PROJECT = EXPECTED_DEMO_ROOT / "Pods" / "Pods.xcodeproj"
EXPECTED_PODS_BUILD_ROOT = EXPECTED_DEMO_ROOT / "build"
EXPECTED_PODS_PRODUCTS_ROOT = EXPECTED_PODS_BUILD_ROOT / "Debug-iphoneos"
EXPECTED_FMDB_FRAMEWORK_DIR = EXPECTED_PODS_PRODUCTS_ROOT / "FMDB"
EXPECTED_MJEXTENSION_FRAMEWORK_DIR = EXPECTED_PODS_PRODUCTS_ROOT / "MJExtension"
EXPECTED_BINARY_SHA256 = (
    "22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35"
)
EXPECTED_VENDOR_FRAMEWORK_SHA256 = {
    "ABParTool": "585f084f6955f5da0abc7d57eacaa123c0a0342016238770119cab077a74e39b",
    "DFUnits": "9fdd6bf728f2733051ccb1aeaf9c8035b8916556401b1e0c932d27e2673f0100",
    "GRDFUSDK": "8a84fde46a0f9fdb36a8aa1150afa6f01ad054abf9621e74385de8fcf2ade499",
    "JLDialUnit": "3bcd10c92d490187ff8b441bedbae9f7bb3ff32918d4130d6db7156be8737146",
    "JL_BLEKit": "e35bb7b223f35f624af8323aa6ed39b8356e0694bfffd10ecd3925026ce4aa48",
    "ZipZap": "a9fe0ba509e08b4bc13b7f41f7770596d1496fca297d1ff032d0d7e1e6cc51c2",
}
EXPECTED_LINK_FLAGS = (
    "-ObjC "
    "-framework VeepooBleSDK "
    "-framework ABParTool "
    "-framework DFUnits "
    "-framework GRDFUSDK "
    "-framework JLDialUnit "
    "-framework JL_BLEKit "
    "-framework ZipZap "
    "-framework FMDB "
    "-framework MJExtension "
    "-lsqlite3 -lz"
)
EXPECTED_EXECUTABLE_NAME = "VeepooBleSDK"
EXPECTED_ARCHITECTURES = ("arm64",)
EXPECTED_PLATFORM_NAME = "iphoneos"
EXPECTED_SUPPORTED_PLATFORMS = ("iPhoneOS",)
LOCAL_CONFIG_RELATIVE_PATH = Path("Config/VeepooLocalSDK.xcconfig")
TRUST_RELATIVE_PATH = Path("release/supplier/ios-artifact-trust.json")
EXPECTED_BUILD_FILE_PATHS = (
    "Demo/VeepooBleSDKDemo/Podfile",
    "Demo/VeepooBleSDKDemo/Podfile.lock",
)
EXPECTED_BUILD_TREE_PATHS = ("Demo/VeepooBleSDKDemo/Pods",)
EXPECTED_GENERATED_FRAMEWORK_PATHS = {
    "FMDB": (
        "Demo/VeepooBleSDKDemo/build/Debug-iphoneos/"
        "FMDB/FMDB.framework"
    ),
    "MJExtension": (
        "Demo/VeepooBleSDKDemo/build/Debug-iphoneos/"
        "MJExtension/MJExtension.framework"
    ),
}
MAX_BINARY_BYTES = 32 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 4096
MAX_TRUST_ROOT_BYTES = 256 * 1024
MAX_INVENTORY_FILES = 4096
MAX_INVENTORY_BYTES = 512 * 1024 * 1024
COMMAND_TIMEOUT_SECONDS = 10
DEPENDENCY_BUILD_TIMEOUT_SECONDS = 600
SHA256 = re.compile(r"[0-9a-f]{64}")


class VerificationError(RuntimeError):
    pass


class FileTrust(NamedTuple):
    relative_path: str
    sha256: str


class TreeTrust(NamedTuple):
    relative_path: str
    file_count: int
    total_bytes: int
    inventory_sha256: str


class GeneratedFrameworkTrust(NamedTuple):
    name: str
    relative_path: str
    binary_sha256: str
    file_count: int
    total_bytes: int
    inventory_sha256: str


class IOSSupplierTrustRoot(NamedTuple):
    build_files: tuple[FileTrust, ...]
    build_trees: tuple[TreeTrust, ...]
    generated_frameworks: tuple[GeneratedFrameworkTrust, ...]


class TreeInventory(NamedTuple):
    file_count: int
    total_bytes: int
    sha256: str


def _absolute(path: Path) -> Path:
    return Path(os.path.abspath(path))


def _reject_symlinked_path(
    path: Path,
    label: str = "approved framework",
) -> None:
    if not path.is_absolute():
        raise VerificationError(f"{label} path must be absolute")

    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError as error:
            raise VerificationError(f"{label} path is incomplete") from error
        except OSError as error:
            raise VerificationError(f"{label} path is not inspectable") from error
        if stat.S_ISLNK(mode):
            raise VerificationError(f"{label} path must not contain symlinks")


def _regular_file(path: Path, *, maximum_bytes: int, label: str) -> int:
    try:
        file_stat = path.lstat()
    except OSError as error:
        raise VerificationError(f"{label} is not readable") from error
    if not stat.S_ISREG(file_stat.st_mode):
        raise VerificationError(f"{label} must be a regular file")
    if file_stat.st_size <= 0 or file_stat.st_size > maximum_bytes:
        raise VerificationError(f"{label} size is outside the approved bound")
    return file_stat.st_size


def _sha256_file(path: Path, *, label: str = "file") -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise VerificationError(f"{label} could not be hashed") from error
    return digest.hexdigest()


def _relative_path(value: object, *, label: str) -> str:
    if not isinstance(value, str):
        raise VerificationError(f"{label} must be a string")
    candidate = PurePosixPath(value)
    if (
        not value
        or candidate.is_absolute()
        or "." in candidate.parts
        or ".." in candidate.parts
        or "\\" in value
        or value != candidate.as_posix()
    ):
        raise VerificationError(f"{label} must be a canonical relative path")
    return value


def _digest(value: object, *, label: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        raise VerificationError(f"{label} must be lowercase SHA-256")
    return value


def _canonical_nonnegative_integer(value: object, *, label: str) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 0
    ):
        raise VerificationError(f"{label} must be a nonnegative integer")
    return value


def _tree_inventory(
    root: Path,
    *,
    label: str,
    maximum_files: int = MAX_INVENTORY_FILES,
    maximum_bytes: int = MAX_INVENTORY_BYTES,
) -> TreeInventory:
    root = _absolute(root)
    _reject_symlinked_path(root, label)
    try:
        root_stat = root.lstat()
    except OSError as error:
        raise VerificationError(f"{label} is not readable") from error
    if not stat.S_ISDIR(root_stat.st_mode):
        raise VerificationError(f"{label} must be a directory")

    records: list[tuple[str, int, str]] = []
    total_bytes = 0
    for directory, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        directory_path = Path(directory)
        directory_names.sort()
        file_names.sort()
        for entry_name in (*directory_names, *file_names):
            entry_path = directory_path / entry_name
            try:
                entry_stat = entry_path.lstat()
            except OSError as error:
                raise VerificationError(
                    f"{label} inventory is not inspectable"
                ) from error
            if stat.S_ISLNK(entry_stat.st_mode):
                raise VerificationError(
                    f"{label} inventory must not contain symlinks"
                )
            if entry_name in directory_names:
                if not stat.S_ISDIR(entry_stat.st_mode):
                    raise VerificationError(
                        f"{label} inventory contains an invalid directory entry"
                    )
                continue
            if not stat.S_ISREG(entry_stat.st_mode):
                raise VerificationError(
                    f"{label} inventory must contain regular files only"
                )
            relative = entry_path.relative_to(root).as_posix()
            total_bytes += entry_stat.st_size
            if (
                len(records) >= maximum_files
                or total_bytes > maximum_bytes
            ):
                raise VerificationError(
                    f"{label} inventory exceeds its approved bound"
                )
            records.append(
                (
                    relative,
                    entry_stat.st_size,
                    _sha256_file(entry_path, label=f"{label} inventory file"),
                )
            )

    if not records:
        raise VerificationError(f"{label} inventory must not be empty")
    inventory_digest = hashlib.sha256()
    for relative, file_bytes, file_digest in records:
        inventory_digest.update(relative.encode("utf-8", errors="strict"))
        inventory_digest.update(b"\0")
        inventory_digest.update(str(file_bytes).encode("ascii"))
        inventory_digest.update(b"\0")
        inventory_digest.update(file_digest.encode("ascii"))
        inventory_digest.update(b"\n")
    return TreeInventory(
        file_count=len(records),
        total_bytes=total_bytes,
        sha256=inventory_digest.hexdigest(),
    )


def _git_tracked_paths(repository_root: Path) -> set[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "ls-files", "-z"],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(
            "repository Git index is not inspectable"
        ) from error
    if result.returncode != 0:
        raise VerificationError("repository root must be a Git worktree")
    try:
        return {
            entry.decode("utf-8", errors="strict")
            for entry in result.stdout.split(b"\0")
            if entry
        }
    except UnicodeError as error:
        raise VerificationError(
            "repository Git index contains a non-UTF-8 path"
        ) from error


def verify_repository_boundary(repository_root: Path) -> None:
    repository_root = _absolute(repository_root)
    tracked = _git_tracked_paths(repository_root)
    if TRUST_RELATIVE_PATH.as_posix() not in tracked:
        raise VerificationError("iOS supplier trust root must be tracked")
    if LOCAL_CONFIG_RELATIVE_PATH.as_posix() in tracked:
        raise VerificationError("local iOS supplier config must not be tracked")


def load_trust_root(path: Path) -> IOSSupplierTrustRoot:
    path = _absolute(path)
    _reject_symlinked_path(path, "iOS supplier trust root")
    _regular_file(
        path,
        maximum_bytes=MAX_TRUST_ROOT_BYTES,
        label="iOS supplier trust root",
    )
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(
            "iOS supplier trust root is not valid UTF-8 JSON"
        ) from error
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "buildInputs",
        "generatedFrameworks",
    }:
        raise VerificationError(
            "iOS supplier trust root has unexpected fields"
        )
    if document["schemaVersion"] != 1:
        raise VerificationError(
            "iOS supplier trust root schemaVersion must be 1"
        )

    build_inputs = document["buildInputs"]
    if not isinstance(build_inputs, dict) or set(build_inputs) != {
        "files",
        "trees",
    }:
        raise VerificationError(
            "iOS supplier buildInputs has unexpected fields"
        )
    raw_files = build_inputs["files"]
    raw_trees = build_inputs["trees"]
    raw_frameworks = document["generatedFrameworks"]
    if not isinstance(raw_files, list):
        raise VerificationError("iOS supplier build files must be an array")
    if not isinstance(raw_trees, list):
        raise VerificationError("iOS supplier build trees must be an array")
    if not isinstance(raw_frameworks, list):
        raise VerificationError(
            "iOS supplier generatedFrameworks must be an array"
        )

    build_files: list[FileTrust] = []
    for index, value in enumerate(raw_files):
        label = f"iOS supplier build file {index}"
        if not isinstance(value, dict) or set(value) != {"path", "sha256"}:
            raise VerificationError(f"{label} has unexpected fields")
        build_files.append(
            FileTrust(
                relative_path=_relative_path(
                    value["path"],
                    label=f"{label}.path",
                ),
                sha256=_digest(
                    value["sha256"],
                    label=f"{label}.sha256",
                ),
            )
        )

    build_trees: list[TreeTrust] = []
    for index, value in enumerate(raw_trees):
        label = f"iOS supplier build tree {index}"
        if not isinstance(value, dict) or set(value) != {
            "path",
            "fileCount",
            "bytes",
            "inventorySha256",
        }:
            raise VerificationError(f"{label} has unexpected fields")
        build_trees.append(
            TreeTrust(
                relative_path=_relative_path(
                    value["path"],
                    label=f"{label}.path",
                ),
                file_count=_canonical_nonnegative_integer(
                    value["fileCount"],
                    label=f"{label}.fileCount",
                ),
                total_bytes=_canonical_nonnegative_integer(
                    value["bytes"],
                    label=f"{label}.bytes",
                ),
                inventory_sha256=_digest(
                    value["inventorySha256"],
                    label=f"{label}.inventorySha256",
                ),
            )
        )

    generated_frameworks: list[GeneratedFrameworkTrust] = []
    for index, value in enumerate(raw_frameworks):
        label = f"iOS supplier generated framework {index}"
        if not isinstance(value, dict) or set(value) != {
            "name",
            "path",
            "binarySha256",
            "fileCount",
            "bytes",
            "inventorySha256",
        }:
            raise VerificationError(f"{label} has unexpected fields")
        name = value["name"]
        if not isinstance(name, str) or not name:
            raise VerificationError(f"{label}.name must be a string")
        generated_frameworks.append(
            GeneratedFrameworkTrust(
                name=name,
                relative_path=_relative_path(
                    value["path"],
                    label=f"{label}.path",
                ),
                binary_sha256=_digest(
                    value["binarySha256"],
                    label=f"{label}.binarySha256",
                ),
                file_count=_canonical_nonnegative_integer(
                    value["fileCount"],
                    label=f"{label}.fileCount",
                ),
                total_bytes=_canonical_nonnegative_integer(
                    value["bytes"],
                    label=f"{label}.bytes",
                ),
                inventory_sha256=_digest(
                    value["inventorySha256"],
                    label=f"{label}.inventorySha256",
                ),
            )
        )

    if tuple(entry.relative_path for entry in build_files) != (
        EXPECTED_BUILD_FILE_PATHS
    ):
        raise VerificationError(
            "iOS supplier build file inventory is not approved"
        )
    if tuple(entry.relative_path for entry in build_trees) != (
        EXPECTED_BUILD_TREE_PATHS
    ):
        raise VerificationError(
            "iOS supplier build tree inventory is not approved"
        )
    expected_framework_entries = tuple(
        sorted(EXPECTED_GENERATED_FRAMEWORK_PATHS.items())
    )
    actual_framework_entries = tuple(
        (entry.name, entry.relative_path)
        for entry in generated_frameworks
    )
    if actual_framework_entries != expected_framework_entries:
        raise VerificationError(
            "iOS supplier generated framework inventory is not approved"
        )
    if any(
        entry.file_count <= 0 or entry.total_bytes <= 0
        for entry in (*build_trees, *generated_frameworks)
    ):
        raise VerificationError(
            "iOS supplier inventories must not be empty"
        )
    return IOSSupplierTrustRoot(
        build_files=tuple(build_files),
        build_trees=tuple(build_trees),
        generated_frameworks=tuple(generated_frameworks),
    )


def _verify_tree(path: Path, expected: TreeTrust, *, label: str) -> None:
    inventory = _tree_inventory(path, label=label)
    if (
        inventory.file_count != expected.file_count
        or inventory.total_bytes != expected.total_bytes
        or inventory.sha256 != expected.inventory_sha256
    ):
        raise VerificationError(
            f"{label} does not match the protected inventory"
        )


def verify_build_inputs(
    trust_root: IOSSupplierTrustRoot,
    *,
    sdk_root: Path = EXPECTED_SDK_ROOT,
) -> None:
    sdk_root = _absolute(sdk_root)
    _reject_symlinked_path(sdk_root, "approved supplier SDK root")
    for expected in trust_root.build_files:
        path = sdk_root / expected.relative_path
        _regular_file(
            path,
            maximum_bytes=MAX_METADATA_BYTES,
            label=f"approved build input {expected.relative_path}",
        )
        if _sha256_file(
            path,
            label=f"approved build input {expected.relative_path}",
        ) != expected.sha256:
            raise VerificationError(
                f"approved build input digest mismatch: "
                f"{expected.relative_path}"
            )
    for expected in trust_root.build_trees:
        _verify_tree(
            sdk_root / expected.relative_path,
            expected,
            label=f"approved build input {expected.relative_path}",
        )


def _lipo_architectures(binary_path: Path) -> tuple[str, ...]:
    try:
        result = subprocess.run(
            ["/usr/bin/xcrun", "lipo", "-archs", str(binary_path)],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError("framework architecture check did not complete") from error

    if (
        len(result.stdout) > MAX_COMMAND_OUTPUT_BYTES
        or len(result.stderr) > MAX_COMMAND_OUTPUT_BYTES
    ):
        raise VerificationError("framework architecture output exceeded its bound")
    if result.returncode != 0:
        raise VerificationError("framework architecture check failed")
    try:
        architectures = tuple(result.stdout.decode("ascii", errors="strict").split())
    except UnicodeError as error:
        raise VerificationError("framework architecture output was invalid") from error
    if not architectures:
        raise VerificationError("framework architecture output was empty")
    return architectures


def verify_framework(
    framework_path: Path = EXPECTED_FRAMEWORK_PATH,
    *,
    expected_path: Path = EXPECTED_FRAMEWORK_PATH,
    expected_sha256: str = EXPECTED_BINARY_SHA256,
    architecture_reader: Callable[[Path], tuple[str, ...]] = _lipo_architectures,
) -> dict[str, object]:
    framework_path = _absolute(framework_path)
    expected_path = _absolute(expected_path)
    if framework_path != expected_path:
        raise VerificationError("framework path does not match the approved local path")

    _reject_symlinked_path(framework_path)
    try:
        framework_stat = framework_path.lstat()
    except OSError as error:
        raise VerificationError("approved framework is not readable") from error
    if not stat.S_ISDIR(framework_stat.st_mode):
        raise VerificationError("approved framework path must be a directory")

    binary_path = framework_path / EXPECTED_EXECUTABLE_NAME
    info_path = framework_path / "Info.plist"
    module_map_path = framework_path / "Modules" / "module.modulemap"
    binary_bytes = _regular_file(
        binary_path,
        maximum_bytes=MAX_BINARY_BYTES,
        label="framework executable",
    )
    _regular_file(
        info_path,
        maximum_bytes=MAX_METADATA_BYTES,
        label="framework Info.plist",
    )
    _regular_file(
        module_map_path,
        maximum_bytes=MAX_METADATA_BYTES,
        label="framework module map",
    )

    if _sha256_file(binary_path) != expected_sha256:
        raise VerificationError("framework executable SHA-256 does not match")

    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError("framework Info.plist is invalid") from error
    if not isinstance(info, dict):
        raise VerificationError("framework Info.plist root must be a dictionary")
    if info.get("CFBundleExecutable") != EXPECTED_EXECUTABLE_NAME:
        raise VerificationError("framework executable name is not approved")
    if info.get("CFBundlePackageType") != "FMWK":
        raise VerificationError("artifact is not an Apple framework bundle")
    if info.get("DTPlatformName") != EXPECTED_PLATFORM_NAME:
        raise VerificationError("framework is not built for physical iPhoneOS")
    if tuple(info.get("CFBundleSupportedPlatforms", ())) != EXPECTED_SUPPORTED_PLATFORMS:
        raise VerificationError("framework supported platforms are not approved")
    capabilities = info.get("UIRequiredDeviceCapabilities", ())
    if not isinstance(capabilities, list) or "arm64" not in capabilities:
        raise VerificationError("framework does not require arm64")

    try:
        module_map = module_map_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise VerificationError("framework module map is invalid") from error
    if "framework module VeepooBleSDK" not in module_map:
        raise VerificationError("framework module map does not expose VeepooBleSDK")

    architectures = architecture_reader(binary_path)
    if architectures != EXPECTED_ARCHITECTURES:
        raise VerificationError("framework architecture is not the approved arm64 slice")

    return {
        "architecture": architectures[0],
        "binaryBytes": binary_bytes,
        "platform": EXPECTED_PLATFORM_NAME,
        "sha256": expected_sha256,
    }


def _verify_companion_framework(
    framework_path: Path,
    framework_name: str,
    *,
    expected_sha256: str,
    architecture_reader: Callable[
        [Path], tuple[str, ...]
    ] = _lipo_architectures,
) -> tuple[str, ...]:
    framework_path = _absolute(framework_path)
    _reject_symlinked_path(
        framework_path,
        f"{framework_name}.framework",
    )
    try:
        framework_stat = framework_path.lstat()
    except OSError as error:
        raise VerificationError(
            f"{framework_name}.framework is not readable"
        ) from error
    if not stat.S_ISDIR(framework_stat.st_mode):
        raise VerificationError(
            f"{framework_name}.framework must be a directory"
        )

    binary_path = framework_path / framework_name
    info_path = framework_path / "Info.plist"
    _regular_file(
        binary_path,
        maximum_bytes=MAX_BINARY_BYTES,
        label=f"{framework_name} executable",
    )
    _regular_file(
        info_path,
        maximum_bytes=MAX_METADATA_BYTES,
        label=f"{framework_name} Info.plist",
    )
    if _sha256_file(
        binary_path,
        label=f"{framework_name} executable",
    ) != expected_sha256:
        raise VerificationError(
            f"{framework_name} executable SHA-256 does not match"
        )
    architectures = architecture_reader(binary_path)
    if "arm64" not in architectures:
        raise VerificationError(
            f"{framework_name}.framework has no physical arm64 slice"
        )
    return architectures


def _verify_generated_framework(
    expected: GeneratedFrameworkTrust,
    *,
    sdk_root: Path = EXPECTED_SDK_ROOT,
    architecture_reader: Callable[
        [Path], tuple[str, ...]
    ] = _lipo_architectures,
) -> None:
    framework_path = _absolute(sdk_root) / expected.relative_path
    architectures = _verify_companion_framework(
        framework_path,
        expected.name,
        expected_sha256=expected.binary_sha256,
        architecture_reader=architecture_reader,
    )
    if architectures != EXPECTED_ARCHITECTURES:
        raise VerificationError(
            f"{expected.name}.framework architecture is not the "
            "approved arm64 slice"
        )

    info_path = framework_path / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError(
            f"{expected.name}.framework Info.plist is invalid"
        ) from error
    if not isinstance(info, dict):
        raise VerificationError(
            f"{expected.name}.framework Info.plist root must be a dictionary"
        )
    if info.get("CFBundleExecutable") != expected.name:
        raise VerificationError(
            f"{expected.name}.framework executable name is not approved"
        )
    if info.get("CFBundlePackageType") != "FMWK":
        raise VerificationError(
            f"{expected.name} is not an Apple framework bundle"
        )
    if info.get("DTPlatformName") != EXPECTED_PLATFORM_NAME:
        raise VerificationError(
            f"{expected.name}.framework is not built for physical iPhoneOS"
        )
    if (
        tuple(info.get("CFBundleSupportedPlatforms", ()))
        != EXPECTED_SUPPORTED_PLATFORMS
    ):
        raise VerificationError(
            f"{expected.name}.framework supported platforms are not approved"
        )
    _verify_tree(
        framework_path,
        TreeTrust(
            relative_path=expected.relative_path,
            file_count=expected.file_count,
            total_bytes=expected.total_bytes,
            inventory_sha256=expected.inventory_sha256,
        ),
        label=f"{expected.name}.framework",
    )


def build_pod_frameworks(trust_root: IOSSupplierTrustRoot) -> None:
    verify_build_inputs(trust_root)
    _reject_symlinked_path(EXPECTED_PODS_PROJECT, "approved Pods project")
    command = [
        "/usr/bin/xcrun",
        "xcodebuild",
        "-project",
        str(EXPECTED_PODS_PROJECT),
        "-scheme",
        "Pods-VeepooBleSDKDemo",
        "-configuration",
        "Debug",
        "-destination",
        "generic/platform=iOS",
        f"SYMROOT={EXPECTED_PODS_BUILD_ROOT}",
        f"OBJROOT={EXPECTED_PODS_BUILD_ROOT / 'Intermediates'}",
        "IPHONEOS_DEPLOYMENT_TARGET=17.0",
        "ARCHS=arm64",
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "build",
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            cwd=EXPECTED_DEMO_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=DEPENDENCY_BUILD_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(
            "FMDB and MJExtension dependency build did not complete"
        ) from error
    if result.returncode != 0:
        output = result.stdout[-MAX_COMMAND_OUTPUT_BYTES:].decode(
            "utf-8",
            errors="replace",
        )
        raise VerificationError(
            "FMDB and MJExtension dependency build failed:\n" + output
        )
    verify_build_inputs(trust_root)


def verify_companion_frameworks(
    trust_root: IOSSupplierTrustRoot,
) -> None:
    for framework_name, expected_sha256 in (
        EXPECTED_VENDOR_FRAMEWORK_SHA256.items()
    ):
        _verify_companion_framework(
            EXPECTED_VENDOR_FRAMEWORK_DIR
            / f"{framework_name}.framework",
            framework_name,
            expected_sha256=expected_sha256,
        )
    for expected in trust_root.generated_frameworks:
        _verify_generated_framework(expected)


def render_local_config() -> str:
    return (
        "// Generated only after Tools/local/configure-veepoo-ios-sdk.py verifies the\n"
        "// protected iOS supplier manifest and local bundle. Do not copy supplier\n"
        "// frameworks into this repo.\n"
        "// The values themselves are qualified so simulator builds retain the empty,\n"
        "// default-off settings from Config/NOOPiOS.xcconfig.\n"
        "NOOP_VEEPOO_SDK_ENABLED[sdk=iphoneos*] = YES\n"
        "NOOP_VEEPOO_FRAMEWORK_DIR[sdk=iphoneos*] = "
        f"{EXPECTED_FRAMEWORK_PATH.parent}\n"
        "NOOP_VEEPOO_VENDOR_FRAMEWORK_DIR[sdk=iphoneos*] = "
        f"{EXPECTED_VENDOR_FRAMEWORK_DIR}\n"
        "NOOP_VEEPOO_FMDB_FRAMEWORK_DIR[sdk=iphoneos*] = "
        f"{EXPECTED_FMDB_FRAMEWORK_DIR}\n"
        "NOOP_VEEPOO_MJEXTENSION_FRAMEWORK_DIR[sdk=iphoneos*] = "
        f"{EXPECTED_MJEXTENSION_FRAMEWORK_DIR}\n"
        "NOOP_VEEPOO_LINK_FLAGS[sdk=iphoneos*] = "
        f"{EXPECTED_LINK_FLAGS}\n"
        "NOOP_VEEPOO_SWIFT_CONDITION[sdk=iphoneos*] = "
        "NOOP_SUPPLIER_VEEPOO\n"
    )


def write_local_config(repository_root: Path) -> Path:
    repository_root = _absolute(repository_root)
    config_directory = repository_root / LOCAL_CONFIG_RELATIVE_PATH.parent
    try:
        config_stat = config_directory.lstat()
    except OSError as error:
        raise VerificationError("repository Config directory is not available") from error
    if not stat.S_ISDIR(config_stat.st_mode) or config_directory.is_symlink():
        raise VerificationError("repository Config directory must be a regular directory")

    destination = repository_root / LOCAL_CONFIG_RELATIVE_PATH
    if destination.is_symlink():
        raise VerificationError("local SDK config must not be a symlink")
    if destination.exists():
        _regular_file(
            destination,
            maximum_bytes=MAX_METADATA_BYTES,
            label="local SDK config",
        )

    encoded = render_local_config().encode("utf-8")
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=".VeepooLocalSDK.",
        suffix=".tmp",
        dir=config_directory,
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(file_descriptor, 0o600)
        with os.fdopen(file_descriptor, "wb") as destination_file:
            destination_file.write(encoded)
            destination_file.flush()
            os.fsync(destination_file.fileno())
        os.replace(temporary_path, destination)
    except OSError as error:
        raise VerificationError("local SDK config could not be written") from error
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass
    return destination


def verify_build_environment(environment: Mapping[str, str]) -> None:
    required_values = {
        "PLATFORM_NAME": EXPECTED_PLATFORM_NAME,
        "NOOP_VEEPOO_SDK_ENABLED": "YES",
        "NOOP_VEEPOO_FRAMEWORK_DIR": str(EXPECTED_FRAMEWORK_PATH.parent),
        "NOOP_VEEPOO_VENDOR_FRAMEWORK_DIR": str(
            EXPECTED_VENDOR_FRAMEWORK_DIR
        ),
        "NOOP_VEEPOO_FMDB_FRAMEWORK_DIR": str(
            EXPECTED_FMDB_FRAMEWORK_DIR
        ),
        "NOOP_VEEPOO_MJEXTENSION_FRAMEWORK_DIR": str(
            EXPECTED_MJEXTENSION_FRAMEWORK_DIR
        ),
        "NOOP_VEEPOO_LINK_FLAGS": EXPECTED_LINK_FLAGS,
        "NOOP_VEEPOO_SWIFT_CONDITION": "NOOP_SUPPLIER_VEEPOO",
    }
    for name, expected_value in required_values.items():
        if environment.get(name) != expected_value:
            raise VerificationError(f"build setting {name} is not approved")
    if not environment.get("SDK_NAME", "").startswith("iphoneos"):
        raise VerificationError("build SDK is not physical iPhoneOS")


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify the exact local Veepoo iPhoneOS SDK dependency bundle."
        )
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--write-config",
        action="store_true",
        help="write the verified, gitignored NOOPiOS local config",
    )
    mode.add_argument(
        "--build-check",
        action="store_true",
        help="also require the exact physical-device Xcode build settings",
    )
    arguments = parser.parse_args(argv)

    try:
        repository_root = _repository_root()
        verify_repository_boundary(repository_root)
        trust_root = load_trust_root(
            repository_root / TRUST_RELATIVE_PATH
        )
        if arguments.build_check:
            verify_build_environment(os.environ)
        verify_build_inputs(trust_root)
        if arguments.write_config:
            build_pod_frameworks(trust_root)
        result = verify_framework()
        verify_companion_frameworks(trust_root)
        if arguments.write_config:
            destination = write_local_config(repository_root)
            print(f"wrote {destination.relative_to(repository_root)}")
        print(
            "verified Veepoo iPhoneOS bundle: "
            f"{result['platform']} {result['architecture']}, "
            "primary and companion frameworks matched"
        )
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
