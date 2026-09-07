from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "forgejo-version-gate.py"
SPEC = importlib.util.spec_from_file_location("forgejo_version_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ForgejoVersionGateTests(unittest.TestCase):
    def test_first_publication_has_no_existing_version(self) -> None:
        self.assertIsNone(GATE.latest_stable_history_version([]))
        GATE.validate("9.2.1", None)

    def test_latest_stable_history_includes_interrupted_draft_refresh(self) -> None:
        releases = [
            {"tag_name": "v9.2.1", "draft": False, "prerelease": False},
            {"tag_name": "v10.0.0", "draft": True, "prerelease": False},
            {"tag_name": "v9.9.0", "draft": False, "prerelease": True},
            {"tag_name": "stable", "draft": False, "prerelease": False},
            {"tag_name": "v9.3.0", "draft": False, "prerelease": False},
        ]
        self.assertEqual(
            GATE.latest_stable_history_version(releases),
            "10.0.0",
        )

    def test_same_and_newer_versions_are_allowed(self) -> None:
        GATE.validate("9.2.1", "9.2.1")
        GATE.validate("10.0.0", "9.9.9")

    def test_backward_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "cannot move backward"):
            GATE.validate("9.2.1", "9.3.0")

    def test_release_history_must_have_typed_entries(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "JSON array"):
            GATE.latest_stable_history_version({})
        with self.assertRaisesRegex(GATE.GateError, "invalid entry"):
            GATE.latest_stable_history_version(
                [{"tag_name": "v9.2.1", "draft": "false", "prerelease": False}]
            )


if __name__ == "__main__":
    unittest.main()
