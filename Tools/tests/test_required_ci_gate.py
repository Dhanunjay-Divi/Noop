from __future__ import annotations

import copy
import importlib.util
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

    def test_repository_required_workflows_fail_closed(self) -> None:
        GATE.check_repository()

    def test_release_build_uses_only_exact_green_main_source(self) -> None:
        GATE.check_release_workflow(ROOT)
        GATE.check_altstore_workflow(ROOT)
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

    def test_applicability_consumes_the_complete_diff_before_matching(self) -> None:
        for workflow in self.config["workflows"]:
            text = (ROOT / workflow["path"]).read_text(encoding="utf-8")
            section = GATE._job_section(text, workflow["applicabilityJob"])
            self.assertIn(
                'git diff --name-only "$BASE_SHA" "$GITHUB_SHA" '
                '> "$CHANGED_FILES"',
                section,
            )
            self.assertNotRegex(
                section,
                r"git diff --name-only[^\n]*\|\s*\n\s*grep\s+-[A-Za-z]*q",
            )

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

    def test_latest_check_run_must_be_completed_success(self) -> None:
        runs = []
        for index, context in enumerate(self.config["requiredContexts"], start=1):
            runs.append(
                {
                    "id": index,
                    "name": context,
                    "status": "completed",
                    "conclusion": "success",
                    "app": {"id": self.config["requiredCheckAppId"]},
                }
            )
        GATE.evaluate_check_runs(self.config, runs)
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "failure",
                "app": {"id": self.config["requiredCheckAppId"]},
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
        runs = []
        for index, context in enumerate(self.config["requiredContexts"], start=1):
            runs.append(
                {
                    "id": index,
                    "name": context,
                    "status": "completed",
                    "conclusion": "success",
                    "app": {"id": self.config["requiredCheckAppId"]},
                }
            )
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
