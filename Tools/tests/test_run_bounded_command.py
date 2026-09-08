from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "run-bounded-command.py"
SPEC = importlib.util.spec_from_file_location("run_bounded_command", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def _process_is_live(pid: int) -> bool:
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    state = result.stdout.strip()
    return result.returncode == 0 and bool(state) and not state.startswith("Z")


class RunBoundedCommandTests(unittest.TestCase):
    def test_success_and_failure_codes_are_preserved(self) -> None:
        self.assertEqual(
            RUNNER.run_command(
                [sys.executable, "-c", "raise SystemExit(0)"],
                timeout_seconds=2,
                grace_seconds=1,
                label="success-case",
            ),
            0,
        )
        self.assertEqual(
            RUNNER.run_command(
                [sys.executable, "-c", "raise SystemExit(23)"],
                timeout_seconds=2,
                grace_seconds=1,
                label="failure-case",
            ),
            23,
        )

    def test_timeout_kills_the_complete_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid_path = root / "child.pid"
            program = (
                "import pathlib, subprocess, sys, time;"
                "child=subprocess.Popen([sys.executable,'-c','import time;"
                "time.sleep(60)']);"
                f"pathlib.Path({str(child_pid_path)!r}).write_text("
                "str(child.pid), encoding='utf-8');"
                "time.sleep(60)"
            )
            stderr = io.StringIO()
            status_file = root / "timeout.status"
            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=1,
                    grace_seconds=1,
                    label="timeout-case",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=timeout-case status=timeout\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=timeout-case\nstatus=timeout\nexit_code=124\n",
            )
            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while _process_is_live(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(_process_is_live(child_pid))

    def test_status_file_contains_only_fixed_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "nested" / "status.txt"
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "raise SystemExit(7)"],
                timeout_seconds=2,
                grace_seconds=1,
                label="status-case",
                status_file=status_file,
            )
            self.assertEqual(exit_code, 7)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=status-case\nstatus=failed\nexit_code=7\n",
            )

    def test_invalid_inputs_fail_before_spawning(self) -> None:
        with self.assertRaisesRegex(ValueError, "command is required"):
            RUNNER.run_command(
                [],
                timeout_seconds=1,
                grace_seconds=1,
                label="missing-command",
            )
        with self.assertRaisesRegex(ValueError, "label is invalid"):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                label="NOT SAFE",
            )
        with self.assertRaisesRegex(ValueError, "timeout is invalid"):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=0,
                grace_seconds=1,
                label="invalid-timeout",
            )

    def test_start_failure_is_bounded_and_does_not_echo_the_command(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            exit_code = RUNNER.run_command(
                ["/definitely-not-a-real-command-with-sensitive-argument"],
                timeout_seconds=1,
                grace_seconds=1,
                label="start-case",
            )
        self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=start-case status=start-error\n",
        )
        self.assertNotIn("sensitive", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
