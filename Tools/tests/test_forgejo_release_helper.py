from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "forgejo-release.sh"


class ForgejoReleaseHelperTests(unittest.TestCase):
    def run_helper(
        self,
        *,
        version: str = "9.2.1",
        domain: str = "forge.example.invalid",
        organization: str = "noop",
        repository: str = "noop",
        target: str = "a" * 40,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            asset = Path(temporary) / "release.bin"
            asset.write_bytes(b"synthetic-release")
            environment = os.environ.copy()
            environment.update(
                {
                    "FORGE_DOMAIN": domain,
                    "FORGE_ORG": organization,
                    "FORGE_REPO": repository,
                    "FORGE_TARGET_COMMITISH": target,
                    "NOOP_FORGEJO_TOKEN": "synthetic-secret",
                }
            )
            return subprocess.run(
                [str(SCRIPT), version, str(asset)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )

    def test_rejects_unsafe_repository_coordinate_before_network(self) -> None:
        result = self.run_helper(domain="forge.example.invalid/path")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid Forgejo repository coordinate", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_requires_exact_target_commit_before_network(self) -> None:
        result = self.run_helper(target="main")
        self.assertEqual(result.returncode, 2)
        self.assertIn("exact lowercase commit SHA", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_rejects_invalid_version_before_network(self) -> None:
        result = self.run_helper(version="9.2.1;invalid")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid Forgejo release version", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_secret_is_supplied_through_private_curl_config(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--config "$AUTH_CONFIG"', source)
        self.assertNotIn('Authorization: token $TOKEN"', source)
        self.assertIn("unset TOKEN NOOP_FORGEJO_TOKEN", source)

    def test_version_history_is_checked_before_release_mutation(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        gate = source.index("Tools/forgejo-version-gate.py")
        create = source.index('api -X POST "$API/repos/$ORG/$REPO/releases"')
        update = source.index('api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID"')
        self.assertLess(gate, create)
        self.assertLess(gate, update)
        self.assertIn("Forgejo release history exceeded the bounded page limit", source)
        self.assertIn('case "$REL_STATUS" in', source)
        self.assertNotIn("2>/dev/null || true", source)


if __name__ == "__main__":
    unittest.main()
