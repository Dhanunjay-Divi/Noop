#!/usr/bin/env python3
"""Run a non-interactive command in its own process group with a hard deadline."""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import math
import os
import queue
import re
import resource
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


TIMEOUT_EXIT_CODE = 124
RESOURCE_EXIT_CODE = 125
CLEANUP_EXIT_CODE = 126
START_FAILURE_EXIT_CODE = 127
INTERRUPTED_EXIT_CODE = 130
MAX_TIMEOUT_SECONDS = 3_600
MAX_GRACE_SECONDS = 60
DEFAULT_HEARTBEAT_SECONDS = 60
MAX_HEARTBEAT_SECONDS = 300
DEFAULT_RESOURCE_CHECK_SECONDS = 5
MAX_RESOURCE_CHECK_SECONDS = 300
MAX_RESOURCE_PROBE_SECONDS = 5
FINAL_KILL_WAIT_SECONDS = 10
PROCESS_GROUP_POLL_SECONDS = 0.05
MAX_RECOVERY_PROCESS_SCAN = 4_096
MAX_CLEANUP_INTERRUPTION_RETRIES = 3
GIB_BYTES = 1024 * 1024 * 1024
SAFE_LABEL = re.compile(r"^[a-z][a-z0-9-]{2,63}$")
MEMORY_PERCENT = re.compile(
    r"System-wide memory free percentage:\s*([0-9]+(?:\.[0-9]+)?)%"
)
_RESOURCE_PROBE_LOCK = threading.Lock()
_RESOURCE_PROBE_THREAD: threading.Thread | None = None
_SPAWN_LOCK = threading.Lock()
_SUPERVISOR_CLAIMED = b"C"
_SUPERVISOR_READY = b"R"
_SPAWN_STARTED = b"S"
_SPAWN_FAILED = b"E"
_SPAWN_RELEASED = b"G"
_SUPERVISOR_STATUS_FD = 198
_SUPERVISOR_RELEASE_FD = 199
_SUPERVISOR_IDENTITY_ENV = "NOOP_BOUNDED_COMMAND_SUPERVISOR"
_DARWIN_CTL_KERN = 1
_DARWIN_KERN_PROCARGS2 = 49
_SIGINFO_BUFFER_BYTES = 128


class _SignalInterruption(BaseException):
    def __init__(self, signum: int) -> None:
        self.signum = signum


class _SpawnDeadlineExceeded(BaseException):
    pass


class _SpawnCleanupFailed(BaseException):
    pass


class _SpawnedProcess:
    """Minimal Popen-compatible handle for a supervised process group."""

    def __init__(self, pid: int, spawn_status_fd: int) -> None:
        self.pid = pid
        self.returncode: int | None = None
        self._spawn_status_fd: int | None = spawn_status_fd
        self._spawn_status = "pending"
        self._spawn_status_buffer = bytearray()
        self._supervisor_claimed = False
        self._supervisor_ready = False
        self._target_pid: int | None = None
        self._reaped = False

    def _close_spawn_status_fd(self) -> None:
        if self._spawn_status_fd is None:
            return
        try:
            os.close(self._spawn_status_fd)
        except OSError:
            pass
        self._spawn_status_fd = None

    def _refresh_spawn_status(self) -> None:
        if self._spawn_status_fd is None:
            return
        reached_eof = False
        while True:
            try:
                status = os.read(self._spawn_status_fd, 64)
            except BlockingIOError:
                break
            except OSError:
                reached_eof = True
                break
            if not status:
                reached_eof = True
                break
            self._spawn_status_buffer.extend(status)

        while b"\n" in self._spawn_status_buffer:
            raw_line, _, remainder = self._spawn_status_buffer.partition(b"\n")
            self._spawn_status_buffer = bytearray(remainder)
            if raw_line[:1] == _SUPERVISOR_CLAIMED:
                try:
                    supervisor_pid = int(raw_line[1:])
                except ValueError:
                    self._spawn_status = "failed"
                else:
                    if supervisor_pid == self.pid:
                        self._supervisor_claimed = True
                    else:
                        self._spawn_status = "failed"
            elif raw_line[:1] == _SUPERVISOR_READY:
                try:
                    supervisor_pid = int(raw_line[1:])
                except ValueError:
                    self._spawn_status = "failed"
                else:
                    if supervisor_pid == self.pid and self._supervisor_claimed:
                        self._supervisor_ready = True
                    else:
                        self._spawn_status = "failed"
            elif raw_line[:1] == _SPAWN_STARTED:
                try:
                    target_pid = int(raw_line[1:])
                except ValueError:
                    self._spawn_status = "failed"
                else:
                    if target_pid > 0 and self._supervisor_ready:
                        self._spawn_status = "started"
                        self._target_pid = target_pid
                    else:
                        self._spawn_status = "failed"
            elif raw_line == _SPAWN_FAILED:
                self._spawn_status = "failed"
            else:
                self._spawn_status = "failed"

            if self._spawn_status in {"failed", "started"}:
                self._close_spawn_status_fd()
                return

        if reached_eof:
            if self._spawn_status == "pending":
                self._spawn_status = "failed"
            self._close_spawn_status_fd()

    @property
    def start_failed(self) -> bool:
        self._refresh_spawn_status()
        return self._spawn_status == "failed"

    @property
    def target_pid(self) -> int | None:
        self._refresh_spawn_status()
        return self._target_pid

    def _record_wait_status(self, wait_status: int) -> int:
        self._refresh_spawn_status()
        if os.WIFEXITED(wait_status):
            self.returncode = os.WEXITSTATUS(wait_status)
        elif os.WIFSIGNALED(wait_status):
            self.returncode = -os.WTERMSIG(wait_status)
        else:
            raise OSError("unexpected child wait status")
        self._reaped = True
        return self.returncode

    def _peek_returncode(self, *, nohang: bool) -> int | None:
        waitid = getattr(os, "waitid", None)
        if waitid is None:
            result = _native_waitid_result(self.pid, nohang=nohang)
            if result is None:
                return None
            status_code, status = result
        else:
            options = os.WEXITED | os.WNOWAIT
            if nohang:
                options |= os.WNOHANG
            while True:
                try:
                    process_info = waitid(os.P_PID, self.pid, options)
                except InterruptedError:
                    continue
                break
            if process_info is None or process_info.si_pid == 0:
                return None
            status_code = process_info.si_code
            status = process_info.si_status
        if status_code == os.CLD_EXITED:
            return status
        if status_code in {os.CLD_KILLED, os.CLD_DUMPED}:
            return -status
        raise OSError("unexpected child wait status")

    @property
    def reaped(self) -> bool:
        return self._reaped

    def reap(self) -> int:
        if self._reaped:
            if self.returncode is None:
                raise OSError("reaped process has no return code")
            return self.returncode
        _, wait_status = os.waitpid(self.pid, 0)
        return self._record_wait_status(wait_status)

    def poll(self) -> int | None:
        self._refresh_spawn_status()
        if self.returncode is not None:
            return self.returncode
        self.returncode = self._peek_returncode(nohang=True)
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        if self.returncode is not None:
            return self.returncode
        if timeout is None:
            self.returncode = self._peek_returncode(nohang=False)
            if self.returncode is None:
                raise OSError("child wait completed without a status")
            return self.returncode

        deadline = time.monotonic() + max(0, timeout)
        while True:
            returncode = self.poll()
            if returncode is not None:
                return returncode
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired("<bounded-command>", timeout)
            time.sleep(min(PROCESS_GROUP_POLL_SECONDS, remaining))


