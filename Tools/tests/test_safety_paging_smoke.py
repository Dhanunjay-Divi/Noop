from __future__ import annotations

import asyncio
import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "safety-paging-smoke.py"
SPEC = importlib.util.spec_from_file_location("safety_paging_smoke", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SMOKE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SMOKE
try:
    SPEC.loader.exec_module(SMOKE)
except ModuleNotFoundError as error:
    if error.name != "cryptography":
        raise
    raise unittest.SkipTest(
        "server cryptography dependency is required for the Safety smoke"
    ) from error


class SafetyPagingSmokeTests(unittest.TestCase):
    def test_synthetic_smoke_covers_owner_and_both_mobile_platforms(self) -> None:
        report = asyncio.run(SMOKE.run_smoke())

        self.assertEqual(report["external_network_requests"], 0)
        self.assertFalse(report["real_people_contacted"])
        self.assertFalse(report["emergency_services_contacted"])
        self.assertEqual(
            report["summary"],
            {
                "contacts_targeted": 2,
                "contacts_reached": 2,
                "installations_targeted": 3,
                "installations_reached": 3,
            },
        )
        self.assertEqual(
            [delivery["role"] for delivery in report["deliveries"]],
            [
                "owner_test_confirmation",
                "emergency_contact_1",
                "emergency_contact_2",
            ],
        )
        self.assertEqual(
            {delivery["platform"] for delivery in report["deliveries"]},
            {"ios", "android"},
        )
        self.assertTrue(
            all(
                delivery["contains_sensitive_values"] is False
                for delivery in report["deliveries"]
            )
        )
        self.assertTrue(
            report["recipient_scope"].startswith("Preselected dummy recipients")
        )
        self.assertTrue(
            report["location_scope"].startswith("No location is created or sent")
        )
        self.assertTrue(report["owner_test_behavior"].startswith("Test-only"))
        self.assertTrue(
            report["real_incident_owner_behavior"].startswith(
                "The owner sees incident"
            )
        )
