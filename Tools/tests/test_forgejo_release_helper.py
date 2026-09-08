from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "forgejo-release.sh"


class ForgejoReleaseHelperTests(unittest.TestCase):
    def run_forge_scenario(
        self, scenario: str
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "release.bin"
            asset.write_bytes(b"synthetic-release")
            state_file = root / "state.json"
            binary_directory = root / "bin"
            binary_directory.mkdir()
            fake_curl = binary_directory / "curl"
            fake_curl.write_text(
                """#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

args = sys.argv[1:]
scenario = os.environ["FAKE_FORGE_SCENARIO"]
state_path = Path(os.environ["FAKE_FORGE_STATE"])
asset_path = Path(os.environ["FAKE_FORGE_ASSET"])
target = os.environ["FORGE_TARGET_COMMITISH"]
state = (
    json.loads(state_path.read_text(encoding="utf-8"))
    if state_path.exists()
    else {"events": [], "assets": [], "published": False}
)

def option_value(name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None

def save():
    state_path.write_text(json.dumps(state), encoding="utf-8")

def emit(payload, *, status=None):
    text = payload if isinstance(payload, str) else json.dumps(payload)
    output = option_value("--output")
    if output:
        Path(output).write_text(text, encoding="utf-8")
    elif text:
        print(text)
    if status is not None:
        print(status, end="")
    save()

url = next(
    (value for value in reversed(args) if value.startswith("https://")), ""
)
method = option_value("-X") or ("POST" if "-F" in args else "GET")
path = urlparse(url).path
state["events"].append({"method": method, "path": path})

release = {
    "id": 7,
    "tag_name": "v9.2.1",
    "target_commitish": target,
    "name": "NOOP v9.2.1",
    "body": "NOOP v9.2.1 — see CHANGELOG.md.",
    "draft": not state["published"],
    "prerelease": False,
}

if "/releases/download/" in path:
    output = option_value("--output")
    if not output:
        save()
        raise SystemExit(8)
    shutil.copyfile(asset_path, output)
    save()
elif "/releases?" in url:
    emit([])
elif path.endswith("/releases/tags/v9.2.1"):
    emit("{}", status="404")
elif path.endswith("/releases") and method == "POST":
    if scenario in {"public_create", "public_create_rollback_failure"}:
        state["published"] = True
        release["draft"] = False
    emit(release)
elif path.endswith("/releases/7/assets") and method == "POST":
    name = parse_qs(urlparse(url).query)["name"][0]
    uploaded = {
        "id": 11,
        "name": name,
        "size": asset_path.stat().st_size,
        "type": "attachment",
        "browser_download_url": (
            f"https://forge.example.invalid/noop/noop/releases/download/"
            f"v9.2.1/{name}"
        ),
    }
    state["assets"] = [uploaded]
    emit(uploaded)
elif path.endswith("/releases/7/assets") and method == "GET":
    if scenario == "post_publish_asset_lookup_failure" and state["published"]:
        save()
        raise SystemExit(9)
    emit(state["assets"])
elif path.endswith("/releases/7") and method == "PATCH":
    payload = json.loads(option_value("-d") or "{}")
    if payload.get("draft") is True:
        state["events"][-1]["operation"] = "rollback"
        if scenario in {
            "public_create_rollback_failure",
            "invalid_publication_rollback_failure",
        }:
            save()
            raise SystemExit(9)
        state["published"] = False
        release["draft"] = True
        emit(release)
    else:
        state["events"][-1]["operation"] = "publish"
        state["published"] = True
        release["draft"] = False
        if scenario in {
            "invalid_publication",
            "invalid_publication_rollback_failure",
        }:
            release["target_commitish"] = "b" * 40
        emit(release)
else:
    save()
    raise SystemExit(7)
""",
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
                    "FAKE_FORGE_SCENARIO": scenario,
                    "FAKE_FORGE_STATE": str(state_file),
                    "FAKE_FORGE_ASSET": str(asset),
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
            state = json.loads(state_file.read_text(encoding="utf-8"))
            return result, state

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
        self.assertIn("Forgejo invalid publication rollback failed", source)
        self.assertIn(
            "Forgejo publication metadata is invalid; release is draft",
            source,
        )
        self.assertIn("return_release_to_draft", source)
        response_validation = source.index(
            '[ "$(jq -r \'.draft\' <<<"$PUBLISHED_RELEASE")" = "false" ]'
        )
        invalid_metadata = source.index(
            "Forgejo publication metadata is invalid; release is draft"
        )
        metadata_rollback = source.index(
            "return_release_to_draft", response_validation
        )
        self.assertLess(metadata_rollback, invalid_metadata)
        clear_assets = source.index(
            'api -X DELETE \\\n'
            '      "$API/repos/$ORG/$REPO/releases/$REL_ID/assets/$asset_id"'
        )
        publish = source.index(
            'if ! PUBLISHED_RELEASE="$(\n'
            '  api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID"'
        )
        self.assertLess(clear_assets, publish)

    def test_unexpected_public_creation_is_returned_to_draft(self) -> None:
        result, state = self.run_forge_scenario("public_create")
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "created a release with an invalid identity; release is draft",
            result.stderr,
        )
        self.assertFalse(state["published"])
        self.assertEqual(
            [event.get("operation") for event in state["events"]],
            [None, None, None, None, "rollback"],
        )
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_post_publish_asset_lookup_failure_is_returned_to_draft(self) -> None:
        result, state = self.run_forge_scenario(
            "post_publish_asset_lookup_failure"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "release asset set changed during publication; release is draft",
            result.stderr,
        )
        self.assertFalse(state["published"])
        operations = [
            event.get("operation")
            for event in state["events"]
            if event.get("operation")
        ]
        self.assertEqual(operations, ["publish", "rollback"])
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_invalid_publication_metadata_is_returned_to_draft(self) -> None:
        result, state = self.run_forge_scenario("invalid_publication")
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "publication metadata is invalid; release is draft",
            result.stderr,
        )
        self.assertFalse(state["published"])
        operations = [
            event.get("operation")
            for event in state["events"]
            if event.get("operation")
        ]
        self.assertEqual(operations, ["publish", "rollback"])
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_failed_public_creation_rollback_is_explicit(self) -> None:
        result, state = self.run_forge_scenario(
            "public_create_rollback_failure"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid creation rollback failed", result.stderr)
        self.assertTrue(state["published"])
        self.assertEqual(state["events"][-1].get("operation"), "rollback")
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

    def test_failed_invalid_publication_rollback_is_explicit(self) -> None:
        result, state = self.run_forge_scenario(
            "invalid_publication_rollback_failure"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid publication rollback failed", result.stderr)
        self.assertTrue(state["published"])
        operations = [
            event.get("operation")
            for event in state["events"]
            if event.get("operation")
        ]
        self.assertEqual(operations, ["publish", "rollback"])
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)

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
