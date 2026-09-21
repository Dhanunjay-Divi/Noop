#!/usr/bin/env python3
"""Classify the exact Android managed-device failures that are safe to retry."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


MAX_EVIDENCE_FILES = 32
MAX_EVIDENCE_BYTES = 1_000_000
MAX_STATUS_BYTES = 4_096
DEFAULT_EXPECTED_LABEL = "review-sample-fresh-process"
SAFE_LABEL = re.compile(r"^[a-z][a-z0-9-]{2,63}$")
BOUNDED_RESOURCE_STATUSES = {
    "resource-disk",
    "resource-disk-unavailable",
    "resource-memory",
    "resource-memory-unavailable",
    "resource-output",
    "resource-probe-timeout",
    "resource-probe-unavailable",
}


@dataclass(frozen=True)
class RetryDecision:
    retry: bool
    category: str
    evidence_files: int


def _read_bounded(paths: list[Path]) -> tuple[str | None, str | None]:
    if len(paths) > MAX_EVIDENCE_FILES:
        return None, "too-many-evidence-files"
    chunks: list[str] = []
    try:
        for path in paths:
            if path.stat().st_size > MAX_EVIDENCE_BYTES:
                return None, "oversized-evidence-file"
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return None, "unreadable-evidence"
    return "\n".join(chunks), None


def _read_status(
    path: Path | None,
    *,
    expected_label: str,
) -> tuple[dict[str, str] | None, str | None]:
    if path is None or not path.exists():
        return None, None
    try:
        if not path.is_file() or path.stat().st_size > MAX_STATUS_BYTES:
            return None, "invalid-bounded-status"
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None, "invalid-bounded-status"
    fields: dict[str, str] = {}
    for line in lines:
        if line.count("=") != 1:
            return None, "invalid-bounded-status"
        key, value = line.split("=", 1)
        if key not in {"label", "status", "exit_code"} or key in fields:
            return None, "invalid-bounded-status"
        fields[key] = value
    if set(fields) != {"label", "status", "exit_code"}:
        return None, "invalid-bounded-status"
    if fields["label"] != expected_label:
        return None, "invalid-bounded-status"
    allowed_statuses = {
        "success",
        "failed",
        "timeout",
        "start-error",
        *BOUNDED_RESOURCE_STATUSES,
    }
    if fields["status"] not in allowed_statuses:
        return None, "invalid-bounded-status"
    try:
        exit_code = int(fields["exit_code"])
    except ValueError:
        return None, "invalid-bounded-status"
    status = fields["status"]
    if (
        (status == "success" and exit_code != 0)
        or (status == "failed" and exit_code == 0)
        or (status == "timeout" and exit_code != 124)
        or (status == "start-error" and exit_code != 127)
        or (status in BOUNDED_RESOURCE_STATUSES and exit_code != 125)
    ):
        return None, "invalid-bounded-status"
    return fields, None


def _activity_service_lost(proto_text: str, log_text: str) -> bool:
    return (
        (
            "IActivityManager.startInstrumentation" in proto_text
            and "on a null object reference" in proto_text
        )
        or "cmd: Can't find service: activity" in log_text
    )


def classify(
    results_root: Path,
    *,
    bounded_status_file: Path | None = None,
    expected_label: str = DEFAULT_EXPECTED_LABEL,
) -> RetryDecision:
    if not SAFE_LABEL.fullmatch(expected_label):
        return RetryDecision(False, "invalid-expected-label", 0)
    bounded_status, status_error = _read_status(
        bounded_status_file,
        expected_label=expected_label,
    )
    if status_error is not None:
        return RetryDecision(False, status_error, 0)
    timeout_before_results = bounded_status == {
        "label": expected_label,
        "status": "timeout",
        "exit_code": "124",
    }
    resource_status = (
        bounded_status["status"]
        if bounded_status is not None
        and bounded_status["status"] in BOUNDED_RESOURCE_STATUSES
        and bounded_status["exit_code"] == "125"
        else None
    )

    if not results_root.is_dir():
        if timeout_before_results:
            return RetryDecision(False, "timeout-without-infrastructure-evidence", 0)
        if resource_status is not None:
            return RetryDecision(False, f"bounded-{resource_status}", 0)
        return RetryDecision(False, "missing-results", 0)

    textprotos = sorted(results_root.rglob("test-result.textproto"))
    logs = sorted(results_root.rglob("utp*.log"))
    evidence_files = len(textprotos) + len(logs)
    if evidence_files > MAX_EVIDENCE_FILES:
        return RetryDecision(False, "too-many-evidence-files", evidence_files)
    if not textprotos:
        log_text, log_error = _read_bounded(logs)
        if log_error is not None:
            return RetryDecision(False, log_error, evidence_files)
        assert log_text is not None
        if timeout_before_results:
            if _activity_service_lost("", log_text):
                return RetryDecision(
                    True,
                    "activity-service-unavailable-before-tests",
                    evidence_files,
                )
            return RetryDecision(
                False,
                "timeout-without-infrastructure-evidence",
                evidence_files,
            )
        if resource_status is not None:
            return RetryDecision(
                False,
                f"bounded-{resource_status}",
                evidence_files,
            )
        return RetryDecision(False, "missing-test-result", evidence_files)

    proto_text, proto_error = _read_bounded(textprotos)
    log_text, log_error = _read_bounded(logs)
    if proto_error is not None:
        return RetryDecision(False, proto_error, evidence_files)
    if log_error is not None:
        return RetryDecision(False, log_error, evidence_files)
    assert proto_text is not None
    assert log_text is not None

    if "test_case {" in proto_text:
        return RetryDecision(False, "test-results-present", evidence_files)
    if resource_status is not None:
        return RetryDecision(
            False,
            f"bounded-{resource_status}",
            evidence_files,
        )

    activity_service_lost = _activity_service_lost(proto_text, log_text)
    if timeout_before_results and activity_service_lost:
        return RetryDecision(
            True,
            "activity-service-unavailable-before-tests",
            evidence_files,
        )
    instrumentation_failed = (
        'test_status: FAILED' in proto_text
        and 'name: "INSTRUMENTATION_FAILED"' in proto_text
        and "Test run failed to complete. No test results." in proto_text
    )
    if instrumentation_failed and activity_service_lost:
        return RetryDecision(
            True,
            "activity-service-unavailable-before-tests",
            evidence_files,
        )
    if timeout_before_results:
        return RetryDecision(
            False,
            "timeout-without-infrastructure-evidence",
            evidence_files,
        )
    return RetryDecision(False, "unclassified-failure", evidence_files)


def _write_github_output(path: Path, decision: RetryDecision) -> None:
    with path.open("a", encoding="utf-8") as output:
        output.write(f"retry={'true' if decision.retry else 'false'}\n")
        output.write(f"category={decision.category}\n")
        output.write(f"evidence_files={decision.evidence_files}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results_root", type=Path)
    parser.add_argument("--bounded-status-file", type=Path)
    parser.add_argument(
        "--expected-label",
        default=DEFAULT_EXPECTED_LABEL,
    )
    parser.add_argument("--github-output", type=Path)
    arguments = parser.parse_args(argv)

    decision = classify(
        arguments.results_root,
        bounded_status_file=arguments.bounded_status_file,
        expected_label=arguments.expected_label,
    )
    if arguments.github_output is not None:
        _write_github_output(arguments.github_output, decision)
    print(
        "android-managed-device-retry:"
        f" category={decision.category}"
        f" evidence_files={decision.evidence_files}"
    )
    return 0 if decision.retry else 1


if __name__ == "__main__":
    sys.exit(main())
