#!/usr/bin/env python3
"""Fail closed on NOOP's repository-controlled release invariants.

This gate checks source-control inputs only. It does not claim that credentials
were rotated, that a hosted environment is approved, or that a physical release
candidate passed. Its optional report contains fixed check names and outcomes
only so it can be included in a privacy-safe release evidence bundle.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "release" / "release-policy.json"
ACTION_PIN = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_CHECK_NAME = re.compile(r"^[a-z][a-z0-9-]{1,63}$")
MIGRATION_NAME = re.compile(r"^(?P<sequence>[0-9]{3})_[a-z0-9_]+\.sql$")
EXTERNAL_IMAGE = re.compile(r"^\S+@sha256:[0-9a-f]{64}$")
USES_LINE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)")
IMAGE_LINE = re.compile(r"^\s*image:\s*[\"']?([^\s\"'#]+)")

TOKEN_PATTERNS = (
    (
        "aws-access-key-id",
        re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),
    ),
    (
        "google-api-key",
        re.compile(r"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])"),
    ),
    (
        "github-token",
        re.compile(
            r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9_]{30,}"
            r"|github_pat_[A-Za-z0-9_]{50,})(?![A-Za-z0-9_])"
        ),
    ),
    (
        "slack-token",
        re.compile(r"(?<![A-Za-z0-9-])xox[baprs]-[A-Za-z0-9-]{10,}"),
    ),
    (
        "stripe-live-secret",
        re.compile(r"(?<![A-Za-z0-9_])sk_live_[A-Za-z0-9]{16,}"),
    ),
    (
        "sendgrid-api-key",
        re.compile(
            r"(?<![A-Za-z0-9_.-])SG\.[A-Za-z0-9_-]{16,}"
            r"\.[A-Za-z0-9_-]{16,}"
        ),
    ),
    (
        "private-key",
        re.compile(
            r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
        ),
    ),
)


class GateError(RuntimeError):
    """A release invariant is absent or invalid."""


def _run(root: Path, *args: str) -> str:
    result = subprocess.run(
        list(args),
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise GateError(f"command failed: {' '.join(args)}")
    return result.stdout.decode("utf-8", errors="strict").strip()


def _relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise GateError(f"{label} must be a non-empty repository-relative path")
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise GateError(f"{label} must stay inside the repository")
    return value


def _string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise GateError(f"{label} must be a non-empty list")
    if not all(isinstance(item, str) and item for item in value):
        raise GateError(f"{label} contains an invalid string")
    return value


def load_policy(path: Path = DEFAULT_POLICY) -> dict[str, Any]:
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("release policy is missing or invalid JSON") from error
    validate_policy(policy)
    return policy


def validate_policy(policy: dict[str, Any]) -> None:
    required = {
        "schemaVersion",
        "product",
        "repository",
        "requiredChecks",
        "sourceControls",
        "naming",
        "reproducibility",
        "migrations",
        "vulnerabilityPolicy",
        "evidence",
        "environments",
    }
    if not isinstance(policy, dict) or set(policy) != required:
        raise GateError("release policy top-level fields do not match schema version 1")
    if policy["schemaVersion"] != 1 or policy["product"] != "NOOP":
        raise GateError("release policy identity is invalid")
    if policy["repository"] != "https://github.com/Dhanunjay-Divi/Noop":
        raise GateError("release policy repository is not canonical")

    checks = _string_list(policy["requiredChecks"], "requiredChecks")
    if checks != sorted(set(checks)) or any(
        SAFE_CHECK_NAME.fullmatch(item) is None for item in checks
    ):
        raise GateError("requiredChecks must be unique, sorted, safe check names")

    controls = policy["sourceControls"]
    if not isinstance(controls, dict):
        raise GateError("sourceControls must be an object")
    expected_controls = {
        "requiredPaths",
        "lockfiles",
        "workflowDirectory",
        "dockerfiles",
        "imageReferenceFiles",
        "requiredPinnedImageText",
        "migrationDirectory",
        "migrationManifest",
        "credentialExampleAllowlist",
        "blockedCredentialBasenames",
        "blockedCredentialSuffixes",
    }
    if set(controls) != expected_controls:
        raise GateError("sourceControls fields do not match schema version 1")
    for key in (
        "requiredPaths",
        "dockerfiles",
        "imageReferenceFiles",
        "credentialExampleAllowlist",
    ):
        for index, value in enumerate(_string_list(controls[key], key)):
            _relative_path(value, f"{key}[{index}]")
    for key in ("workflowDirectory", "migrationDirectory", "migrationManifest"):
        _relative_path(controls[key], key)
    _string_list(controls["requiredPinnedImageText"], "requiredPinnedImageText")
    _string_list(controls["blockedCredentialBasenames"], "blockedCredentialBasenames")
    _string_list(controls["blockedCredentialSuffixes"], "blockedCredentialSuffixes")
    lockfiles = controls["lockfiles"]
    if not isinstance(lockfiles, list) or not lockfiles:
        raise GateError("sourceControls.lockfiles must be a non-empty list")
    supported_lock_kinds = {
        "gradle",
        "gradle-verification",
        "npm",
        "python-hashes",
        "swiftpm",
    }
    lock_paths: list[str] = []
    for item in lockfiles:
        if not isinstance(item, dict) or set(item) != {"path", "kind"}:
            raise GateError("each lockfile needs exactly path and kind")
        lock_paths.append(_relative_path(item["path"], "lockfile.path"))
        if item["kind"] not in supported_lock_kinds:
            raise GateError(f"unsupported lockfile kind: {item['kind']}")
    if lock_paths != sorted(set(lock_paths)):
        raise GateError("lockfile paths must be unique and sorted")

    naming = policy["naming"]
    expected_naming = {
        "releaseBranchPattern",
        "hotfixBranchPattern",
        "tagPattern",
        "artifactPattern",
        "validExamples",
        "invalidExamples",
    }
    if not isinstance(naming, dict) or set(naming) != expected_naming:
        raise GateError("naming fields do not match schema version 1")
    compiled: dict[str, re.Pattern[str]] = {}
    for key in (
        "releaseBranchPattern",
        "hotfixBranchPattern",
        "tagPattern",
        "artifactPattern",
    ):
        try:
            compiled[key] = re.compile(naming[key])
        except (TypeError, re.error) as error:
            raise GateError(f"invalid naming regex: {key}") from error
    examples = naming["validExamples"]
    invalid_examples = naming["invalidExamples"]
    if not isinstance(examples, dict) or set(examples) != {
        "releaseBranch",
        "hotfixBranch",
        "tag",
        "artifact",
    }:
        raise GateError("validExamples are incomplete")
    if not isinstance(invalid_examples, dict) or set(invalid_examples) != set(examples):
        raise GateError("invalidExamples are incomplete")
    mapping = {
        "releaseBranch": "releaseBranchPattern",
        "hotfixBranch": "hotfixBranchPattern",
        "tag": "tagPattern",
        "artifact": "artifactPattern",
    }
    for example_key, pattern_key in mapping.items():
        if compiled[pattern_key].fullmatch(examples[example_key]) is None:
            raise GateError(f"valid naming example fails: {example_key}")
        if compiled[pattern_key].fullmatch(invalid_examples[example_key]) is not None:
            raise GateError(f"invalid naming example passes: {example_key}")

    reproducibility = policy["reproducibility"]
    expected_platforms = {"android", "firmware", "ios", "macos", "server", "tools"}
    if not isinstance(reproducibility, dict) or set(reproducibility) != expected_platforms:
        raise GateError("reproducibility must define every release platform")
    for platform, definition in reproducibility.items():
        if not isinstance(definition, dict) or set(definition) != {
            "status",
            "commands",
            "comparison",
        }:
            raise GateError(f"invalid reproducibility definition: {platform}")
        if definition["status"] not in {"enforced", "blocked-external-input"}:
            raise GateError(f"invalid reproducibility status: {platform}")
        _string_list(definition["commands"], f"reproducibility.{platform}.commands")
        if not isinstance(definition["comparison"], str) or not definition["comparison"]:
            raise GateError(f"missing reproducibility comparison: {platform}")

    migrations = policy["migrations"]
    if not isinstance(migrations, dict) or set(migrations) != {
        "strategy",
        "immutableAppliedFiles",
        "destructiveDownMigration",
        "requiredStages",
    }:
        raise GateError("migration policy is incomplete")
    if (
        migrations["strategy"] != "expand-migrate-verify-contract"
        or migrations["immutableAppliedFiles"] is not True
        or migrations["destructiveDownMigration"] != "forbidden"
        or migrations["requiredStages"] != ["expand", "migrate", "verify", "contract"]
    ):
        raise GateError("migration policy weakens the rollback contract")

    vulnerabilities = policy["vulnerabilityPolicy"]
    if not isinstance(vulnerabilities, dict) or set(vulnerabilities) != {
        "criticalMaximum",
        "highMaximum",
        "mediumDisposition",
        "requiredCommands",
        "exceptionRequirements",
    }:
        raise GateError("vulnerability policy is incomplete")
    if vulnerabilities["criticalMaximum"] != 0 or vulnerabilities["highMaximum"] != 0:
        raise GateError("critical and high release vulnerability thresholds must be zero")
    if vulnerabilities["mediumDisposition"] != "review-required":
        raise GateError("medium vulnerabilities must require review")
    _string_list(vulnerabilities["requiredCommands"], "vulnerability requiredCommands")
    _string_list(
        vulnerabilities["exceptionRequirements"], "vulnerability exceptionRequirements"
    )

    evidence = policy["evidence"]
    if not isinstance(evidence, dict) or set(evidence) != {
        "directory",
        "manifestSchema",
        "sbomFormat",
        "artifactFields",
        "checkFields",
    }:
        raise GateError("evidence policy is incomplete")
    _relative_path(evidence["directory"], "evidence.directory")
    _relative_path(evidence["manifestSchema"], "evidence.manifestSchema")
    if evidence["sbomFormat"] != "CycloneDX-1.5":
        raise GateError("unsupported SBOM format")
    if evidence["artifactFields"] != ["name", "sha256", "size", "mediaType"]:
        raise GateError("release artifact evidence fields are not minimal")
    if evidence["checkFields"] != ["name", "status"]:
        raise GateError("release check evidence fields are not minimal")

    environments = policy["environments"]
    if not isinstance(environments, dict) or set(environments) != {
        "staging",
        "production",
    }:
        raise GateError("staging and production environment policy is required")
    for name, environment in environments.items():
        if not isinstance(environment, dict) or set(environment) != {
            "approvalRequired",
            "status",
        }:
            raise GateError(f"invalid environment policy: {name}")
        if environment["approvalRequired"] is not True:
            raise GateError(f"{name} must require approval")
        if environment["status"] not in {"source-defined", "owner-approval-required"}:
            raise GateError(f"invalid environment status: {name}")


def tracked_files(root: Path) -> list[str]:
    raw = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if raw.returncode != 0:
        raise GateError("cannot enumerate tracked files")
    return sorted(
        item.decode("utf-8", errors="strict")
        for item in raw.stdout.split(b"\0")
        if item
    )


def check_required_paths(
    root: Path, policy: dict[str, Any], tracked: set[str]
) -> None:
    controls = policy["sourceControls"]
    required = list(controls["requiredPaths"])
    required.extend(item["path"] for item in controls["lockfiles"])
    required.extend(controls["dockerfiles"])
    required.extend(controls["imageReferenceFiles"])
    required.extend(
        [
            controls["migrationManifest"],
            policy["evidence"]["manifestSchema"],
        ]
    )
    missing = sorted(
        path for path in set(required) if path not in tracked or not (root / path).is_file()
    )
    if missing:
        raise GateError("required release inputs are absent from Git: " + ", ".join(missing))


def _check_swift_lock(path: Path) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"invalid SwiftPM lockfile: {path.name}") from error
    pins = data.get("pins")
    if not isinstance(pins, list) or not pins:
        raise GateError(f"empty SwiftPM lockfile: {path.name}")
    for pin in pins:
        state = pin.get("state", {}) if isinstance(pin, dict) else {}
        revision = state.get("revision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise GateError(f"SwiftPM dependency is not revision pinned: {path.name}")


def _check_npm_lock(path: Path) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"invalid npm lockfile: {path.name}") from error
    if data.get("lockfileVersion", 0) < 2 or not isinstance(data.get("packages"), dict):
        raise GateError(f"npm lockfile is not an exact modern lock: {path.name}")
    for name, package in data["packages"].items():
        if name and isinstance(package, dict) and not package.get("link"):
            if not package.get("version") or not package.get("integrity"):
                raise GateError(f"npm package lacks version/integrity: {name}")


def _check_gradle_lock(path: Path) -> None:
    count = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("empty="):
            continue
        if "=" not in line:
            raise GateError(f"invalid Gradle lock entry in {path.name}")
        coordinate, configurations = line.split("=", 1)
        parts = coordinate.rsplit(":", 2)
        if len(parts) != 3 or not all(parts) or not configurations:
            raise GateError(f"unversioned Gradle lock entry in {path.name}")
        count += 1
    if count == 0:
        raise GateError(f"Gradle lockfile is empty: {path.name}")


def _check_gradle_verification(path: Path) -> None:
    try:
        document = ET.parse(path)
    except (OSError, ET.ParseError) as error:
        raise GateError("Gradle verification metadata is invalid") from error
    root = document.getroot()
    namespace = {"g": "https://schema.gradle.org/dependency-verification"}
    verify = root.find("g:configuration/g:verify-metadata", namespace)
    hashes = root.findall(".//g:sha256", namespace)
    if verify is None or (verify.text or "").strip().lower() != "true" or not hashes:
        raise GateError("Gradle metadata or artifact verification is disabled")
    if any(SHA256.fullmatch(item.attrib.get("value", "")) is None for item in hashes):
        raise GateError("Gradle verification metadata contains an invalid SHA-256")


def _check_python_hash_lock(path: Path) -> None:
    blocks: list[str] = []
    current = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        current = f"{current} {stripped}".strip()
        if stripped.endswith("\\"):
            current = current[:-1].rstrip()
            continue
        blocks.append(current)
        current = ""
    if current:
        blocks.append(current)
    requirements = [item for item in blocks if not item.startswith("--")]
    if not requirements:
        raise GateError("Python runtime hash lock is empty")
    for requirement in requirements:
        first = requirement.split()[0]
        if "==" not in first or "--hash=sha256:" not in requirement:
            raise GateError("Python runtime requirement is not version/hash locked")


def check_lockfiles(root: Path, policy: dict[str, Any]) -> None:
    checkers = {
        "swiftpm": _check_swift_lock,
        "npm": _check_npm_lock,
        "gradle": _check_gradle_lock,
        "gradle-verification": _check_gradle_verification,
        "python-hashes": _check_python_hash_lock,
    }
    for item in policy["sourceControls"]["lockfiles"]:
        checkers[item["kind"]](root / item["path"])


def check_action_pins(root: Path, workflow_directory: str) -> None:
    directory = root / workflow_directory
    workflows = sorted(directory.glob("*.yml")) + sorted(directory.glob("*.yaml"))
    if not workflows:
        raise GateError("no GitHub Actions workflows found")
    seen = 0
    offenders: list[str] = []
    for path in workflows:
        relative = path.relative_to(root).as_posix()
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            match = USES_LINE.match(line)
            if match is None:
                continue
            seen += 1
            reference = match.group(1)
            if reference.startswith("./"):
                continue
            if reference.startswith("docker://"):
                if EXTERNAL_IMAGE.fullmatch(reference[len("docker://") :]) is None:
                    offenders.append(f"{relative}:{line_number}")
                continue
            if "@" not in reference:
                offenders.append(f"{relative}:{line_number}")
                continue
            revision = reference.rsplit("@", 1)[1]
            if ACTION_PIN.fullmatch(revision) is None:
                offenders.append(f"{relative}:{line_number}")
    if seen == 0:
        raise GateError("no GitHub Actions uses references found")
    if offenders:
        raise GateError("GitHub Actions are not commit pinned: " + ", ".join(offenders))


def check_container_digests(root: Path, policy: dict[str, Any]) -> None:
    controls = policy["sourceControls"]
    for relative in controls["dockerfiles"]:
        stages: set[str] = set()
        external = 0
        for line_number, raw in enumerate(
            (root / relative).read_text(encoding="utf-8").splitlines(), start=1
        ):
            line = raw.strip()
            if not line.upper().startswith("FROM "):
                continue
            parts = line.split()
            cursor = 1
            while cursor < len(parts) and parts[cursor].startswith("--"):
                cursor += 1
            if cursor >= len(parts):
                raise GateError(f"invalid FROM instruction: {relative}:{line_number}")
            image = parts[cursor]
            alias = None
            if cursor + 2 < len(parts) and parts[cursor + 1].lower() == "as":
                alias = parts[cursor + 2].lower()
            lowered = image.lower()
            if lowered != "scratch" and lowered not in stages:
                if EXTERNAL_IMAGE.fullmatch(image) is None:
                    raise GateError(
                        f"container base is not digest pinned: {relative}:{line_number}"
                    )
                external += 1
            if alias:
                stages.add(alias)
        if external == 0:
            raise GateError(f"no digest-pinned external base found: {relative}")

    for relative in controls["imageReferenceFiles"]:
        seen = 0
        for line_number, raw in enumerate(
            (root / relative).read_text(encoding="utf-8").splitlines(), start=1
        ):
            match = IMAGE_LINE.match(raw)
            if match is None:
                continue
            seen += 1
            if EXTERNAL_IMAGE.fullmatch(match.group(1)) is None:
                raise GateError(
                    f"container image is not digest pinned: {relative}:{line_number}"
                )
        if seen == 0:
            raise GateError(f"no container image reference found: {relative}")

    pinned_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (root / "infra" / "gcp").glob("*.tf")
    )
    for marker in controls["requiredPinnedImageText"]:
        if marker not in pinned_text:
            raise GateError("IaC digest validation is missing a required invariant")


def _is_blocked_credential_path(
    path: str, controls: dict[str, Any], example_allowlist: set[str]
) -> bool:
    if path in example_allowlist:
        return False
    item = PurePosixPath(path)
    lowered_name = item.name.lower()
    if lowered_name in {name.lower() for name in controls["blockedCredentialBasenames"]}:
        return True
    suffixes = "".join(item.suffixes).lower()
    if any(
        suffixes == suffix.lower()
        or suffixes.endswith(suffix.lower() + "-wal")
        or suffixes.endswith(suffix.lower() + "-shm")
        for suffix in controls["blockedCredentialSuffixes"]
    ):
        return True
    if lowered_name == ".env" or lowered_name.startswith(".env."):
        return True
    return False


def check_tracked_credentials(
    root: Path, policy: dict[str, Any], tracked: list[str]
) -> None:
    controls = policy["sourceControls"]
    allowlist = set(controls["credentialExampleAllowlist"])
    blocked_paths = [
        path
        for path in tracked
        if _is_blocked_credential_path(path, controls, allowlist)
    ]
    if blocked_paths:
        raise GateError(
            "tracked credential/private artifact filenames found: "
            + ", ".join(blocked_paths)
        )

    token_offenders: list[str] = []
    for relative in tracked:
        path = root / relative
        if not path.is_file():
            continue
        try:
            raw = path.read_bytes()
        except OSError as error:
            raise GateError(f"cannot inspect tracked file: {relative}") from error
        if b"\0" in raw:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for name, pattern in TOKEN_PATTERNS:
            if pattern.search(text):
                token_offenders.append(f"{relative} ({name})")
    if token_offenders:
        raise GateError(
            "high-confidence credential format found; rotate it and remove it from Git: "
            + ", ".join(sorted(token_offenders))
        )


def check_migration_manifest(root: Path, policy: dict[str, Any]) -> None:
    controls = policy["sourceControls"]
    directory = root / controls["migrationDirectory"]
    manifest_path = root / controls["migrationManifest"]
    migrations = sorted(path for path in directory.glob("*.sql") if path.is_file())
    if not migrations:
        raise GateError("server migration directory is empty")
    names = [path.name for path in migrations]
    sequences: list[int] = []
    for name in names:
        match = MIGRATION_NAME.fullmatch(name)
        if match is None:
            raise GateError(f"invalid migration filename: {name}")
        sequences.append(int(match.group("sequence")))
    if len(sequences) != len(set(sequences)) or sequences != sorted(sequences):
        raise GateError("server migration sequences are duplicate or unordered")

    entries: dict[str, str] = {}
    for line_number, raw in enumerate(
        manifest_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", raw)
        if match is None:
            raise GateError(f"invalid migration manifest line: {line_number}")
        digest, name = match.groups()
        if name in entries:
            raise GateError(f"duplicate migration manifest entry: {name}")
        entries[name] = digest
    if sorted(entries) != names:
        raise GateError("migration manifest and migration directory differ")
    for path in migrations:
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if entries[path.name] != actual:
            raise GateError(f"immutable migration digest changed: {path.name}")


def check_runtime_inventory(root: Path) -> None:
    result = subprocess.run(
        [sys.executable, "Tools/release-legal-gate.py", "check"],
        cwd=root,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        raise GateError("runtime inventory/license gate failed")


def run_checks(root: Path, policy_path: Path) -> list[dict[str, str]]:
    policy = load_policy(policy_path)
    tracked = tracked_files(root)
    tracked_set = set(tracked)
    checks = (
        ("release-policy", lambda: validate_policy(policy)),
        (
            "required-release-inputs",
            lambda: check_required_paths(root, policy, tracked_set),
        ),
        ("dependency-locks", lambda: check_lockfiles(root, policy)),
        (
            "github-actions-pinned",
            lambda: check_action_pins(
                root, policy["sourceControls"]["workflowDirectory"]
            ),
        ),
        ("container-digests", lambda: check_container_digests(root, policy)),
        (
            "tracked-credential-exclusion",
            lambda: check_tracked_credentials(root, policy, tracked),
        ),
        ("migration-integrity", lambda: check_migration_manifest(root, policy)),
        ("runtime-inventory", lambda: check_runtime_inventory(root)),
    )
    results: list[dict[str, str]] = []
    for name, check in checks:
        check()
        results.append({"name": name, "status": "passed"})
    expected = policy["requiredChecks"]
    actual = sorted(item["name"] for item in results)
    if actual != expected:
        raise GateError("executed release checks differ from requiredChecks policy")
    return results


def write_report(path: Path, checks: list[dict[str, str]]) -> None:
    report = {"schemaVersion": 1, "checks": sorted(checks, key=lambda item: item["name"])}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check", help="verify every source release control")
    check.add_argument("--root", type=Path, default=ROOT)
    check.add_argument("--policy", type=Path)
    check.add_argument("--report", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.root.resolve()
    policy_path = (
        args.policy.resolve()
        if args.policy is not None
        else root / "release" / "release-policy.json"
    )
    try:
        checks = run_checks(root, policy_path)
        if args.report is not None:
            write_report(args.report, checks)
        print(f"Release controls passed: {len(checks)} checks")
    except (GateError, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
