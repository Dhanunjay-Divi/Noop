from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "altstore-source.py"
SPEC = importlib.util.spec_from_file_location("altstore_source", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)


def sample(version: str = "9.1.1") -> dict:
    return {
        "sourceURL": "https://example.com/source.json",
        "apps": [
            {
                "versions": [
                    {
                        "version": version,
                        "buildVersion": "208",
                        "minOSVersion": "17.0",
                    }
                ]
            }
        ],
    }


class AltStoreSourceTests(unittest.TestCase):
    def update(self, payload: dict, version: str = "9.2.1") -> dict:
        return SOURCE.update_source(
            payload,
            source_url="https://example.com/stable/source.json",
            version=version,
            build="231",
            published_date="2026-09-07",
            description="NOOP release",
            download_url=f"https://example.com/releases/v{version}/app.ipa",
            size=1234,
        )

    def test_update_prepends_and_mirrors_release(self) -> None:
        updated = self.update(sample())
        app = updated["apps"][0]
        self.assertEqual(
            updated["sourceURL"], "https://example.com/stable/source.json"
        )
        self.assertEqual(app["versions"][0]["version"], "9.2.1")
        self.assertEqual(app["version"], "9.2.1")
        self.assertEqual(app["buildVersion"], "231")
        self.assertEqual(app["size"], 1234)
        self.assertEqual(len(app["versions"]), 2)

    def test_same_version_update_is_idempotently_deduplicated(self) -> None:
        first = self.update(sample())
        second = self.update(first)
        versions = second["apps"][0]["versions"]
        self.assertEqual(
            [entry["version"] for entry in versions].count("9.2.1"),
            1,
        )

    def test_older_version_cannot_replace_current_source(self) -> None:
        with self.assertRaisesRegex(SOURCE.SourceError, "cannot move backward"):
            self.update(sample("9.3.0"), version="9.2.1")

    def test_unsorted_history_cannot_hide_a_newer_version(self) -> None:
        payload = sample("9.1.1")
        payload["apps"][0]["versions"].append(
            {
                "version": "9.3.0",
                "buildVersion": "240",
                "minOSVersion": "17.0",
            }
        )
        with self.assertRaisesRegex(SOURCE.SourceError, "cannot move backward"):
            self.update(payload, version="9.2.1")

    def test_same_version_build_cannot_move_backward(self) -> None:
        payload = sample("9.2.1")
        payload["apps"][0]["versions"][0]["buildVersion"] = "240"
        with self.assertRaisesRegex(SOURCE.SourceError, "build cannot move backward"):
            self.update(payload, version="9.2.1")

    def test_invalid_source_shape_is_rejected(self) -> None:
        with self.assertRaisesRegex(SOURCE.SourceError, "primary app"):
            self.update({"apps": []})


if __name__ == "__main__":
    unittest.main()
