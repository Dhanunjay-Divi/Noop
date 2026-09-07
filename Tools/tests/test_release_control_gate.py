from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "release-control-gate.py"
SPEC = importlib.util.spec_from_file_location("release_control_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ReleaseControlGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = GATE.load_policy(ROOT / "release" / "release-policy.json")

    def test_machine_policy_is_fail_closed(self) -> None:
        GATE.validate_policy(self.policy)
        self.assertEqual(
            self.policy["migrations"]["strategy"],
            "expand-migrate-verify-contract",
        )
        self.assertEqual(
            self.policy["vulnerabilityPolicy"]["criticalMaximum"],
            0,
        )
        self.assertEqual(
            self.policy["vulnerabilityPolicy"]["highMaximum"],
            0,
        )

    def test_policy_rejects_weakened_vulnerability_threshold(self) -> None:
        policy = copy.deepcopy(self.policy)
        policy["vulnerabilityPolicy"]["highMaximum"] = 1
        with self.assertRaisesRegex(GATE.GateError, "thresholds must be zero"):
            GATE.validate_policy(policy)

    def test_repository_dependency_locks_are_exact(self) -> None:
        GATE.check_lockfiles(ROOT, self.policy)

    def test_repository_actions_are_commit_pinned(self) -> None:
        GATE.check_action_pins(
            ROOT, self.policy["sourceControls"]["workflowDirectory"]
        )

    def test_unpinned_action_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            (workflows / "unsafe.yml").write_text(
                "jobs:\n  check:\n    steps:\n      - uses: actions/checkout@v4\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "not commit pinned"):
                GATE.check_action_pins(root, ".github/workflows")

    def test_repository_container_inputs_are_digest_pinned(self) -> None:
        GATE.check_container_digests(ROOT, self.policy)

    def test_high_confidence_token_format_is_rejected_without_echoing_value(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            token = "ghp_" + ("A" * 40)
            (root / "source.txt").write_text(f"value={token}\n", encoding="utf-8")
            with self.assertRaises(GATE.GateError) as context:
                GATE.check_tracked_credentials(
                    root,
                    self.policy,
                    ["source.txt"],
                )
            message = str(context.exception)
            self.assertIn("github-token", message)
            self.assertNotIn(token, message)

    def test_noncredential_identifier_is_not_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "source.txt").write_text(
                "l10n_charge_heart_rate_variability_026745e6\n",
                encoding="utf-8",
            )
            GATE.check_tracked_credentials(root, self.policy, ["source.txt"])

    def test_credential_filename_is_rejected_but_reviewed_example_is_allowed(
        self,
    ) -> None:
        controls = self.policy["sourceControls"]
        allowlist = set(controls["credentialExampleAllowlist"])
        self.assertTrue(
            GATE._is_blocked_credential_path(
                "private/release-key.p12", controls, allowlist
            )
        )
        self.assertFalse(
            GATE._is_blocked_credential_path(
                "server/.env.example", controls, allowlist
            )
        )

    def test_repository_migration_manifest_is_exact(self) -> None:
        GATE.check_migration_manifest(ROOT, self.policy)

    def test_tampered_migration_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            migrations = root / "migrations"
            migrations.mkdir()
            migration = migrations / "001_init.sql"
            migration.write_text("SELECT 1;\n", encoding="utf-8")
            digest = hashlib.sha256(migration.read_bytes()).hexdigest()
            manifest = root / "migration-manifest.sha256"
            manifest.write_text(f"{digest}  001_init.sql\n", encoding="utf-8")
            policy = copy.deepcopy(self.policy)
            policy["sourceControls"]["migrationDirectory"] = "migrations"
            policy["sourceControls"]["migrationManifest"] = (
                "migration-manifest.sha256"
            )
            GATE.check_migration_manifest(root, policy)
            migration.write_text("SELECT 2;\n", encoding="utf-8")
            with self.assertRaisesRegex(GATE.GateError, "digest changed"):
                GATE.check_migration_manifest(root, policy)

    def test_report_has_only_static_names_and_outcomes(self) -> None:
        checks = [
            {"name": "alpha-check", "status": "passed"},
            {"name": "beta-check", "status": "passed"},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"
            GATE.write_report(output, checks)
            report = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(set(report), {"schemaVersion", "checks"})
        self.assertEqual(
            set(report["checks"][0]),
            {"name", "status"},
        )


if __name__ == "__main__":
    unittest.main()
