from __future__ import annotations

import importlib.util
import json
import tempfile
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
            {"swiftpm": 5, "maven": 127, "pypi": 20},
        )
        self.assertEqual(len(inventory["containers"]), 3)

    def test_python_runtime_is_fully_hash_locked(self) -> None:
        requirements = GATE.requirement_entries(ROOT / "server" / "requirements.lock")
        self.assertEqual(set(requirements), set(GATE.PYTHON))

    def test_distribution_fails_closed_on_inherited_no_license_code(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "DISTRIBUTION BLOCKED"):
            GATE.distribution_gate()

    def test_repository_rights_state_keeps_every_known_blocker(self) -> None:
        status = GATE.verified_rights_status()
        blockers = {item["id"]: item["status"] for item in status["blockers"]}
        self.assertEqual(status["distributionStatus"], "blocked")
        self.assertEqual(
            blockers,
            {
                "polyform-upstream-lineage": "unresolved",
                "unlicensed-whoop4-expression": "unresolved",
                "contributor-relicensing-rights": "unresolved",
            },
        )

    def test_unresolved_provenance_markers_are_present(self) -> None:
        GATE.verified_rights_status()
        for relative, markers in GATE.UNRESOLVED_PROVENANCE_MARKERS.items():
            text = (ROOT / relative).read_text(encoding="utf-8")
            for marker in markers:
                self.assertIn(marker, text, f"{relative} must retain {marker!r}")

    def test_required_blocker_cannot_be_deleted_from_rights_state(self) -> None:
        status = GATE.verified_rights_status()
        status["blockers"] = [
            item
            for item in status["blockers"]
            if item["id"] != "polyform-upstream-lineage"
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rights-status.json"
            path.write_text(json.dumps(status), encoding="utf-8")
            with mock.patch.object(GATE, "RIGHTS_STATUS_PATH", path):
                with self.assertRaisesRegex(
                    GATE.GateError, "removed without resolution"
                ):
                    GATE.verified_rights_status()

    def test_terms_acknowledgment_versions_match(self) -> None:
        self.assertEqual(GATE.verified_terms_version(), "2.3")


if __name__ == "__main__":
    unittest.main()
