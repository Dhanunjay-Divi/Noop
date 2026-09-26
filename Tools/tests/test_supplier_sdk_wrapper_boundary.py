from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SWIFT_IMPORT_KIND = (
    r"(?:typealias|struct|class|enum|protocol|let|var|func)"
)


def _manifest_framework_names() -> tuple[str, ...]:
    manifest = json.loads(
        (
            ROOT / "release" / "supplier" / "ios-artifact-trust.json"
        ).read_text(encoding="utf-8")
    )
    frameworks = manifest["fixedFrameworks"] + manifest["generatedFrameworks"]
    return tuple(sorted({framework["name"] for framework in frameworks}))


def _manifest_android_package_prefixes() -> tuple[str, ...]:
    manifest = json.loads(
        (
            ROOT / "release" / "supplier" / "android-artifact-trust.json"
        ).read_text(encoding="utf-8")
    )
    prefixes = {
        ".".join(class_name.split(".")[:2]) + "."
        for artifact in manifest["artifacts"]
        for class_name in artifact["requiredClasses"]
    }
    return tuple(sorted(prefixes))


APPLE_SUPPLIER_MODULES = _manifest_framework_names()
ANDROID_SUPPLIER_PACKAGE_PREFIXES = _manifest_android_package_prefixes()
APPLE_MODULE_ALTERNATION = "|".join(
    re.escape(module) for module in APPLE_SUPPLIER_MODULES
)
SWIFT_IMPORT_ATTRIBUTE = (
    r"@[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^)\n]*\))?"
)
SWIFT_IMPORT_ACCESS = r"(?:private|fileprivate|internal|package|public|open)"
APPLE_IMPORT = re.compile(
    rf"(?m)(?:^|;)[ \t]*"
    rf"(?:(?:{SWIFT_IMPORT_ATTRIBUTE}|{SWIFT_IMPORT_ACCESS})[ \t]+)*"
    rf"import"
    rf"(?:\s+{SWIFT_IMPORT_KIND})?\s+"
    rf"(?:{APPLE_MODULE_ALTERNATION})"
    rf"(?=\.|[ \t]*(?:(?://[^\n]*)?;|(?://[^\n]*)?$))"
)
APPLE_QUALIFIED_REFERENCE = re.compile(
    rf"\b(?:{APPLE_MODULE_ALTERNATION})\s*\."
)
ANDROID_SUPPLIER_REFERENCE = re.compile(
    r"\b(?:"
    + "|".join(
        re.escape(prefix.removesuffix("."))
        for prefix in ANDROID_SUPPLIER_PACKAGE_PREFIXES
    )
    + r")\."
)


def _uses_apple_supplier_api(source: str) -> bool:
    return bool(
        APPLE_IMPORT.search(source)
        or APPLE_QUALIFIED_REFERENCE.search(source)
    )


def _uses_android_supplier_api(source: str) -> bool:
    return bool(ANDROID_SUPPLIER_REFERENCE.search(source))


