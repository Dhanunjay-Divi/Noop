from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "BrandLocalization" / "generate.py"
SPEC = importlib.util.spec_from_file_location("brand_localization", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class BrandLocalizationTests(unittest.TestCase):
    def test_reused_entries_cover_every_shipping_locale(self) -> None:
        catalog = GENERATOR.load_json(GENERATOR.DEFAULT_CATALOG)
        expected = GENERATOR.expected_entries(catalog)

        self.assertEqual(len(expected), 15)
        self.assertEqual(GENERATOR.verify_catalog(catalog, expected), [])
        for current, entry in expected.items():
            self.assertEqual(
                set(entry["localizations"]),
                set(GENERATOR.REQUIRED_LOCALES),
            )
            predecessor = GENERATOR.MAPPINGS[current]
            for localized in entry["localizations"].values():
                value = localized["stringUnit"]["value"]
                self.assertNotIn(value, {current, predecessor})

    def test_localized_literals_are_not_hidden_in_the_baseline(self) -> None:
        baseline = GENERATOR.load_json(GENERATOR.DEFAULT_BASELINE)

        self.assertEqual(GENERATOR.verify_baseline(baseline), [])

    def test_questionable_inherited_values_remain_visible_for_review(self) -> None:
        catalog = GENERATOR.load_json(GENERATOR.DEFAULT_CATALOG)
        baseline = GENERATOR.load_json(GENERATOR.DEFAULT_BASELINE)

        self.assertEqual(
            GENERATOR.verify_deferred_review(catalog, baseline),
            [],
        )
        self.assertTrue(all(GENERATOR.LOCALE_OWNER_REVIEW.values()))
        self.assertEqual(
            set(GENERATOR.LOCALE_OWNER_REVIEW),
            set(GENERATOR.LOCALE_OWNER_REVIEW_PATHS),
        )


if __name__ == "__main__":
    unittest.main()