def _default_child_signals() -> set[int]:
    default_signals = {
        signal.SIGALRM,
        signal.SIGCHLD,
        signal.SIGHUP,
        signal.SIGINT,
        signal.SIGTERM,
        signal.SIGPIPE,
    }
    for name in ("SIGXFZ", "SIGXFSZ"):
        signum = getattr(signal, name, None)
        if signum is not None:
            default_signals.add(signum)
    return default_signals


def _write_spawn_status(
    status_fd: int,
    status: bytes,
    *,
    target_pid: int | None = None,
) -> None:
    payload = status
    if (
        status
        in {
            _SUPERVISOR_CLAIMED,
            _SUPERVISOR_READY,
            _SPAWN_STARTED,
        }
        and target_pid is not None
    ):
        payload += f"{target_pid}\n".encode("ascii")
    else:
        payload += b"\n"
    remaining = memoryview(payload)
    while remaining:
        try:
            written = os.write(status_fd, remaining)
        except OSError:
            return
        if written <= 0:
            return
        remaining = remaining[written:]


def _exit_like_child(wait_status: int) -> None:
    if os.WIFEXITED(wait_status):
        os._exit(os.WEXITSTATUS(wait_status))
    if os.WIFSIGNALED(wait_status):
        signum = os.WTERMSIG(wait_status)
        try:
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        except (OSError, ValueError):
            pass
        os._exit(min(255, 128 + signum))
    os._exit(START_FAILURE_EXIT_CODE)


def _native_waitid_result(
    child_pid: int,
    *,
    nohang: bool,
) -> tuple[int, int] | None:
    if not all(
        hasattr(os, attribute)
        for attribute in ("P_PID", "WEXITED", "WNOWAIT")
    ):
        raise OSError("unreaped process waiting is unavailable")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        waitid = libc.waitid
    except (AttributeError, OSError) as error:
        raise OSError("unreaped process waiting is unavailable") from error
    waitid.argtypes = [
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    waitid.restype = ctypes.c_int
    if sys.platform != "darwin":
        raise OSError("native waitid result parsing is unavailable")
    process_info = (ctypes.c_byte * _SIGINFO_BUFFER_BYTES)()
    options = os.WEXITED | os.WNOWAIT
    if nohang:
        options |= os.WNOHANG
    while True:
        ctypes.set_errno(0)
        result = waitid(
            os.P_PID,
            child_pid,
            ctypes.byref(process_info),
            options,
        )
        if result == 0:
            values = ctypes.cast(
                process_info,
                ctypes.POINTER(ctypes.c_int),
            )
            if values[3] == 0:
                return None
            return values[2], values[5]
        error_number = ctypes.get_errno()
        if error_number == getattr(os, "EINTR", 4):
            continue
        raise OSError(error_number, "unreaped process waiting failed")


def _native_waitid_without_reaping(child_pid: int) -> None:
    _native_waitid_result(child_pid, nohang=False)


def _wait_without_reaping(child_pid: int) -> None:
    waitid = getattr(os, "waitid", None)
    if (
        waitid is not None
        and hasattr(os, "P_PID")
        and hasattr(os, "WEXITED")
        and hasattr(os, "WNOWAIT")
    ):
        while True:
            try:
                waitid(
                    os.P_PID,
                    child_pid,
                    os.WEXITED | os.WNOWAIT,
                )
            except InterruptedError:
                continue
            return
    _native_waitid_without_reaping(child_pid)


def _wait_for_target_exit(child_pid: int) -> int:
    _wait_without_reaping(child_pid)

    # A target that created a new session uses its PID as the process-group ID.
    # Keep the exited leader unreaped so that ID cannot be reused while
    # terminating descendants that attempted to outlive the command.
    _signal_process_group(child_pid, signal.SIGKILL)
    while True:
        try:
            _, wait_status = os.waitpid(child_pid, 0)
        except InterruptedError:
            continue
        break

    deadline = time.monotonic() + FINAL_KILL_WAIT_SECONDS
    while _process_group_exists(child_pid):
        _signal_process_group(child_pid, signal.SIGKILL)
        if time.monotonic() >= deadline:
            os._exit(CLEANUP_EXIT_CODE)
        time.sleep(PROCESS_GROUP_POLL_SECONDS)
    return wait_status


def _supervise_command(
    command: list[str],
    status_fd: int,
    release_fd: int,
) -> None:
    default_signals = _default_child_signals()
    child_pid: int | None = None

    def forward_termination(signum: int, _frame: object) -> None:
        if child_pid is None:
            return
        try:
            child_process_group_id = os.getpgid(child_pid)
        except (ProcessLookupError, PermissionError):
            child_process_group_id = None
        if (
            child_process_group_id is not None
            and child_process_group_id != os.getpgrp()
        ):
            try:
                os.killpg(child_process_group_id, signum)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.kill(child_pid, signum)
        except (ProcessLookupError, PermissionError):
            pass

    try:
        for signum in default_signals:
            signal.signal(signum, signal.SIG_DFL)
        os.setpgid(0, 0)
        if hasattr(signal, "pthread_sigmask"):
            signal.pthread_sigmask(signal.SIG_SETMASK, set())
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, forward_termination)
        _write_spawn_status(
            status_fd,
            _SUPERVISOR_READY,
            target_pid=os.getpid(),
        )
        release = os.read(release_fd, 1)
        os.close(release_fd)
        if release != _SPAWN_RELEASED:
            raise OSError("supervisor launch was not released")
        target_environment = os.environ.copy()
        target_environment.pop(_SUPERVISOR_IDENTITY_ENV, None)
        child_pid = os.posix_spawnp(
            command[0],
            command,
            target_environment,
            file_actions=[
                (
                    os.POSIX_SPAWN_OPEN,
                    0,
                    os.devnull,
                    os.O_RDONLY,
                    0o666,
                ),
                (os.POSIX_SPAWN_CLOSE, status_fd),
            ],
            setsigdef=default_signals,
            setsigmask=(),
        )
    except BaseException:
        _write_spawn_status(status_fd, _SPAWN_FAILED)
        try:
            os.close(status_fd)
        except OSError:
            pass
        os._exit(START_FAILURE_EXIT_CODE)

    _write_spawn_status(
        status_fd,
        _SPAWN_STARTED,
        target_pid=child_pid,
    )
    try:
        os.close(status_fd)
    except OSError:
        pass
    try:
        wait_status = _wait_for_target_exit(child_pid)
    except ChildProcessError:
        os._exit(START_FAILURE_EXIT_CODE)
    _exit_like_child(wait_status)


def _kill_failed_supervisor(
    pid: int,
    *,
    deadline: float | None = None,
) -> bool:
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if deadline is None:
        deadline = time.monotonic() + FINAL_KILL_WAIT_SECONDS
    while True:
        try:
            waited_pid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return not _process_exists(pid) and not _process_group_exists(pid)
        except OSError:
            return False
        if waited_pid == pid:
            return not _process_group_exists(pid)
        if time.monotonic() >= deadline:
            return False
        time.sleep(PROCESS_GROUP_POLL_SECONDS)


