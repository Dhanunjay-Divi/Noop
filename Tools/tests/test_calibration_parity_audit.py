from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "calibration-parity-audit.py"
SPEC = importlib.util.spec_from_file_location("calibration_parity_audit", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class CalibrationParityAuditTests(unittest.TestCase):
    def test_repository_contract_matches_both_platforms(self) -> None:
        result = AUDIT.audit(ROOT)
        self.assertEqual(result["metrics"], 12)
        self.assertEqual(result["algorithmRevisions"], 3)
        self.assertEqual(result["criticalGuards"], 16)

    def test_threshold_drift_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (
                AUDIT.SWIFT_PATH,
                AUDIT.KOTLIN_PATH,
                "release/metrics/reference-calibration-v1.json",
            ):
                source = ROOT / relative
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            kotlin = root / AUDIT.KOTLIN_PATH
            kotlin.write_text(
                kotlin.read_text(encoding="utf-8").replace(
                    "val minimumPairs: Int = 28",
                    "val minimumPairs: Int = 27",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                AUDIT.AuditError,
                "Kotlin minimumPairs calibration threshold drift",
            ):
                AUDIT.audit(root)

    def test_contract_cannot_remove_a_platform_metric(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (
                AUDIT.SWIFT_PATH,
                AUDIT.KOTLIN_PATH,
                "release/metrics/reference-calibration-v1.json",
            ):
                source = ROOT / relative
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            contract = root / "release/metrics/reference-calibration-v1.json"
            text = contract.read_text(encoding="utf-8")
            start = text.index('    {\n      "kotlin": "SLEEP_EFFICIENCY_PERCENT"')
            end = text.index("\n    }", start) + len("\n    }")
            contract.write_text(
                text[:start].rstrip(",\n") + "\n  ]," + text[end + len("\n  ],") :],
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                AUDIT.AuditError,
                "Swift comparable metric set drift",
            ):
                AUDIT.audit(root)


if __name__ == "__main__":
    unittest.main()
