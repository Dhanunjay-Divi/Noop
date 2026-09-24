#!/usr/bin/env python3
"""Verify and optionally enable the approved local Veepoo iPhoneOS SDK."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path


EXPECTED_FRAMEWORK_PATH = Path(
    "/Users/divii/Downloads/SDK/iOS_Ble_SDK-master/iOS_sdk_source/"
    "Framework/2.2.XX.15/VeepooBleSDK.framework"
)
EXPECTED_BINARY_SHA256 = (
    "22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35"
)
EXPECTED_EXECUTABLE_NAME = "VeepooBleSDK"
EXPECTED_ARCHITECTURES = ("arm64",)
EXPECTED_PLATFORM_NAME = "iphoneos"
EXPECTED_SUPPORTED_PLATFORMS = ("iPhoneOS",)
LOCAL_CONFIG_RELATIVE_PATH = Path("Config/VeepooLocalSDK.xcconfig")
MAX_BINARY_BYTES = 32 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 4096
COMMAND_TIMEOUT_SECONDS = 10


class VerificationError(RuntimeError):
    pass


def _absolute(path: Path) -> Path:
    return Path(os.path.abspath(path))


def _reject_symlinked_path(path: Path) -> None:
    if not path.is_absolute():
        raise VerificationError("approved framework path must be absolute")

    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError as error:
            raise VerificationError("approved framework path is incomplete") from error
        except OSError as error:
            raise VerificationError("approved framework path is not inspectable") from error
        if stat.S_ISLNK(mode):
            raise VerificationError("approved framework path must not contain symlinks")


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


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise VerificationError("framework executable could not be hashed") from error
    return digest.hexdigest()


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


def render_local_config() -> str:
    return (
        "// Generated only after Tools/local/configure-veepoo-ios-sdk.py verifies the\n"
        "// approved local artifact. Do not copy VeepooBleSDK.framework into this repo.\n"
        "// The values themselves are qualified so simulator builds retain the empty,\n"
        "// default-off settings from Config/NOOPiOS.xcconfig.\n"
        "NOOP_VEEPOO_SDK_ENABLED[sdk=iphoneos*] = YES\n"
        "NOOP_VEEPOO_FRAMEWORK_DIR[sdk=iphoneos*] = "
        f"{EXPECTED_FRAMEWORK_PATH.parent}\n"
        "NOOP_VEEPOO_LINK_FLAGS[sdk=iphoneos*] = "
        "-ObjC -framework VeepooBleSDK\n"
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
        "NOOP_VEEPOO_LINK_FLAGS": "-ObjC -framework VeepooBleSDK",
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
            "Verify the exact local Veepoo iPhoneOS framework without copying it."
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
        if arguments.build_check:
            verify_build_environment(os.environ)
        result = verify_framework()
        if arguments.write_config:
            destination = write_local_config(_repository_root())
            print(f"wrote {destination.relative_to(_repository_root())}")
        print(
            "verified VeepooBleSDK.framework: "
            f"{result['platform']} {result['architecture']}, SHA-256 matched"
        )
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