def _darwin_direct_child_pids(parent_pid: int) -> set[int]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        list_children = libproc.proc_listchildpids
    except (AttributeError, OSError) as error:
        raise OSError("direct child discovery is unavailable") from error
    list_children.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    list_children.restype = ctypes.c_int

    capacity = list_children(parent_pid, None, 0)
    if capacity < 0:
        raise OSError(
            ctypes.get_errno(),
            "direct child discovery failed",
        )
    if capacity == 0:
        return set()
    children = (ctypes.c_int * capacity)()
    count = list_children(
        parent_pid,
        ctypes.byref(children),
        ctypes.sizeof(children),
    )
    if count < 0:
        raise OSError(
            ctypes.get_errno(),
            "direct child discovery failed",
        )
    return {pid for pid in children[:count] if pid > 0}


def _linux_direct_child_pids(parent_pid: int) -> set[int]:
    children_path = Path(
        f"/proc/{parent_pid}/task/{parent_pid}/children"
    )
    try:
        raw_children = children_path.read_text(encoding="ascii")
    except OSError as error:
        raise OSError("direct child discovery is unavailable") from error
    try:
        return {int(value) for value in raw_children.split()}
    except ValueError as error:
        raise OSError("direct child discovery returned invalid data") from error


def _direct_child_pids(parent_pid: int) -> set[int]:
    if sys.platform == "darwin":
        return _darwin_direct_child_pids(parent_pid)
    if sys.platform.startswith("linux"):
        return _linux_direct_child_pids(parent_pid)
    raise OSError("direct child discovery is unavailable")


def _darwin_all_process_pids(
    max_processes: int,
) -> tuple[set[int], bool]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        list_processes = libproc.proc_listallpids
    except (AttributeError, OSError) as error:
        raise OSError("process discovery is unavailable") from error
    list_processes.argtypes = [ctypes.c_void_p, ctypes.c_int]
    list_processes.restype = ctypes.c_int

    capacity = list_processes(None, 0)
    if capacity < 0:
        raise OSError(ctypes.get_errno(), "process discovery failed")
    if capacity == 0:
        return set(), False
    buffer_capacity = min(capacity, max_processes + 1)
    processes = (ctypes.c_int * buffer_capacity)()
    count = list_processes(
        ctypes.byref(processes),
        ctypes.sizeof(processes),
    )
    if count < 0:
        raise OSError(ctypes.get_errno(), "process discovery failed")
    process_ids = [pid for pid in processes[:count] if pid > 0]
    truncated = (
        capacity > max_processes
        or len(process_ids) > max_processes
        or count >= buffer_capacity
    )
    return set(process_ids[:max_processes]), truncated


def _linux_all_process_pids(
    max_processes: int,
) -> tuple[set[int], bool]:
    process_ids: set[int] = set()
    truncated = False
    try:
        with os.scandir("/proc") as entries:
            for entry in entries:
                if not entry.name.isdigit():
                    continue
                if len(process_ids) >= max_processes:
                    truncated = True
                    break
                process_ids.add(int(entry.name))
    except OSError as error:
        raise OSError("process discovery is unavailable") from error
    return process_ids, truncated


def _all_process_pids(
    max_processes: int = MAX_RECOVERY_PROCESS_SCAN,
) -> tuple[set[int], bool]:
    if sys.platform == "darwin":
        return _darwin_all_process_pids(max_processes)
    if sys.platform.startswith("linux"):
        return _linux_all_process_pids(max_processes)
    raise OSError("process discovery is unavailable")


