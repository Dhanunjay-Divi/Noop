from __future__ import annotations

import os
import subprocess
import tempfile
import time
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
            '    run_git_bounded git "${GIT_HTTP_ARGS[@]}" \\\n'
            "      -c credential.helper=",
            source,
        )
        self.assertIn(
            'FORGE_TOKEN="$FORGE_TOKEN" FORGE_ORG="$FORGE_ORG" \\\n'
            '    run_git_bounded git "${GIT_HTTP_ARGS[@]}" \\\n'
            "      -c credential.helper=",
            source,
        )
        self.assertLess(
            source.index("unset GH_TOKEN"),
            source.index('push --quiet "$FORGE_TAP_URL" HEAD:main'),
        )

    def test_git_transport_has_a_hard_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "release.zip"
            archive.write_bytes(b"synthetic-release")
            binary_directory = root / "bin"
            binary_directory.mkdir()
            fake_git = binary_directory / "git"
            fake_git.write_text("#!/bin/sh\nsleep 5\n", encoding="utf-8")
            fake_git.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{binary_directory}:{environment['PATH']}",
                    "NOOP_HOMEBREW_TAP_ORG": "safe-owner",
                    "NOOP_HOMEBREW_GITHUB_TOKEN": "synthetic-secret",
                    "NOOP_HOMEBREW_GIT_TIMEOUT_SECONDS": "1",
                }
            )
            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), "9.2.1", str(archive)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            elapsed = time.monotonic() - started
            self.assertEqual(result.returncode, 1)
            self.assertLess(elapsed, 4)
            self.assertIn("exceeded its deadline", result.stderr)
            self.assertNotIn("synthetic-secret", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
