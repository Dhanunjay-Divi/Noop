from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "update-homebrew-cask.sh"


class HomebrewHelperTests(unittest.TestCase):
    def run_helper(
        self, version: str, tap_owner: str
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "release.zip"
            archive.write_bytes(b"synthetic-release")
            environment = os.environ.copy()
            environment.update(
                {
                    "NOOP_HOMEBREW_TAP_ORG": tap_owner,
                    "NOOP_HOMEBREW_GITHUB_TOKEN": "synthetic-secret",
                }
            )
            return subprocess.run(
                [str(SCRIPT), version, str(archive)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )

    def test_rejects_unsafe_repository_coordinate_before_network(self) -> None:
        result = self.run_helper("9.2.1", "owner;invalid")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid Homebrew repository coordinate", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_rejects_invalid_version_before_network(self) -> None:
        result = self.run_helper("9.2.1;invalid", "safe-owner")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid Homebrew release version", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_requested_forge_mirror_failure_is_not_hidden(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "Forge mirror push failed; the canonical GitHub tap is current.",
            source,
        )
        self.assertNotIn("⚠ Forge mirror push failed", source)


if __name__ == "__main__":
    unittest.main()
