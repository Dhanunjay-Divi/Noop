from __future__ import annotations

import copy
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "required-ci-gate.py"
SPEC = importlib.util.spec_from_file_location("required_ci_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class RequiredCIGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = GATE.load_config()

    def green_runs(self) -> list[dict[str, object]]:
        workflow_paths = GATE.required_workflow_paths(self.config)
        return [
            {
                "id": index,
                "name": context,
                "status": "completed",
                "conclusion": "success",
                "app": {"id": self.config["requiredCheckAppId"]},
                "workflowPath": workflow_paths[context],
            }
            for index, context in enumerate(
                self.config["requiredContexts"], start=1
            )
        ]

    def test_repository_required_workflows_fail_closed(self) -> None:
        GATE.check_repository()

    def test_release_build_uses_only_exact_green_main_source(self) -> None:
        GATE.check_release_workflow(ROOT)
        GATE.check_altstore_workflow(ROOT)
        GATE.check_forgejo_workflow(ROOT)
        GATE.check_homebrew_workflow(ROOT)
        GATE.check_release_control_test_suite(ROOT)
        GATE.check_local_release_entrypoint(ROOT)

    def test_required_contexts_are_the_protected_merge_contract(self) -> None:
        self.assertEqual(self.config["requiredCheckAppId"], 15368)
        self.assertEqual(
            self.config["requiredContexts"],
            [
                "android-ci-required",
                "apple-ci-required",
                "health-claims",
                "i18n-coverage",
                "operations-record",
                "release-controls",
                "runtime-license-required",
                "server-ci-required",
                "swift-packages-required",
            ],
        )

    def test_each_required_context_has_one_configured_workflow_owner(self) -> None:
        GATE.check_required_context_ownership(ROOT, self.config)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "  duplicate:\n"
                "    name: release-controls\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "must have exactly one workflow owner"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_universal_required_workflow_cannot_be_path_filtered(self) -> None:
        workflow = self.config["universalWorkflows"][2]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "  push:\n    branches: [main]\n",
            "  push:\n    branches: [main]\n    paths: ['docs/ops/**']\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "universal check cannot use event-level path filters"
            ):
                GATE.check_universal_workflow(root, workflow)

    def test_event_level_path_filter_is_rejected(self) -> None:
        workflow = self.config["workflows"][0]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "  pull_request:\n    branches: [main]\n",
            "  pull_request:\n    branches: [main]\n    paths: ['android/**']\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "event-level path filters"
            ):
                GATE.check_workflow(root, workflow)

    def test_apple_scope_covers_every_xcode_target_and_lock_input(self) -> None:
        text = (ROOT / ".github/workflows/app-build.yml").read_text(
            encoding="utf-8"
        )
        for marker in (
            "NOOPWatch|NOOPWatchComplications",
            "Strand\\.xcodeproj/project\\.xcworkspace/xcshareddata/swiftpm/"
            "Package\\.resolved",
            "LICENSE|NOTICE|ATTRIBUTION\\.md|DISCLAIMER\\.md|TERMS\\.md",
        ):
            self.assertIn(marker, text)

    def test_applicability_consumes_both_rename_paths_before_matching(self) -> None:
        for workflow in self.config["workflows"]:
            text = (ROOT / workflow["path"]).read_text(encoding="utf-8")
            section = GATE._job_section(text, workflow["applicabilityJob"])
            self.assertIn(
                'git diff --no-renames --name-only "$BASE_SHA" "$GITHUB_SHA"',
                section,
            )
            self.assertIn('> "$CHANGED_FILES"', section)
            self.assertNotRegex(
                section,
                r"git diff[^\n]*--name-only[^\n]*\|\s*\n\s*grep\s+-[A-Za-z]*q",
            )

    def test_release_dispatch_is_bound_to_the_verified_source_sha(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        self.assertIn("release_sha:", workflow)
        self.assertIn(
            "EXPECTED_RELEASE_SHA: ${{ github.event.inputs.release_sha }}",
            workflow,
        )
        self.assertIn('test "$GITHUB_SHA" = "$EXPECTED_RELEASE_SHA"', workflow)
        self.assertIn('--field "release_sha=$SOURCE_SHA"', dispatcher)

    def test_altstore_channel_recovers_only_a_marked_initial_asset(self) -> None:
        text = (ROOT / ".github/workflows/altstore-source.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('select(.name == "altstore-source.json")', text)
        self.assertIn('INITIALIZING_MARKER="NOOP_ALTSTORE_STATE=initializing"', text)
        self.assertIn(
            'grep -Fq "$INITIALIZING_MARKER" <<<"$CHANNEL_BODY"',
            text,
        )
        self.assertIn('cp altstore-source.json "$MANIFEST"', text)

    def test_altstore_channel_preserves_history_before_clobber(self) -> None:
        text = (ROOT / ".github/workflows/altstore-source.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('select(.name == "altstore-source.previous.json")', text)
        self.assertIn('elif [ "$SOURCE_ASSET_COUNT" = "0" ] &&', text)
        self.assertIn('BASE_SOURCE="backup"', text)
        backup_upload = text.index(
            'gh release upload "$CHANNEL_TAG" "$BACKUP"'
        )
        source_upload = text.index(
            'gh release upload "$CHANNEL_TAG" "$MANIFEST"'
        )
        self.assertLess(backup_upload, source_upload)

    def test_homebrew_opt_in_reaches_a_retryable_verified_workflow(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        homebrew = (ROOT / ".github/workflows/homebrew-cask.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("publish_homebrew:", release)
        self.assertIn("uses: ./.github/workflows/homebrew-cask.yml", release)
        self.assertIn("if: ${{ inputs.publish_homebrew }}", release)
        self.assertIn(
            "NOOP_HOMEBREW_TAP_TOKEN: ${{ secrets.NOOP_HOMEBREW_TAP_TOKEN }}",
            release,
        )
        self.assertIn(
            "NOOP_HOMEBREW_FORGE_TOKEN: ${{ secrets.NOOP_HOMEBREW_FORGE_TOKEN }}",
            release,
        )
        self.assertNotIn("secrets: inherit", release)
        self.assertIn(
            '--field "publish_homebrew=$PUBLISH_HOMEBREW"',
            dispatcher,
        )
        self.assertIn(
            '--field "publish_homebrew_forgejo=$PUBLISH_HOMEBREW_FORGEJO"',
            dispatcher,
        )
        self.assertIn("publish_homebrew_forgejo:", release)
        self.assertIn(
            "The Homebrew Forgejo mirror requires Homebrew publication.",
            release,
        )
        self.assertIn(
            "publish_forgejo: ${{ inputs.publish_homebrew_forgejo }}",
            release,
        )
        self.assertIn("workflow_dispatch:", homebrew)
        self.assertIn("publish_forgejo:", homebrew)
        self.assertIn("Tools/required-ci-gate.py verify-github", homebrew)
        self.assertIn("Tools/update-homebrew-cask.sh", homebrew)
        self.assertIn("NOOP_HOMEBREW_FORGE_TOKEN", homebrew)
        helper = (ROOT / "Tools/update-homebrew-cask.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("Tools/homebrew-version-gate.py", helper)

    def test_forgejo_opt_in_reaches_a_retryable_verified_workflow(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        forgejo = (ROOT / ".github/workflows/forgejo-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("publish_forgejo:", release)
        self.assertIn("uses: ./.github/workflows/forgejo-release.yml", release)
        self.assertIn("if: ${{ inputs.publish_forgejo }}", release)
        self.assertIn(
            '--field "publish_forgejo=$PUBLISH_FORGEJO"',
            dispatcher,
        )
        self.assertIn("workflow_dispatch:", forgejo)
        self.assertIn("Tools/required-ci-gate.py verify-github", forgejo)
        self.assertIn("Tools/forgejo-release.sh", forgejo)

    def test_release_controls_run_publication_safety_tests(self) -> None:
        workflow = (ROOT / ".github/workflows/release-controls.yml").read_text(
            encoding="utf-8"
        )
        for module in (
            "Tools.tests.test_forgejo_release_helper",
            "Tools.tests.test_forgejo_version_gate",
            "Tools.tests.test_homebrew_helper",
            "Tools.tests.test_homebrew_version_gate",
        ):
            self.assertIn(module, workflow)

    def test_required_job_cannot_ignore_a_heavy_job(self) -> None:
        workflow = self.config["workflows"][0]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "${{ needs.production-shell.result }}",
            "ignored-production-shell-result",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(GATE.GateError, "ignores production-shell"):
                GATE.check_workflow(root, workflow)

    def test_android_infrastructure_retry_is_bounded_and_fail_closed(self) -> None:
        source = (ROOT / ".github/workflows/android.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("timeout-minutes: 50", source)
        self.assertEqual(source.count("continue-on-error: true"), 1)
        self.assertIn("Tools/android-managed-device-retry.py", source)
        self.assertIn(
            "steps.review_sample_first.outcome == 'failure'",
            source,
        )
        self.assertIn(
            "steps.review_sample_retry.outputs.retry == 'true'",
            source,
        )
        self.assertEqual(source.count("--rerun-tasks"), 1)
        self.assertIn(
            "Tools/android-managed-device-retry\\.py$",
            source,
        )

    def test_latest_check_run_must_be_completed_success(self) -> None:
        runs = self.green_runs()
        GATE.evaluate_check_runs(self.config, runs)
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "failure",
                "app": {"id": self.config["requiredCheckAppId"]},
                "workflowPath": GATE.required_workflow_paths(self.config)[
                    "release-controls"
                ],
            }
        )
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=completed/failure"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_missing_required_check_is_rejected(self) -> None:
        config = copy.deepcopy(self.config)
        with self.assertRaisesRegex(GATE.GateError, "android-ci-required=missing"):
            GATE.evaluate_check_runs(config, [])

    def test_same_named_check_from_another_app_is_rejected(self) -> None:
        runs = self.green_runs()
        runs = [
            run for run in runs if run["name"] != "release-controls"
        ]
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "success",
                "app": {"id": 1},
            }
        )
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=missing"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_required_check_from_another_workflow_is_rejected(self) -> None:
        runs = self.green_runs()
        for run in runs:
            if run["name"] == "release-controls":
                run["workflowPath"] = ".github/workflows/rogue.yml"
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=unexpected-workflow"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_workflow_run_url_is_repository_and_job_bound(self) -> None:
        url = (
            "https://github.com/Dhanunjay-Divi/Noop/"
            "actions/runs/34166917443/job/101879686504"
        )
        self.assertEqual(
            GATE._workflow_run_id(url, "Dhanunjay-Divi/Noop"),
            34166917443,
        )
        for invalid in (
            "http://github.com/Dhanunjay-Divi/Noop/actions/runs/1/job/2",
            "https://github.com/other/Noop/actions/runs/1/job/2",
            "https://github.com/Dhanunjay-Divi/Noop/actions/runs/1",
            "https://example.com/Dhanunjay-Divi/Noop/actions/runs/1/job/2",
        ):
            with self.assertRaisesRegex(GATE.GateError, "no valid run URL"):
                GATE._workflow_run_id(invalid, "Dhanunjay-Divi/Noop")

    def test_workflow_run_payload_is_bound_to_exact_sha(self) -> None:
        sha = "a" * 40
        payload = {
            "id": 123,
            "head_sha": sha,
            "path": ".github/workflows/release-controls.yml",
        }
        self.assertEqual(
            GATE._workflow_path_from_run(payload, 123, sha),
            ".github/workflows/release-controls.yml",
        )
        with self.assertRaisesRegex(GATE.GateError, "identity is invalid"):
            GATE._workflow_path_from_run(payload, 123, "b" * 40)

    def test_release_workflow_cannot_push_directly_to_main(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "uses: ./.github/workflows/altstore-source.yml",
            "uses: ./.github/workflows/altstore-source.yml\n"
            "    # git push origin HEAD:refs/heads/main",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "cannot push directly to main"
            ):
                GATE.check_release_workflow(root)

    def test_local_release_entrypoint_cannot_publish_directly(self) -> None:
        source = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        source += "\ngh release upload v1.2.3 app.ipa\n"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "Tools/release.sh"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "retains direct publication"
            ):
                GATE.check_local_release_entrypoint(root)


if __name__ == "__main__":
    unittest.main()
