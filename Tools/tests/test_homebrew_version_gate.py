from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "homebrew-version-gate.py"
SPEC = importlib.util.spec_from_file_location("homebrew_version_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class HomebrewVersionGateTests(unittest.TestCase):
    def test_first_publication_has_no_existing_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            self.assertIsNone(
                GATE.existing_version(Path(temporary) / "noop.rb")
            )
        GATE.validate("9.2.1", None)

    def test_same_and_newer_versions_are_allowed(self) -> None:
        GATE.validate("9.2.1", "9.2.1")
        GATE.validate("10.0.0", "9.9.9")

    def test_backward_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "cannot move backward"):
            GATE.validate("9.2.1", "9.3.0")

    def test_existing_cask_must_have_one_numeric_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cask = Path(temporary) / "noop.rb"
            cask.write_text(
                'cask "noop" do\n  version "latest"\nend\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "numeric"):
                GATE.existing_version(cask)
            cask.write_text(
                'version "9.1.1"\nversion "9.2.1"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "exactly one"):
                GATE.existing_version(cask)


if __name__ == "__main__":
    unittest.main()
