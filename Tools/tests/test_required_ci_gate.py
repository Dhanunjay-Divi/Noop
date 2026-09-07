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

    def test_required_contexts_are_the_protected_merge_contract(self) -> None:
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
                }
            )
        GATE.evaluate_check_runs(self.config, runs)
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "failure",
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


if __name__ == "__main__":
    unittest.main()
