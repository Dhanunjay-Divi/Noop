from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "release-legal-gate.py"
SPEC = importlib.util.spec_from_file_location("release_legal_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ReleaseLegalGateTests(unittest.TestCase):
    def test_exact_checked_inventory_is_current(self) -> None:
        inventory = GATE.checked_data()
        by_ecosystem: dict[str, int] = {}
        for component in inventory["components"]:
            ecosystem = component["ecosystem"]
            by_ecosystem[ecosystem] = by_ecosystem.get(ecosystem, 0) + 1
        self.assertEqual(
            by_ecosystem,
            {"swiftpm": 5, "maven": 139, "pypi": 20},
        )
        self.assertEqual(len(inventory["containers"]), 3)
        self.assertEqual(
            inventory["assetLicenseFiles"],
            [
                GATE.license_file("assets/musclemap.txt"),
            ],
        )

    def test_python_runtime_is_fully_hash_locked(self) -> None:
        requirements = GATE.requirement_entries(ROOT / "server" / "requirements.lock")
        self.assertEqual(set(requirements), set(GATE.PYTHON))

    def test_flattened_runtime_keeps_every_external_base_pinned(self) -> None:
        server_images = [
            item["name"]
            for item in GATE.container_components()
            if item["usedBy"] == "server/Dockerfile"
        ]
        self.assertEqual(len(server_images), 1)
        self.assertRegex(server_images[0], r"@sha256:[0-9a-f]{64}$")

    def test_distribution_passes_for_owner_controlled_repository(self) -> None:
        GATE.distribution_gate()

    def test_repository_rights_state_records_owner_controlled_clearance(self) -> None:
        status = GATE.verified_rights_status()
        self.assertEqual(status["distributionStatus"], "cleared")
        self.assertEqual(
            status["ownerRightsBasis"]["representation"],
            "noop-owner-controlled-source",
        )
        self.assertTrue(
            status["ownerRightsBasis"]["sourceAndContributionRightsControlled"]
        )
        self.assertEqual(
            status["thirdPartyDependencies"]["status"],
            "preserved-under-own-terms",
        )

    def test_noop_polyform_license_and_required_notice_remain(self) -> None:
        text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        for marker in GATE.PROJECT_LICENSE_MARKERS:
            self.assertIn(marker, text)
        self.assertEqual(
            (ROOT / "LICENSE").read_bytes(),
            (ROOT / "server" / "LICENSE").read_bytes(),
        )
        self.assertEqual(
            (ROOT / "LICENSE").read_bytes(),
            (ROOT / "server" / "backup" / "LICENSE").read_bytes(),
        )

    def test_independent_dependency_notices_remain_generated(self) -> None:
        GATE.checked_data()
        notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
        self.assertIn("Exact license and notice texts", notice)
        self.assertIn("===== ThirdPartyNotices/licenses/android/Apache-2.0.txt", notice)
        self.assertIn("===== ThirdPartyNotices/licenses/apple/grdb.swift.txt", notice)
        self.assertIn("===== ThirdPartyNotices/licenses/assets/musclemap.txt", notice)
        self.assertIn("===== ThirdPartyNotices/licenses/python/fastapi-", notice)

    def test_owner_declaration_is_mandatory(self) -> None:
        with mock.patch.object(
            GATE,
            "OWNER_DECLARATION_PATH",
            ROOT / "docs" / "provenance" / "missing-owner-declaration.md",
        ):
            with self.assertRaisesRegex(GATE.GateError, "declaration is missing"):
                GATE.verified_owner_declaration()

    def test_terms_acknowledgment_versions_match(self) -> None:
        self.assertEqual(GATE.verified_terms_version(), "2.5")


if __name__ == "__main__":
    unittest.main()
