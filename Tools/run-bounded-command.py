#!/usr/bin/env python3
"""Run a command in its own process group with a hard deadline."""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
from pathlib import Path


TIMEOUT_EXIT_CODE = 124
START_FAILURE_EXIT_CODE = 127
MAX_TIMEOUT_SECONDS = 3_600
MAX_GRACE_SECONDS = 60
SAFE_LABEL = re.compile(r"^[a-z][a-z0-9-]{2,63}$")


def _write_status(
    path: Path | None,
    *,
    label: str,
    status: str,
    exit_code: int,
) -> None:
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"label={label}\nstatus={status}\nexit_code={exit_code}\n",
            encoding="utf-8",
        )
    except OSError:
        print(
            f"bounded-command: label={label} status=status-file-error",
            file=sys.stderr,
            flush=True,
        )


def _signal_process_group(process: subprocess.Popen[bytes], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def run_command(
    command: list[str],
    *,
    timeout_seconds: float,
    grace_seconds: float,
    label: str,
    status_file: Path | None = None,
) -> int:
    if not command:
        raise ValueError("command is required")
    if not SAFE_LABEL.fullmatch(label):
        raise ValueError("label is invalid")
    if not 0 < timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError("timeout is invalid")
    if not 0 < grace_seconds <= MAX_GRACE_SECONDS:
        raise ValueError("grace period is invalid")

    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError:
        print(
            f"bounded-command: label={label} status=start-error",
            file=sys.stderr,
            flush=True,
        )
        _write_status(
            status_file,
            label=label,
            status="start-error",
            exit_code=START_FAILURE_EXIT_CODE,
        )
        return START_FAILURE_EXIT_CODE

    try:
        exit_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"bounded-command: label={label} status=timeout",
            file=sys.stderr,
            flush=True,
        )
        _signal_process_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            _signal_process_group(process, signal.SIGKILL)
            process.wait()
        _write_status(
            status_file,
            label=label,
            status="timeout",
            exit_code=TIMEOUT_EXIT_CODE,
        )
        return TIMEOUT_EXIT_CODE

    status = "success" if exit_code == 0 else "failed"
    _write_status(
        status_file,
        label=label,
        status=status,
        exit_code=exit_code,
    )
    return exit_code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--grace-seconds", type=int, default=30)
    parser.add_argument("--label", required=True)
    parser.add_argument("--status-file", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args(argv)

    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        return run_command(
            command,
            timeout_seconds=arguments.timeout_seconds,
            grace_seconds=arguments.grace_seconds,
            label=arguments.label,
            status_file=arguments.status_file,
        )
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
