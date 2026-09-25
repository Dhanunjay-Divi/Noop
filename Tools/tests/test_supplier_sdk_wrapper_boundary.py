from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


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

    def _production_kotlin_sources(self) -> list[Path]:
        source_root = ROOT / "android" / "app" / "src"
        return sorted(
            path
            for path in source_root.rglob("*.kt")
            if path.is_file()
            and "test" not in path.relative_to(source_root).parts[0].lower()
        )

    def test_apple_vendor_import_is_quarantined_to_native_client(self) -> None:
        importers = {
            path.relative_to(ROOT).as_posix()
            for path in self._swift_sources()
            if "import VeepooBleSDK" in path.read_text(encoding="utf-8")
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
        vendor_import_prefixes = (
            "import com.inuker.bluetooth.",
            "import com.veepoo.",
        )
        importers = {
            path.relative_to(ROOT).as_posix()
            for path in self._production_kotlin_sources()
            if any(
                line.startswith(vendor_import_prefixes)
                for line in path.read_text(encoding="utf-8").splitlines()
            )
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
            self.assertNotIn("import com.inuker.bluetooth.", source)
            self.assertNotIn("import com.veepoo.", source)

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

        self.assertNotIn("VeepooBleSDK", apple_coordinator)
        self.assertNotIn("VPBle", apple_coordinator)
        self.assertNotIn("com.noop.ble.veepoo.vendor", android_coordinator)
        self.assertNotIn("com.veepoo.", android_coordinator)
        self.assertNotIn("com.inuker.bluetooth.", android_coordinator)


if __name__ == "__main__":
    unittest.main()
