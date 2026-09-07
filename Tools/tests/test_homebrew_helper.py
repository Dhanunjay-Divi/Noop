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

    def test_already_current_github_tap_still_retries_forge_mirror(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        unchanged = source.index(
            "Homebrew cask already current for ${VER} on GitHub."
        )
        forge_push = source.index(
            'push --quiet "$FORGE_TAP_URL" HEAD:main'
        )
        self.assertLess(unchanged, forge_push)
        self.assertNotIn(
            "Homebrew cask already current for ${VER} — nothing to push.",
            source,
        )

    def test_each_git_push_receives_only_its_host_token(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("export GH_TOKEN", source)
        self.assertNotIn("export FORGE_TOKEN", source)
        self.assertIn(
            'GH_TOKEN="$GH_TOKEN" TAP_ORG="$TAP_ORG" \\\n'
            "    git -c credential.helper=",
            source,
        )
        self.assertIn(
            'FORGE_TOKEN="$FORGE_TOKEN" FORGE_ORG="$FORGE_ORG" \\\n'
            "    git -c credential.helper=",
            source,
        )
        self.assertLess(
            source.index("unset GH_TOKEN"),
            source.index('push --quiet "$FORGE_TAP_URL" HEAD:main'),
        )


if __name__ == "__main__":
    unittest.main()
