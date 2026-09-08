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
        self.assertIn("--max-filesize 10485760", source)
        self.assertNotIn("/assets?limit=50&page=$page", source)
        self.assertIn('case "$REL_STATUS" in', source)
        self.assertNotIn("2>/dev/null || true", source)

    def test_interrupted_draft_refresh_still_blocks_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "release.bin"
            asset.write_bytes(b"synthetic-release")
            binary_directory = root / "bin"
            binary_directory.mkdir()
            fake_curl = binary_directory / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import sys\n"
                "url = next((value for value in reversed(sys.argv[1:]) "
                "if value.startswith('https://')), '')\n"
                "if '/releases?' not in url:\n"
                "    raise SystemExit(9)\n"
                "if 'draft=true' in url:\n"
                "    print(json.dumps([{\n"
                "        'id': 7,\n"
                "        'tag_name': 'v9.3.0',\n"
                "        'draft': True,\n"
                "        'prerelease': False,\n"
                "    }]))\n"
                "else:\n"
                "    print('[]')\n",
                encoding="utf-8",
            )
            fake_curl.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{binary_directory}:{environment['PATH']}",
                    "FORGE_DOMAIN": "forge.example.invalid",
                    "FORGE_ORG": "noop",
                    "FORGE_REPO": "noop",
                    "FORGE_TARGET_COMMITISH": "a" * 40,
                    "NOOP_FORGEJO_TOKEN": "synthetic-secret",
                }
            )
            result = subprocess.run(
                [str(SCRIPT), "9.2.1", str(asset)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("cannot move backward", result.stderr)
            self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_asset_refresh_is_bounded_and_publishes_only_an_exact_set(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--connect-timeout 10 --max-time 600", source)
        self.assertIn("--location -fsS --output", source)
        self.assertIn('.type == "attachment"', source)
        self.assertIn(".browser_download_url == ($download_root + .name)", source)
        self.assertIn(
            "Forgejo release asset set is not exact; release remains draft",
            source,
        )
        self.assertIn(
            "Forgejo release asset set changed during publication; release is draft",
            source,
        )
        self.assertGreaterEqual(source.count("verify_remote_payloads"), 3)
        self.assertIn("Forgejo publication drift rollback failed", source)
        self.assertIn("Forgejo ambiguous publication rollback failed", source)
        self.assertIn(
            "Forgejo publication response failed; release is draft",
            source,
        )
        self.assertIn("return_release_to_draft", source)
        clear_assets = source.index(
            'api -X DELETE \\\n'
            '      "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$asset_id"'
        )
        publish = source.index(
            'if ! PUBLISHED_RELEASE="$(\n'
            '  api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID"'
        )
        self.assertLess(clear_assets, publish)

    def test_idempotent_release_requires_canonical_name_and_notes(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        exact_exit = source.index(
            "is already published with the exact verified asset set"
        )
        for condition in (
            '[ "$REMOTE_NAME" = "NOOP $TAG" ]',
            '[ "$REMOTE_BODY" = "$NOTES" ]',
        ):
            self.assertLess(source.index(condition), exact_exit)
        self.assertIn(
            "existing release has exact assets; reconciling canonical metadata",
            source,
        )
        self.assertIn(
            '[ "$(jq -r \'.body\' <<<"$PUBLISHED_RELEASE")" = "$NOTES" ]',
            source,
        )


if __name__ == "__main__":
    unittest.main()
