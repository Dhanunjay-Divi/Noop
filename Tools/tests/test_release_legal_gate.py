from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
