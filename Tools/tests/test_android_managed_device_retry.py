from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "android-managed-device-retry.py"
SPEC = importlib.util.spec_from_file_location("android_managed_device_retry", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RETRY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RETRY
SPEC.loader.exec_module(RETRY)


class AndroidManagedDeviceRetryTests(unittest.TestCase):
    def _results(
        self,
        root: Path,
        *,
        proto: str,
        log: str = "",
    ) -> Path:
        results = root / "managedDevice" / "pixel2Api35"
        results.mkdir(parents=True)
        (results / "test-result.textproto").write_text(proto, encoding="utf-8")
        (results / "utp.0.log").write_text(log, encoding="utf-8")
        return root

    def _timeout_status(self, root: Path) -> Path:
        path = root / "review-sample.status"
        path.write_text(
            "label=review-sample-fresh-process\n"
            "status=timeout\n"
            "exit_code=124\n",
            encoding="utf-8",
        )
        return path

    def test_activity_service_loss_before_any_test_is_retriable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._results(
                Path(temporary),
                proto="""
test_status: FAILED
issue {
  name: "INSTRUMENTATION_FAILED"
  message: "Test run failed to complete. No test results. onError: commandError=true message=Attempt to invoke interface method 'boolean android.app.IActivityManager.startInstrumentation(...)' on a null object reference"
}
""",
            )
            decision = RETRY.classify(root)
            self.assertTrue(decision.retry)
            self.assertEqual(
                decision.category,
                "activity-service-unavailable-before-tests",
            )

    def test_real_test_failure_is_never_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._results(
                Path(temporary),
                proto="""
test_status: FAILED
test_result {
  test_case {
    test_class: "com.noop.ui.AppShellInstrumentedTest"
  }
  test_status: FAILED
  error {
    error_type: "java.lang.AssertionError"
  }
}
""",
            )
            decision = RETRY.classify(root)
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "test-results-present")

    def test_unknown_zero_test_failure_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._results(
                Path(temporary),
                proto="""
test_status: FAILED
issue {
  name: "INSTRUMENTATION_FAILED"
  message: "Test run failed to complete. No test results."
}
""",
            )
            decision = RETRY.classify(root)
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "unclassified-failure")

    def test_missing_results_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            decision = RETRY.classify(Path(temporary) / "missing")
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "missing-results")

    def test_bounded_timeout_before_results_is_retriable_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status = self._timeout_status(root)
            decision = RETRY.classify(
                root / "missing",
                bounded_status_file=status,
            )
            self.assertTrue(decision.retry)
            self.assertEqual(
                decision.category,
                "managed-device-timeout-before-results",
            )

    def test_timeout_never_retries_after_a_test_result_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            results = self._results(
                root / "results",
                proto="""
test_status: FAILED
test_result {
  test_case {
    test_class: "com.noop.ui.ReviewSampleInstrumentedTest"
  }
  test_status: FAILED
}
""",
            )
            decision = RETRY.classify(
                results,
                bounded_status_file=self._timeout_status(root),
            )
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "test-results-present")

    def test_invalid_bounded_status_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status = root / "invalid.status"
            status.write_text(
                "label=review-sample-fresh-process\nstatus=timeout\n",
                encoding="utf-8",
            )
            decision = RETRY.classify(
                root / "missing",
                bounded_status_file=status,
            )
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "invalid-bounded-status")

    def test_evidence_file_scan_is_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._results(
                Path(temporary),
                proto="""
test_status: FAILED
issue {
  name: "INSTRUMENTATION_FAILED"
  message: "Test run failed to complete. No test results."
}
""",
            )
            for index in range(RETRY.MAX_EVIDENCE_FILES):
                (root / f"utp.{index + 1}.log").write_text(
                    "cmd: Can't find service: activity\n",
                    encoding="utf-8",
                )
            decision = RETRY.classify(root)
            self.assertFalse(decision.retry)
            self.assertEqual(decision.category, "too-many-evidence-files")

    def test_github_output_is_bounded_to_fixed_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "github-output"
            decision = RETRY.RetryDecision(
                True,
                "activity-service-unavailable-before-tests",
                2,
            )
            RETRY._write_github_output(output, decision)
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "retry=true\n"
                "category=activity-service-unavailable-before-tests\n"
                "evidence_files=2\n",
            )


if __name__ == "__main__":
    unittest.main()
