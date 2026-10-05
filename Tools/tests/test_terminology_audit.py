from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "terminology-audit.py"
SPEC = importlib.util.spec_from_file_location("terminology_audit", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class TerminologyAuditTests(unittest.TestCase):
    def test_legacy_persisted_id_is_not_relabelled_first_party(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = "Source.swift"
            (root / path).write_text(
                'let source = "my-whoop"\n',
                encoding="utf-8",
            )
            occurrences, forbidden = AUDIT.scan(root, [path])
        self.assertEqual(forbidden, [])
        self.assertEqual(occurrences[0].category, "persisted")

    def test_legacy_source_to_first_party_label_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = "Source.swift"
            (root / path).write_text(
                'case "my-whoop": return "Noop Band"\n',
                encoding="utf-8",
            )
            _, forbidden = AUDIT.scan(root, [path])
        self.assertEqual(
            forbidden[0]["rule"],
            "legacy-source-first-party-label",
        )

    def test_customer_and_core_snapshot_is_a_fail_closed_ratchet(self) -> None:
        inventory = {
            "entries": [
                {
                    "path": "Strand/Screens/Example.swift",
                    "category": "customer",
                    "occurrenceCount": 1,
                    "sha256": "a" * 64,
                },
                {
                    "path": "Packages/Example.swift",
                    "category": "core",
                    "occurrenceCount": 2,
                    "sha256": "b" * 64,
                },
                {
                    "path": "docs/example.md",
                    "category": "historical",
                    "occurrenceCount": 3,
                    "sha256": "c" * 64,
                },
            ]
        }
        allowlist = AUDIT.active_allowlist(inventory)
        self.assertEqual(len(allowlist["entries"]), 2)
        for entry in allowlist["entries"]:
            self.assertTrue(entry["owner"])
            self.assertTrue(entry["reason"])
            self.assertTrue(entry["removalCondition"])

    def test_generated_audit_outputs_do_not_scan_themselves(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inventory = "release/terminology/legacy-inventory.json"
            (root / inventory).parent.mkdir(parents=True)
            (root / inventory).write_text(
                '{"legacy": "WHOOP"}\n',
                encoding="utf-8",
            )
            occurrences, forbidden = AUDIT.scan(root, [inventory])
        self.assertEqual(occurrences, [])
        self.assertEqual(forbidden, [])

    def test_localization_keys_may_preserve_history_but_visible_values_may_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            apple = root / "Strand" / "Resources" / "Localizable.xcstrings"
            apple.parent.mkdir(parents=True)
            apple.write_text(
                json.dumps(
                    {
                        "strings": {
                            "Import WHOOP export": {
                                "localizations": {
                                    "en": {
                                        "stringUnit": {
                                            "state": "translated",
                                            "value": "Import wearable export",
                                        }
                                    }
                                }
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            android = (
                root
                / "android"
                / "app"
                / "src"
                / "main"
                / "res"
                / "values"
                / "strings.xml"
            )
            android.parent.mkdir(parents=True)
            android.write_text(
                '<resources><string name="legacy_key">Compatible band</string></resources>',
                encoding="utf-8",
            )

            self.assertEqual(
                AUDIT.customer_visible_value_violations(root),
                [],
            )

            catalog = json.loads(apple.read_text(encoding="utf-8"))
            catalog["strings"]["Import WHOOP export"]["localizations"]["en"][
                "stringUnit"
            ]["value"] = "Import WHOOP export"
            apple.write_text(json.dumps(catalog), encoding="utf-8")
            android.write_text(
                '<resources><string name="legacy_key">WHOOP band</string></resources>',
                encoding="utf-8",
            )

            violations = AUDIT.customer_visible_value_violations(root)
            self.assertEqual(len(violations), 2)
            self.assertEqual(
                {violation.path for violation in violations},
                {
                    "Strand/Resources/Localizable.xcstrings",
                    "android/app/src/main/res/values/strings.xml",
                },
            )

    def test_apple_source_language_key_fallback_is_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            retired_vendor = "".join(("WHO", "OP"))
            path = Path(AUDIT.APPLE_LOCALIZATION_CATALOGS[0])
            catalog = root / path
            catalog.parent.mkdir(parents=True)
            key = f"Import {retired_vendor} export"
            catalog.write_text(
                json.dumps(
                    {
                        "sourceLanguage": "en",
                        "strings": {key: {}},
                    }
                ),
                encoding="utf-8",
            )

            violations = AUDIT.customer_visible_value_violations(root)

        self.assertEqual(
            violations,
            [
                AUDIT.CustomerVisibleValueViolation(
                    path=path.as_posix(),
                    key=key,
                    locale="en",
                )
            ],
        )

    def test_every_shipped_apple_catalog_is_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            retired_vendor = "".join(("WHO", "OP"))
            for relative_path in AUDIT.APPLE_LOCALIZATION_CATALOGS:
                catalog = root / relative_path
                catalog.parent.mkdir(parents=True)
                catalog.write_text(
                    json.dumps(
                        {
                            "sourceLanguage": "en",
                            "strings": {
                                "visible.value": {
                                    "localizations": {
                                        "en": {
                                            "stringUnit": {
                                                "state": "translated",
                                                "value": f"{retired_vendor} band",
                                            }
                                        }
                                    }
                                }
                            },
                        }
                    ),
                    encoding="utf-8",
                )

            violations = AUDIT.customer_visible_value_violations(root)

        self.assertEqual(len(violations), len(AUDIT.APPLE_LOCALIZATION_CATALOGS))
        self.assertEqual(
            {violation.path for violation in violations},
            set(AUDIT.APPLE_LOCALIZATION_CATALOGS),
        )
        self.assertEqual({violation.locale for violation in violations}, {"en"})

    def test_android_packaged_source_sets_and_locales_are_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            retired_vendor = "".join(("WHO", "OP"))
            resource_directories = (
                ("main", "values"),
                ("main", "values-de"),
                ("demo", "values"),
                ("debug", "values-fr"),
            )
            expected_paths = set()
            for source_set, values_directory in resource_directories:
                resource = (
                    root
                    / "android"
                    / "app"
                    / "src"
                    / source_set
                    / "res"
                    / values_directory
                    / "strings.xml"
                )
                resource.parent.mkdir(parents=True)
                resource.write_text(
                    "<resources>"
                    f'<string name="visible_value">{retired_vendor} band</string>'
                    "</resources>",
                    encoding="utf-8",
                )
                expected_paths.add(resource.relative_to(root).as_posix())

            violations = AUDIT.customer_visible_value_violations(root)

        self.assertEqual(len(violations), len(resource_directories))
        self.assertEqual(
            {violation.path for violation in violations},
            expected_paths,
        )
        self.assertEqual(
            {violation.locale for violation in violations},
            {"values", "values-de", "values-fr"},
        )

    def test_android_dynamic_customer_copy_is_sanitized_at_render_boundaries(self) -> None:
        whats_new = (
            ROOT / "android/app/src/main/java/com/noop/ui/WhatsNewSheet.kt"
        ).read_text(encoding="utf-8")
        onboarding = (
            ROOT / "android/app/src/main/java/com/noop/ui/OnboardingScreen.kt"
        ).read_text(encoding="utf-8")
        updates = (
            ROOT / "android/app/src/main/java/com/noop/ui/UpdatesInboxScreen.kt"
        ).read_text(encoding="utf-8")

        for required in (
            "Text(CustomerFacingBrand.text(e.title)",
            "Text(CustomerFacingBrand.text(e.body)",
            "CustomerFacingBrand.text(release.title)",
            "val rendered = CustomerFacingBrand.text(source)",
        ):
            self.assertIn(required, whats_new)
        self.assertIn(
            "Text(CustomerFacingBrand.text(e.title)",
            onboarding,
        )
        self.assertIn(
            "Text(CustomerFacingBrand.text(e.body)",
            onboarding,
        )
        self.assertIn(
            "val visibleTitle = CustomerFacingBrand.text(item.title)",
            updates,
        )
        self.assertIn(
            "val visibleMessage = CustomerFacingBrand.text(item.message)",
            updates,
        )

    def test_repository_snapshot_is_current(self) -> None:
        AUDIT.check(
            ROOT,
            ROOT / "release" / "terminology" / "legacy-inventory.json",
            ROOT / "release" / "terminology" / "active-allowlist.json",
        )


if __name__ == "__main__":
    unittest.main()
