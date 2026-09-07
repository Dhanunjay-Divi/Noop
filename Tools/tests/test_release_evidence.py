from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "release-evidence.py"
SPEC = importlib.util.spec_from_file_location("release_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


def run(root: Path, *args: str) -> None:
    subprocess.run(
        list(args),
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def make_source_repo(root: Path) -> None:
    (root / "ThirdPartyNotices").mkdir(parents=True)
    (root / "release" / "evidence").mkdir(parents=True)
    inventory = {
        "schemaVersion": 1,
        "generatedFrom": ["fixture"],
        "components": [
            {
                "ecosystem": "pypi",
                "name": "example",
                "version": "1.2.3",
                "license": "MIT",
                "source": "https://example.invalid/example",
                "licenseFiles": [],
            }
        ],
        "containers": [
            {
                "ecosystem": "oci",
                "name": "example.invalid/noop/runtime:1@sha256:" + ("a" * 64),
                "usedBy": "Dockerfile",
            }
        ],
        "assetLicenseFiles": [],
    }
    (root / EVIDENCE.INVENTORY_PATH).write_text(
        json.dumps(inventory, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (root / EVIDENCE.POLICY_PATH).write_text("{}\n", encoding="utf-8")
    (root / EVIDENCE.SCHEMA_PATH).write_text("{}\n", encoding="utf-8")
    run(root, "git", "init", "-q")
    run(root, "git", "config", "user.name", "NOOP Test")
    run(root, "git", "config", "user.email", "noop-test@invalid.example")
    run(root, "git", "add", ".")
    run(root, "git", "commit", "-qm", "fixture")


class ReleaseEvidenceTests(unittest.TestCase):
    def test_repository_sbom_is_deterministic_and_complete(self) -> None:
        first = EVIDENCE.generate_sbom(ROOT, "HEAD", "9.2.1")
        second = EVIDENCE.generate_sbom(ROOT, "HEAD", "9.2.1")
        self.assertEqual(
            EVIDENCE.canonical_json(first),
            EVIDENCE.canonical_json(second),
        )
        self.assertEqual(first["bomFormat"], "CycloneDX")
        self.assertEqual(first["specVersion"], "1.5")
        self.assertEqual(len(first["components"]), 216)
        self.assertEqual(
            sum(item["type"] == "container" for item in first["components"]),
            3,
        )

    def test_manifest_records_only_basenames_hashes_sizes_and_static_checks(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            make_source_repo(root)
            output = Path(temporary) / "output"
            output.mkdir()
            artifact = output / "NOOP-source-v1.0.0.cdx.json"
            artifact.write_text('{"bomFormat":"CycloneDX"}\n', encoding="utf-8")
            checks = output / "release-controls.json"
            checks.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "checks": [
                            {"name": "release-policy", "status": "passed"}
                        ],
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            manifest = EVIDENCE.generate_manifest(
                root,
                "HEAD",
                "1.0.0",
                [artifact, checks],
                checks,
            )
            manifest_path = output / "NOOP-source-v1.0.0.manifest.json"
            EVIDENCE.write_json(manifest_path, manifest)
            EVIDENCE.verify_manifest(
                root,
                manifest_path,
                output,
                "HEAD",
            )
            for record in manifest["artifacts"]:
                self.assertEqual(
                    set(record),
                    {"name", "sha256", "size", "mediaType"},
                )
                self.assertNotIn("/", record["name"])
            self.assertEqual(
                set(manifest["checks"][0]),
                {"name", "status"},
            )

    def test_artifact_tamper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            make_source_repo(root)
            output = Path(temporary) / "output"
            output.mkdir()
            artifact = output / "NOOP-source-v1.0.0.cdx.json"
            artifact.write_text("{}\n", encoding="utf-8")
            checks = output / "release-controls.json"
            checks.write_text(
                '{"checks":[{"name":"release-policy","status":"passed"}],'
                '"schemaVersion":1}\n',
                encoding="utf-8",
            )
            manifest = EVIDENCE.generate_manifest(
                root, "HEAD", "1.0.0", [artifact], checks
            )
            manifest_path = output / "manifest.json"
            EVIDENCE.write_json(manifest_path, manifest)
            artifact.write_text('{"changed":true}\n', encoding="utf-8")
            with self.assertRaisesRegex(EVIDENCE.EvidenceError, "digest mismatch"):
                EVIDENCE.verify_manifest(root, manifest_path, output, "HEAD")

    def test_manifest_rejects_paths_and_nonpassed_checks(self) -> None:
        valid = {
            "schemaVersion": 1,
            "product": "NOOP",
            "releaseVersion": "1.0.0",
            "source": {
                "repository": EVIDENCE.CANONICAL_REPOSITORY,
                "commit": "a" * 40,
                "tree": "b" * 40,
            },
            "policy": {"name": "release-policy.json", "sha256": "c" * 64},
            "manifestSchema": {
                "name": "manifest.schema.json",
                "sha256": "d" * 64,
            },
            "artifacts": [
                {
                    "name": "NOOP-source-v1.0.0.cdx.json",
                    "sha256": "e" * 64,
                    "size": 1,
                    "mediaType": "application/vnd.cyclonedx+json",
                }
            ],
            "checks": [{"name": "release-policy", "status": "passed"}],
        }
        EVIDENCE.validate_manifest(valid)
        unsafe = copy.deepcopy(valid)
        unsafe["artifacts"][0]["name"] = "../private.json"
        with self.assertRaises(EVIDENCE.EvidenceError):
            EVIDENCE.validate_manifest(unsafe)
        failed = copy.deepcopy(valid)
        failed["checks"][0]["status"] = "failed"
        with self.assertRaises(EVIDENCE.EvidenceError):
            EVIDENCE.validate_manifest(failed)

    def test_checked_in_manifest_schema_is_valid_json(self) -> None:
        schema = json.loads(
            (ROOT / EVIDENCE.SCHEMA_PATH).read_text(encoding="utf-8")
        )
        self.assertEqual(schema["type"], "object")
        self.assertFalse(schema["additionalProperties"])


if __name__ == "__main__":
    unittest.main()
