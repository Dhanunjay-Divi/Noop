from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "FeedbackLocalization" / "generate.py"
SPEC = importlib.util.spec_from_file_location("feedback_localization", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class FeedbackLocalizationTests(unittest.TestCase):
    def test_all_platform_resources_share_the_same_nine_locale_contract(
        self,
    ) -> None:
        entries = GENERATOR.expected_entries()

        self.assertGreaterEqual(len(entries), 86)
        self.assertEqual(GENERATOR.verify(entries), [])
        for entry in entries.values():
            self.assertEqual(
                set(entry["localizations"]),
                set(GENERATOR.LOCALE_FILES),
            )

    def test_android_placeholders_are_converted_for_apple(self) -> None:
        self.assertEqual(
            GENERATOR.apple_format("Receipt: %1$s"),
            "Receipt: %1$@",
        )
        self.assertEqual(
            GENERATOR.apple_format("%1$d%%"),
            "%1$lld%%",
        )

    def test_apple_specific_truth_variants_are_part_of_the_shared_contract(
        self,
    ) -> None:
        entries = GENERATOR.expected_entries()

        for key in (
            "app_report_privacy_detail_apple",
            "app_report_status_sent_cleanup_pending",
            "app_report_status_canceled_cleanup_pending",
            "app_report_send_disclosure",
        ):
            with self.subTest(key=key):
                self.assertIn(key, entries)


if __name__ == "__main__":
    unittest.main()
