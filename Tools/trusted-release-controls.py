#!/usr/bin/env python3
"""Validate release trust roots from protected base-branch source."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


SAFE_LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
SAFE_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_SHA = re.compile(r"^[0-9a-f]{40}$")
CHECK_NAME = "trusted-release-controls"
CHECK_SCOPES = {"protected-main", "pull-request"}
GITHUB_ACTIONS_APP_ID = 15368
MAX_RESPONSE_BYTES = 1024 * 1024
PROTECTED_PREFIXES = (".github/workflows/",)
PROTECTED_PATHS = {
    "release/required-ci.json",
    "release/evidence/manifest.schema.json",
    "release/metrics/reference-calibration-v1.json",
    "release/release-policy.json",
    "release/terminology/active-allowlist.json",
    "release/terminology/legacy-inventory.json",
    "Tools/altstore-source.py",
    "Tools/android-lockfile-sbom.py",
    "Tools/appchangelog-gen.py",
    "Tools/calibration-parity-audit.py",
    "Tools/check-private-data.py",
    "Tools/forgejo-release.sh",
    "Tools/forgejo-version-gate.py",
    "Tools/github-release-publish.py",
    "Tools/github-release-tag-gate.py",
    "Tools/health_claims_gate.py",
    "Tools/homebrew-version-gate.py",
    "Tools/i18n_audit.py",
    "Tools/i18n_audit_baseline.json",
    "Tools/prepare-ios-sideload-app.sh",
    "Tools/publish-testing-snapshot.sh",
    "Tools/release-control-gate.py",
    "Tools/release-evidence.py",
    "Tools/release-legal-gate.py",
    "Tools/release-version-gate.py",
    "Tools/release.sh",
    "Tools/required-ci-gate.py",
    "Tools/terminology-audit.py",
    "Tools/trusted-release-controls.py",
    "Tools/update-homebrew-cask.sh",
}


class TrustedControlError(RuntimeError):
    """A candidate attempted to bypass the protected release trust root."""


class GitHubCheckClient:
    """Create one bounded check run with the workflow's GitHub App token."""

    def __init__(self, token: str) -> None:
        if not token:
            raise TrustedControlError("GitHub check token is unavailable")
        self._token = token

    def create_check(self, repository: str, payload: dict[str, Any]) -> Any:
        request = urllib.request.Request(
            f"https://api.github.com/repos/{repository}/check-runs",
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
                "User-Agent": "noop-trusted-release-controls",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(MAX_RESPONSE_BYTES + 1)
        except (OSError, urllib.error.HTTPError) as error:
            raise TrustedControlError(
                "exact-head release-control check could not be published"
            ) from error
        if len(data) > MAX_RESPONSE_BYTES:
            raise TrustedControlError(
                "exact-head release-control check response is too large"
            )
        try:
            return json.loads(data)
        except json.JSONDecodeError as error:
            raise TrustedControlError(
                "exact-head release-control check response is invalid"
            ) from error


def _valid_check_details_url(
    value: Any,
    *,
    repository: str,
    requested_url: str,
    check_id: int,
) -> bool:
    if value == requested_url:
        return True
    if not isinstance(value, str):
        return False
    parsed = urllib.parse.urlsplit(value)
    owner, name = repository.split("/", 1)
    canonical = re.compile(
        rf"/{re.escape(owner)}/{re.escape(name)}/runs/{check_id}",
        re.IGNORECASE,
    )
    return (
        parsed.scheme == "https"
        and parsed.netloc == "github.com"
        and not parsed.query
        and not parsed.fragment
        and canonical.fullmatch(parsed.path) is not None
    )


def _safe_root(path: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise TrustedControlError(f"{label} is unavailable") from error
    if not resolved.is_dir():
        raise TrustedControlError(f"{label} must be a directory")
    return resolved


def _safe_path(value: str) -> str:
    candidate = PurePosixPath(value)
    if (
        not value
        or candidate.is_absolute()
        or ".." in candidate.parts
        or "." in candidate.parts
        or value != candidate.as_posix()
    ):
        raise TrustedControlError("candidate changed-path inventory is invalid")
    return value


def is_protected_path(value: str) -> bool:
    path = _safe_path(value)
    return path in PROTECTED_PATHS or path.startswith(PROTECTED_PREFIXES)


def authorize_changed_paths(
    changed_paths: list[str],
    *,
    repository_owner: str,
    actor: str,
) -> list[str]:
    if (
        SAFE_LOGIN.fullmatch(repository_owner) is None
        or SAFE_LOGIN.fullmatch(actor) is None
    ):
        raise TrustedControlError(
            "repository owner or exact-head actor is invalid"
        )
    normalized = sorted({_safe_path(path) for path in changed_paths})
    protected = [path for path in normalized if is_protected_path(path)]
    if protected and actor.casefold() != repository_owner.casefold():
        raise TrustedControlError(
            "release trust-root changes require the repository owner as the "
            "exact-head event actor: "
            + ", ".join(protected[:20])
        )
    return protected


def _git(root: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "diff.external=",
            *arguments,
        ],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise TrustedControlError("candidate Git identity or diff is invalid")
    return result.stdout


def changed_paths(
    candidate_root: Path,
    *,
    base_sha: str,
    head_sha: str,
) -> list[str]:
    if SAFE_SHA.fullmatch(base_sha) is None or SAFE_SHA.fullmatch(head_sha) is None:
        raise TrustedControlError("pull-request commit identity is invalid")
    actual_head = _git(candidate_root, "rev-parse", "HEAD").decode(
        "ascii", errors="strict"
    ).strip()
    if actual_head != head_sha:
        raise TrustedControlError("candidate checkout does not match the pull request")
    _git(candidate_root, "cat-file", "-e", f"{base_sha}^{{commit}}")
    raw = _git(
        candidate_root,
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--name-only",
        "-z",
        base_sha,
        head_sha,
        "--",
    )
    try:
        decoded = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise TrustedControlError(
            "candidate changed-path inventory is not UTF-8"
        ) from error
    return [_safe_path(path) for path in decoded.split("\0") if path]


def _load_required_gate(base_root: Path) -> Any:
    path = base_root / "Tools" / "required-ci-gate.py"
    spec = importlib.util.spec_from_file_location(
        "trusted_base_required_ci_gate", path
    )
    if spec is None or spec.loader is None:
        raise TrustedControlError("trusted required-CI gate cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except (OSError, RuntimeError, SyntaxError) as error:
        raise TrustedControlError("trusted required-CI gate cannot be loaded") from error
    return module


def _check_candidate_with_base_gate(base_root: Path, candidate_root: Path) -> None:
    gate = _load_required_gate(base_root)
    try:
        gate.check_repository(
            candidate_root,
            candidate_root / "release" / "required-ci.json",
        )
    except gate.GateError as error:
        raise TrustedControlError(
            "candidate fails the protected base release-control contract"
        ) from error


def verify_pull_request(
    *,
    base_root: Path,
    candidate_root: Path,
    base_sha: str,
    head_sha: str,
    repository: str,
    head_repository: str,
    repository_owner: str,
    actor: str,
) -> tuple[int, int]:
    trusted_base = _safe_root(base_root, "trusted base checkout")
    candidate = _safe_root(candidate_root, "candidate checkout")
    if trusted_base == candidate:
        raise TrustedControlError("candidate checkout must be isolated")
    if (
        SAFE_REPOSITORY.fullmatch(repository) is None
        or SAFE_REPOSITORY.fullmatch(head_repository) is None
        or repository.split("/", 1)[0].casefold()
        != repository_owner.casefold()
    ):
        raise TrustedControlError("pull-request repository identity is invalid")
    paths = changed_paths(candidate, base_sha=base_sha, head_sha=head_sha)
    protected = authorize_changed_paths(
        paths,
        repository_owner=repository_owner,
        actor=actor,
    )
    if protected:
        if head_repository.casefold() != repository.casefold():
            raise TrustedControlError(
                "release trust-root changes require an in-repository head"
            )
    else:
        _check_candidate_with_base_gate(trusted_base, candidate)
    return len(paths), len(protected)


def verify_self(root: Path) -> None:
    repository = _safe_root(root, "repository root")
    gate = _load_required_gate(repository)
    try:
        gate.check_repository(
            repository,
            repository / "release" / "required-ci.json",
        )
    except gate.GateError as error:
        raise TrustedControlError(
            "protected main fails its release-control contract"
        ) from error


def report_exact_check(
    *,
    client: Any,
    repository: str,
    head_sha: str,
    scope: str,
    validation_result: str,
    run_id: int,
    run_attempt: int,
) -> bool:
    if SAFE_REPOSITORY.fullmatch(repository) is None:
        raise TrustedControlError("GitHub repository identity is invalid")
    if SAFE_SHA.fullmatch(head_sha) is None:
        raise TrustedControlError("checked commit identity is invalid")
    if scope not in CHECK_SCOPES:
        raise TrustedControlError("trusted check scope is invalid")
    if validation_result not in {"success", "failure", "cancelled", "skipped"}:
        raise TrustedControlError("trusted validation result is invalid")
    if (
        not isinstance(run_id, int)
        or isinstance(run_id, bool)
        or run_id <= 0
        or not isinstance(run_attempt, int)
        or isinstance(run_attempt, bool)
        or run_attempt <= 0
    ):
        raise TrustedControlError("trusted workflow run identity is invalid")

    passed = validation_result == "success"
    conclusion = "success" if passed else "failure"
    details_url = f"https://github.com/{repository}/actions/runs/{run_id}"
    external_id = (
        f"{CHECK_NAME}:{scope}:{run_id}:{run_attempt}:{head_sha}"
    )
    if scope == "pull-request":
        success_summary = (
            "Protected base authorization accepted the exact pull-request "
            "head. Candidate release controls are enforced separately."
        )
        failure_summary = (
            "Protected base authorization did not accept the exact "
            "pull-request head."
        )
    else:
        success_summary = (
            "Protected main release controls validated the exact commit."
        )
        failure_summary = (
            "Protected main release controls did not validate the exact "
            "commit."
        )
    payload = {
        "name": CHECK_NAME,
        "head_sha": head_sha,
        "status": "completed",
        "conclusion": conclusion,
        "details_url": details_url,
        "external_id": external_id,
        "output": {
            "title": (
                "Protected release controls passed"
                if passed
                else "Protected release controls failed"
            ),
            "summary": (
                success_summary if passed else failure_summary
            ),
        },
    }
    response = client.create_check(repository, payload)
    app = response.get("app") if isinstance(response, dict) else None
    response_id = response.get("id") if isinstance(response, dict) else None
    valid_response_id = (
        isinstance(response_id, int)
        and not isinstance(response_id, bool)
        and response_id > 0
    )
    if (
        not isinstance(response, dict)
        or not valid_response_id
        or response.get("name") != CHECK_NAME
        or response.get("head_sha") != head_sha
        or response.get("status") != "completed"
        or response.get("conclusion") != conclusion
        or not _valid_check_details_url(
            response.get("details_url"),
            repository=repository,
            requested_url=details_url,
            check_id=response_id,
        )
        or response.get("external_id") != external_id
        or not isinstance(app, dict)
        or app.get("id") != GITHUB_ACTIONS_APP_ID
    ):
        raise TrustedControlError(
            "exact-head release-control check identity is invalid"
        )
    if not passed:
        raise TrustedControlError(
            "exact source did not pass protected release controls"
        )
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    pull_request = subparsers.add_parser("verify-pr")
    pull_request.add_argument("--base-root", type=Path, required=True)
    pull_request.add_argument("--candidate-root", type=Path, required=True)
    pull_request.add_argument("--base-sha", required=True)
    pull_request.add_argument("--head-sha", required=True)
    pull_request.add_argument("--repository", required=True)
    pull_request.add_argument("--head-repository", required=True)
    pull_request.add_argument("--repository-owner", required=True)
    pull_request.add_argument("--actor", required=True)
    self_check = subparsers.add_parser("verify-self")
    self_check.add_argument("--root", type=Path, required=True)
    report = subparsers.add_parser("report-check")
    report.add_argument("--repository", required=True)
    report.add_argument("--head-sha", required=True)
    report.add_argument("--scope", choices=sorted(CHECK_SCOPES), required=True)
    report.add_argument("--validation-result", required=True)
    report.add_argument("--run-id", type=int, required=True)
    report.add_argument("--run-attempt", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.command == "verify-pr":
            changed_count, protected_count = verify_pull_request(
                base_root=args.base_root,
                candidate_root=args.candidate_root,
                base_sha=args.base_sha,
                head_sha=args.head_sha,
                repository=args.repository,
                head_repository=args.head_repository,
                repository_owner=args.repository_owner,
                actor=args.actor,
            )
            print(
                "trusted-release-controls: "
                f"{changed_count} changed path(s), "
                f"{protected_count} exact-head owner-authorized trust-root "
                "path(s)"
            )
        elif args.command == "verify-self":
            verify_self(args.root)
            print("trusted-release-controls: protected main verified")
        else:
            report_exact_check(
                client=GitHubCheckClient(os.environ.get("GH_TOKEN", "")),
                repository=args.repository,
                head_sha=args.head_sha,
                scope=args.scope,
                validation_result=args.validation_result,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
            )
            print(
                "trusted-release-controls: exact checked commit verified"
            )
    except TrustedControlError as error:
        print(f"trusted-release-controls: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
