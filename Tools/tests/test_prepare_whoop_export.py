from __future__ import annotations

import csv
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "validation" / "prepare_whoop_export.py"
SPEC = importlib.util.spec_from_file_location("prepare_whoop_export", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PREPARE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PREPARE
SPEC.loader.exec_module(PREPARE)


class PrepareWhoopExportTests(unittest.TestCase):
    def test_canonical_day_uses_wake_then_end_then_start_in_cycle_timezone(self) -> None:
        self.assertEqual(
            PREPARE.canonical_day(
                {
                    "Cycle timezone": "UTC-05:00",
                    "Cycle start time": "2026-01-01 23:00:00",
                    "Cycle end time": "2026-01-02 22:00:00",
                    "Wake onset": "2026-01-02 07:30:00",
                }
            ),
            "2026-01-02",
        )
        self.assertEqual(
            PREPARE.canonical_day(
                {
                    "Cycle timezone": "UTC+02:00",
                    "Cycle start time": "2026-01-01T21:30:00Z",
                    "Cycle end time": "2026-01-02T22:30:00Z",
                    "Wake onset": "",
                }
            ),
            "2026-01-03",
        )

    def test_prepare_collapses_activity_only_collision_and_excludes_ambiguous_day(self) -> None:
        headers = [
            "Cycle start time",
            "Cycle end time",
            "Cycle timezone",
            "Wake onset",
            "Recovery score %",
            "Resting heart rate (bpm)",
            "Heart rate variability (ms)",
            "Day Strain",
        ]
        rows = [
            {
                "Cycle start time": "2026-01-01 01:00:00",
                "Cycle end time": "2026-01-02 01:00:00",
                "Cycle timezone": "UTC",
                "Wake onset": "2026-01-01 08:00:00",
                "Recovery score %": "70",
                "Resting heart rate (bpm)": "60",
                "Heart rate variability (ms)": "50",
                "Day Strain": "8",
            },
            {
                "Cycle start time": "2025-12-31 01:00:00",
                "Cycle end time": "2026-01-01 01:00:00",
                "Cycle timezone": "UTC",
                "Wake onset": "",
                "Day Strain": "6",
            },
            {
                "Cycle start time": "2026-01-02 01:00:00",
                "Cycle end time": "2026-01-03 01:00:00",
                "Cycle timezone": "UTC",
                "Wake onset": "2026-01-02 08:00:00",
                "Recovery score %": "40",
                "Resting heart rate (bpm)": "70",
                "Heart rate variability (ms)": "30",
            },
            {
                "Cycle start time": "2026-01-02 14:00:00",
                "Cycle end time": "2026-01-03 14:00:00",
                "Cycle timezone": "UTC",
                "Wake onset": "2026-01-02 16:00:00",
                "Recovery score %": "80",
                "Resting heart rate (bpm)": "55",
                "Heart rate variability (ms)": "65",
            },
        ]

        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "export.zip"
            text = io.StringIO()
            writer = csv.DictWriter(text, fieldnames=headers)
            writer.writeheader()
            writer.writerows(rows)
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("physiological_cycles.csv", text.getvalue())

            prepared, total, collapsed, ambiguous = PREPARE.prepare(
                str(archive), "test-cohort"
            )

        self.assertEqual(total, 4)
        self.assertEqual(collapsed, 1)
        self.assertEqual(ambiguous, 1)
        self.assertEqual([row["day"] for row in prepared], ["2026-01-01"])
        self.assertEqual(prepared[0]["recovery"], 70.0)
        self.assertNotIn("start", prepared[0])
        self.assertNotIn("_start", prepared[0])


if __name__ == "__main__":
    unittest.main()
