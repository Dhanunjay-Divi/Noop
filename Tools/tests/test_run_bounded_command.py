from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
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


def _wait_for_path(path: Path, timeout_seconds: float = 3) -> None:
    deadline = time.monotonic() + timeout_seconds
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not path.exists():
        raise AssertionError(f"Timed out waiting for {path.name}")


class RunBoundedCommandTests(unittest.TestCase):
    def test_child_output_is_discarded_without_an_explicit_log_file(self) -> None:
        program = (
            "import sys;"
            "sys.stdout.write('x' * 1_000_000);"
            "sys.stderr.write('y' * 1_000_000)"
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--timeout-seconds",
                "5",
                "--grace-seconds",
                "1",
                "--label",
                "discarded-output",
                "--",
                sys.executable,
                "-c",
                program,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_log_file_captures_child_output_without_terminal_flooding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_file = Path(temporary) / "nested" / "command.log"
            stdout = io.StringIO()
            stderr = io.StringIO()
            program = (
                "import sys;"
                "print('bounded stdout');"
                "print('bounded stderr', file=sys.stderr)"
            )

            with (
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="logged-output",
                    log_file=log_file,
                )

            self.assertEqual(exit_code, 0)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(
                set(log_file.read_text(encoding="utf-8").splitlines()),
                {"bounded stdout", "bounded stderr"},
            )
            self.assertEqual(stat.S_IMODE(log_file.stat().st_mode), 0o600)

    def test_log_file_limit_stops_runaway_output_and_caps_the_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_file = Path(temporary) / "command.log"
            status_file = Path(temporary) / "command.status"
            stderr = io.StringIO()
            max_log_bytes = 16 * 1024
            program = (
                "import sys;"
                "chunk=b'x' * 65536;"
                "[sys.stdout.buffer.write(chunk) for _ in range(64)];"
                "sys.stdout.buffer.flush()"
            )

            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=5,
                    grace_seconds=1,
                    label="runaway-output",
                    status_file=status_file,
                    log_file=log_file,
                    max_log_bytes=max_log_bytes,
                )

            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertLessEqual(log_file.stat().st_size, max_log_bytes)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=runaway-output "
                "status=resource-pressure kind=output\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=runaway-output\nstatus=resource-output\nexit_code=125\n",
            )

    def test_fast_writer_is_capped_during_observation_and_at_completion(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_file = Path(temporary) / "command.log"
            max_log_bytes = 16 * 1024
            finished = threading.Event()
            maximum_observed = 0

            def monitor_log() -> None:
                nonlocal maximum_observed
                while not finished.is_set():
                    try:
                        maximum_observed = max(
                            maximum_observed,
                            log_file.stat().st_size,
                        )
                    except FileNotFoundError:
                        pass
                    time.sleep(0.001)

            monitor = threading.Thread(target=monitor_log)
            monitor.start()
            try:
                exit_code = RUNNER.run_command(
                    [
                        sys.executable,
                        "-c",
                        "import os;"
                        "chunk=b'x'*65536;"
                        "exec('while True:\\n os.write(1, chunk)')",
                    ],
                    timeout_seconds=5,
                    grace_seconds=1,
                    label="fast-writer",
                    log_file=log_file,
                    max_log_bytes=max_log_bytes,
                )
            finally:
                finished.set()
                monitor.join(timeout=1)
            maximum_observed = max(
                maximum_observed,
                log_file.stat().st_size,
            )

            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertLessEqual(maximum_observed, max_log_bytes)
            self.assertFalse(monitor.is_alive())

    def test_blocked_log_writer_does_not_make_abort_wait_unbounded(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_file = Path(temporary) / "command.log"
            descriptor = os.open(
                log_file,
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                0o600,
            )
            capture = RUNNER._BoundedLogCapture(descriptor, 16 * 1024)
            write_started = threading.Event()
            release_write = threading.Event()

            def blocked_write(_data: memoryview) -> bool:
                write_started.set()
                release_write.wait(timeout=5)
                return True

            with mock.patch.object(
                capture,
                "_write_bounded",
                side_effect=blocked_write,
            ):
                os.write(capture.child_write_fd, b"x")
                capture.close_parent_write()
                self.assertTrue(write_started.wait(timeout=1))
                started_at = time.monotonic()
                self.assertFalse(capture.abort())
                self.assertLess(time.monotonic() - started_at, 1.5)
                release_write.set()
                capture._thread.join(timeout=1)

            self.assertFalse(capture._thread.is_alive())

    def test_log_file_and_status_file_must_be_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            shared_path = Path(temporary) / "shared.txt"
            with self.assertRaisesRegex(
                ValueError,
                "log file and status file must be different",
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="shared-output",
                    status_file=shared_path,
                    log_file=shared_path,
                )

    def test_log_and_status_alias_through_symlinked_parent_are_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_parent = root / "real"
            real_parent.mkdir()
            alias_parent = root / "alias"
            alias_parent.symlink_to(real_parent, target_is_directory=True)

            with self.assertRaisesRegex(
                ValueError,
                "log file and status file must be different",
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="parent-alias",
                    status_file=alias_parent / "shared.txt",
                    log_file=real_parent / "shared.txt",
                )

    def test_existing_case_alias_is_rejected_on_case_insensitive_volume(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lower_path = root / "case-alias.txt"
            lower_path.write_text("preserve", encoding="utf-8")
            upper_path = root / "CASE-ALIAS.TXT"
            if not upper_path.exists():
                self.skipTest("temporary volume is case-sensitive")

            with self.assertRaisesRegex(
                ValueError,
                "log file and status file must be different",
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="case-alias",
                    status_file=upper_path,
                    log_file=lower_path,
                )
            self.assertEqual(lower_path.read_text(encoding="utf-8"), "preserve")

    def test_log_file_refuses_a_symbolic_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.log"
            target.write_text("preserve", encoding="utf-8")
            log_file = root / "command.log"
            log_file.symlink_to(target)
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "print('secret')"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="symlink-output",
                    log_file=log_file,
                )

            self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve")
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=symlink-output status=log-file-error\n",
            )

    def test_log_file_refuses_a_hard_link_without_truncating_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.log"
            target.write_text("preserve", encoding="utf-8")
            log_file = root / "command.log"
            os.link(target, log_file)
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "print('secret')"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="hardlink-output",
                    log_file=log_file,
                )

            self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve")
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=hardlink-output status=log-file-error\n",
            )

    def test_log_file_refuses_a_fifo_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log_file = Path(temporary) / "command.log"
            os.mkfifo(log_file)
            stderr = io.StringIO()
            started_at = time.monotonic()

            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "print('secret')"],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="fifo-output",
                    log_file=log_file,
                )

            self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
            self.assertLess(time.monotonic() - started_at, 1)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=fifo-output status=log-file-error\n",
            )

    def test_log_file_descriptor_survives_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log_file = root / "command.log"
            moved_log = root / "moved.log"
            status_file = root / "command.status"
            max_log_bytes = 16 * 1024
            program = (
                "import os,pathlib,sys;"
                f"log=pathlib.Path({str(log_file)!r});"
                f"moved=pathlib.Path({str(moved_log)!r});"
                "os.rename(log,moved);"
                "log.write_text('replacement',encoding='utf-8');"
                "chunk=b'x'*65536;"
                "[sys.stdout.buffer.write(chunk) for _ in range(64)];"
                "sys.stdout.buffer.flush()"
            )

            exit_code = RUNNER.run_command(
                [sys.executable, "-c", program],
                timeout_seconds=5,
                grace_seconds=1,
                label="replaced-output",
                status_file=status_file,
                log_file=log_file,
                max_log_bytes=max_log_bytes,
            )

            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertLessEqual(moved_log.stat().st_size, max_log_bytes)
            self.assertEqual(
                log_file.read_text(encoding="utf-8"),
                "replacement",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=replaced-output\nstatus=resource-output\nexit_code=125\n",
            )

    def test_log_is_capped_when_descendant_writes_during_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log_file = root / "command.log"
            status_file = root / "command.status"
            ready = root / "ready"
            write_started = root / "write-started"
            max_log_bytes = 16 * 1024
            descendant = (
                "import pathlib,signal,sys,time;"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
                f"pathlib.Path({str(ready)!r}).write_text('1');"
                "time.sleep(0.15);"
                f"pathlib.Path({str(write_started)!r}).write_text('1');"
                "chunk=b'x'*65536;"
                "[sys.stdout.buffer.write(chunk) for _ in range(64)];"
                "sys.stdout.buffer.flush();"
                "time.sleep(60)"
            )
            program = (
                "import pathlib,subprocess,sys,time\n"
                f"ready=pathlib.Path({str(ready)!r})\n"
                f"subprocess.Popen([sys.executable,'-c',{descendant!r}])\n"
                "deadline=time.monotonic()+2\n"
                "while not ready.exists() and time.monotonic()<deadline:\n"
                "    time.sleep(0.01)\n"
            )

            exit_code = RUNNER.run_command(
                [sys.executable, "-c", program],
                timeout_seconds=5,
                grace_seconds=0.5,
                label="cleanup-output",
                status_file=status_file,
                log_file=log_file,
                max_log_bytes=max_log_bytes,
            )

            self.assertTrue(write_started.exists())
            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertLessEqual(log_file.stat().st_size, max_log_bytes)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=cleanup-output\nstatus=resource-output\nexit_code=125\n",
            )

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
                "child=subprocess.Popen([sys.executable,'-c','import signal,time;"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)']);"
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

    def test_completion_at_the_deadline_wins_over_timeout(self) -> None:
        fake_process = mock.Mock(pid=12_345)
        fake_process.poll.return_value = 0
        fake_process.wait.side_effect = subprocess.TimeoutExpired(
            cmd="<bounded-command>",
            timeout=1,
        )
        with (
            mock.patch.object(
                RUNNER,
                "_spawn_process_before_deadline",
                return_value=fake_process,
            ),
            mock.patch.object(
                RUNNER.time,
                "monotonic",
                side_effect=[0.0, 0.0, 0.0, 1.0],
            ),
            mock.patch.object(
                RUNNER,
                "_terminate_process_group",
                return_value=True,
            ),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=0.1,
                label="deadline-complete",
            )

        self.assertEqual(exit_code, 0)
        fake_process.wait.assert_called_once_with(timeout=1.0)

    def test_successful_leader_cannot_leave_a_descendant_running(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            child_pid_path = Path(temporary) / "child.pid"
            program = (
                "import pathlib, subprocess, sys;"
                "child=subprocess.Popen([sys.executable,'-c','import signal,time;"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)']);"
                f"pathlib.Path({str(child_pid_path)!r}).write_text("
                "str(child.pid), encoding='utf-8')"
            )
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", program],
                timeout_seconds=2,
                grace_seconds=0.1,
                label="orphan-case",
            )

            self.assertEqual(exit_code, 0)
            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertFalse(_process_is_live(child_pid))

    def test_process_group_is_signaled_before_waiting_for_exit(self) -> None:
        fake_process = mock.Mock(pid=12_345)
        fake_process.poll.return_value = None
        with (
            mock.patch.object(
                RUNNER,
                "_signal_process_group",
                return_value="missing",
            ) as signal_group,
            mock.patch.object(
                RUNNER,
                "_wait_for_process_group_exit",
                return_value=True,
            ) as wait_for_exit,
            mock.patch.object(
                RUNNER,
                "_process_group_exists",
                side_effect=AssertionError("pre-signal existence check"),
            ),
        ):
            self.assertTrue(
                RUNNER._terminate_process_group(
                    fake_process,
                    grace_seconds=0.1,
                )
            )

        signal_group.assert_called_once_with(12_345, signal.SIGTERM)
        wait_for_exit.assert_called_once()

    def test_supervisor_descriptor_targets_avoid_source_collisions(self) -> None:
        self.assertEqual(
            RUNNER._supervisor_fd_targets(
                {198, 199, 200},
                soft_limit=203,
            ),
            (197, 196),
        )

    def test_supervisor_descriptor_targets_honor_a_low_soft_limit(self) -> None:
        self.assertEqual(
            RUNNER._supervisor_fd_targets(set(), soft_limit=128),
            (127, 126),
        )

    def test_completed_supervisor_never_signals_a_stale_target_pid(self) -> None:
        status_read_fd, status_write_fd = os.pipe()
        process = RUNNER._SpawnedProcess(12_345, status_read_fd)
        process.returncode = 0
        process._reaped = True
        os.close(status_write_fd)
        try:
            with (
                mock.patch.object(
                    RUNNER,
                    "_signal_process_group",
                    return_value="missing",
                ) as signal_group,
                mock.patch.object(
                    RUNNER,
                    "_signal_process",
                    return_value="sent",
                ) as signal_process,
                mock.patch.object(
                    RUNNER,
                    "_wait_for_process_group_exit",
                    return_value=True,
                ),
            ):
                self.assertTrue(
                    RUNNER._terminate_process_group(
                        process,
                        grace_seconds=0.1,
                    )
                )
        finally:
            process._close_spawn_status_fd()

        signal_process.assert_not_called()
        signal_group.assert_not_called()

    def test_completed_supervisor_is_not_refreshed_after_grace(self) -> None:
        fake_process = mock.Mock(pid=12_345)
        fake_process.poll.side_effect = [None, 0]
        with (
            mock.patch.object(
                RUNNER,
                "_tracked_target",
                return_value=(54_321, 54_321),
            ) as tracked_target,
            mock.patch.object(
                RUNNER,
                "_signal_managed_processes",
                return_value=True,
            ) as signal_managed,
            mock.patch.object(
                RUNNER,
                "_wait_for_process_group_exit",
                side_effect=[False, True],
            ),
        ):
            self.assertTrue(
                RUNNER._terminate_process_group(
                    fake_process,
                    grace_seconds=0.1,
                )
            )

        tracked_target.assert_called_once_with(fake_process)
        signal_managed.assert_called_once()

    def test_status_write_failure_invalidates_stale_evidence_and_fails_closed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "status.txt"
            status_file.write_text(
                "label=old-case\nstatus=success\nexit_code=0\n",
                encoding="utf-8",
            )
            stderr = io.StringIO()

            with (
                mock.patch.object(
                    RUNNER.os,
                    "replace",
                    side_effect=OSError("injected replacement failure"),
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "import time; time.sleep(10)"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="status-write-failure",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
            self.assertFalse(status_file.exists())
            self.assertIn("status=status-file-error", stderr.getvalue())

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

    def test_concurrent_status_writes_use_unique_temporary_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status_file = root / "status.txt"
            replace_barrier = threading.Barrier(2)
            original_replace = RUNNER.os.replace
            stderr = io.StringIO()

            def synchronized_replace(source: Path, destination: Path) -> None:
                replace_barrier.wait(timeout=2)
                original_replace(source, destination)

            threads = [
                threading.Thread(
                    target=RUNNER._write_status,
                    kwargs={
                        "path": status_file,
                        "label": f"writer-{index}",
                        "status": "success",
                        "exit_code": 0,
                    },
                )
                for index in range(2)
            ]
            with (
                mock.patch.object(
                    RUNNER.os,
                    "replace",
                    side_effect=synchronized_replace,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=3)

            self.assertTrue(all(not thread.is_alive() for thread in threads))
            self.assertNotIn("status-file-error", stderr.getvalue())
            self.assertIn(
                status_file.read_text(encoding="utf-8"),
                {
                    "label=writer-0\nstatus=success\nexit_code=0\n",
                    "label=writer-1\nstatus=success\nexit_code=0\n",
                },
            )
            self.assertFalse(list(root.glob(f".{status_file.name}.*.tmp")))

    def test_resource_preflight_fails_before_spawning(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "spawned"
            status_file = root / "resource.status"
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    RUNNER,
                    "_system_free_memory_percent",
                    return_value=10,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [
                        sys.executable,
                        "-c",
                        f"import pathlib; pathlib.Path({str(marker)!r})"
                        ".write_text('spawned', encoding='utf-8')",
                    ],
                    timeout_seconds=2,
                    grace_seconds=1,
                    label="resource-preflight",
                    status_file=status_file,
                    min_free_memory_percent=20,
                )

            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertFalse(marker.exists())
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=resource-preflight "
                "status=resource-pressure kind=memory\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=resource-preflight\nstatus=resource-memory\nexit_code=125\n",
            )

    def test_preflight_interruption_replaces_stale_terminal_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "preflight.status"
            status_file.write_text(
                "label=old-case\nstatus=success\nexit_code=0\n",
                encoding="utf-8",
            )
            with (
                mock.patch.object(
                    RUNNER,
                    "_bounded_resource_pressure_kind",
                    side_effect=RUNNER._SignalInterruption(signal.SIGTERM),
                ),
                self.assertRaises(RUNNER._SignalInterruption),
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="preflight-interrupt",
                    status_file=status_file,
                    min_free_memory_percent=20,
                )

            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=preflight-interrupt\n"
                "status=interrupted\n"
                f"exit_code={128 + signal.SIGTERM}\n",
            )

    def test_resource_pressure_kills_the_complete_process_group(self) -> None:
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
            status_file = root / "resource.status"
            probe_count = 0

            def resource_pressure(**_arguments: object) -> str | None:
                nonlocal probe_count
                probe_count += 1
                if probe_count == 1:
                    return None
                _wait_for_path(child_pid_path)
                return "memory"

            with (
                mock.patch.object(
                    RUNNER,
                    "_resource_pressure_kind",
                    side_effect=resource_pressure,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=3,
                    grace_seconds=1,
                    resource_check_seconds=0.05,
                    label="resource-runtime",
                    status_file=status_file,
                    min_free_memory_percent=20,
                )

            self.assertEqual(exit_code, RUNNER.RESOURCE_EXIT_CODE)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=resource-runtime "
                "status=resource-pressure kind=memory\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=resource-runtime\nstatus=resource-memory\nexit_code=125\n",
            )
            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while _process_is_live(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(_process_is_live(child_pid))

    def test_process_completion_wins_a_resource_probe_race(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            child_pid_path = Path(temporary) / "child.pid"
            probe_count = 0
            completion_seen = False

            def resource_pressure(**_arguments: object) -> str | None:
                nonlocal probe_count, completion_seen
                probe_count += 1
                if probe_count == 1:
                    return None
                _wait_for_path(child_pid_path)
                child_pid = int(child_pid_path.read_text(encoding="utf-8"))
                deadline = time.monotonic() + 2
                while _process_is_live(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                completion_seen = not _process_is_live(child_pid)
                return "memory" if completion_seen else None

            program = (
                "import os, pathlib, time;"
                f"pathlib.Path({str(child_pid_path)!r}).write_text("
                "str(os.getpid()), encoding='utf-8');"
                "time.sleep(0.03)"
            )
            with mock.patch.object(
                RUNNER,
                "_resource_pressure_kind",
                side_effect=resource_pressure,
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=3,
                    grace_seconds=0.1,
                    resource_check_seconds=0.01,
                    label="probe-race",
                    min_free_memory_percent=20,
                )

        self.assertTrue(completion_seen)
        self.assertEqual(exit_code, 0)

    def test_resource_probe_cannot_extend_the_hard_deadline(self) -> None:
        probe_count = 0
        release_probe = threading.Event()

        def resource_pressure(**_arguments: object) -> str | None:
            nonlocal probe_count
            probe_count += 1
            if probe_count == 1:
                return None
            release_probe.wait(timeout=2)
            return None

        started_at = time.monotonic()
        try:
            with mock.patch.object(
                RUNNER,
                "_resource_pressure_kind",
                side_effect=resource_pressure,
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    timeout_seconds=0.15,
                    grace_seconds=0.1,
                    resource_check_seconds=0.01,
                    label="probe-deadline",
                    min_free_memory_percent=20,
                )
        finally:
            release_probe.set()
            thread = RUNNER._RESOURCE_PROBE_THREAD
            if thread is not None:
                thread.join(timeout=2)
        elapsed = time.monotonic() - started_at

        self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
        self.assertLess(elapsed, 0.7)

    def test_repeated_probe_timeouts_keep_at_most_one_worker(self) -> None:
        release_probe = threading.Event()

        def blocked_probe(**_arguments: object) -> str | None:
            release_probe.wait(timeout=2)
            return None

        try:
            with mock.patch.object(
                RUNNER,
                "_resource_pressure_kind",
                side_effect=blocked_probe,
            ):
                results = [
                    RUNNER._bounded_resource_pressure_kind(
                        min_free_memory_percent=20,
                        min_free_disk_bytes=0,
                        disk_path=Path.cwd(),
                        timeout_seconds=0.01,
                    )
                    for _ in range(5)
                ]

            self.assertEqual(results, ["probe-timeout"] * 5)
            workers = [
                thread
                for thread in threading.enumerate()
                if thread.name == "bounded-command-resource-probe"
            ]
            self.assertLessEqual(len(workers), 1)
        finally:
            release_probe.set()
            for thread in threading.enumerate():
                if thread.name == "bounded-command-resource-probe":
                    thread.join(timeout=2)

    def test_disk_pressure_probe_uses_the_selected_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            free_bytes = RUNNER.shutil.disk_usage(root).free
            self.assertEqual(
                RUNNER._resource_pressure_kind(
                    min_free_memory_percent=0,
                    min_free_disk_bytes=free_bytes + 1,
                    disk_path=root,
                ),
                "disk",
            )

    def test_heartbeat_is_bounded_and_does_not_echo_the_command(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            exit_code = RUNNER.run_command(
                [
                    sys.executable,
                    "-c",
                    "import time; time.sleep(0.16)",
                    "sensitive-argument",
                ],
                timeout_seconds=1,
                grace_seconds=1,
                heartbeat_seconds=0.05,
                label="heartbeat-case",
            )
        self.assertEqual(exit_code, 0)
        lines = stderr.getvalue().splitlines()
        self.assertGreaterEqual(len(lines), 2)
        self.assertTrue(
            all(
                line.startswith(
                    "bounded-command: label=heartbeat-case status=running heartbeat="
                )
                for line in lines
            )
        )
        self.assertNotIn("sensitive", stderr.getvalue())

    def test_running_status_atomically_replaces_stale_terminal_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status_file = root / "status.txt"
            status_file.write_text(
                "label=old-case\nstatus=success\nexit_code=0\n",
                encoding="utf-8",
            )
            wrapper = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--timeout-seconds",
                    "2",
                    "--grace-seconds",
                    "1",
                    "--label",
                    "running-case",
                    "--status-file",
                    str(status_file),
                    "--",
                    sys.executable,
                    "-c",
                    "import time; time.sleep(0.25)",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if "status=running" in status_file.read_text(encoding="utf-8"):
                    break
                time.sleep(0.01)

            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=running-case\nstatus=running\nexit_code=-1\n",
            )
            self.assertFalse(list(root.glob(f".{status_file.name}.*.tmp")))
            self.assertEqual(wrapper.wait(timeout=2), 0)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=running-case\nstatus=success\nexit_code=0\n",
            )

    def test_multithreaded_wrapper_uses_safe_supervisor_spawn(self) -> None:
        release_thread = threading.Event()
        worker = threading.Thread(
            target=lambda: release_thread.wait(timeout=2),
            name="unrelated-worker",
        )
        worker.start()
        try:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=1,
                    grace_seconds=0.1,
                    label="threaded-wrapper",
                )
        finally:
            release_thread.set()
            worker.join(timeout=2)

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")

    def test_parent_setup_failure_never_releases_the_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target_marker = root / "target-started"
            status_file = root / "parent-setup.status"
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    RUNNER.os,
                    "set_blocking",
                    side_effect=OSError("injected parent setup failure"),
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [
                        sys.executable,
                        "-c",
                        f"import pathlib; pathlib.Path({str(target_marker)!r})"
                        ".write_text('started', encoding='utf-8')",
                    ],
                    timeout_seconds=1,
                    grace_seconds=0.1,
                    label="parent-setup",
                    status_file=status_file,
                )

            time.sleep(0.1)
            self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
            self.assertFalse(target_marker.exists())
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=parent-setup status=start-error\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=parent-setup\nstatus=start-error\nexit_code=127\n",
            )

    def test_second_pipe_failure_closes_the_first_pipe(self) -> None:
        original_pipe = RUNNER.os.pipe
        created_descriptors: list[int] = []
        call_count = 0

        def fail_second_pipe() -> tuple[int, int]:
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                descriptors = original_pipe()
                created_descriptors.extend(descriptors)
                return descriptors
            raise OSError("injected second pipe failure")

        stderr = io.StringIO()
        with (
            mock.patch.object(
                RUNNER.os,
                "pipe",
                side_effect=fail_second_pipe,
            ),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=0.1,
                label="second-pipe",
            )

        self.assertEqual(exit_code, RUNNER.START_FAILURE_EXIT_CODE)
        self.assertEqual(call_count, 2)
        for descriptor in created_descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=second-pipe status=start-error\n",
        )

    def test_low_file_descriptor_limit_still_launches(self) -> None:
        with mock.patch.object(
            RUNNER.resource,
            "getrlimit",
            return_value=(128, 128),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=0.1,
                label="low-fd-limit",
            )

        self.assertEqual(exit_code, 0)

    def test_target_cannot_access_supervisor_status_descriptors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result_path = Path(temporary) / "open-status-fds.txt"
            program = (
                "import os,pathlib;"
                "opened=[];"
                "\nfor descriptor in (198,199):"
                "\n try: os.fstat(descriptor)"
                "\n except OSError: pass"
                "\n else: opened.append(descriptor);"
                f"\npathlib.Path({str(result_path)!r}).write_text("
                "repr(opened),encoding='utf-8');"
                "\nraise SystemExit(23 if opened else 0)"
            )
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", program],
                timeout_seconds=2,
                grace_seconds=0.1,
                label="status-fd-isolation",
            )

            self.assertEqual(exit_code, 0)
            self.assertEqual(
                result_path.read_text(encoding="utf-8"),
                "[]",
            )

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_supervisor_spawn_stall_respects_the_hard_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            spawn_marker = root / "spawn-entered"
            status_file = root / "supervisor-timeout.status"
            original_posix_spawnp = RUNNER.os.posix_spawnp

            def stalled_posix_spawnp(
                *arguments: object,
                **keywords: object,
            ) -> int:
                spawn_marker.write_text("entered", encoding="utf-8")
                time.sleep(1)
                return original_posix_spawnp(*arguments, **keywords)

            stderr = io.StringIO()
            started_at = time.monotonic()
            with (
                mock.patch.object(
                    RUNNER.os,
                    "posix_spawnp",
                    side_effect=stalled_posix_spawnp,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=0.05,
                    grace_seconds=0.1,
                    label="supervisor-timeout",
                    status_file=status_file,
                )

            elapsed = time.monotonic() - started_at
            self.assertTrue(spawn_marker.exists())
            self.assertLess(elapsed, 0.5)
            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=supervisor-timeout status=timeout\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=supervisor-timeout\nstatus=timeout\nexit_code=124\n",
            )

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_post_spawn_deadline_reaps_unknown_supervisor_pid(self) -> None:
        original_posix_spawnp = RUNNER.os.posix_spawnp
        spawned_supervisors: list[int] = []

        def spawn_then_stall(
            *arguments: object,
            **keywords: object,
        ) -> int:
            supervisor_pid = original_posix_spawnp(*arguments, **keywords)
            spawned_supervisors.append(supervisor_pid)
            time.sleep(1)
            return supervisor_pid

        stderr = io.StringIO()
        started_at = time.monotonic()
        with (
            mock.patch.object(
                RUNNER.os,
                "posix_spawnp",
                side_effect=spawn_then_stall,
            ),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                timeout_seconds=0.05,
                grace_seconds=0.1,
                label="post-spawn-timeout",
            )

        elapsed = time.monotonic() - started_at
        self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
        self.assertLess(elapsed, 0.7)
        self.assertEqual(len(spawned_supervisors), 1)
        supervisor_pid = spawned_supervisors[0]
        self.assertFalse(_process_is_live(supervisor_pid))
        self.assertFalse(RUNNER._process_group_exists(supervisor_pid))
        with self.assertRaises(ChildProcessError):
            os.waitpid(supervisor_pid, os.WNOHANG)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=post-spawn-timeout status=timeout\n",
        )

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_post_spawn_deadline_recovers_supervisor_without_readiness(
        self,
    ) -> None:
        original_posix_spawnp = RUNNER.os.posix_spawnp
        spawned_supervisors: list[int] = []

        def spawn_then_stall(
            *arguments: object,
            **keywords: object,
        ) -> int:
            supervisor_pid = original_posix_spawnp(*arguments, **keywords)
            spawned_supervisors.append(supervisor_pid)
            time.sleep(1)
            return supervisor_pid

        def no_ready_supervisor(
            _command: list[str],
            *,
            status_fd: int,
            release_fd: int,
        ) -> list[str]:
            del status_fd, release_fd
            return [sys.executable, "-c", "import time; time.sleep(60)"]

        stderr = io.StringIO()
        started_at = time.monotonic()
        with (
            mock.patch.object(
                RUNNER,
                "_supervisor_argv",
                side_effect=no_ready_supervisor,
            ),
            mock.patch.object(
                RUNNER.os,
                "posix_spawnp",
                side_effect=spawn_then_stall,
            ),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=0.05,
                grace_seconds=0.1,
                label="no-ready-supervisor",
            )

        elapsed = time.monotonic() - started_at
        self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
        self.assertLess(elapsed, 0.7)
        self.assertEqual(len(spawned_supervisors), 1)
        supervisor_pid = spawned_supervisors[0]
        self.assertFalse(_process_is_live(supervisor_pid))
        self.assertFalse(RUNNER._process_group_exists(supervisor_pid))
        with self.assertRaises(ChildProcessError):
            os.waitpid(supervisor_pid, os.WNOHANG)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=no-ready-supervisor status=timeout\n",
        )

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_unreported_recovery_never_kills_an_unrelated_new_child(
        self,
    ) -> None:
        original_posix_spawnp = RUNNER.os.posix_spawnp
        unrelated_children: list[int] = []

        def unrelated_child_then_deadline(
            *arguments: object,
            **keywords: object,
        ) -> int:
            del arguments, keywords
            unrelated_pid = original_posix_spawnp(
                sys.executable,
                [
                    sys.executable,
                    "-c",
                    "import time; time.sleep(60)",
                ],
                os.environ.copy(),
                setpgroup=0,
            )
            unrelated_children.append(unrelated_pid)
            raise RUNNER._SpawnDeadlineExceeded()

        stderr = io.StringIO()
        try:
            with (
                mock.patch.object(
                    RUNNER.os,
                    "posix_spawnp",
                    side_effect=unrelated_child_then_deadline,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=0.5,
                    grace_seconds=0.1,
                    label="unrelated-child",
                )

            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertEqual(len(unrelated_children), 1)
            self.assertTrue(_process_is_live(unrelated_children[0]))
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=unrelated-child status=timeout\n",
            )
        finally:
            for child_pid in unrelated_children:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child_pid, 0)
                except ChildProcessError:
                    pass

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_discovery_failure_reaps_owned_supervisor_and_closes_fds(
        self,
    ) -> None:
        original_posix_spawnp = RUNNER.os.posix_spawnp
        spawned_supervisors: list[int] = []

        def spawn_then_stall(
            *arguments: object,
            **keywords: object,
        ) -> int:
            supervisor_pid = original_posix_spawnp(*arguments, **keywords)
            spawned_supervisors.append(supervisor_pid)
            time.sleep(1)
            return supervisor_pid

        def no_ready_supervisor(
            _command: list[str],
            *,
            status_fd: int,
            release_fd: int,
        ) -> list[str]:
            del status_fd, release_fd
            return [sys.executable, "-c", "import time; time.sleep(60)"]

        descriptor_root = Path("/dev/fd")
        if not descriptor_root.exists():
            descriptor_root = Path("/proc/self/fd")
        descriptors_before = {
            int(entry.name)
            for entry in descriptor_root.iterdir()
            if entry.name.isdigit()
        }
        stderr = io.StringIO()
        with (
            mock.patch.object(
                RUNNER,
                "_supervisor_argv",
                side_effect=no_ready_supervisor,
            ),
            mock.patch.object(
                RUNNER.os,
                "posix_spawnp",
                side_effect=spawn_then_stall,
            ),
            mock.patch.object(
                RUNNER,
                "_direct_child_pids",
                side_effect=OSError("injected discovery failure"),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=0.05,
                grace_seconds=0.1,
                label="discovery-failure",
            )

        descriptors_after = {
            int(entry.name)
            for entry in descriptor_root.iterdir()
            if entry.name.isdigit()
        }
        self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
        self.assertEqual(descriptors_after, descriptors_before)
        self.assertEqual(len(spawned_supervisors), 1)
        supervisor_pid = spawned_supervisors[0]
        self.assertFalse(_process_is_live(supervisor_pid))
        with self.assertRaises(ChildProcessError):
            os.waitpid(supervisor_pid, os.WNOHANG)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=discovery-failure status=cleanup-failed\n",
        )

    @unittest.skipUnless(
        hasattr(signal, "setitimer"),
        "POSIX interval timers are required",
    )
    def test_persistent_identity_failure_uses_claimed_supervisor_pid(
        self,
    ) -> None:
        original_posix_spawnp = RUNNER.os.posix_spawnp
        spawned_supervisors: list[int] = []

        def spawn_then_stall(
            *arguments: object,
            **keywords: object,
        ) -> int:
            supervisor_pid = original_posix_spawnp(*arguments, **keywords)
            spawned_supervisors.append(supervisor_pid)
            time.sleep(1)
            return supervisor_pid

        claimed_supervisor = (
            "import os,sys,time;"
            "status_fd=int(sys.argv[1]);"
            "time.sleep(0.1);"
            "os.write(status_fd,b'C'+str(os.getpid()).encode('ascii')+b'\\n');"
            "time.sleep(60)"
        )

        def claimed_but_not_ready_supervisor(
            _command: list[str],
            *,
            status_fd: int,
            release_fd: int,
        ) -> list[str]:
            del release_fd
            return [
                sys.executable,
                "-c",
                claimed_supervisor,
                str(status_fd),
            ]

        descriptor_root = Path("/dev/fd")
        if not descriptor_root.exists():
            descriptor_root = Path("/proc/self/fd")
        descriptors_before = {
            int(entry.name)
            for entry in descriptor_root.iterdir()
            if entry.name.isdigit()
        }
        stderr = io.StringIO()
        with (
            mock.patch.object(
                RUNNER,
                "_supervisor_argv",
                side_effect=claimed_but_not_ready_supervisor,
            ),
            mock.patch.object(
                RUNNER.os,
                "posix_spawnp",
                side_effect=spawn_then_stall,
            ),
            mock.patch.object(
                RUNNER,
                "_process_has_supervisor_identity",
                side_effect=OSError("persistent identity failure"),
            ) as identity_check,
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=0.05,
                grace_seconds=0.1,
                label="persistent-identity",
            )

        descriptors_after = {
            int(entry.name)
            for entry in descriptor_root.iterdir()
            if entry.name.isdigit()
        }
        self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
        self.assertEqual(descriptors_after, descriptors_before)
        self.assertGreater(identity_check.call_count, 0)
        self.assertEqual(len(spawned_supervisors), 1)
        supervisor_pid = spawned_supervisors[0]
        self.assertFalse(_process_is_live(supervisor_pid))
        with self.assertRaises(ChildProcessError):
            os.waitpid(supervisor_pid, os.WNOHANG)
        self.assertEqual(
            stderr.getvalue(),
            "bounded-command: label=persistent-identity status=cleanup-failed\n",
        )

    def test_fallback_process_scan_respects_item_and_time_bounds(self) -> None:
        candidate_pids = set(range(10_000, 10_100))
        with (
            mock.patch.object(
                RUNNER,
                "MAX_RECOVERY_PROCESS_SCAN",
                3,
            ),
            mock.patch.object(
                RUNNER,
                "_direct_child_pids",
                side_effect=OSError("injected discovery failure"),
            ),
            mock.patch.object(
                RUNNER,
                "_all_process_pids",
                return_value=(candidate_pids, True),
            ),
            mock.patch.object(
                RUNNER,
                "_process_has_supervisor_identity",
                return_value=False,
            ) as identity_check,
        ):
            result = RUNNER._recover_unreported_supervisor(
                supervisor_identity="bounded-items",
                deadline=time.monotonic() + 1,
            )

        self.assertEqual(result, (False, True))
        self.assertEqual(identity_check.call_count, 3)

        def slow_identity(_process_id: int, _identity: str) -> bool:
            time.sleep(0.02)
            return False

        started_at = time.monotonic()
        with (
            mock.patch.object(
                RUNNER,
                "MAX_RECOVERY_PROCESS_SCAN",
                len(candidate_pids),
            ),
            mock.patch.object(
                RUNNER,
                "_direct_child_pids",
                side_effect=OSError("injected discovery failure"),
            ),
            mock.patch.object(
                RUNNER,
                "_all_process_pids",
                return_value=(candidate_pids, False),
            ),
            mock.patch.object(
                RUNNER,
                "_process_has_supervisor_identity",
                side_effect=slow_identity,
            ) as identity_check,
        ):
            result = RUNNER._recover_unreported_supervisor(
                supervisor_identity="bounded-time",
                deadline=started_at + 0.05,
            )
        elapsed = time.monotonic() - started_at

        self.assertEqual(result, (False, True))
        self.assertLess(identity_check.call_count, len(candidate_pids))
        self.assertLess(elapsed, 0.2)

    @unittest.skipUnless(hasattr(signal, "SIGCHLD"), "SIGCHLD is required")
    def test_ignored_sigchld_is_defaulted_and_restored(self) -> None:
        previous_handler = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "raise SystemExit(0)"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="ignored-sigchld",
                )
            restored_handler = signal.getsignal(signal.SIGCHLD)
        finally:
            signal.signal(signal.SIGCHLD, previous_handler)

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(restored_handler, signal.SIG_IGN)
        self.assertIn(signal.SIGCHLD, RUNNER._default_child_signals())

    def test_supervisor_identity_is_not_inherited_by_target(self) -> None:
        exit_code = RUNNER.run_command(
            [
                sys.executable,
                "-c",
                "import os; raise SystemExit("
                f"{RUNNER._SUPERVISOR_IDENTITY_ENV!r} in os.environ)",
            ],
            timeout_seconds=2,
            grace_seconds=0.1,
            label="identity-private",
        )

        self.assertEqual(exit_code, 0)

    def test_target_stdin_is_closed_for_noninteractive_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "stdin-closed.status"
            wrapper = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--timeout-seconds",
                    "2",
                    "--grace-seconds",
                    "1",
                    "--label",
                    "stdin-closed",
                    "--status-file",
                    str(status_file),
                    "--",
                    sys.executable,
                    "-c",
                    (
                        "import sys; raise SystemExit("
                        "0 if sys.stdin.buffer.read(1) == b'' else 9)"
                    ),
                ],
                input=b"must-not-reach-target",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )

            self.assertEqual(wrapper.returncode, 0, wrapper.stderr.decode())
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=stdin-closed\nstatus=success\nexit_code=0\n",
            )

    @unittest.skipUnless(
        hasattr(signal, "pthread_sigmask") and hasattr(signal, "setitimer"),
        "POSIX signal masks and interval timers are required",
    )
    def test_blocked_alarm_is_temporarily_unblocked_and_restored(self) -> None:
        delivered_to_previous_handler: list[int] = []
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK,
            {signal.SIGALRM},
        )
        original_posix_spawnp = RUNNER.os.posix_spawnp

        def previous_alarm_handler(signum: int, _frame: object) -> None:
            delivered_to_previous_handler.append(signum)

        def stalled_posix_spawnp(
            *arguments: object,
            **keywords: object,
        ) -> int:
            time.sleep(0.5)
            return original_posix_spawnp(*arguments, **keywords)

        signal.signal(signal.SIGALRM, previous_alarm_handler)
        mask_restored = False
        try:
            started_at = time.monotonic()
            with mock.patch.object(
                RUNNER.os,
                "posix_spawnp",
                side_effect=stalled_posix_spawnp,
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=0.05,
                    grace_seconds=0.1,
                    label="blocked-alarm",
                )
            elapsed = time.monotonic() - started_at

            current_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            self.assertIn(signal.SIGALRM, current_mask)
            self.assertNotIn(signal.SIGALRM, signal.sigpending())
            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertLess(elapsed, 0.3)

            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            mask_restored = True
            time.sleep(0.1)
            self.assertEqual(delivered_to_previous_handler, [])
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            if not mask_restored:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            signal.signal(signal.SIGALRM, previous_handler)

    def test_deadline_context_exit_reaps_the_spawned_supervisor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status_file = root / "deadline-exit.status"
            spawned_processes: list[object] = []
            original_spawn = RUNNER._spawn_process

            @contextlib.contextmanager
            def expire_on_exit(_deadline: float):
                yield
                raise RUNNER._SpawnDeadlineExceeded()

            def capture_spawn(command: list[str]) -> object:
                process = original_spawn(command)
                spawned_processes.append(process)
                return process

            stderr = io.StringIO()
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_deadline_alarm",
                    new=expire_on_exit,
                ),
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    side_effect=capture_spawn,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="deadline-exit",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertEqual(len(spawned_processes), 1)
            process = spawned_processes[0]
            self.assertIsNotNone(process.poll())
            self.assertFalse(RUNNER._process_group_exists(process.pid))
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=deadline-exit status=timeout\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=deadline-exit\nstatus=timeout\nexit_code=124\n",
            )

    def test_deadline_cleanup_failure_is_not_reported_as_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "deadline-cleanup.status"
            fake_process = mock.Mock(pid=12_345)

            @contextlib.contextmanager
            def expire_on_exit(_deadline: float):
                yield
                raise RUNNER._SpawnDeadlineExceeded()

            stderr = io.StringIO()
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_deadline_alarm",
                    new=expire_on_exit,
                ),
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    return_value=fake_process,
                ),
                mock.patch.object(
                    RUNNER,
                    "_terminate_process_group",
                    return_value=False,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="deadline-cleanup",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=deadline-cleanup status=cleanup-failed\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=deadline-cleanup\n"
                "status=cleanup-failed\n"
                f"exit_code={RUNNER.CLEANUP_EXIT_CODE}\n",
            )

    @unittest.skipUnless(hasattr(os, "setsid"), "POSIX sessions are required")
    def test_timeout_kills_a_target_that_moves_to_a_new_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target_pid_path = root / "target.pid"
            status_file = root / "detached-timeout.status"
            program = (
                "import os,pathlib,signal,time;"
                "os.setsid();"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
                f"pathlib.Path({str(target_pid_path)!r}).write_text("
                "str(os.getpid()),encoding='utf-8');"
                "time.sleep(60)"
            )
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", program],
                    timeout_seconds=0.5,
                    grace_seconds=0.1,
                    label="detached-timeout",
                    status_file=status_file,
                )

            target_pid = int(target_pid_path.read_text(encoding="utf-8"))
            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertFalse(_process_is_live(target_pid))
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=detached-timeout status=timeout\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=detached-timeout\nstatus=timeout\nexit_code=124\n",
            )

    @unittest.skipUnless(hasattr(os, "setsid"), "POSIX sessions are required")
    def test_successful_detached_leader_cannot_leave_a_descendant(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            child_pid_path = Path(temporary) / "detached-child.pid"
            program = (
                "import os,pathlib,signal,time;"
                "os.setsid();"
                "read_fd,write_fd=os.pipe();"
                "child=os.fork();"
                "\nif child==0:"
                "\n os.close(read_fd)"
                "\n signal.signal(signal.SIGTERM,signal.SIG_IGN)"
                f"\n pathlib.Path({str(child_pid_path)!r}).write_text("
                "str(os.getpid()),encoding='utf-8')"
                "\n os.write(write_fd,b'1')"
                "\n os.close(write_fd)"
                "\n time.sleep(60)"
                "\nelse:"
                "\n os.close(write_fd)"
                "\n os.read(read_fd,1)"
                "\n os.close(read_fd)"
                "\n os._exit(0)"
            )

            exit_code = RUNNER.run_command(
                [sys.executable, "-c", program],
                timeout_seconds=2,
                grace_seconds=0.1,
                label="detached-descendant",
            )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertEqual(exit_code, 0)
            self.assertFalse(_process_is_live(child_pid))

    def test_target_group_is_signaled_before_the_leader_is_reaped(self) -> None:
        events: list[str] = []

        def wait_without_reaping(_child_pid: int) -> None:
            events.append("wait-unreaped")

        def signal_group(_process_group_id: int, _signum: int) -> str:
            events.append("signal-group")
            return "sent"

        def reap_child(child_pid: int, _options: int) -> tuple[int, int]:
            events.append("reap")
            return child_pid, 0

        with (
            mock.patch.object(
                RUNNER,
                "_wait_without_reaping",
                side_effect=wait_without_reaping,
            ),
            mock.patch.object(
                RUNNER,
                "_signal_process_group",
                side_effect=signal_group,
            ),
            mock.patch.object(
                RUNNER.os,
                "waitpid",
                side_effect=reap_child,
            ),
            mock.patch.object(
                RUNNER,
                "_process_group_exists",
                return_value=False,
            ),
        ):
            wait_status = RUNNER._wait_for_target_exit(12_345)

        self.assertEqual(wait_status, 0)
        self.assertEqual(events, ["wait-unreaped", "signal-group", "reap"])

    def test_interruption_during_running_status_reaps_child_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "interrupt.status"
            spawned_processes: list[subprocess.Popen[bytes]] = []
            original_spawn = RUNNER._spawn_process
            original_write_status = RUNNER._write_status
            interruption_injected = False

            def capture_spawn(
                command: list[str],
            ) -> subprocess.Popen[bytes]:
                process = original_spawn(command)
                spawned_processes.append(process)
                return process

            def interrupt_running_status(
                path: Path | None,
                *,
                label: str,
                status: str,
                exit_code: int,
            ) -> bool:
                nonlocal interruption_injected
                if status == "running" and not interruption_injected:
                    interruption_injected = True
                    raise RUNNER._SignalInterruption(signal.SIGTERM)
                return original_write_status(
                    path,
                    label=label,
                    status=status,
                    exit_code=exit_code,
                )

            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    side_effect=capture_spawn,
                ),
                mock.patch.object(
                    RUNNER,
                    "_write_status",
                    side_effect=interrupt_running_status,
                ),
                self.assertRaises(RUNNER._SignalInterruption),
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="setup-interrupt",
                    status_file=status_file,
                )

            self.assertTrue(interruption_injected)
            self.assertEqual(len(spawned_processes), 1)
            process = spawned_processes[0]
            self.assertIsNotNone(process.poll())
            self.assertFalse(RUNNER._process_group_exists(process.pid))
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=setup-interrupt\n"
                "status=interrupted\n"
                f"exit_code={128 + signal.SIGTERM}\n",
            )

    @unittest.skipUnless(
        hasattr(signal, "pthread_sigmask"),
        "POSIX signal masks are required",
    )
    def test_signal_during_atomic_spawn_is_deferred_until_child_is_reaped(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "spawn-interrupt.status"
            spawned_processes: list[subprocess.Popen[bytes]] = []
            original_spawn = RUNNER._spawn_process
            previous_handler = signal.getsignal(signal.SIGTERM)

            def raise_signal_interruption(signum: int, _frame: object) -> None:
                raise RUNNER._SignalInterruption(signum)

            def spawn_then_interrupt(
                command: list[str],
            ) -> subprocess.Popen[bytes]:
                process = original_spawn(command)
                spawned_processes.append(process)
                os.kill(os.getpid(), signal.SIGTERM)
                return process

            signal.signal(signal.SIGTERM, raise_signal_interruption)
            try:
                with (
                    mock.patch.object(
                        RUNNER,
                        "_spawn_process",
                        side_effect=spawn_then_interrupt,
                    ),
                    self.assertRaises(RUNNER._SignalInterruption),
                ):
                    RUNNER.run_command(
                        [sys.executable, "-c", "import time; time.sleep(60)"],
                        timeout_seconds=2,
                        grace_seconds=0.1,
                        label="spawn-interrupt",
                        status_file=status_file,
                    )
            finally:
                signal.signal(signal.SIGTERM, previous_handler)

            self.assertEqual(len(spawned_processes), 1)
            process = spawned_processes[0]
            self.assertIsNotNone(process.poll())
            self.assertFalse(RUNNER._process_group_exists(process.pid))
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=spawn-interrupt\n"
                "status=interrupted\n"
                f"exit_code={128 + signal.SIGTERM}\n",
            )

    @unittest.skipUnless(
        hasattr(signal, "pthread_sigmask"),
        "POSIX signal masks are required",
    )
    def test_second_real_signal_after_spawn_cannot_skip_terminal_status(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "double-spawn-interrupt.status"
            spawned_processes: list[subprocess.Popen[bytes]] = []
            original_spawn = RUNNER._spawn_process
            original_terminate = RUNNER._terminate_process_group
            previous_handlers = {
                signum: signal.getsignal(signum)
                for signum in (signal.SIGHUP, signal.SIGTERM)
            }
            second_signal_sent = False

            def raise_signal_interruption(signum: int, _frame: object) -> None:
                raise RUNNER._SignalInterruption(signum)

            def spawn_then_interrupt(
                command: list[str],
            ) -> subprocess.Popen[bytes]:
                process = original_spawn(command)
                spawned_processes.append(process)
                os.kill(os.getpid(), signal.SIGHUP)
                return process

            def terminate_then_interrupt(
                process: subprocess.Popen[bytes],
                *,
                grace_seconds: float,
            ) -> bool:
                nonlocal second_signal_sent
                if not second_signal_sent:
                    second_signal_sent = True
                    os.kill(os.getpid(), signal.SIGTERM)
                return original_terminate(
                    process,
                    grace_seconds=grace_seconds,
                )

            for signum in previous_handlers:
                signal.signal(signum, raise_signal_interruption)
            try:
                with (
                    mock.patch.object(
                        RUNNER,
                        "_spawn_process",
                        side_effect=spawn_then_interrupt,
                    ),
                    mock.patch.object(
                        RUNNER,
                        "_terminate_process_group",
                        side_effect=terminate_then_interrupt,
                    ),
                    self.assertRaises(RUNNER._SignalInterruption) as raised,
                ):
                    RUNNER.run_command(
                        [sys.executable, "-c", "import time; time.sleep(60)"],
                        timeout_seconds=2,
                        grace_seconds=0.1,
                        label="double-spawn-interrupt",
                        status_file=status_file,
                    )
            finally:
                for signum, handler in previous_handlers.items():
                    signal.signal(signum, handler)

            self.assertEqual(raised.exception.signum, signal.SIGHUP)
            self.assertTrue(second_signal_sent)
            self.assertEqual(len(spawned_processes), 1)
            process = spawned_processes[0]
            self.assertIsNotNone(process.poll())
            self.assertFalse(RUNNER._process_group_exists(process.pid))
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=double-spawn-interrupt\n"
                "status=interrupted\n"
                f"exit_code={128 + signal.SIGHUP}\n",
            )

    def test_stalled_target_spawn_is_reaped_before_timeout_returns(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status_file = root / "spawn-timeout.status"
            spawn_marker = root / "spawn-entered"
            target_marker = root / "target-started"
            spawned_processes: list[object] = []
            original_spawn = RUNNER._spawn_process

            def capture_spawn(
                command: list[str],
            ) -> object:
                process = original_spawn(command)
                spawned_processes.append(process)
                return process

            helper = (
                "import os,pathlib,sys,time;"
                "status_fd=int(sys.argv[1]);"
                "release_fd=int(sys.argv[2]);"
                "release=os.read(release_fd,1);"
                "os.close(release_fd);"
                "(release == b'G') or sys.exit(127);"
                f"pathlib.Path({str(spawn_marker)!r}).write_text("
                "'entered',encoding='utf-8');"
                "time.sleep(1);"
                f"pathlib.Path({str(target_marker)!r}).write_text("
                "'started',encoding='utf-8');"
                "os.write(status_fd,b'S999999\\n');"
                "time.sleep(60)"
            )

            def stalled_supervisor_argv(
                _command: list[str],
                *,
                status_fd: int,
                release_fd: int,
            ) -> list[str]:
                return [
                    sys.executable,
                    "-c",
                    helper,
                    str(status_fd),
                    str(release_fd),
                ]

            stderr = io.StringIO()
            started_at = time.monotonic()
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    side_effect=capture_spawn,
                ),
                mock.patch.object(
                    RUNNER,
                    "_supervisor_argv",
                    side_effect=stalled_supervisor_argv,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [
                        sys.executable,
                        "-c",
                        f"import pathlib; pathlib.Path({str(target_marker)!r})"
                        ".write_text('started', encoding='utf-8')",
                    ],
                    timeout_seconds=0.25,
                    grace_seconds=0.1,
                    label="spawn-timeout",
                    status_file=status_file,
                )

            elapsed = time.monotonic() - started_at
            self.assertTrue(spawn_marker.exists())
            self.assertLess(elapsed, 0.9)
            self.assertEqual(exit_code, RUNNER.TIMEOUT_EXIT_CODE)
            self.assertEqual(len(spawned_processes), 1)
            process = spawned_processes[0]
            self.assertIsNotNone(process.poll())
            self.assertFalse(RUNNER._process_group_exists(process.pid))
            self.assertFalse(target_marker.exists())
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=spawn-timeout status=timeout\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=spawn-timeout\nstatus=timeout\nexit_code=124\n",
            )

    def test_target_exit_127_is_not_reported_as_start_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "target-127.status"
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "raise SystemExit(127)"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="target-127",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, 127)
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=target-127\nstatus=failed\nexit_code=127\n",
            )

    def test_interruption_cleanup_failure_returns_cleanup_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "cleanup-failed.status"
            original_write_status = RUNNER._write_status
            interruption_injected = False

            def interrupt_running_status(
                path: Path | None,
                *,
                label: str,
                status: str,
                exit_code: int,
            ) -> bool:
                nonlocal interruption_injected
                if status == "running" and not interruption_injected:
                    interruption_injected = True
                    raise RUNNER._SignalInterruption(signal.SIGTERM)
                return original_write_status(
                    path,
                    label=label,
                    status=status,
                    exit_code=exit_code,
                )

            fake_process = mock.Mock(pid=12_345)
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    return_value=fake_process,
                ),
                mock.patch.object(
                    RUNNER,
                    "_terminate_process_group",
                    return_value=False,
                ),
                mock.patch.object(
                    RUNNER,
                    "_write_status",
                    side_effect=interrupt_running_status,
                ),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="cleanup-interrupt",
                    status_file=status_file,
                )

            self.assertTrue(interruption_injected)
            self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=cleanup-interrupt\n"
                "status=cleanup-failed\n"
                f"exit_code={RUNNER.CLEANUP_EXIT_CODE}\n",
            )

    def test_timeout_cleanup_failure_reports_only_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "timeout-cleanup-failed.status"
            fake_process = mock.Mock(pid=12_345)
            fake_process.poll.return_value = None
            fake_process.wait.side_effect = subprocess.TimeoutExpired(
                cmd=["sleep"],
                timeout=0.01,
            )
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    return_value=fake_process,
                ),
                mock.patch.object(
                    RUNNER,
                    "_terminate_process_group",
                    return_value=False,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=0.01,
                    grace_seconds=0.1,
                    label="timeout-cleanup-failed",
                    status_file=status_file,
                )

            self.assertEqual(exit_code, RUNNER.CLEANUP_EXIT_CODE)
            self.assertEqual(
                stderr.getvalue(),
                "bounded-command: label=timeout-cleanup-failed status=cleanup-failed\n",
            )
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=timeout-cleanup-failed\n"
                "status=cleanup-failed\n"
                f"exit_code={RUNNER.CLEANUP_EXIT_CODE}\n",
            )

    def test_second_interruption_during_cleanup_is_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "cleanup-retry.status"
            original_write_status = RUNNER._write_status
            interruption_injected = False

            def interrupt_running_status(
                path: Path | None,
                *,
                label: str,
                status: str,
                exit_code: int,
            ) -> bool:
                nonlocal interruption_injected
                if status == "running" and not interruption_injected:
                    interruption_injected = True
                    raise RUNNER._SignalInterruption(signal.SIGTERM)
                return original_write_status(
                    path,
                    label=label,
                    status=status,
                    exit_code=exit_code,
                )

            fake_process = mock.Mock(pid=12_345)
            with (
                mock.patch.object(
                    RUNNER,
                    "_spawn_process",
                    return_value=fake_process,
                ),
                mock.patch.object(
                    RUNNER,
                    "_terminate_process_group",
                    side_effect=[
                        RUNNER._SignalInterruption(signal.SIGHUP),
                        True,
                    ],
                ) as terminate,
                mock.patch.object(
                    RUNNER,
                    "_write_status",
                    side_effect=interrupt_running_status,
                ),
                self.assertRaises(RUNNER._SignalInterruption),
            ):
                RUNNER.run_command(
                    [sys.executable, "-c", "pass"],
                    timeout_seconds=2,
                    grace_seconds=0.1,
                    label="cleanup-retry",
                    status_file=status_file,
                )

            self.assertTrue(interruption_injected)
            self.assertEqual(terminate.call_count, 2)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=cleanup-retry\n"
                "status=interrupted\n"
                f"exit_code={128 + signal.SIGTERM}\n",
            )

    def test_cli_interrupt_terminates_the_child_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid_path = root / "child.pid"
            status_file = root / "interrupt.status"
            child_program = (
                "import os,pathlib,time;"
                f"pathlib.Path({str(child_pid_path)!r}).write_text("
                "str(os.getpid()),encoding='utf-8');"
                "time.sleep(60)"
            )
            wrapper = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--timeout-seconds",
                    "10",
                    "--grace-seconds",
                    "1",
                    "--label",
                    "interrupt-case",
                    "--status-file",
                    str(status_file),
                    "--",
                    sys.executable,
                    "-c",
                    child_program,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            _wait_for_path(child_pid_path)
            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            wrapper.send_signal(signal.SIGINT)
            self.assertEqual(wrapper.wait(timeout=4), RUNNER.INTERRUPTED_EXIT_CODE)
            self.assertFalse(_process_is_live(child_pid))
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=interrupt-case\nstatus=interrupted\nexit_code=130\n",
            )

    def test_signal_exit_is_normalized_for_status_and_return(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_file = Path(temporary) / "signal.status"
            exit_code = RUNNER.run_command(
                [
                    sys.executable,
                    "-c",
                    "import os,signal; os.kill(os.getpid(), signal.SIGTERM)",
                ],
                timeout_seconds=2,
                grace_seconds=0.1,
                label="signal-case",
                status_file=status_file,
            )
            self.assertEqual(exit_code, 128 + signal.SIGTERM)
            self.assertEqual(
                status_file.read_text(encoding="utf-8"),
                "label=signal-case\nstatus=failed\nexit_code=143\n",
            )

    def test_linux_memory_parser_requires_available_and_total(self) -> None:
        with (
            mock.patch.object(RUNNER.sys, "platform", "linux"),
            mock.patch.object(
                RUNNER.Path,
                "read_text",
                return_value="MemTotal: 100 kB\n",
            ),
        ):
            self.assertIsNone(RUNNER._system_free_memory_percent())

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
        with self.assertRaisesRegex(ValueError, "heartbeat interval is invalid"):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                heartbeat_seconds=0,
                label="invalid-heartbeat",
            )
        with self.assertRaisesRegex(
            ValueError,
            "minimum free memory percentage is invalid",
        ):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                min_free_memory_percent=101,
                label="invalid-memory",
            )
        with self.assertRaisesRegex(
            ValueError,
            "minimum free disk size is invalid",
        ):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                min_free_disk_bytes=-1,
                label="invalid-disk",
            )
        with self.assertRaisesRegex(
            ValueError,
            "resource check interval is invalid",
        ):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                resource_check_seconds=0,
                label="invalid-resource-check",
            )
        with self.assertRaisesRegex(
            ValueError,
            "minimum free memory percentage is invalid",
        ):
            RUNNER.run_command(
                [sys.executable, "-c", "pass"],
                timeout_seconds=1,
                grace_seconds=1,
                min_free_memory_percent=float("inf"),
                label="invalid-memory-infinity",
            )

    def test_direct_api_rejects_invalid_log_caps_before_spawning(self) -> None:
        invalid_values = (
            True,
            False,
            1.5,
            float("nan"),
            float("inf"),
            0,
            RUNNER.MAX_MAX_LOG_MIB * RUNNER.MIB_BYTES + 1,
        )
        with mock.patch.object(
            RUNNER,
            "_spawn_process_before_deadline",
        ) as spawn:
            for value in invalid_values:
                with (
                    self.subTest(value=value),
                    self.assertRaisesRegex(
                        ValueError,
                        "maximum log size is invalid",
                    ),
                ):
                    RUNNER.run_command(
                        [sys.executable, "-c", "pass"],
                        timeout_seconds=1,
                        grace_seconds=1,
                        label="invalid-log-cap",
                        max_log_bytes=value,
                    )
        spawn.assert_not_called()

    def test_cli_enables_conservative_resource_floors_by_default(self) -> None:
        with mock.patch.object(RUNNER, "run_command", return_value=0) as run:
            exit_code = RUNNER.main(
                [
                    "--timeout-seconds",
                    "1",
                    "--label",
                    "default-resource-floors",
                    "--",
                    sys.executable,
                    "-c",
                    "pass",
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            run.call_args.kwargs["min_free_memory_percent"],
            RUNNER.DEFAULT_MIN_FREE_MEMORY_PERCENT,
        )
        self.assertEqual(
            run.call_args.kwargs["min_free_disk_bytes"],
            RUNNER._minimum_free_disk_bytes(
                RUNNER.DEFAULT_MIN_FREE_DISK_GIB,
            ),
        )

    def test_cli_allows_an_explicit_zero_resource_floor(self) -> None:
        with mock.patch.object(RUNNER, "run_command", return_value=0) as run:
            exit_code = RUNNER.main(
                [
                    "--timeout-seconds",
                    "1",
                    "--label",
                    "explicit-zero-resource-floors",
                    "--min-free-memory-percent",
                    "0",
                    "--min-free-disk-gib",
                    "0",
                    "--",
                    sys.executable,
                    "-c",
                    "pass",
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(run.call_args.kwargs["min_free_memory_percent"], 0)
        self.assertEqual(run.call_args.kwargs["min_free_disk_bytes"], 0)

    def test_cli_rejects_infinite_disk_limit_without_traceback(self) -> None:
        stderr = io.StringIO()
        with (
            contextlib.redirect_stderr(stderr),
            self.assertRaises(SystemExit) as raised,
        ):
            RUNNER.main(
                [
                    "--timeout-seconds",
                    "1",
                    "--label",
                    "invalid-disk-infinity",
                    "--min-free-disk-gib",
                    "inf",
                    "--",
                    sys.executable,
                    "-c",
                    "pass",
                ]
            )
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("minimum free disk size is invalid", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_cli_rejects_overflowing_and_subbyte_disk_limits(self) -> None:
        for value in ("1e308", "1e-320"):
            with self.subTest(value=value):
                stderr = io.StringIO()
                with (
                    contextlib.redirect_stderr(stderr),
                    self.assertRaises(SystemExit) as raised,
                ):
                    RUNNER.main(
                        [
                            "--timeout-seconds",
                            "1",
                            "--label",
                            "invalid-disk-size",
                            "--min-free-disk-gib",
                            value,
                            "--",
                            sys.executable,
                            "-c",
                            "pass",
                        ]
                    )
                self.assertEqual(raised.exception.code, 2)
                self.assertIn(
                    "minimum free disk size is invalid",
                    stderr.getvalue(),
                )
                self.assertNotIn("Traceback", stderr.getvalue())

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
