from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "release-version-gate.py"
SPEC = importlib.util.spec_from_file_location("release_version_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ReleaseVersionGateTests(unittest.TestCase):
    def test_repository_advances_from_latest_published_release(self) -> None:
        current = GATE.current_state(ROOT)
        previous = GATE.previous_state(ROOT, "v9.1.1")
        GATE.validate_transition(current, "9.2.1", previous)

    def test_reused_android_build_number_is_rejected(self) -> None:
        previous = GATE.VersionState((9, 1, 1), 299, 208)
        current = GATE.VersionState((9, 2, 1), 299, 231)
        with self.assertRaisesRegex(GATE.GateError, "Android versionCode"):
            GATE.validate_transition(current, "9.2.1", previous)

    def test_reused_apple_build_number_is_rejected(self) -> None:
        previous = GATE.VersionState((9, 1, 1), 299, 208)
        current = GATE.VersionState((9, 2, 1), 304, 208)
        with self.assertRaisesRegex(
            GATE.GateError, "Apple CURRENT_PROJECT_VERSION"
        ):
            GATE.validate_transition(current, "9.2.1", previous)

    def test_non_advancing_marketing_version_is_rejected(self) -> None:
        previous = GATE.VersionState((9, 2, 1), 299, 208)
        current = GATE.VersionState((9, 2, 1), 304, 231)
        with self.assertRaisesRegex(GATE.GateError, "version must advance"):
            GATE.validate_transition(current, "9.2.1", previous)

    def test_platform_marketing_version_mismatch_is_rejected(self) -> None:
        android = 'versionCode = 304\nversionName = "9.2.1"\n'
        apple = (
            'MARKETING_VERSION: "9.2.0"\n'
            'CURRENT_PROJECT_VERSION: "231"\n'
        )
        with self.assertRaisesRegex(
            GATE.GateError, "marketing versions differ"
        ):
            GATE.parse_state(android, apple)

    def test_confirmed_version_must_match_source(self) -> None:
        current = GATE.VersionState((9, 2, 1), 304, 231)
        with self.assertRaisesRegex(
            GATE.GateError, "confirmed version does not match"
        ):
            GATE.validate_transition(current, "9.2.0", None)


if __name__ == "__main__":
    unittest.main()