class SupplierSDKWrapperBoundaryTests(unittest.TestCase):
    def _swift_sources(self) -> list[Path]:
        roots = (
            "Packages",
            "Strand",
            "StrandiOS",
            "StrandiOSShared",
            "StrandiOSWidgets",
            "NOOPWatch",
            "NOOPWatchComplications",
        )
        return sorted(
            path
            for relative in roots
            for path in (ROOT / relative).rglob("*.swift")
            if path.is_file()
        )

    def _production_android_sources(self) -> list[Path]:
        source_root = ROOT / "android" / "app" / "src"
        return sorted(
            path
            for pattern in ("*.kt", "*.java")
            for path in source_root.rglob(pattern)
            if path.is_file()
            and "test" not in path.relative_to(source_root).parts[0].lower()
        )

    def test_apple_vendor_import_is_quarantined_to_native_client(self) -> None:
        importers = {
            path.relative_to(ROOT).as_posix()
            for path in self._swift_sources()
            if _uses_apple_supplier_api(path.read_text(encoding="utf-8"))
        }
        self.assertEqual(
            {"Strand/BLE/VeepooBandAdapter.swift"},
            importers,
        )

        adapter = (
            ROOT / "Strand" / "BLE" / "VeepooBandAdapter.swift"
        ).read_text(encoding="utf-8")
        self.assertEqual(1, adapter.count("import VeepooBleSDK"))
        self.assertIn(
            "private final class VeepooBleSDKClient: VeepooBandSDKClient",
            adapter,
        )

    def test_android_vendor_imports_are_quarantined_to_provider(self) -> None:
        importers = {
            path.relative_to(ROOT).as_posix()
            for path in self._production_android_sources()
            if _uses_android_supplier_api(path.read_text(encoding="utf-8"))
        }
        self.assertEqual(
            {
                "android/app/src/veepoo/java/com/noop/ble/veepoo/vendor/"
                "VeepooBridgeProviderImpl.kt"
            },
            importers,
        )

        neutral_bridge = (
            ROOT
            / "android"
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "noop"
            / "ble"
            / "veepoo"
            / "VeepooBridge.kt"
        ).read_text(encoding="utf-8")
        vendor_bridge = (
            ROOT
            / "android"
            / "app"
            / "src"
            / "veepoo"
            / "java"
            / "com"
            / "noop"
            / "ble"
            / "veepoo"
            / "vendor"
            / "VeepooVendorBridge.kt"
        ).read_text(encoding="utf-8")
        for source in (neutral_bridge, vendor_bridge):
            self.assertFalse(_uses_android_supplier_api(source))

    def test_detector_covers_scoped_and_fully_qualified_usage(self) -> None:
        self.assertTrue(
            _uses_apple_supplier_api(
                "import class VeepooBleSDK.VPBleCentralManage\n"
            )
        )
        for source in (
            "@_implementationOnly import VeepooBleSDK\n",
            "@_exported import GRDFUSDK\n",
            "internal import ABParTool\n",
            "package import DFUnits\n",
            "import JLDialUnit;\n",
            "import Foundation; @_implementationOnly import JL_BLEKit;\n",
            "@preconcurrency @_implementationOnly import ZipZap\n",
        ):
            with self.subTest(swift_import=source):
                self.assertTrue(_uses_apple_supplier_api(source))
        self.assertTrue(
            _uses_apple_supplier_api(
                "let value = GRDFUSDK.Manager.shared\n"
            )
        )
        self.assertTrue(
            _uses_android_supplier_api(
                "val manager = com.jieli.jl_filebrowse."
                "FileBrowseManager.getInstance()\n"
            )
        )
        self.assertTrue(
            _uses_android_supplier_api(
                "import com.bluetrum.abpartool.ParTool;\n"
            )
        )
        self.assertFalse(
            _uses_apple_supplier_api(
                "private final class VeepooBleSDKClient {}\n"
            )
        )
        self.assertFalse(
            _uses_android_supplier_api(
                "package com.noop.ble.veepoo.vendor\n"
            )
        )

    def test_product_coordinators_depend_only_on_noop_owned_interfaces(self) -> None:
        apple_coordinator = (
            ROOT / "Strand" / "BLE" / "SourceCoordinator.swift"
        ).read_text(encoding="utf-8")
        android_coordinator = (
            ROOT
            / "android"
            / "app"
            / "src"
            / "main"
            / "java"
            / "com"
            / "noop"
            / "ble"
            / "SourceCoordinator.kt"
        ).read_text(encoding="utf-8")

        self.assertFalse(_uses_apple_supplier_api(apple_coordinator))
        self.assertNotIn("VPBle", apple_coordinator)
        self.assertNotIn("com.noop.ble.veepoo.vendor", android_coordinator)
        self.assertFalse(_uses_android_supplier_api(android_coordinator))

    def test_release_controls_execute_wrapper_boundary_tests(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "release-controls.yml"
        ).read_text(encoding="utf-8")
        self.assertEqual(
            1,
            workflow.count(
                "Tools.tests.test_supplier_sdk_wrapper_boundary"
            ),
        )


if __name__ == "__main__":
    unittest.main()
