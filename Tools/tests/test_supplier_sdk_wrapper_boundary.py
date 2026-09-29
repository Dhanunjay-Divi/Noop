from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SWIFT_IMPORT_KINDS = frozenset(
    {"typealias", "struct", "class", "enum", "protocol", "let", "var", "func"}
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
ANDROID_SUPPLIER_PACKAGE_SEGMENTS = tuple(
    tuple(prefix.removesuffix(".").split("."))
    for prefix in ANDROID_SUPPLIER_PACKAGE_PREFIXES
)


def _source_tokens(source: str) -> tuple[str, ...]:
    """Return identifiers and punctuation outside comments and string literals."""
    tokens: list[str] = []
    index = 0
    length = len(source)

    def skip_quoted(start: int, quote: str, raw_hashes: int = 0) -> int:
        delimiter = quote + ("#" * raw_hashes)
        cursor = start + len(quote)
        while cursor < length:
            if source.startswith(delimiter, cursor):
                return cursor + len(delimiter)
            if raw_hashes == 0 and len(quote) == 1 and source[cursor] == "\\":
                cursor += 2
            else:
                cursor += 1
        return length

    while index < length:
        char = source[index]
        if char.isspace():
            index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = length if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            depth = 1
            index += 2
            while index < length and depth > 0:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            continue
        if char == "#":
            hash_end = index
            while hash_end < length and source[hash_end] == "#":
                hash_end += 1
            quote = (
                '"""'
                if source.startswith('"""', hash_end)
                else '"' if source.startswith('"', hash_end) else None
            )
            if quote is not None:
                index = skip_quoted(
                    hash_end,
                    quote,
                    raw_hashes=hash_end - index,
                )
                continue
        if source.startswith('"""', index):
            index = skip_quoted(index, '"""')
            continue
        if char in {'"', "'"}:
            index = skip_quoted(index, char)
            continue
        if char == "_" or char.isalpha():
            end = index + 1
            while end < length and (
                source[end] == "_" or source[end].isalnum()
            ):
                end += 1
            tokens.append(source[index:end])
            index = end
            continue
        tokens.append(char)
        index += 1

    return tuple(tokens)


def _contains_qualified_path(
    tokens: tuple[str, ...],
    segments: tuple[str, ...],
) -> bool:
    if not segments:
        return False
    width = len(segments) * 2 - 1
    for start in range(0, len(tokens) - width + 1):
        for offset, segment in enumerate(segments):
            token_index = start + offset * 2
            if tokens[token_index] != segment:
                break
            if offset + 1 < len(segments) and tokens[token_index + 1] != ".":
                break
        else:
            return True
    return False


def _uses_apple_supplier_api(source: str) -> bool:
    tokens = _source_tokens(source)
    for index, token in enumerate(tokens):
        if token == "import":
            module_index = index + 1
            if (
                module_index < len(tokens)
                and tokens[module_index] in SWIFT_IMPORT_KINDS
            ):
                module_index += 1
            if (
                module_index < len(tokens)
                and tokens[module_index] in APPLE_SUPPLIER_MODULES
            ):
                return True
        if (
            token in APPLE_SUPPLIER_MODULES
            and index + 1 < len(tokens)
            and tokens[index + 1] == "."
        ):
            return True
    return False


def _uses_android_supplier_api(source: str) -> bool:
    tokens = _source_tokens(source)
    return any(
        _contains_qualified_path(tokens, segments)
        for segments in ANDROID_SUPPLIER_PACKAGE_SEGMENTS
    )


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

    def test_detector_cannot_be_bypassed_with_comments(self) -> None:
        for source in (
            "import /* gap */ VeepooBleSDK\n",
            "import class VeepooBleSDK/* gap */.VPBleCentralManage\n",
            "let value = GRDFUSDK/* gap */.Manager.shared\n",
            "import /* outer /* nested */ gap */ ZipZap\n",
        ):
            with self.subTest(swift_source=source):
                self.assertTrue(_uses_apple_supplier_api(source))

        for source in (
            "import com/* gap */.jieli.jl_filebrowse.FileBrowseManager\n",
            "val manager = com/* outer /* nested */ gap */.jieli."
            "jl_filebrowse.FileBrowseManager\n",
            "import com.bluetrum/* gap */.abpartool.ParTool\n",
        ):
            with self.subTest(android_source=source):
                self.assertTrue(_uses_android_supplier_api(source))

    def test_detector_ignores_comments_and_string_literals(self) -> None:
        for source in (
            "// import VeepooBleSDK\n",
            "/* let value = GRDFUSDK.Manager.shared */\n",
            'let text = "import ZipZap; JL_BLEKit.Manager.shared"\n',
            'let raw = #"VeepooBleSDK.Manager.shared"#\n',
            'let multiline = """GRDFUSDK.Manager.shared"""\n',
        ):
            with self.subTest(swift_source=source):
                self.assertFalse(_uses_apple_supplier_api(source))

        for source in (
            "// import com.jieli.jl_filebrowse.FileBrowseManager\n",
            "/* val manager = com.bluetrum.abpartool.ParTool */\n",
            'val text = "com.jieli.jl_filebrowse.FileBrowseManager"\n',
            'val raw = """com.bluetrum.abpartool.ParTool"""\n',
        ):
            with self.subTest(android_source=source):
                self.assertFalse(_uses_android_supplier_api(source))

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
