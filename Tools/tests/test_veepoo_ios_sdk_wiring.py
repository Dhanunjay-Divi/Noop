from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "Tools" / "local" / "configure-veepoo-ios-sdk.py"
SPEC = importlib.util.spec_from_file_location("veepoo_ios_sdk_wiring", TOOL)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VeepooIOSSDKWiringTests(unittest.TestCase):
    def _synthetic_framework(
        self,
        root: Path,
        *,
        binary: bytes = b"approved-device-framework",
        platform: str = "iphoneos",
        supported_platforms: list[str] | None = None,
    ) -> Path:
        framework = root / "VeepooBleSDK.framework"
        (framework / "Modules").mkdir(parents=True)
        (framework / "VeepooBleSDK").write_bytes(binary)
        (framework / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "VeepooBleSDK",
                    "CFBundlePackageType": "FMWK",
                    "CFBundleSupportedPlatforms": (
                        supported_platforms
                        if supported_platforms is not None
                        else ["iPhoneOS"]
                    ),
                    "DTPlatformName": platform,
                    "UIRequiredDeviceCapabilities": ["arm64"],
                }
            )
        )
        (framework / "Modules" / "module.modulemap").write_text(
            'framework module VeepooBleSDK { umbrella header "VeepooBleSDK.h" }\n',
            encoding="utf-8",
        )
        return framework

    def _synthetic_companion_framework(
        self,
        root: Path,
        name: str,
        *,
        binary: bytes = b"approved-generated-framework",
    ) -> Path:
        framework = root / f"{name}.framework"
        (framework / "Headers").mkdir(parents=True)
        (framework / "Modules").mkdir()
        (framework / name).write_bytes(binary)
        (framework / "Headers" / f"{name}.h").write_text(
            f"// {name}\n",
            encoding="utf-8",
        )
        (framework / "Modules" / "module.modulemap").write_text(
            f"framework module {name} {{}}\n",
            encoding="utf-8",
        )
        (framework / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": name,
                    "CFBundlePackageType": "FMWK",
                    "CFBundleSupportedPlatforms": ["iPhoneOS"],
                    "DTPlatformName": "iphoneos",
                    "UIRequiredDeviceCapabilities": ["arm64"],
                }
            )
        )
        return framework

    def test_constants_pin_the_owner_supplied_artifact(self) -> None:
        self.assertEqual(
            MODULE.EXPECTED_FRAMEWORK_PATH,
            Path(
                "/Users/divii/Downloads/SDK/iOS_Ble_SDK-master/iOS_sdk_source/"
                "Framework/2.2.XX.15/VeepooBleSDK.framework"
            ),
        )
        self.assertEqual(
            MODULE.EXPECTED_BINARY_SHA256,
            "22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35",
        )
        self.assertEqual(
            MODULE.TRUST_RELATIVE_PATH,
            Path("release/supplier/ios-artifact-trust.json"),
        )

    def test_tracked_manifest_pins_generated_frameworks_and_inputs(self) -> None:
        trust_root = MODULE.load_trust_root(
            ROOT / MODULE.TRUST_RELATIVE_PATH
        )
        self.assertEqual(
            tuple(item.relative_path for item in trust_root.build_files),
            MODULE.EXPECTED_BUILD_FILE_PATHS,
        )
        self.assertEqual(
            tuple(item.relative_path for item in trust_root.build_trees),
            MODULE.EXPECTED_BUILD_TREE_PATHS,
        )
        self.assertEqual(
            {
                item.name: item.binary_sha256
                for item in trust_root.generated_frameworks
            },
            {
                "FMDB": (
                    "c22b46589e8bf9b7198146226366a421"
                    "963d682945d0dc80c69f6d4d1fa95aae"
                ),
                "MJExtension": (
                    "fadb76572cb8d507751cacbd4b37f742"
                    "d291c2b6cff8ff5fb7149b8560ce9d3d"
                ),
            },
        )
        MODULE.verify_repository_boundary(ROOT)

    def test_trust_root_rejects_unapproved_generated_path(self) -> None:
        document = json.loads(
            (ROOT / MODULE.TRUST_RELATIVE_PATH).read_text(encoding="utf-8")
        )
        document["generatedFrameworks"][0]["path"] = (
            "Demo/VeepooBleSDKDemo/build/Debug-iphoneos/"
            "Unreviewed/FMDB.framework"
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / "trust.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "generated framework inventory is not approved",
            ):
                MODULE.load_trust_root(path)

    def test_matching_iPhoneOS_framework_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            framework = self._synthetic_framework(Path(temporary).resolve())
            digest = hashlib.sha256(
                (framework / "VeepooBleSDK").read_bytes()
            ).hexdigest()
            result = MODULE.verify_framework(
                framework,
                expected_path=framework,
                expected_sha256=digest,
                architecture_reader=lambda _: ("arm64",),
            )
        self.assertEqual(result["platform"], "iphoneos")
        self.assertEqual(result["architecture"], "arm64")

    def test_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            framework = self._synthetic_framework(Path(temporary).resolve())
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "SHA-256",
            ):
                MODULE.verify_framework(
                    framework,
                    expected_path=framework,
                    expected_sha256="0" * 64,
                    architecture_reader=lambda _: ("arm64",),
                )

    def test_alternate_framework_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            framework = self._synthetic_framework(root)
            other_path = root / "Other.framework"
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "approved local path",
            ):
                MODULE.verify_framework(
                    framework,
                    expected_path=other_path,
                    expected_sha256=hashlib.sha256(
                        (framework / "VeepooBleSDK").read_bytes()
                    ).hexdigest(),
                    architecture_reader=lambda _: ("arm64",),
                )

    def test_simulator_framework_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            framework = self._synthetic_framework(
                Path(temporary).resolve(),
                platform="iphonesimulator",
                supported_platforms=["iPhoneSimulator"],
            )
            digest = hashlib.sha256(
                (framework / "VeepooBleSDK").read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "physical iPhoneOS",
            ):
                MODULE.verify_framework(
                    framework,
                    expected_path=framework,
                    expected_sha256=digest,
                    architecture_reader=lambda _: ("arm64",),
                )

    def test_symlinked_framework_executable_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            framework = self._synthetic_framework(root)
            binary = framework / "VeepooBleSDK"
            external = root / "external-binary"
            binary.replace(external)
            binary.symlink_to(external)
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "regular file",
            ):
                MODULE.verify_framework(
                    framework,
                    expected_path=framework,
                    expected_sha256=hashlib.sha256(
                        external.read_bytes()
                    ).hexdigest(),
                    architecture_reader=lambda _: ("arm64",),
                )

    def test_build_inputs_reject_changed_or_extra_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root = Path(temporary).resolve()
            podfile = sdk_root / "Podfile"
            lockfile = sdk_root / "Podfile.lock"
            pods = sdk_root / "Pods"
            pods.mkdir()
            podfile.write_text("pod 'FMDB'\n", encoding="utf-8")
            lockfile.write_text("FMDB 2.6.2\n", encoding="utf-8")
            (pods / "project.pbxproj").write_text(
                "approved\n",
                encoding="utf-8",
            )
            inventory = MODULE._tree_inventory(pods, label="Pods")
            trust_root = MODULE.IOSSupplierTrustRoot(
                build_files=(
                    MODULE.FileTrust(
                        "Podfile",
                        hashlib.sha256(podfile.read_bytes()).hexdigest(),
                    ),
                    MODULE.FileTrust(
                        "Podfile.lock",
                        hashlib.sha256(lockfile.read_bytes()).hexdigest(),
                    ),
                ),
                build_trees=(
                    MODULE.TreeTrust(
                        "Pods",
                        inventory.file_count,
                        inventory.total_bytes,
                        inventory.sha256,
                    ),
                ),
                generated_frameworks=(),
            )
            MODULE.verify_build_inputs(trust_root, sdk_root=sdk_root)
            podfile.write_text("pod 'Unreviewed'\n", encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "build input digest mismatch",
            ):
                MODULE.verify_build_inputs(trust_root, sdk_root=sdk_root)
            podfile.write_text("pod 'FMDB'\n", encoding="utf-8")
            (pods / "injected.m").write_text(
                "void injected(void) {}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "protected inventory",
            ):
                MODULE.verify_build_inputs(trust_root, sdk_root=sdk_root)

    def test_generated_framework_rejects_binary_or_inventory_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root = Path(temporary).resolve()
            framework = self._synthetic_companion_framework(
                sdk_root,
                "FMDB",
            )
            inventory = MODULE._tree_inventory(
                framework,
                label="FMDB.framework",
            )
            expected = MODULE.GeneratedFrameworkTrust(
                name="FMDB",
                relative_path="FMDB.framework",
                binary_sha256=hashlib.sha256(
                    (framework / "FMDB").read_bytes()
                ).hexdigest(),
                file_count=inventory.file_count,
                total_bytes=inventory.total_bytes,
                inventory_sha256=inventory.sha256,
            )
            MODULE._verify_generated_framework(
                expected,
                sdk_root=sdk_root,
                architecture_reader=lambda _: ("arm64",),
            )
            binary = framework / "FMDB"
            approved_binary = binary.read_bytes()
            binary.write_bytes(b"changed-generated-framework")
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "SHA-256",
            ):
                MODULE._verify_generated_framework(
                    expected,
                    sdk_root=sdk_root,
                    architecture_reader=lambda _: ("arm64",),
                )
            binary.write_bytes(approved_binary)
            (framework / "injected.dylib").write_bytes(b"unreviewed")
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "protected inventory",
            ):
                MODULE._verify_generated_framework(
                    expected,
                    sdk_root=sdk_root,
                    architecture_reader=lambda _: ("arm64",),
                )

    def test_build_check_requires_exact_physical_device_settings(self) -> None:
        approved = {
            "PLATFORM_NAME": "iphoneos",
            "SDK_NAME": "iphoneos26.5",
            "NOOP_VEEPOO_SDK_ENABLED": "YES",
            "NOOP_VEEPOO_FRAMEWORK_DIR": str(
                MODULE.EXPECTED_FRAMEWORK_PATH.parent
            ),
            "NOOP_VEEPOO_VENDOR_FRAMEWORK_DIR": str(
                MODULE.EXPECTED_VENDOR_FRAMEWORK_DIR
            ),
            "NOOP_VEEPOO_FMDB_FRAMEWORK_DIR": str(
                MODULE.EXPECTED_FMDB_FRAMEWORK_DIR
            ),
            "NOOP_VEEPOO_MJEXTENSION_FRAMEWORK_DIR": str(
                MODULE.EXPECTED_MJEXTENSION_FRAMEWORK_DIR
            ),
            "NOOP_VEEPOO_LINK_FLAGS": MODULE.EXPECTED_LINK_FLAGS,
            "NOOP_VEEPOO_SWIFT_CONDITION": "NOOP_SUPPLIER_VEEPOO",
        }
        MODULE.verify_build_environment(approved)
        simulator = dict(approved, PLATFORM_NAME="iphonesimulator")
        with self.assertRaisesRegex(
            MODULE.VerificationError,
            "PLATFORM_NAME",
        ):
            MODULE.verify_build_environment(simulator)

    def test_generated_config_matches_the_tracked_example(self) -> None:
        example = (
            ROOT / "Config" / "VeepooLocalSDK.example.xcconfig"
        ).read_text(encoding="utf-8")
        self.assertEqual(MODULE.render_local_config(), example)
        self.assertEqual(example.count("[sdk=iphoneos*]"), 7)
        self.assertNotIn("NOOP_VEEPOO_SDK_ENABLED = YES", example)

    def test_writer_creates_only_the_local_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve()
            (repository / "Config").mkdir()
            destination = MODULE.write_local_config(repository)
            self.assertEqual(
                destination,
                repository / "Config" / "VeepooLocalSDK.xcconfig",
            )
            self.assertEqual(
                destination.read_text(encoding="utf-8"),
                MODULE.render_local_config(),
            )
            self.assertFalse(
                any(repository.rglob("VeepooBleSDK.framework"))
            )

    def test_project_wiring_is_default_off_and_iPhoneOS_only(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        target_start = project.index("\n  NOOPiOS:\n")
        target_end = project.index("\n  NOOPiOSUITests:\n", target_start)
        target = project[target_start:target_end]
        for setting in (
            '"FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]"',
            '"OTHER_LDFLAGS[sdk=iphoneos*]"',
            '"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]"',
        ):
            self.assertIn(setting, target)
            self.assertEqual(project.count(setting), 1)
        self.assertIn("--build-check", target)
        self.assertIn('"${PLATFORM_NAME:-}" = "iphoneos"', target)
        self.assertIn("embed-veepoo-ios-frameworks.sh", target)

        embed = (
            ROOT / "Tools" / "local" / "embed-veepoo-ios-frameworks.sh"
        ).read_text(encoding="utf-8")
        verification = embed.index(
            "configure-veepoo-ios-sdk.py\" --build-check"
        )
        first_copy = embed.index("/usr/bin/ditto")
        self.assertLess(verification, first_copy)

        wrapper = (ROOT / "Config" / "NOOPiOS.xcconfig").read_text(
            encoding="utf-8"
        )
        self.assertIn("NOOP_VEEPOO_SDK_ENABLED = NO", wrapper)
        self.assertIn("NOOP_VEEPOO_FRAMEWORK_DIR =", wrapper)
        self.assertIn("NOOP_VEEPOO_VENDOR_FRAMEWORK_DIR =", wrapper)
        self.assertIn("NOOP_VEEPOO_FMDB_FRAMEWORK_DIR =", wrapper)
        self.assertIn("NOOP_VEEPOO_MJEXTENSION_FRAMEWORK_DIR =", wrapper)
        self.assertIn('#include? "VeepooLocalSDK.xcconfig"', wrapper)
        self.assertLess(
            wrapper.index("NOOP_VEEPOO_SDK_ENABLED = NO"),
            wrapper.index('#include? "VeepooLocalSDK.xcconfig"'),
        )

        ignores = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("Config/VeepooLocalSDK.xcconfig", ignores)
        self.assertIn("VeepooBleSDK.framework/", ignores)


if __name__ == "__main__":
    unittest.main()