def _darwin_process_arguments(process_id: int) -> bytes:
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        sysctl = libc.sysctl
    except (AttributeError, OSError) as error:
        raise OSError("process identity is unavailable") from error
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int
    query = (ctypes.c_int * 3)(
        _DARWIN_CTL_KERN,
        _DARWIN_KERN_PROCARGS2,
        process_id,
    )
    size = ctypes.c_size_t()
    if sysctl(query, 3, None, ctypes.byref(size), None, 0) != 0:
        error_number = ctypes.get_errno()
        if error_number == getattr(os, "ESRCH", 3):
            raise ProcessLookupError(error_number, "process exited")
        raise OSError(error_number, "process identity is unavailable")
    if size.value == 0:
        raise ProcessLookupError(process_id, "process exited")
    arguments = ctypes.create_string_buffer(size.value)
    if (
        sysctl(
            query,
            3,
            arguments,
            ctypes.byref(size),
            None,
            0,
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        if error_number == getattr(os, "ESRCH", 3):
            raise ProcessLookupError(error_number, "process exited")
        raise OSError(error_number, "process identity is unavailable")
    return bytes(arguments.raw[: size.value])


def _process_has_supervisor_identity(
    process_id: int,
    supervisor_identity: str,
) -> bool:
    expected = (
        f"{_SUPERVISOR_IDENTITY_ENV}={supervisor_identity}".encode("ascii")
    )
    if sys.platform == "darwin":
        process_data = _darwin_process_arguments(process_id)
    elif sys.platform.startswith("linux"):
        try:
            process_data = Path(f"/proc/{process_id}/environ").read_bytes()
        except FileNotFoundError as error:
            raise ProcessLookupError(process_id, "process exited") from error
        except OSError as error:
            raise OSError("process identity is unavailable") from error
    else:
        raise OSError("process identity is unavailable")
    return expected in process_data.split(b"\0")


def _recover_unreported_supervisor(
    *,
    supervisor_identity: str,
    deadline: float,
) -> tuple[bool, bool]:
    recovery_error = False
    scan_incomplete = False
    remaining_scan_items = MAX_RECOVERY_PROCESS_SCAN
    if time.monotonic() >= deadline:
        return False, True
    try:
        candidate_pids = _direct_child_pids(os.getpid())
    except OSError:
        recovery_error = True
        try:
            candidate_pids, scan_incomplete = _all_process_pids(
                remaining_scan_items
            )
        except OSError:
            return False, True

    matched_pids: set[int] = set()
    identity_error_pids: set[int] = set()
    identity_error = False
    for pid in candidate_pids:
        if remaining_scan_items <= 0 or time.monotonic() >= deadline:
            scan_incomplete = True
            break
        remaining_scan_items -= 1
        try:
            if _process_has_supervisor_identity(pid, supervisor_identity):
                matched_pids.add(pid)
        except ProcessLookupError:
            continue
        except OSError:
            identity_error = True
            identity_error_pids.add(pid)

    if identity_error:
        recovery_error = True
        if remaining_scan_items <= 0:
            scan_incomplete = True
            fallback_pids = set()
        else:
            try:
                fallback_pids, fallback_truncated = _all_process_pids(
                    remaining_scan_items
                )
                scan_incomplete = scan_incomplete or fallback_truncated
            except OSError:
                fallback_pids = set()
                scan_incomplete = True
        fallback_candidates = (
            fallback_pids - candidate_pids
        ) | identity_error_pids
        for pid in fallback_candidates:
            if remaining_scan_items <= 0 or time.monotonic() >= deadline:
                scan_incomplete = True
                break
            remaining_scan_items -= 1
            try:
                if _process_has_supervisor_identity(
                    pid,
                    supervisor_identity,
                ):
                    matched_pids.add(pid)
            except (OSError, ProcessLookupError):
                continue

    cleanup_succeeded = True
    for pid in matched_pids:
        if time.monotonic() >= deadline:
            cleanup_succeeded = False
            scan_incomplete = True
            break
        cleanup_succeeded = (
            _kill_failed_supervisor(pid, deadline=deadline)
            and cleanup_succeeded
        )
    if not matched_pids and (identity_error or scan_incomplete):
        cleanup_succeeded = False
    return cleanup_succeeded, recovery_error or scan_incomplete


def _supervisor_fd_targets(
    source_fds: set[int],
    *,
    soft_limit: int | None = None,
) -> tuple[int, int]:
    if soft_limit is None:
        try:
            configured_limit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except (OSError, ValueError) as error:
            raise OSError("file descriptor limit is unavailable") from error
        if configured_limit == resource.RLIM_INFINITY:
            soft_limit = _SUPERVISOR_RELEASE_FD + 1
        else:
            soft_limit = int(configured_limit)

    upper_bound = min(_SUPERVISOR_RELEASE_FD, soft_limit - 1)
    targets = [
        descriptor
        for descriptor in range(upper_bound, 2, -1)
        if descriptor not in source_fds
    ]
    if len(targets) < 2:
        raise OSError("supervisor descriptors are unavailable")
    return targets[0], targets[1]


def _close_descriptor(descriptor: int | None) -> None:
    if descriptor is None:
        return
    try:
        os.close(descriptor)
    except OSError:
        pass


def _await_supervisor_identity_pid(
    status_fd: int,
    *,
    timeout_seconds: float,
) -> int | None:
    deadline = time.monotonic() + max(0, timeout_seconds)
    buffered = bytearray()
    while True:
        reached_eof = False
        while True:
            try:
                chunk = os.read(status_fd, 64)
            except BlockingIOError:
                break
            except OSError:
                reached_eof = True
                break
            if not chunk:
                reached_eof = True
                break
            buffered.extend(chunk)

        while b"\n" in buffered:
            raw_line, _, remainder = buffered.partition(b"\n")
            buffered = bytearray(remainder)
            if raw_line[:1] not in (
                _SUPERVISOR_CLAIMED,
                _SUPERVISOR_READY,
            ):
                continue
            try:
                supervisor_pid = int(raw_line[1:])
            except ValueError:
                return None
            return supervisor_pid if supervisor_pid > 0 else None

        if reached_eof:
            return None
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            readable, _, _ = select.select(
                [status_fd],
                [],
                [],
                min(PROCESS_GROUP_POLL_SECONDS, remaining),
            )
        except (InterruptedError, OSError):
            continue
        if not readable:
            continue


def _supervisor_argv(
    command: list[str],
    *,
    status_fd: int,
    release_fd: int,
) -> list[str]:
    return [
        sys.executable,
        str(Path(__file__).resolve()),
        "--internal-supervisor",
        str(status_fd),
        str(release_fd),
        "--",
        *command,
    ]


def _supervisor_file_actions(
    *,
    status_read_fd: int,
    status_write_fd: int,
    release_read_fd: int,
    release_write_fd: int,
    supervisor_status_fd: int,
    supervisor_release_fd: int,
    log_file: Path | None = None,
) -> list[tuple[int, ...]]:
    actions: list[tuple[int, ...]] = [
        (
            os.POSIX_SPAWN_DUP2,
            status_write_fd,
            supervisor_status_fd,
        ),
        (
            os.POSIX_SPAWN_DUP2,
            release_read_fd,
            supervisor_release_fd,
        ),
    ]
    if log_file is not None:
        log_flags = os.O_WRONLY | os.O_APPEND
        if hasattr(os, "O_NOFOLLOW"):
            log_flags |= os.O_NOFOLLOW
        actions.extend(
            [
                (
                    os.POSIX_SPAWN_OPEN,
                    1,
                    str(log_file),
                    log_flags,
                    0o600,
                ),
                (os.POSIX_SPAWN_DUP2, 1, 2),
            ]
        )
    for descriptor in {
        status_read_fd,
        status_write_fd,
        release_read_fd,
        release_write_fd,
    }:
        if descriptor not in {
            supervisor_status_fd,
            supervisor_release_fd,
        }:
            actions.append((os.POSIX_SPAWN_CLOSE, descriptor))
    return actions


def _spawn_process_locked(
    command: list[str],
    *,
    log_file: Path | None = None,
) -> _SpawnedProcess:
    required_spawn_attributes = (
        "POSIX_SPAWN_CLOSE",
        "POSIX_SPAWN_DUP2",
        "POSIX_SPAWN_OPEN",
        "posix_spawnp",
    )
    if any(
        not hasattr(os, attribute)
        for attribute in required_spawn_attributes
    ):
        raise OSError("supervised process spawning is unavailable")

    supervisor_identity = secrets.token_hex(32)
    status_read_fd, status_write_fd = os.pipe()
    try:
        release_read_fd, release_write_fd = os.pipe()
    except BaseException:
        _close_descriptor(status_read_fd)
        _close_descriptor(status_write_fd)
        raise

    try:
        os.set_blocking(status_read_fd, False)
        supervisor_status_fd, supervisor_release_fd = _supervisor_fd_targets(
            {
                status_read_fd,
                status_write_fd,
                release_read_fd,
                release_write_fd,
            }
        )
    except BaseException:
        _close_descriptor(status_read_fd)
        _close_descriptor(status_write_fd)
        _close_descriptor(release_read_fd)
        _close_descriptor(release_write_fd)
        raise

    try:
        supervisor_environment = os.environ.copy()
        supervisor_environment[_SUPERVISOR_IDENTITY_ENV] = supervisor_identity
        pid = os.posix_spawnp(
            sys.executable,
            _supervisor_argv(
                command,
                status_fd=supervisor_status_fd,
                release_fd=supervisor_release_fd,
            ),
            supervisor_environment,
            file_actions=_supervisor_file_actions(
                status_read_fd=status_read_fd,
                status_write_fd=status_write_fd,
                release_read_fd=release_read_fd,
                release_write_fd=release_write_fd,
                supervisor_status_fd=supervisor_status_fd,
                supervisor_release_fd=supervisor_release_fd,
                log_file=log_file,
            ),
            setpgroup=0,
            setsigdef=_default_child_signals(),
            setsigmask=(),
        )
    except BaseException:
        _close_descriptor(status_write_fd)
        _close_descriptor(release_read_fd)
        _close_descriptor(release_write_fd)
        supervisor_pid = _await_supervisor_identity_pid(
            status_read_fd,
            timeout_seconds=PROCESS_GROUP_POLL_SECONDS,
        )
        recovery_error = False
        cleanup_deadline = time.monotonic() + FINAL_KILL_WAIT_SECONDS
        try:
            if supervisor_pid is not None:
                cleanup_succeeded = _kill_failed_supervisor(
                    supervisor_pid,
                    deadline=cleanup_deadline,
                )
            else:
                cleanup_succeeded, recovery_error = (
                    _recover_unreported_supervisor(
                        supervisor_identity=supervisor_identity,
                        deadline=cleanup_deadline,
                    )
                )
                if (
                    (not cleanup_succeeded or recovery_error)
                    and time.monotonic() < cleanup_deadline
                ):
                    supervisor_pid = _await_supervisor_identity_pid(
                        status_read_fd,
                        timeout_seconds=max(
                            0,
                            cleanup_deadline - time.monotonic(),
                        ),
                    )
                    if supervisor_pid is not None:
                        cleanup_succeeded = _kill_failed_supervisor(
                            supervisor_pid,
                            deadline=cleanup_deadline,
                        )
        except BaseException:
            cleanup_succeeded = False
            recovery_error = True
        finally:
            _close_descriptor(status_read_fd)
        if not cleanup_succeeded or recovery_error:
            raise _SpawnCleanupFailed() from None
        raise

    _close_descriptor(status_write_fd)
    _close_descriptor(release_read_fd)
    process = _SpawnedProcess(pid, status_read_fd)
    try:
        _write_spawn_status(release_write_fd, _SPAWN_RELEASED)
        _close_descriptor(release_write_fd)
    except BaseException:
        _close_descriptor(release_write_fd)
        cleanup_succeeded = _kill_failed_supervisor(pid)
        process._close_spawn_status_fd()
        if not cleanup_succeeded:
            raise _SpawnCleanupFailed() from None
        raise
    return process


def _spawn_process(
    command: list[str],
    *,
    log_file: Path | None = None,
) -> _SpawnedProcess:
    with _SPAWN_LOCK:
        return _spawn_process_locked(command, log_file=log_file)


@contextlib.contextmanager
def _spawn_deadline_alarm(deadline: float):
    if (
        not hasattr(signal, "SIGALRM")
        or not hasattr(signal, "ITIMER_REAL")
        or not hasattr(signal, "getitimer")
        or not hasattr(signal, "pthread_sigmask")
        or not hasattr(signal, "sigpending")
        or not hasattr(signal, "setitimer")
    ):
        raise OSError("hard spawn deadline is unavailable")
    if threading.current_thread() is not threading.main_thread():
        raise OSError("hard spawn deadline requires the main thread")

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise _SpawnDeadlineExceeded()

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    if signal.SIGALRM in signal.sigpending():
        raise OSError("hard spawn deadline conflicts with a pending alarm")
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    if previous_timer != (0.0, 0.0):
        raise OSError("hard spawn deadline conflicts with an active timer")
    previous_handler = signal.getsignal(signal.SIGALRM)

    def deadline_exceeded(_signum: int, _frame: object) -> None:
        raise _SpawnDeadlineExceeded()

    signal.signal(signal.SIGALRM, deadline_exceeded)
    try:
        signal.setitimer(signal.ITIMER_REAL, remaining)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
            if signal.SIGALRM in signal.sigpending():
                if hasattr(signal, "sigtimedwait"):
                    signal.sigtimedwait({signal.SIGALRM}, 0)
                elif hasattr(signal, "sigwait"):
                    signal.sigwait({signal.SIGALRM})
            signal.signal(signal.SIGALRM, previous_handler)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def _spawn_process_before_deadline(
    command: list[str],
    *,
    deadline: float,
    log_file: Path | None = None,
) -> _SpawnedProcess:
    process: _SpawnedProcess | None = None
    try:
        with _spawn_deadline_alarm(deadline):
            if log_file is None:
                process = _spawn_process(command)
            else:
                process = _spawn_process(command, log_file=log_file)
    except BaseException:
        if process is not None and not _terminate_process_group(
            process,
            grace_seconds=0,
        ):
            raise _SpawnCleanupFailed() from None
        raise
    return process


def _run_internal_supervisor(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        return START_FAILURE_EXIT_CODE
    try:
        status_fd = int(argv[0])
        release_fd = int(argv[1])
    except ValueError:
        return START_FAILURE_EXIT_CODE
    command = argv[3:]
    if not command:
        return START_FAILURE_EXIT_CODE
    _write_spawn_status(
        status_fd,
        _SUPERVISOR_CLAIMED,
        target_pid=os.getpid(),
    )
    _supervise_command(command, status_fd, release_fd)
    return START_FAILURE_EXIT_CODE


def _write_status(
    path: Path | None,
    *,
    label: str,
    status: str,
    exit_code: int,
) -> bool:
    if path is None:
        return True
    temporary_path: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix=f".{path.name}.{os.getpid()}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(
                f"label={label}\nstatus={status}\nexit_code={exit_code}\n"
            )
        os.replace(temporary_path, path)
        return True
    except OSError:
        if temporary_path is not None:
            try:
                temporary_path.unlink(missing_ok=True)
            except OSError:
                pass
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        print(
            f"bounded-command: label={label} status=status-file-error",
            file=sys.stderr,
            flush=True,
        )
        return False


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _signal_process_group(process_group_id: int, signum: int) -> str:
    try:
        os.killpg(process_group_id, signum)
    except ProcessLookupError:
        return "missing"
    except PermissionError:
        return "denied"
    return "sent"


def _signal_process(process_id: int, signum: int) -> str:
    try:
        os.kill(process_id, signum)
    except ProcessLookupError:
        return "missing"
    except PermissionError:
        return "denied"
    return "sent"


def _process_exists(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _process_group_id(process_id: int) -> int | None:
    try:
        return os.getpgid(process_id)
    except (ProcessLookupError, PermissionError):
        return None


def _tracked_target(
    process: subprocess.Popen[bytes] | _SpawnedProcess,
) -> tuple[int | None, int | None]:
    if not isinstance(process, _SpawnedProcess):
        return None, None
    target_pid = process.target_pid
    if target_pid is None:
        return None, None
    return target_pid, _process_group_id(target_pid)


def _signal_managed_processes(
    process: subprocess.Popen[bytes] | _SpawnedProcess,
    *,
    signum: int,
    target_pid: int | None,
    target_process_group_id: int | None,
) -> bool:
    supervisor_process_group_id = process.pid
    outcomes: list[str] = []
    if (
        target_process_group_id is not None
        and target_process_group_id != supervisor_process_group_id
    ):
        outcomes.append(
            _signal_process_group(target_process_group_id, signum)
        )
    if target_pid is not None and target_pid != process.pid:
        outcomes.append(_signal_process(target_pid, signum))
    outcomes.append(
        _signal_process_group(supervisor_process_group_id, signum)
    )
    if outcomes[-1] == "missing" and process.poll() is None:
        outcomes.append(_signal_process(process.pid, signum))
    return "denied" not in outcomes


def _wait_for_process_group_exit(
    process: subprocess.Popen[bytes] | _SpawnedProcess,
    *,
    process_group_id: int,
    target_pid: int | None = None,
    target_process_group_id: int | None = None,
    timeout_seconds: float,
    reap_supervisor: bool = True,
) -> bool:
    deadline = time.monotonic() + max(0, timeout_seconds)
    while True:
        returncode = process.poll()
        if (
            returncode is not None
            and isinstance(process, _SpawnedProcess)
            and not process.reaped
            and reap_supervisor
        ):
            process.reap()
        supervisor_group_gone = not _process_group_exists(process_group_id)
        if returncode is not None:
            target_gone = True
            target_group_gone = True
        else:
            target_gone = (
                target_pid is None or not _process_exists(target_pid)
            )
            target_group_gone = (
                target_process_group_id is None
                or target_process_group_id == process_group_id
                or not _process_group_exists(target_process_group_id)
            )
        if (
            returncode is not None
            and supervisor_group_gone
            and target_gone
            and target_group_gone
        ):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(PROCESS_GROUP_POLL_SECONDS, remaining))


def _terminate_process_group(
    process: subprocess.Popen[bytes] | _SpawnedProcess,
    *,
    grace_seconds: float,
) -> bool:
    process_group_id = process.pid
    supervisor_returncode = process.poll()
    if (
        supervisor_returncode is not None
        and not (
            isinstance(process, _SpawnedProcess)
            and not process.reaped
        )
    ):
        return _wait_for_process_group_exit(
            process,
            process_group_id=process_group_id,
            timeout_seconds=grace_seconds,
        )

    target_pid, target_process_group_id = _tracked_target(process)
    _signal_managed_processes(
        process,
        signum=signal.SIGTERM,
        target_pid=target_pid,
        target_process_group_id=target_process_group_id,
    )

    if _wait_for_process_group_exit(
        process,
        process_group_id=process_group_id,
        target_pid=target_pid,
        target_process_group_id=target_process_group_id,
        timeout_seconds=grace_seconds,
        reap_supervisor=False,
    ):
        if isinstance(process, _SpawnedProcess) and not process.reaped:
            process.reap()
        return True

    post_grace_returncode = process.poll()
    if post_grace_returncode is None:
        refreshed_target_pid, refreshed_target_process_group_id = (
            _tracked_target(process)
        )
        if refreshed_target_pid is not None:
            target_pid = refreshed_target_pid
            target_process_group_id = refreshed_target_process_group_id
    elif not (
        isinstance(process, _SpawnedProcess)
        and not process.reaped
    ):
        return _wait_for_process_group_exit(
            process,
            process_group_id=process_group_id,
            timeout_seconds=FINAL_KILL_WAIT_SECONDS,
        )
    _signal_managed_processes(
        process,
        signum=signal.SIGKILL,
        target_pid=target_pid,
        target_process_group_id=target_process_group_id,
    )
    if isinstance(process, _SpawnedProcess) and not process.reaped:
        process.reap()
    return _wait_for_process_group_exit(
        process,
        process_group_id=process_group_id,
        target_pid=target_pid,
        target_process_group_id=target_process_group_id,
        timeout_seconds=FINAL_KILL_WAIT_SECONDS,
    )


def _system_free_memory_percent() -> float | None:
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/bin/memory_pressure", "-Q"],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        match = MEMORY_PERCENT.search(result.stdout)
        if result.returncode != 0 or match is None:
            return None
        return float(match.group(1))

    if sys.platform.startswith("linux"):
        try:
            values: dict[str, int] = {}
            for line in Path("/proc/meminfo").read_text(
                encoding="utf-8"
            ).splitlines():
                key, separator, remainder = line.partition(":")
                if separator and key in {"MemAvailable", "MemTotal"}:
                    values[key] = int(remainder.strip().split()[0])
        except (OSError, ValueError, IndexError):
            return None
        total = values.get("MemTotal")
        available = values.get("MemAvailable")
        if total is None or available is None or total <= 0 or available < 0:
            return None
        return (available / total) * 100

    return None


def _resource_pressure_kind(
    *,
    min_free_memory_percent: float,
    min_free_disk_bytes: int,
    disk_path: Path,
) -> str | None:
    if min_free_memory_percent > 0:
        free_memory_percent = _system_free_memory_percent()
        if free_memory_percent is None:
            return "memory-unavailable"
        if free_memory_percent < min_free_memory_percent:
            return "memory"

    if min_free_disk_bytes > 0:
        try:
            free_disk_bytes = shutil.disk_usage(disk_path).free
        except OSError:
            return "disk-unavailable"
        if free_disk_bytes < min_free_disk_bytes:
            return "disk"

    return None


def _bounded_resource_pressure_kind(
    *,
    min_free_memory_percent: float,
    min_free_disk_bytes: int,
    disk_path: Path,
    timeout_seconds: float,
) -> str | None:
    global _RESOURCE_PROBE_THREAD

    if timeout_seconds <= 0:
        return "probe-timeout"

    results: queue.Queue[str | None] = queue.Queue(maxsize=1)

    def probe() -> None:
        try:
            result = _resource_pressure_kind(
                min_free_memory_percent=min_free_memory_percent,
                min_free_disk_bytes=min_free_disk_bytes,
                disk_path=disk_path,
            )
        except Exception:
            result = "probe-unavailable"
        try:
            results.put_nowait(result)
        except queue.Full:
            pass

    thread = threading.Thread(
        target=probe,
        name="bounded-command-resource-probe",
        daemon=True,
    )
    with _RESOURCE_PROBE_LOCK:
        if _RESOURCE_PROBE_THREAD is not None:
            if _RESOURCE_PROBE_THREAD.is_alive():
                return "probe-timeout"
            _RESOURCE_PROBE_THREAD = None
        _RESOURCE_PROBE_THREAD = thread
        thread.start()
    thread.join(timeout=min(MAX_RESOURCE_PROBE_SECONDS, timeout_seconds))
    if thread.is_alive():
        return "probe-timeout"
    try:
        return results.get_nowait()
    except queue.Empty:
        return "probe-unavailable"
    finally:
        with _RESOURCE_PROBE_LOCK:
            if _RESOURCE_PROBE_THREAD is thread:
                _RESOURCE_PROBE_THREAD = None


def _write_resource_pressure(
    path: Path | None,
    *,
    label: str,
    kind: str,
) -> bool:
    print(
        f"bounded-command: label={label} "
        f"status=resource-pressure kind={kind}",
        file=sys.stderr,
        flush=True,
    )
    return _write_status(
        path,
        label=label,
        status=f"resource-{kind}",
        exit_code=RESOURCE_EXIT_CODE,
    )


def _normalized_exit_code(exit_code: int) -> int:
    if exit_code >= 0:
        return exit_code
    return min(255, 128 + abs(exit_code))


def _interruption_exit_code(error: BaseException) -> int:
    if isinstance(error, _SignalInterruption):
        return min(255, 128 + error.signum)
    return INTERRUPTED_EXIT_CODE


@contextlib.contextmanager
def _blocked_cleanup_signals():
    if not hasattr(signal, "pthread_sigmask"):
        yield
        return

    cleanup_signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
    try:
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, cleanup_signals)
    except (OSError, ValueError):
        yield
        return
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def _finish_interrupted_run(
    process: subprocess.Popen[bytes] | _SpawnedProcess | None,
    *,
    grace_seconds: float,
    label: str,
    status_file: Path | None,
    error: BaseException,
) -> int | None:
    for _ in range(MAX_CLEANUP_INTERRUPTION_RETRIES):
        try:
            with _blocked_cleanup_signals():
                cleanup_succeeded = (
                    process is None
                    or _terminate_process_group(
                        process,
                        grace_seconds=grace_seconds,
                    )
                )
                if not cleanup_succeeded:
                    if not _write_status(
                        status_file,
                        label=label,
                        status="cleanup-failed",
                        exit_code=CLEANUP_EXIT_CODE,
                    ):
                        return CLEANUP_EXIT_CODE
                    return CLEANUP_EXIT_CODE
                if not _write_status(
                    status_file,
                    label=label,
                    status="interrupted",
                    exit_code=_interruption_exit_code(error),
                ):
                    return CLEANUP_EXIT_CODE
                return None
        except BaseException:
            continue

    _write_status(
        status_file,
        label=label,
        status="cleanup-failed",
        exit_code=CLEANUP_EXIT_CODE,
    )
    return CLEANUP_EXIT_CODE


def _minimum_free_disk_bytes(value_gib: float) -> int:
    if not math.isfinite(value_gib) or value_gib < 0:
        raise ValueError("minimum free disk size is invalid")
    if value_gib == 0:
        return 0
    value_bytes = value_gib * GIB_BYTES
    if not math.isfinite(value_bytes) or value_bytes < 1:
        raise ValueError("minimum free disk size is invalid")
    return math.ceil(value_bytes)


def _prepare_log_file(path: Path) -> Path:
    expanded = path.expanduser().absolute()
    expanded.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(expanded, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    return expanded


def _run_command(
    command: list[str],
    *,
    timeout_seconds: float,
    grace_seconds: float,
    label: str,
    status_file: Path | None = None,
    heartbeat_seconds: float = DEFAULT_HEARTBEAT_SECONDS,
    min_free_memory_percent: float = 0,
    min_free_disk_bytes: int = 0,
    disk_path: Path | None = None,
    resource_check_seconds: float = DEFAULT_RESOURCE_CHECK_SECONDS,
    log_file: Path | None = None,
) -> int:
    if not command:
        raise ValueError("command is required")
    if not SAFE_LABEL.fullmatch(label):
        raise ValueError("label is invalid")
    if not 0 < timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError("timeout is invalid")
    if not 0 < grace_seconds <= MAX_GRACE_SECONDS:
        raise ValueError("grace period is invalid")
    if not 0 < heartbeat_seconds <= MAX_HEARTBEAT_SECONDS:
        raise ValueError("heartbeat interval is invalid")
    if (
        not math.isfinite(min_free_memory_percent)
        or not 0 <= min_free_memory_percent <= 100
    ):
        raise ValueError("minimum free memory percentage is invalid")
    if min_free_disk_bytes < 0:
        raise ValueError("minimum free disk size is invalid")
    if (
        not math.isfinite(resource_check_seconds)
        or not 0 < resource_check_seconds <= MAX_RESOURCE_CHECK_SECONDS
    ):
        raise ValueError("resource check interval is invalid")
    if (
        log_file is not None
        and status_file is not None
        and log_file.expanduser().absolute() == status_file.expanduser().absolute()
    ):
        raise ValueError("log file and status file must be different")

    wrapper_started_at = time.monotonic()
    wrapper_deadline = wrapper_started_at + timeout_seconds
    effective_disk_path = disk_path or Path.cwd()
    prepared_log_file: Path | None = None
    if log_file is not None:
        try:
            prepared_log_file = _prepare_log_file(log_file)
        except OSError:
            print(
                f"bounded-command: label={label} status=log-file-error",
                file=sys.stderr,
                flush=True,
            )
            if not _write_status(
                status_file,
                label=label,
                status="start-error",
                exit_code=START_FAILURE_EXIT_CODE,
            ):
                return CLEANUP_EXIT_CODE
            return START_FAILURE_EXIT_CODE
    resource_limits_enabled = (
        min_free_memory_percent > 0 or min_free_disk_bytes > 0
    )
    if resource_limits_enabled:
        try:
            pressure_kind = _bounded_resource_pressure_kind(
                min_free_memory_percent=min_free_memory_percent,
                min_free_disk_bytes=min_free_disk_bytes,
                disk_path=effective_disk_path,
                timeout_seconds=max(0, wrapper_deadline - time.monotonic()),
            )
            if pressure_kind is not None:
                if not _write_resource_pressure(
                    status_file,
                    label=label,
                    kind=pressure_kind,
                ):
                    return CLEANUP_EXIT_CODE
                return RESOURCE_EXIT_CODE
        except BaseException as error:
            terminal_exit_code = _finish_interrupted_run(
                None,
                grace_seconds=grace_seconds,
                label=label,
                status_file=status_file,
                error=error,
            )
            if terminal_exit_code is not None:
                return terminal_exit_code
            raise

    process: subprocess.Popen[bytes] | _SpawnedProcess | None = None
    try:
        with _blocked_cleanup_signals():
            if prepared_log_file is None:
                process = _spawn_process_before_deadline(
                    command,
                    deadline=wrapper_deadline,
                )
            else:
                process = _spawn_process_before_deadline(
                    command,
                    deadline=wrapper_deadline,
                    log_file=prepared_log_file,
                )
    except _SpawnCleanupFailed:
        print(
            f"bounded-command: label={label} status=cleanup-failed",
            file=sys.stderr,
            flush=True,
        )
        _write_status(
            status_file,
            label=label,
            status="cleanup-failed",
            exit_code=CLEANUP_EXIT_CODE,
        )
        return CLEANUP_EXIT_CODE
    except _SpawnDeadlineExceeded:
        print(
            f"bounded-command: label={label} status=timeout",
            file=sys.stderr,
            flush=True,
        )
        if not _write_status(
            status_file,
            label=label,
            status="timeout",
            exit_code=TIMEOUT_EXIT_CODE,
        ):
            return CLEANUP_EXIT_CODE
        return TIMEOUT_EXIT_CODE
    except OSError:
        print(
            f"bounded-command: label={label} status=start-error",
            file=sys.stderr,
            flush=True,
        )
        if not _write_status(
            status_file,
            label=label,
            status="start-error",
            exit_code=START_FAILURE_EXIT_CODE,
        ):
            return CLEANUP_EXIT_CODE
        return START_FAILURE_EXIT_CODE
    except BaseException as error:
        terminal_exit_code = _finish_interrupted_run(
            process,
            grace_seconds=grace_seconds,
            label=label,
            status_file=status_file,
            error=error,
        )
        if terminal_exit_code is not None:
            return terminal_exit_code
        raise

    try:
        if not _write_status(
            status_file,
            label=label,
            status="running",
            exit_code=-1,
        ):
            _terminate_process_group(
                process,
                grace_seconds=grace_seconds,
            )
            return CLEANUP_EXIT_CODE

        started_at = time.monotonic()
        deadline = wrapper_deadline
        next_heartbeat_at = started_at + heartbeat_seconds
        next_resource_check_at = (
            started_at + resource_check_seconds
            if resource_limits_enabled
            else float("inf")
        )
        heartbeat = 0
        exit_code: int | None = None
        pressure_kind: str | None = None
        while exit_code is None:
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                exit_code = process.poll()
                break
            next_event_at = min(
                deadline,
                next_heartbeat_at,
                next_resource_check_at,
            )
            try:
                exit_code = process.wait(
                    timeout=max(0.001, next_event_at - now)
                )
            except subprocess.TimeoutExpired:
                now = time.monotonic()
                if now >= deadline:
                    exit_code = process.poll()
                    break
                if now >= next_resource_check_at:
                    pressure_kind = _bounded_resource_pressure_kind(
                        min_free_memory_percent=min_free_memory_percent,
                        min_free_disk_bytes=min_free_disk_bytes,
                        disk_path=effective_disk_path,
                        timeout_seconds=max(0, deadline - now),
                    )
                    exit_code = process.poll()
                    now = time.monotonic()
                    if exit_code is not None:
                        pressure_kind = None
                        break
                    if now >= deadline:
                        pressure_kind = None
                        exit_code = process.poll()
                        break
                    if pressure_kind is not None:
                        break
                    while next_resource_check_at <= now:
                        next_resource_check_at += resource_check_seconds
                if now >= next_heartbeat_at:
                    heartbeat += 1
                    print(
                        f"bounded-command: label={label} "
                        f"status=running heartbeat={heartbeat}",
                        file=sys.stderr,
                        flush=True,
                    )
                    while next_heartbeat_at <= now:
                        next_heartbeat_at += heartbeat_seconds

        if pressure_kind is not None:
            cleanup_succeeded = _terminate_process_group(
                process,
                grace_seconds=grace_seconds,
            )
            if not cleanup_succeeded:
                print(
                    f"bounded-command: label={label} status=cleanup-failed",
                    file=sys.stderr,
                    flush=True,
                )
                _write_status(
                    status_file,
                    label=label,
                    status="cleanup-failed",
                    exit_code=CLEANUP_EXIT_CODE,
                )
                return CLEANUP_EXIT_CODE
            if not _write_resource_pressure(
                status_file,
                label=label,
                kind=pressure_kind,
            ):
                return CLEANUP_EXIT_CODE
            return RESOURCE_EXIT_CODE

        if exit_code is None:
            cleanup_succeeded = _terminate_process_group(
                process,
                grace_seconds=grace_seconds,
            )
            if not cleanup_succeeded:
                print(
                    f"bounded-command: label={label} status=cleanup-failed",
                    file=sys.stderr,
                    flush=True,
                )
                _write_status(
                    status_file,
                    label=label,
                    status="cleanup-failed",
                    exit_code=CLEANUP_EXIT_CODE,
                )
                return CLEANUP_EXIT_CODE
            print(
                f"bounded-command: label={label} status=timeout",
                file=sys.stderr,
                flush=True,
            )
            if not _write_status(
                status_file,
                label=label,
                status="timeout",
                exit_code=TIMEOUT_EXIT_CODE,
            ):
                return CLEANUP_EXIT_CODE
            return TIMEOUT_EXIT_CODE

        cleanup_succeeded = _terminate_process_group(
            process,
            grace_seconds=grace_seconds,
        )
        if not cleanup_succeeded:
            print(
                f"bounded-command: label={label} status=cleanup-failed",
                file=sys.stderr,
                flush=True,
            )
            _write_status(
                status_file,
                label=label,
                status="cleanup-failed",
                exit_code=CLEANUP_EXIT_CODE,
            )
            return CLEANUP_EXIT_CODE

        if isinstance(process, _SpawnedProcess) and process.start_failed:
            print(
                f"bounded-command: label={label} status=start-error",
                file=sys.stderr,
                flush=True,
            )
            if not _write_status(
                status_file,
                label=label,
                status="start-error",
                exit_code=START_FAILURE_EXIT_CODE,
            ):
                return CLEANUP_EXIT_CODE
            return START_FAILURE_EXIT_CODE

        normalized_exit_code = _normalized_exit_code(exit_code)
        status = "success" if normalized_exit_code == 0 else "failed"
        if not _write_status(
            status_file,
            label=label,
            status=status,
            exit_code=normalized_exit_code,
        ):
            return CLEANUP_EXIT_CODE
        return normalized_exit_code
    except BaseException as error:
        terminal_exit_code = _finish_interrupted_run(
            process,
            grace_seconds=grace_seconds,
            label=label,
            status_file=status_file,
            error=error,
        )
        if terminal_exit_code is not None:
            return terminal_exit_code
        raise


@contextlib.contextmanager
def _default_ignored_sigchld():
    previous_handler = signal.getsignal(signal.SIGCHLD)
    restore_handler = previous_handler == signal.SIG_IGN
    if restore_handler:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    try:
        yield
    finally:
        if restore_handler:
            signal.signal(signal.SIGCHLD, previous_handler)


def run_command(
    command: list[str],
    *,
    timeout_seconds: float,
    grace_seconds: float,
    label: str,
    status_file: Path | None = None,
    heartbeat_seconds: float = DEFAULT_HEARTBEAT_SECONDS,
    min_free_memory_percent: float = 0,
    min_free_disk_bytes: int = 0,
    disk_path: Path | None = None,
    resource_check_seconds: float = DEFAULT_RESOURCE_CHECK_SECONDS,
    log_file: Path | None = None,
) -> int:
    with _default_ignored_sigchld():
        return _run_command(
            command,
            timeout_seconds=timeout_seconds,
            grace_seconds=grace_seconds,
            label=label,
            status_file=status_file,
            heartbeat_seconds=heartbeat_seconds,
            min_free_memory_percent=min_free_memory_percent,
            min_free_disk_bytes=min_free_disk_bytes,
            disk_path=disk_path,
            resource_check_seconds=resource_check_seconds,
            log_file=log_file,
        )


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv[:1] == ["--internal-supervisor"]:
        return _run_internal_supervisor(argv[1:])

    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--grace-seconds", type=int, default=30)
    parser.add_argument(
        "--heartbeat-seconds",
        type=int,
        default=DEFAULT_HEARTBEAT_SECONDS,
    )
    parser.add_argument("--min-free-memory-percent", type=float, default=0)
    parser.add_argument("--min-free-disk-gib", type=float, default=0)
    parser.add_argument("--disk-path", type=Path)
    parser.add_argument(
        "--resource-check-seconds",
        type=float,
        default=DEFAULT_RESOURCE_CHECK_SECONDS,
    )
    parser.add_argument("--label", required=True)
    parser.add_argument("--status-file", type=Path)
    parser.add_argument("--log-file", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args(argv)

    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        min_free_disk_bytes = _minimum_free_disk_bytes(
            arguments.min_free_disk_gib
        )
    except ValueError as error:
        parser.error(str(error))

    def raise_signal_interruption(signum: int, _frame: object) -> None:
        raise _SignalInterruption(signum)

    previous_handlers: dict[int, signal.Handlers] = {}
    for signum in (signal.SIGHUP, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(
            signum,
            raise_signal_interruption,
        )
    try:
        try:
            return run_command(
                command,
                timeout_seconds=arguments.timeout_seconds,
                grace_seconds=arguments.grace_seconds,
                label=arguments.label,
                status_file=arguments.status_file,
                heartbeat_seconds=arguments.heartbeat_seconds,
                min_free_memory_percent=arguments.min_free_memory_percent,
                min_free_disk_bytes=min_free_disk_bytes,
                disk_path=arguments.disk_path,
                resource_check_seconds=arguments.resource_check_seconds,
                log_file=arguments.log_file,
            )
        except ValueError as error:
            parser.error(str(error))
        except KeyboardInterrupt:
            return INTERRUPTED_EXIT_CODE
        except _SignalInterruption as error:
            return _interruption_exit_code(error)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
