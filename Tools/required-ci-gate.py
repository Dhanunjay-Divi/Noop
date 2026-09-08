#!/usr/bin/env python3
"""Validate required CI workflows and exact-SHA GitHub check results."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = ROOT / "release" / "required-ci.json"
SAFE_CONTEXT = re.compile(r"^[a-z][a-z0-9-]{2,63}$")
SAFE_JOB = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
SAFE_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_SHA = re.compile(r"^[0-9a-f]{40}$")
JOB_HEADER = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_-]*):[ \t]*$", re.MULTILINE)
JOB_HEADER_LINE = re.compile(r"^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*$")
JOB_PROPERTY_LINE = re.compile(
    r"^    [A-Za-z_][A-Za-z0-9_-]*:(?:[ \t].*)?$"
)
JOB_NAME = re.compile(r"^    name:\s*(.*?)\s*$", re.MULTILINE)
GITHUB_EXPRESSION = re.compile(r"\$\{\{.*?\}\}")
TRUSTED_CONTEXT = "trusted-release-controls"
TRUSTED_WORKFLOW_PATH = ".github/workflows/trusted-release-controls.yml"
TRUSTED_EXTERNAL_ID = re.compile(
    r"^trusted-release-controls:(pull-request|protected-main):"
    r"([1-9][0-9]*):([1-9][0-9]*):([0-9a-f]{40})$"
)
RELEASE_SOURCE_DIGESTS = {
    ".github/workflows/altstore-source.yml": (
        "af4c6d8e7e5731c09fd862c0f7760239bbdfb1ee14b20217cbcbc0e8a326f8ab"
    ),
    ".github/workflows/forgejo-release.yml": (
        "a78362c71188c47d87d6ab0b2e811cf97ab45df6c5b5478de25bd5b61fb83595"
    ),
    ".github/workflows/homebrew-cask.yml": (
        "75020df9587cc34387f41b3b9482bd71187639e39a79a3db97cb1dfd13552719"
    ),
    ".github/workflows/release-controls.yml": (
        "98f9b95510411d6c84aa3e78233c73cb8e2263b2b0d798c23104b775f1b876ce"
    ),
    ".github/workflows/release.yml": (
        "c79dbea991420931a246e7874b663f257fb99c53e9718a7a9d33313cc25dfc82"
    ),
    ".github/workflows/testing-build.yml": (
        "44cd2ac7ad024429fd885b02236267604207ff6e54f4199f7ae116d755041c10"
    ),
    ".github/workflows/trusted-release-controls.yml": (
        "9a1884acf3a8f65945b5939222c0ec5b9800afb9de2ec3691fb617e428d56cf8"
    ),
    "release/evidence/manifest.schema.json": (
        "71a32e31caaf3005e7067d11a0616dc84ac972eac46fa32898d1a0a445034e35"
    ),
    "release/metrics/reference-calibration-v1.json": (
        "bd9e093efb04c9e930fb45c6c3842dfe0b5a4483deac583ee647cdfb8dba92bc"
    ),
    "release/release-policy.json": (
        "57bc7fc96412a5703578f55ae6a0776430f3079ab313f6d1dc84c31d1d07ffb8"
    ),
    "release/required-ci.json": (
        "74f6978e7244bff50d17270a772b64d5b7f60a6cdc64f4d777e19dfb7231ec05"
    ),
    "release/terminology/active-allowlist.json": (
        "ab8994c7133abad633395486d0676e0dcd26b58fc59a56f46a9ed51ee250b64b"
    ),
    "release/terminology/legacy-inventory.json": (
        "46767d35d64376725f2f9715074d5feed94da8055f853e00c611b3e5fd917624"
    ),
    "Tools/altstore-source.py": (
        "55c5ac0bb7a18ab5f81dd984e1563bd853d247a10539bfebe58264530dce32f0"
    ),
    "Tools/android-lockfile-sbom.py": (
        "a36a24ab0cffcefdd927f5595d762b8be9cccd4da2bc375777dddb897947be10"
    ),
    "Tools/appchangelog-gen.py": (
        "ee921680754362391718059be7107123021aec50c5e626272e9e22f4e0ef63f0"
    ),
    "Tools/calibration-parity-audit.py": (
        "78c66bd1654af5e2eb32a9d517e897c7ca177afda7b043ab02b9c3f108fa81bb"
    ),
    "Tools/check-private-data.py": (
        "a576abcb572baceba3c86d289e0d28872eb081a791bc93ec16f6a0e628986b7f"
    ),
    "Tools/forgejo-release.sh": (
        "719123727a360a632ce60761edd8e14dd3d1d05a933c81a4f46a0522b2fe0802"
    ),
    "Tools/forgejo-version-gate.py": (
        "f4374129699a85e0acd38c20599a02ca436ddd23791f04c2649e03c09f18639b"
    ),
    "Tools/github-release-publish.py": (
        "908b246ff686833945b3aff0c294ede63a42d2e3889e4a80d0f07ee803ae3323"
    ),
    "Tools/github-release-tag-gate.py": (
        "dce752caaa9273cbb99b3327e16fe191167878a9e70d082ec0e7c9803b51beba"
    ),
    "Tools/health_claims_gate.py": (
        "a63f74aac0c8c8cf09219e8e37842a8b6d35296a40541c701a2d4725df463221"
    ),
    "Tools/homebrew-version-gate.py": (
        "1b2b40a565de57f22f2ec84998abf4f37103c93dd49bf018c6c7db0f2f5ea3a8"
    ),
    "Tools/i18n_audit.py": (
        "86e2040fd6ce9f7abc1126e0b16a056ba84a39fa878caa3367f7273d6306e8b4"
    ),
    "Tools/i18n_audit_baseline.json": (
        "5b7519589dbeeca37ce22a0fe35e51756a66247ecda7f27662d488fea7ed00d7"
    ),
    "Tools/prepare-ios-sideload-app.sh": (
        "d81bf5b8086c21a648a1417afa58cbb5bb9781c1738f2ff9d1cae6950ab2f097"
    ),
    "Tools/publish-testing-snapshot.sh": (
        "b6c87c6e0c8de61c6e090a8d74e76e7e6e9d47577e0a723161881c3f37a1e420"
    ),
    "Tools/release-control-gate.py": (
        "3ee267778fccdbf6de76ca60bd08547afebebd2d19d903d1c42a1db56a7d52d3"
    ),
    "Tools/release-evidence.py": (
        "8bda73730006cc4add6fa4533d76dcf5be6861167658d0c9212342ee8ea2c700"
    ),
    "Tools/release-legal-gate.py": (
        "33cf34fc61a1b47f44c0507ff69501e7a7527386e2fd5508d8cb81efd8c3cca2"
    ),
    "Tools/release-version-gate.py": (
        "b6c8bf64f657ee76ea63d26668ae0843fda097ba7b9c36f7071866c8730c950f"
    ),
    "Tools/release.sh": (
        "76d015c094ef603515d70cd56ead7501be52ad68b8286c4d04a0ee84dff81b95"
    ),
    "Tools/terminology-audit.py": (
        "8cb907cd981db978a895668bfc97e9c66d9ae632957032dec727ea5c8450b983"
    ),
    "Tools/trusted-release-controls.py": (
        "979d6870507e2bc50d46d4300b74814f58679a93a1351792a9bfad0a23e4ef2d"
    ),
    "Tools/update-homebrew-cask.sh": (
        "1733e7b43266ac7f16ed3043cef4bea51f8353ebe533fb9aa3d260fa76639989"
    ),
}


class GateError(RuntimeError):
    """A required CI invariant is absent or invalid."""


def _require_reviewed_source_digest(root: Path, relative_path: str) -> None:
    expected = RELEASE_SOURCE_DIGESTS[relative_path]
    try:
        data = (root / relative_path).read_bytes()
    except OSError as error:
        raise GateError(
            f"reviewed release source is missing: {relative_path}"
        ) from error
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise GateError(
            f"{relative_path} changed outside its reviewed source contract"
        )


def check_reviewed_release_sources(root: Path) -> None:
    for relative_path in sorted(RELEASE_SOURCE_DIGESTS):
        _require_reviewed_source_digest(root, relative_path)


def _string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise GateError(f"{label} must be a non-empty list")
    if not all(isinstance(item, str) and item for item in value):
        raise GateError(f"{label} contains an invalid string")
    return value


def load_config(path: Path = DEFAULT_CONFIG) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("required CI config is missing or invalid JSON") from error
    expected = {
        "schemaVersion",
        "sourceBranch",
        "requiredCheckAppId",
        "requiredContexts",
        "universalWorkflows",
        "workflows",
    }
    if not isinstance(config, dict) or set(config) != expected:
        raise GateError("required CI config fields do not match schema version 2")
    if config["schemaVersion"] != 2 or config["sourceBranch"] != "main":
        raise GateError("required CI config identity is invalid")
    if (
        not isinstance(config["requiredCheckAppId"], int)
        or isinstance(config["requiredCheckAppId"], bool)
        or config["requiredCheckAppId"] <= 0
    ):
        raise GateError("requiredCheckAppId must be a positive integer")

    contexts = _string_list(config["requiredContexts"], "requiredContexts")
    if contexts != sorted(set(contexts)) or any(
        SAFE_CONTEXT.fullmatch(context) is None for context in contexts
    ):
        raise GateError("requiredContexts must be unique, sorted, safe names")

    universal_workflows = config["universalWorkflows"]
    if not isinstance(universal_workflows, list) or not universal_workflows:
        raise GateError("universalWorkflows must be a non-empty list")
    universal_paths: list[str] = []
    universal_jobs: list[str] = []
    for index, workflow in enumerate(universal_workflows):
        if not isinstance(workflow, dict) or set(workflow) != {
            "path",
            "pullRequestEvent",
            "requiredJob",
        }:
            raise GateError(f"universalWorkflows[{index}] fields are invalid")
        path = workflow["path"]
        if not isinstance(path, str) or not path:
            raise GateError(f"universalWorkflows[{index}].path is invalid")
        candidate = PurePosixPath(path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise GateError(
                f"universalWorkflows[{index}].path must stay inside the repository"
            )
        if SAFE_JOB.fullmatch(str(workflow["requiredJob"])) is None:
            raise GateError(
                f"universalWorkflows[{index}].requiredJob is invalid"
            )
        if workflow["pullRequestEvent"] not in {
            "pull_request",
            "pull_request_target",
        }:
            raise GateError(
                f"universalWorkflows[{index}].pullRequestEvent is invalid"
            )
        universal_paths.append(path)
        universal_jobs.append(workflow["requiredJob"])
    if universal_paths != sorted(set(universal_paths)):
        raise GateError("universal workflow paths must be unique and sorted")
    if universal_jobs != sorted(universal_jobs):
        raise GateError("universal workflow jobs must be sorted by context")

    workflows = config["workflows"]
    if not isinstance(workflows, list) or not workflows:
        raise GateError("workflows must be a non-empty list")
    paths: list[str] = []
    required_jobs: list[str] = []
    for index, workflow in enumerate(workflows):
        expected_workflow = {
            "path",
            "applicabilityJob",
            "heavyJobs",
            "requiredJob",
        }
        if not isinstance(workflow, dict) or set(workflow) != expected_workflow:
            raise GateError(f"workflows[{index}] fields are invalid")
        path = workflow["path"]
        if not isinstance(path, str) or not path:
            raise GateError(f"workflows[{index}].path is invalid")
        candidate = PurePosixPath(path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise GateError(f"workflows[{index}].path must stay inside the repository")
        paths.append(path)
        for key in ("applicabilityJob", "requiredJob"):
            if SAFE_JOB.fullmatch(str(workflow[key])) is None:
                raise GateError(f"workflows[{index}].{key} is invalid")
        heavy_jobs = _string_list(
            workflow["heavyJobs"], f"workflows[{index}].heavyJobs"
        )
        if heavy_jobs != sorted(set(heavy_jobs)) or any(
            SAFE_JOB.fullmatch(job) is None for job in heavy_jobs
        ):
            raise GateError(
                f"workflows[{index}].heavyJobs must be unique, sorted job names"
            )
        if workflow["applicabilityJob"] in heavy_jobs:
            raise GateError(f"workflows[{index}] applicability job cannot be heavy")
        required_jobs.append(workflow["requiredJob"])

    if paths != sorted(set(paths)):
        raise GateError("workflow paths must be unique and sorted")
    if required_jobs != sorted(required_jobs):
        raise GateError("required workflow jobs must be sorted by context")
    configured_contexts = sorted(set(required_jobs + universal_jobs))
    if configured_contexts != contexts:
        raise GateError(
            "requiredContexts must exactly match universal and conditional jobs"
        )
    return config


def _jobs_section(text: str) -> str:
    marker = "\njobs:\n"
    if marker not in text:
        raise GateError("workflow must use a canonical jobs block")
    remainder = text.split(marker, 1)[1]
    lines = remainder.splitlines()
    jobs: list[str] = []
    saw_job = False
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            jobs.append(line)
            continue
        if line.startswith("\t"):
            raise GateError("workflow jobs cannot use tab indentation")
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            break
        if not saw_job:
            if JOB_HEADER_LINE.fullmatch(line) is None:
                raise GateError(
                    "workflow jobs must use canonical two-space block syntax"
                )
            saw_job = True
        if indent < 2:
            raise GateError(
                "workflow jobs must use canonical two-space block syntax"
            )
        if indent == 2 and JOB_HEADER_LINE.fullmatch(line) is None:
            raise GateError(
                "workflow jobs must use canonical two-space block syntax"
            )
        jobs.append(line)
    if not saw_job:
        raise GateError("workflow has no jobs")
    return "\n".join(jobs)


def _job_section(text: str, job_id: str) -> str:
    jobs = _jobs_section(text)
    matches = list(JOB_HEADER.finditer(jobs))
    for index, match in enumerate(matches):
        if match.group(1) != job_id:
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(jobs)
        return jobs[match.start() : end]
    raise GateError(f"workflow is missing job {job_id}")


def _job_ids(text: str) -> list[str]:
    return [match.group(1) for match in JOB_HEADER.finditer(_jobs_section(text))]


def _top_level_permissions(text: str, label: str) -> dict[str, str]:
    before_jobs = text.split("\njobs:\n", 1)[0]
    lines = before_jobs.splitlines()
    matches = [index for index, line in enumerate(lines) if line == "permissions:"]
    if len(matches) != 1:
        raise GateError(f"{label} must define one canonical permissions block")
    result: dict[str, str] = {}
    for line in lines[matches[0] + 1 :]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            break
        match = re.fullmatch(r"  ([a-z][a-z-]*): (read|write|none)", line)
        if match is None or match.group(1) in result:
            raise GateError(f"{label} has invalid top-level permissions")
        result[match.group(1)] = match.group(2)
    if not result:
        raise GateError(f"{label} has an empty top-level permissions block")
    return result


def _job_permissions(section: str, job_id: str) -> dict[str, str] | None:
    lines = section.splitlines()
    permission_properties = [
        index
        for index, line in enumerate(lines[1:], start=1)
        if len(line) - len(line.lstrip(" ")) == 4
        and line.strip().startswith("permissions")
    ]
    if not permission_properties:
        return None
    if (
        len(permission_properties) != 1
        or lines[permission_properties[0]] != "    permissions:"
    ):
        raise GateError(f"job {job_id} has invalid permissions syntax")
    result: dict[str, str] = {}
    for line in lines[permission_properties[0] + 1 :]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= 4:
            break
        match = re.fullmatch(r"      ([a-z][a-z-]*): (read|write|none)", line)
        if match is None or match.group(1) in result:
            raise GateError(f"job {job_id} has invalid permissions")
        result[match.group(1)] = match.group(2)
    if not result:
        raise GateError(f"job {job_id} has an empty permissions block")
    return result


def _require_exact_workflow_permissions(
    text: str,
    label: str,
    *,
    top_level: dict[str, str],
    jobs: dict[str, dict[str, str]],
) -> None:
    if _top_level_permissions(text, label) != top_level:
        raise GateError(f"{label} top-level permissions are not least privilege")
    actual: dict[str, dict[str, str]] = {}
    for job_id in _job_ids(text):
        permissions = _job_permissions(_job_section(text, job_id), job_id)
        if permissions is not None:
            actual[job_id] = permissions
    if actual != jobs:
        raise GateError(f"{label} write-capable jobs are not the exact allowlist")


def _normalized_shell_text(text: str) -> str:
    return re.sub(r"\\\r?\n[ \t]*", " ", text)


def _command_lines(text: str) -> list[str]:
    return [
        line.strip()
        for line in _normalized_shell_text(text).splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def _reject_direct_release_publication(text: str, label: str) -> None:
    for line in _command_lines(text):
        lowered = line.lower()
        if re.search(r"\bdraft[\"']?\s*[:=]\s*(?:false|0)\b", lowered):
            raise GateError(f"{label} contains a direct draft publication bypass")
        if re.search(r"\bmake[_-]?latest\b", lowered):
            raise GateError(f"{label} contains a direct latest-release mutation")
        if re.search(r"\bgh\s+release\s+create\b", lowered) and not re.search(
            r"(?:^|\s)--draft(?:\s|$)", lowered
        ):
            raise GateError(f"{label} creates a release outside draft state")
        if re.search(r"\bgh\s+release\s+edit\b", lowered) and not re.search(
            r"(?:^|\s)--draft(?:\s|$)", lowered
        ):
            raise GateError(f"{label} edits a release outside draft state")

        if re.search(r"\bgh\s+api\b", lowered) and "releases" in lowered:
            mutation = (
                re.search(
                    r"(?:--method|-x)\s+(?:post|patch|put|delete)\b",
                    lowered,
                )
                or re.search(
                    r"(?:^|\s)(?:-f|--field|--raw-field|--input)(?:\s|=)",
                    lowered,
                )
                or " mutation " in f" {lowered} "
            )
            generate_notes = (
                "releases/generate-notes" in lowered
                and re.search(
                    r"(?:--method|-x)\s+post\b",
                    lowered,
                )
                is not None
                and lowered.count("gh api") == 1
            )
            if mutation and not generate_notes:
                raise GateError(
                    f"{label} contains a direct release API mutation"
                )

        if "release" in lowered and any(
            primitive in lowered
            for primitive in (
                "api.github.com",
                "curl ",
                "curl\t",
                "import requests",
                "import subprocess",
                "import urllib",
                "wget ",
                "wget\t",
            )
        ):
            raise GateError(
                f"{label} contains an alternate release network mutation path"
            )


def _reject_owner_script_mutations(text: str, label: str) -> None:
    for line in _command_lines(text):
        lowered = line.lower()
        if re.search(r"\bgh\s+api\b", lowered) and (
            re.search(
                r"(?:--method|-x)\s+(?:post|patch|put|delete)\b",
                lowered,
            )
            or re.search(
                r"(?:^|\s)(?:-f|--field|--raw-field|--input)(?:\s|=)",
                lowered,
            )
            or " mutation " in f" {lowered} "
        ):
            raise GateError(f"{label} contains a raw GitHub API mutation")
        if re.search(r"\bdraft[\"']?\s*[:=]\s*(?:false|0)\b", lowered):
            raise GateError(f"{label} contains a direct draft publication bypass")
        if re.search(r"\bmake[_-]?latest\b", lowered):
            raise GateError(f"{label} contains a direct latest-release mutation")
        if any(
            primitive in lowered
            for primitive in (
                "api.github.com",
                "curl ",
                "curl\t",
                "import requests",
                "import subprocess",
                "import urllib",
                "wget ",
                "wget\t",
            )
        ):
            raise GateError(f"{label} contains an alternate network mutator")


def _job_property_keys(section: str, job_id: str) -> list[str]:
    keys: list[str] = []
    for line in section.splitlines()[1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent != 4:
            continue
        if JOB_PROPERTY_LINE.fullmatch(line) is None:
            raise GateError(f"job {job_id} has invalid property syntax")
        key = line.strip().split(":", 1)[0]
        if key in keys:
            raise GateError(f"job {job_id} repeats property {key}")
        keys.append(key)
    return keys


def _named_step(section: str, name: str) -> str:
    header = f"      - name: {name}"
    lines = section.splitlines()
    matches = [index for index, line in enumerate(lines) if line == header]
    if len(matches) != 1:
        raise GateError(f"workflow must contain exactly one step named {name}")
    start = matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        indent = len(line) - len(line.lstrip(" "))
        if line.startswith("      - ") or (
            line.strip() and indent <= 4
        ):
            end = index
            break
    return "\n".join(lines[start:end])


def _folded_run_command(step: str, name: str) -> str:
    marker = "        run: >-"
    lines = step.splitlines()
    matches = [index for index, line in enumerate(lines) if line == marker]
    if len(matches) != 1:
        raise GateError(f"step {name} must use one canonical folded run command")
    command_lines = lines[matches[0] + 1 :]
    while command_lines and not command_lines[-1].strip():
        command_lines.pop()
    if not command_lines or any(
        len(line) - len(line.lstrip(" ")) != 10 or not line.strip()
        for line in command_lines
    ):
        raise GateError(f"step {name} has an invalid folded run command")
    return " ".join(line.strip() for line in command_lines)


def _step_environment(
    step: str,
    name: str,
    *,
    run_line: str = "        run: >-",
) -> dict[str, str]:
    lines = step.splitlines()
    top_level = [
        line
        for line in lines[1:]
        if line.strip()
        and not line.lstrip().startswith("#")
        and len(line) - len(line.lstrip(" ")) == 8
    ]
    if top_level != ["        env:", run_line]:
        raise GateError(f"step {name} must contain only canonical env and run")
    env_index = lines.index("        env:")
    run_index = lines.index(run_line)
    if env_index >= run_index:
        raise GateError(f"step {name} must define env before run")
    result: dict[str, str] = {}
    for line in lines[env_index + 1 : run_index]:
        if not line.strip():
            continue
        if (
            len(line) - len(line.lstrip(" ")) != 10
            or ":" not in line.strip()
        ):
            raise GateError(f"step {name} has an invalid environment")
        key, value = line.strip().split(":", 1)
        if (
            re.fullmatch(r"[A-Z][A-Z0-9_]*", key) is None
            or not value.strip()
            or key in result
        ):
            raise GateError(f"step {name} has an invalid environment")
        result[key] = value.strip()
    return result


def _literal_run_body(step: str, name: str) -> str:
    marker = "        run: |"
    _step_environment(step, name, run_line=marker)
    lines = step.splitlines()
    run_index = lines.index(marker)
    body = lines[run_index + 1 :]
    while body and not body[-1].strip():
        body.pop()
    if not body or any(
        len(line) - len(line.lstrip(" ")) < 10 for line in body if line.strip()
    ):
        raise GateError(f"step {name} has an invalid literal run body")
    return "\n".join(
        line[10:] if line.strip() else "" for line in body
    )


def _needs(section: str, job_id: str) -> set[str]:
    match = re.search(r"^    needs:\s*\[([^\]]+)\]\s*$", section, re.MULTILINE)
    if match is None:
        raise GateError(f"job {job_id} must use an explicit needs list")
    return {item.strip() for item in match.group(1).split(",") if item.strip()}


def required_workflow_paths(config: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for workflow in [
        *config["universalWorkflows"],
        *config["workflows"],
    ]:
        result[workflow["requiredJob"]] = workflow["path"]
    return result


def _job_display_name(section: str, job_id: str) -> str:
    for line in section.splitlines()[1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 4 and JOB_PROPERTY_LINE.fullmatch(line) is None:
            raise GateError(
                f"job {job_id} must use canonical property key syntax"
            )
    match = JOB_NAME.search(section)
    if match is None:
        return job_id
    name = match.group(1).strip()
    if (
        len(name) >= 2
        and name[0] in {"'", '"'}
        and name[-1] == name[0]
    ):
        name = name[1:-1]
    if not name:
        raise GateError(f"job {job_id} has an empty display name")
    if (
        name[0] in {"|", ">", "&", "*", "!", "{", "["}
        or "#" in name
        or "\\" in name
    ):
        raise GateError(f"job {job_id} uses an unsupported display name")
    return name


def _dynamic_name_can_resolve_to_context(name: str, context: str) -> bool:
    if "${{" not in name and "}}" not in name:
        return name == context
    matches = list(GITHUB_EXPRESSION.finditer(name))
    if not matches:
        return True
    fragments: list[str] = []
    cursor = 0
    for match in matches:
        fragment = name[cursor : match.start()]
        if "${{" in fragment or "}}" in fragment:
            return True
        fragments.append(fragment)
        cursor = match.end()
    final_fragment = name[cursor:]
    if "${{" in final_fragment or "}}" in final_fragment:
        return True
    fragments.append(final_fragment)
    pattern = "^" + ".*".join(re.escape(fragment) for fragment in fragments) + "$"
    return re.fullmatch(pattern, context) is not None


def check_required_context_ownership(
    root: Path, config: dict[str, Any]
) -> None:
    expected = required_workflow_paths(config)
    owners: dict[str, list[tuple[str, str]]] = {
        context: [] for context in expected
    }
    workflow_directory = root / ".github" / "workflows"
    paths = sorted(
        {
            *workflow_directory.glob("*.yml"),
            *workflow_directory.glob("*.yaml"),
        }
    )
    if not paths:
        raise GateError("repository has no GitHub Actions workflows")

    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            raise GateError("GitHub Actions workflow cannot be read") from error
        jobs = _jobs_section(text)
        matches = list(JOB_HEADER.finditer(jobs))
        for index, match in enumerate(matches):
            end = (
                matches[index + 1].start()
                if index + 1 < len(matches)
                else len(jobs)
            )
            section = jobs[match.start() : end]
            relative = path.relative_to(root).as_posix()
            job_id = match.group(1)
            name = _job_display_name(section, job_id)
            for context in owners:
                if "${{" in name or "}}" in name:
                    if _dynamic_name_can_resolve_to_context(name, context):
                        raise GateError(
                            f"dynamic job name {relative}:{job_id} can resolve "
                            f"to required context {context}"
                        )
                    continue
                if name == context:
                    owners[context].append((relative, job_id))

    for context, expected_path in expected.items():
        matches = owners[context]
        if context == TRUSTED_CONTEXT:
            if expected_path != TRUSTED_WORKFLOW_PATH or matches:
                raise GateError(
                    "trusted release-control context must be published only "
                    "as the exact-head custom check"
                )
            continue
        if len(matches) != 1:
            raise GateError(
                f"required context {context} must have exactly one workflow owner"
            )
        actual_path, _ = matches[0]
        if actual_path != expected_path:
            raise GateError(
                f"required context {context} is owned by an unexpected workflow"
            )
        if matches[0][1] != context:
            raise GateError(
                f"required context {context} is owned by an unexpected job"
            )


def check_workflow(root: Path, workflow: dict[str, Any]) -> None:
    path = root / workflow["path"]
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"required workflow is missing: {workflow['path']}") from error

    before_jobs = text.split("\njobs:\n", 1)[0]
    for event in ("pull_request", "push", "workflow_dispatch"):
        if re.search(rf"^  {event}:", before_jobs, re.MULTILINE) is None:
            raise GateError(f"{workflow['path']} must run for {event}")
    if re.search(r"^\s+paths(?:-ignore)?:", before_jobs, re.MULTILINE):
        raise GateError(
            f"{workflow['path']} cannot use event-level path filters"
        )

    applicability = workflow["applicabilityJob"]
    applicability_section = _job_section(text, applicability)
    for required_text in (
        "outputs:",
        "run: ${{ steps.scope.outputs.run }}",
        "fetch-depth: 0",
        'EVENT_NAME: ${{ github.event_name }}',
        'CHANGED_FILES="$RUNNER_TEMP/noop-required-ci-changed-files.txt"',
        'git diff --no-renames --name-only "$BASE_SHA" "$GITHUB_SHA"',
        '> "$CHANGED_FILES"',
        '"$CHANGED_FILES"',
        '"run=true"',
        '"run=false"',
    ):
        if required_text not in applicability_section:
            raise GateError(
                f"{workflow['path']} applicability job lacks {required_text}"
            )

    for heavy_job in workflow["heavyJobs"]:
        section = _job_section(text, heavy_job)
        if _needs(section, heavy_job) != {applicability}:
            raise GateError(
                f"{workflow['path']} job {heavy_job} must need only {applicability}"
            )
        expected_if = (
            "if: ${{ needs."
            + applicability
            + ".outputs.run == 'true' }}"
        )
        if expected_if not in section:
            raise GateError(
                f"{workflow['path']} job {heavy_job} is not applicability-gated"
            )

    required_job = workflow["requiredJob"]
    required_section = _job_section(text, required_job)
    expected_needs = {applicability, *workflow["heavyJobs"]}
    if _needs(required_section, required_job) != expected_needs:
        raise GateError(
            f"{workflow['path']} job {required_job} has incomplete dependencies"
        )
    for required_text in (
        f"name: {required_job}",
        "if: ${{ always() }}",
        f"${{{{ needs.{applicability}.result }}}}",
        f"${{{{ needs.{applicability}.outputs.run }}}}",
        'test "$APPLICABILITY_RESULT" = "success"',
        'test "$RUN_REQUIRED" = "false"',
    ):
        if required_text not in required_section:
            raise GateError(
                f"{workflow['path']} required job lacks {required_text}"
            )
    for heavy_job in workflow["heavyJobs"]:
        if f"${{{{ needs.{heavy_job}.result }}}}" not in required_section:
            raise GateError(
                f"{workflow['path']} required job ignores {heavy_job}"
            )
    success_checks = required_section.count('= "success"')
    if success_checks < len(workflow["heavyJobs"]) + 1:
        raise GateError(
            f"{workflow['path']} required job does not fail closed on job results"
        )


def check_universal_workflow(root: Path, workflow: dict[str, Any]) -> None:
    path = root / workflow["path"]
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"required workflow is missing: {workflow['path']}") from error
    before_jobs = text.split("\njobs:\n", 1)[0]
    for event in (workflow["pullRequestEvent"], "push"):
        if re.search(rf"^  {event}:", before_jobs, re.MULTILINE) is None:
            raise GateError(f"{workflow['path']} must run for {event}")
    if re.search(r"^\s+paths(?:-ignore)?:", before_jobs, re.MULTILINE):
        raise GateError(
            f"{workflow['path']} universal check cannot use event-level path filters"
        )
    required_job = workflow["requiredJob"]
    if workflow["path"] == TRUSTED_WORKFLOW_PATH:
        if (
            workflow["pullRequestEvent"] != "pull_request_target"
            or required_job != TRUSTED_CONTEXT
        ):
            raise GateError("trusted release-control workflow identity is invalid")
        check_trusted_release_workflow(root)
        return
    section = _job_section(text, required_job)
    if f"name: {required_job}" not in section:
        raise GateError(
            f"{workflow['path']} universal job lacks stable name {required_job}"
        )


def check_trusted_release_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "trusted-release-controls.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("trusted release-controls workflow is missing") from error
    _require_exact_workflow_permissions(
        text,
        "trusted release-controls workflow",
        top_level={"contents": "read"},
        jobs={
            "report-pr": {
                "checks": "write",
                "contents": "read",
            },
            "report-main": {
                "checks": "write",
                "contents": "read",
            },
        },
    )
    required_text = (
        "pull_request_target:",
        "types: [opened, synchronize]",
        "push:",
        "contents: read",
        "name: trusted-release-controls-pr-validation",
        "name: trusted-release-controls-pr-report",
        "name: trusted-release-controls-main-validation",
        "name: trusted-release-controls-main-report",
        "Checkout protected base source",
        "ref: ${{ github.event.pull_request.base.sha }}",
        "Checkout candidate as isolated data",
        "path: candidate",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "persist-credentials: false",
        "Tools/trusted-release-controls.py verify-pr",
        '--base-root "$GITHUB_WORKSPACE"',
        '--candidate-root "$GITHUB_WORKSPACE/candidate"',
        '--base-sha "$BASE_SHA"',
        '--head-sha "$HEAD_SHA"',
        '--repository "$REPOSITORY"',
        '--head-repository "$HEAD_REPOSITORY"',
        '--repository-owner "$REPOSITORY_OWNER"',
        '--actor "$HEAD_ACTOR"',
        "Tools/trusted-release-controls.py report-check",
        '--repository "$GITHUB_REPOSITORY"',
        "--scope pull-request",
        "--scope protected-main",
        '--validation-result "$VALIDATION_RESULT"',
        '--run-id "$GITHUB_RUN_ID"',
        '--run-attempt "$GITHUB_RUN_ATTEMPT"',
        "Tools/trusted-release-controls.py verify-self",
        '--root "$GITHUB_WORKSPACE"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"trusted release-controls workflow lacks {item}")
    for forbidden in (
        "\n  pull_request:\n",
        "\n  workflow_dispatch:\n",
        "\n    name: trusted-release-controls\n",
        "id-token: write",
        "persist-credentials: true",
        "secrets.",
    ):
        if forbidden in text:
            raise GateError(
                "trusted release-controls workflow has an unsafe capability"
            )
    if text.count(
        "uses: actions/checkout@"
        "3d3c42e5aac5ba805825da76410c181273ba90b1"
    ) != 5:
        raise GateError(
            "trusted release-controls workflow must use five exact checkouts"
        )
    verify = _job_section(text, "verify-pr")
    if _job_property_keys(verify, "verify-pr") != [
        "if",
        "name",
        "runs-on",
        "steps",
    ]:
        raise GateError(
            "trusted pull-request validation job is not canonical"
        )
    verify_name = "Verify candidate with protected base controls"
    verify_step = _named_step(verify, verify_name)
    if _step_environment(verify_step, verify_name) != {
        "BASE_SHA": "${{ github.event.pull_request.base.sha }}",
        "HEAD_ACTOR": "${{ github.actor }}",
        "HEAD_REPOSITORY": (
            "${{ github.event.pull_request.head.repo.full_name }}"
        ),
        "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
        "REPOSITORY": "${{ github.repository }}",
        "REPOSITORY_OWNER": "${{ github.repository_owner }}",
    }:
        raise GateError(
            "trusted pull-request validation environment is not exact"
        )
    expected_verify = (
        'python3 Tools/trusted-release-controls.py verify-pr '
        '--base-root "$GITHUB_WORKSPACE" '
        '--candidate-root "$GITHUB_WORKSPACE/candidate" '
        '--base-sha "$BASE_SHA" '
        '--head-sha "$HEAD_SHA" '
        '--repository "$REPOSITORY" '
        '--head-repository "$HEAD_REPOSITORY" '
        '--repository-owner "$REPOSITORY_OWNER" '
        '--actor "$HEAD_ACTOR"'
    )
    if _folded_run_command(verify_step, verify_name) != expected_verify:
        raise GateError(
            "trusted pull-request validation command is not canonical"
        )

    report = _job_section(text, "report-pr")
    if _job_property_keys(report, "report-pr") != [
        "if",
        "name",
        "needs",
        "permissions",
        "runs-on",
        "steps",
    ]:
        raise GateError("trusted pull-request reporting job is not canonical")
    if _needs(report, "report-pr") != {"verify-pr"}:
        raise GateError(
            "trusted pull-request reporting must depend on validation"
        )
    report_name = "Publish exact pull-request head result"
    report_step = _named_step(report, report_name)
    if _step_environment(report_step, report_name) != {
        "GH_TOKEN": "${{ github.token }}",
        "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
        "VALIDATION_RESULT": "${{ needs.verify-pr.result }}",
    }:
        raise GateError(
            "trusted pull-request reporting environment is not exact"
        )
    expected_report = (
        'python3 Tools/trusted-release-controls.py report-check '
        '--repository "$GITHUB_REPOSITORY" '
        '--head-sha "$HEAD_SHA" '
        '--scope pull-request '
        '--validation-result "$VALIDATION_RESULT" '
        '--run-id "$GITHUB_RUN_ID" '
        '--run-attempt "$GITHUB_RUN_ATTEMPT"'
    )
    if _folded_run_command(report_step, report_name) != expected_report:
        raise GateError(
            "trusted pull-request reporting command is not canonical"
        )

    verify_main = _job_section(text, "verify-main")
    if _job_property_keys(verify_main, "verify-main") != [
        "if",
        "name",
        "runs-on",
        "steps",
    ]:
        raise GateError(
            "trusted protected-main validation job is not canonical"
        )
    if (
        "    if: github.event_name == 'push'\n" not in verify_main
        or "    name: trusted-release-controls-main-validation\n"
        not in verify_main
    ):
        raise GateError(
            "trusted protected-main validation identity is not exact"
        )
    self_step = _named_step(verify_main, "Verify protected main source")
    if _folded_run_command(
        self_step, "Verify protected main source"
    ) != (
        "python3 Tools/trusted-release-controls.py verify-self "
        '--root "$GITHUB_WORKSPACE"'
    ):
        raise GateError(
            "trusted protected-main validation command is not canonical"
        )

    report_main = _job_section(text, "report-main")
    if _job_property_keys(report_main, "report-main") != [
        "if",
        "name",
        "needs",
        "permissions",
        "runs-on",
        "steps",
    ]:
        raise GateError("trusted protected-main reporting job is not canonical")
    if _needs(report_main, "report-main") != {"verify-main"}:
        raise GateError(
            "trusted protected-main reporting must depend on validation"
        )
    if (
        "    if: always() && github.event_name == 'push'\n"
        not in report_main
        or "    name: trusted-release-controls-main-report\n"
        not in report_main
    ):
        raise GateError(
            "trusted protected-main reporting identity is not exact"
        )
    report_main_name = "Publish exact protected-main result"
    report_main_step = _named_step(report_main, report_main_name)
    if _step_environment(report_main_step, report_main_name) != {
        "GH_TOKEN": "${{ github.token }}",
        "HEAD_SHA": "${{ github.sha }}",
        "VALIDATION_RESULT": "${{ needs.verify-main.result }}",
    }:
        raise GateError(
            "trusted protected-main reporting environment is not exact"
        )
    expected_main_report = (
        'python3 Tools/trusted-release-controls.py report-check '
        '--repository "$GITHUB_REPOSITORY" '
        '--head-sha "$HEAD_SHA" '
        '--scope protected-main '
        '--validation-result "$VALIDATION_RESULT" '
        '--run-id "$GITHUB_RUN_ID" '
        '--run-attempt "$GITHUB_RUN_ATTEMPT"'
    )
    if (
        _folded_run_command(report_main_step, report_main_name)
        != expected_main_report
    ):
        raise GateError(
            "trusted protected-main reporting command is not canonical"
        )


def check_release_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "release.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("release workflow is missing") from error
    _require_exact_workflow_permissions(
        text,
        "release workflow",
        top_level={
            "actions": "read",
            "checks": "read",
            "contents": "read",
        },
        jobs={
            "bump": {
                "actions": "read",
                "checks": "read",
                "contents": "write",
            },
            "android": {"contents": "write"},
            "macos": {"contents": "write"},
            "ios": {"contents": "write"},
        },
    )
    _reject_direct_release_publication(text, "release workflow")
    bump_section = _job_section(text, "bump")
    android_section = _job_section(text, "android")
    if "ANDROID_STAGING_KEYSTORE_BASE64" in bump_section:
        raise GateError(
            "release metadata job can access Android signing secrets"
        )
    if "    environment: staging\n" not in android_section:
        raise GateError(
            "release Android signing job lacks the protected staging environment"
        )
    for secret in (
        "ANDROID_STAGING_KEYSTORE_BASE64",
        "ANDROID_STAGING_STORE_PASSWORD",
        "ANDROID_STAGING_KEY_ALIAS",
        "ANDROID_STAGING_KEY_PASSWORD",
    ):
        if secret not in android_section:
            raise GateError(
                f"release Android job lacks protected secret {secret}"
            )
    required_text = (
        "actions: read",
        "checks: read",
        "ref: ${{ github.sha }}",
        "release_sha:",
        "EXPECTED_RELEASE_SHA: ${{ github.event.inputs.release_sha }}",
        'test "$GITHUB_REF" = "refs/heads/main"',
        'test "$GITHUB_SHA" = "$EXPECTED_RELEASE_SHA"',
        "Tools/required-ci-gate.py verify-github",
        "Tools/release-version-gate.py check",
        "--exclude-drafts --exclude-pre-releases --limit 1",
        'PREV="$PREV_TAG"',
        "--release-sha \"$GITHUB_SHA\"",
        "--sha \"$GITHUB_SHA\"",
        "git diff --exit-code",
        "run-name: NOOP release candidate v${{ inputs.version }} @ "
        "${{ inputs.release_sha }}",
        "Reverify required checks for exact candidate",
        "Verify complete candidate bytes",
        "Record exact release draft",
        "Retain exact candidate manifest",
        "--sha \"$RELEASE_SHA\"",
        "Tools/github-release-publish.py",
        "--verify-draft-only",
        "--write-manifest \"$RUNNER_TEMP/release-candidate.json\"",
        "bodySha: ${{ steps.b.outputs.bodySha }}",
        '--title "NOOP ${NEW}" --notes-file "$BODY"',
        'release.get("body") == body',
        'release.get("target_commitish") == sys.argv[4]',
        "production-release-candidate-${{ github.run_id }}-"
        "${{ github.run_attempt }}",
        'RELEASE_SHA: ${{ needs.bump.outputs.sha }}',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"release workflow lacks {item}")
    forbidden_text = (
        "github.event.inputs.bump",
        'git commit -am "Release',
        'git push origin "HEAD:${GITHUB_REF_NAME}"',
    )
    for item in forbidden_text:
        if item in text:
            raise GateError(f"release workflow retains unsafe source mutation: {item}")
    if text.count("Tools/required-ci-gate.py verify-github") < 2:
        raise GateError(
            "release workflow must verify exact-SHA checks before draft and readiness"
        )
    ready_section = _job_section(text, "ready")
    if _job_property_keys(ready_section, "ready") != [
        "name",
        "needs",
        "runs-on",
        "timeout-minutes",
        "steps",
    ]:
        raise GateError(
            "release ready job must contain only canonical required properties"
        )
    if _needs(ready_section, "ready") != {"bump", "android", "macos", "ios"}:
        raise GateError("release ready job must require every artifact producer")
    checks_step_name = "Reverify required checks for exact candidate"
    checks_step = _named_step(ready_section, checks_step_name)
    if _step_environment(checks_step, checks_step_name) != {
        "GH_TOKEN": "${{ github.token }}",
        "RELEASE_SHA": "${{ needs.bump.outputs.sha }}",
    }:
        raise GateError("release exact-check step environment is not exact")
    expected_checks_command = (
        'python3 Tools/required-ci-gate.py verify-github '
        '--repository "$GITHUB_REPOSITORY" '
        '--sha "$RELEASE_SHA"'
    )
    if (
        _folded_run_command(checks_step, checks_step_name)
        != expected_checks_command
    ):
        raise GateError("release exact-check command is not canonical")
    byte_step_name = "Verify complete candidate bytes"
    byte_step = _named_step(ready_section, byte_step_name)
    if _step_environment(
        byte_step,
        byte_step_name,
        run_line="        run: |",
    ) != {
        "GH_TOKEN": "${{ github.token }}",
        "TAG": "${{ needs.bump.outputs.tag }}",
        "VER": "${{ needs.bump.outputs.ver }}",
    }:
        raise GateError("release byte-verification environment is not exact")
    expected_byte_body = '''set -euo pipefail
VERIFY_DIR=$(mktemp -d "$RUNNER_TEMP/noop-release-ready.XXXXXX")
gh release download "$TAG" --repo "$GITHUB_REPOSITORY" \\
  --dir "$VERIFY_DIR" --pattern 'NOOP-*'
(
  cd "$VERIFY_DIR"
  test "$(find . -maxdepth 1 -type f -name 'NOOP-*' | wc -l | tr -d ' ')" = "5"
  sha256sum --check "NOOP-android-v${VER}.apk.sha256"
  jq -e '.bomFormat == "CycloneDX" and (.components | type == "array")' \\
    "NOOP-android-v${VER}.cdx.json" >/dev/null
  unzip -tq "NOOP-android-v${VER}.apk" >/dev/null
  unzip -tq "NOOP-macos-v${VER}.zip" >/dev/null
  unzip -tq "NOOP-ios-unsigned-v${VER}.ipa" >/dev/null
)
rm -rf "$VERIFY_DIR"'''
    if _literal_run_body(byte_step, byte_step_name) != expected_byte_body:
        raise GateError("release byte-verification command is not canonical")
    draft_step_name = "Record exact release draft"
    draft_step = _named_step(ready_section, draft_step_name)
    if _step_environment(draft_step, draft_step_name) != {
        "GH_TOKEN": "${{ github.token }}",
        "TAG": "${{ needs.bump.outputs.tag }}",
        "VER": "${{ needs.bump.outputs.ver }}",
        "RELEASE_SHA": "${{ needs.bump.outputs.sha }}",
        "BODY_SHA": "${{ needs.bump.outputs.bodySha }}",
    }:
        raise GateError("release draft-verification environment is not exact")
    expected_draft_command = (
        'python3 Tools/github-release-publish.py '
        '--repository "$GITHUB_REPOSITORY" '
        '--tag "$TAG" '
        '--version "$VER" '
        '--expected-sha "$RELEASE_SHA" '
        '--expected-name "NOOP $VER" '
        '--expected-body-sha256 "$BODY_SHA" '
        '--expected-target "$RELEASE_SHA" '
        '--verify-draft-only '
        '--write-manifest "$RUNNER_TEMP/release-candidate.json" '
        '--run-id "$GITHUB_RUN_ID" '
        '--run-attempt "$GITHUB_RUN_ATTEMPT"'
    )
    if (
        _folded_run_command(draft_step, draft_step_name)
        != expected_draft_command
        or text.count("Tools/github-release-publish.py") != 1
    ):
        raise GateError(
            "release workflow must execute only the exact draft verifier"
        )
    manifest_step_name = "Retain exact candidate manifest"
    manifest_step = _named_step(ready_section, manifest_step_name)
    expected_manifest_step = (
        "      - name: Retain exact candidate manifest\n"
        "        uses: actions/upload-artifact@"
        "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a "
        "# v7.0.1, pinned 2026-04-10\n"
        "        with:\n"
        "          name: production-release-candidate-"
        "${{ github.run_id }}-${{ github.run_attempt }}\n"
        "          path: ${{ runner.temp }}/release-candidate.json\n"
        "          if-no-files-found: error\n"
        "          retention-days: 14"
    )
    if manifest_step != expected_manifest_step:
        raise GateError("release candidate manifest retention is not canonical")
    if re.search(
        r"git\s+push[^\n]*(?:HEAD:)?(?:refs/heads/)?main(?:[\s\"']|$)",
        text,
    ):
        raise GateError("release workflow cannot push directly to main")
    for forbidden_job in ("publish", "altstore", "homebrew", "forgejo"):
        if re.search(rf"^  {re.escape(forbidden_job)}:\s*$", text, re.MULTILINE):
            raise GateError(
                "release workflow cannot publish or invoke post-release channels"
            )
    _require_reviewed_source_digest(
        root, ".github/workflows/release.yml"
    )


def check_testing_release_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "testing-build.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("testing release workflow is missing") from error
    _require_exact_workflow_permissions(
        text,
        "testing release workflow",
        top_level={"contents": "read"},
        jobs={
            "meta": {"contents": "write"},
            "android": {"contents": "write"},
            "macos": {"contents": "write"},
            "ios": {"contents": "write"},
            "cleanup": {"contents": "write"},
        },
    )
    _reject_direct_release_publication(text, "testing release workflow")
    required_text = (
        "run-name: NOOP testing candidate @ ${{ github.sha }}",
        "Require exact protected-main source",
        'test "$GITHUB_REF" = "refs/heads/main"',
        'MAIN_SHA=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/heads/main"',
        'test "$MAIN_SHA" = "$GITHUB_SHA"',
        "bodySha: ${{ steps.m.outputs.bodySha }}",
        "title: ${{ steps.m.outputs.title }}",
        '--title "$TITLE" --notes-file "$BODY"',
        "    environment: staging",
        "Require protected staging signing secrets",
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"testing release workflow lacks {item}")
    meta_section = _job_section(text, "meta")
    android_section = _job_section(text, "android")
    if "ANDROID_STAGING_KEYSTORE_BASE64" in meta_section:
        raise GateError(
            "testing release metadata job can access signing secrets"
        )
    for secret in (
        "ANDROID_STAGING_KEYSTORE_BASE64",
        "ANDROID_STAGING_STORE_PASSWORD",
        "ANDROID_STAGING_KEY_ALIAS",
        "ANDROID_STAGING_KEY_PASSWORD",
    ):
        if secret not in android_section:
            raise GateError(
                f"testing Android job lacks protected secret {secret}"
            )
    if text.count("          ref: ${{ github.sha }}") != 5:
        raise GateError(
            "testing release checkouts must use the exact protected source"
        )
    ready_section = _job_section(text, "ready")
    if _job_property_keys(ready_section, "ready") != [
        "needs",
        "runs-on",
        "steps",
    ]:
        raise GateError(
            "testing ready job must contain only canonical required properties"
        )
    if _needs(ready_section, "ready") != {"meta", "android", "macos", "ios"}:
        raise GateError("testing ready job must require every artifact producer")
    draft_step_name = "Record exact testing snapshot draft"
    draft_step = _named_step(ready_section, draft_step_name)
    if _step_environment(draft_step, draft_step_name) != {
        "GH_TOKEN": "${{ github.token }}",
        "CANDIDATE_TAG": "${{ needs.meta.outputs.tag }}",
        "VER": "${{ needs.meta.outputs.ver }}",
        "TARGET_SHA": "${{ github.sha }}",
        "EXPECTED_NAME": "${{ needs.meta.outputs.title }}",
        "EXPECTED_BODY_SHA": "${{ needs.meta.outputs.bodySha }}",
    }:
        raise GateError("testing draft-verification environment is not exact")
    expected_draft_command = (
        'python3 Tools/github-release-publish.py '
        '--repository "$GITHUB_REPOSITORY" '
        '--tag "$CANDIDATE_TAG" '
        '--version "$VER" '
        '--expected-sha "$TARGET_SHA" '
        '--expected-name "$EXPECTED_NAME" '
        '--expected-body-sha256 "$EXPECTED_BODY_SHA" '
        '--expected-target "$TARGET_SHA" '
        '--verify-draft-only '
        '--testing-snapshot '
        '--write-manifest "$RUNNER_TEMP/testing-release-candidate.json" '
        '--run-id "$GITHUB_RUN_ID" '
        '--run-attempt "$GITHUB_RUN_ATTEMPT"'
    )
    if (
        _folded_run_command(draft_step, draft_step_name)
        != expected_draft_command
        or text.count("Tools/github-release-publish.py") != 1
    ):
        raise GateError(
            "testing release workflow must execute only the exact draft verifier"
        )
    _require_reviewed_source_digest(
        root, ".github/workflows/testing-build.yml"
    )


def check_altstore_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "altstore-source.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("AltStore source workflow is missing") from error
    required_text = (
        "actions: read",
        "workflow_call:",
        'test "$GITHUB_REF" = "refs/heads/main"',
        "Tools/required-ci-gate.py verify-github",
        'git merge-base --is-ancestor "$RELEASE_SHA" "$GITHUB_SHA"',
        "Tools/altstore-source.py update",
        "releases/download/${CHANNEL_TAG}/altstore-source.json",
        "gh release upload \"$CHANNEL_TAG\" \"$MANIFEST\"",
        "curl --fail --silent --show-error --location",
        "timeout-minutes: 20",
        'select(.name == "altstore-source.json")',
        'select(.name == "altstore-source.previous.json")',
        'if [ "$SOURCE_ASSET_COUNT" = "1" ]',
        'elif [ "$SOURCE_ASSET_COUNT" = "0" ] &&',
        'BASE_SOURCE="backup"',
        'INITIALIZING_MARKER="NOOP_ALTSTORE_STATE=initializing"',
        'READY_MARKER="NOOP_ALTSTORE_STATE=ready"',
        'if [ "$BASE_SOURCE" = "stable" ]',
        'gh release upload "$CHANNEL_TAG" "$BACKUP"',
        'test "$APPLE_VERSION" = "$VERSION"',
        'test "$ANDROID_VERSION" = "$VERSION"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"AltStore source workflow lacks {item}")
    if text.count("--connect-timeout 10 --max-time 30") != 3:
        raise GateError(
            "AltStore source workflow must bound every anonymous download"
        )
    if re.search(r"git\s+push", text):
        raise GateError("AltStore source workflow cannot mutate Git refs")
    backup_upload = text.index('gh release upload "$CHANNEL_TAG" "$BACKUP"')
    source_upload = text.index('gh release upload "$CHANNEL_TAG" "$MANIFEST"')
    if backup_upload >= source_upload:
        raise GateError(
            "AltStore source workflow must preserve history before replacement"
        )
    template_fallback = text.index('cp altstore-source.json "$MANIFEST"')
    initializing_guard = text.index(
        'grep -Fq "$INITIALIZING_MARKER" <<<"$CHANNEL_BODY"'
    )
    if initializing_guard >= template_fallback:
        raise GateError(
            "AltStore template recovery must require first-publication state"
        )


def check_homebrew_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "homebrew-cask.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("Homebrew cask workflow is missing") from error
    required_text = (
        "actions: read",
        "workflow_call:",
        "workflow_dispatch:",
        "publish_forgejo:",
        "timeout-minutes: 20",
        'test "$GITHUB_REF" = "refs/heads/main"',
        "Tools/required-ci-gate.py verify-github",
        'git merge-base --is-ancestor "$RELEASE_SHA" "$GITHUB_SHA"',
        "NOOP_HOMEBREW_TAP_ORG: ${{ vars.NOOP_HOMEBREW_TAP_ORG }}",
        "NOOP_HOMEBREW_GITHUB_TOKEN: ${{ secrets.NOOP_HOMEBREW_TAP_TOKEN }}",
        "NOOP_HOMEBREW_FORGE_TOKEN: ${{ "
        "inputs.publish_forgejo && "
        "secrets.NOOP_HOMEBREW_FORGE_TOKEN || '' }}",
        "FORGE_DOMAIN: ${{ inputs.publish_forgejo && "
        "vars.NOOP_HOMEBREW_FORGE_DOMAIN || '' }}",
        "FORGE_ORG: ${{ inputs.publish_forgejo && "
        "vars.NOOP_HOMEBREW_FORGE_ORG || '' }}",
        'export NOOP_HOMEBREW_FORGE=1',
        'SOURCE_VISIBILITY=$(gh api "repos/${GITHUB_REPOSITORY}"',
        'gh api "repos/${NOOP_HOMEBREW_TAP_ORG}/homebrew-noop"',
        'gh release download "$TAG"',
        'test "$(stat -c %s "$DOWNLOAD_DIR/$ZIP")" = "$SIZE"',
        'test "$APPLE_VERSION" = "$VERSION"',
        'test "$ANDROID_VERSION" = "$VERSION"',
        'Tools/update-homebrew-cask.sh "$VERSION" "$DOWNLOAD_DIR/$ZIP"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"Homebrew cask workflow lacks {item}")


def check_forgejo_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "forgejo-release.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("Forgejo release workflow is missing") from error
    required_text = (
        "actions: read",
        "workflow_call:",
        "workflow_dispatch:",
        'test "$GITHUB_REF" = "refs/heads/main"',
        "Tools/required-ci-gate.py verify-github",
        'git merge-base --is-ancestor "$RELEASE_SHA" "$GITHUB_SHA"',
        "FORGE_DOMAIN: ${{ vars.NOOP_FORGEJO_DOMAIN }}",
        "FORGE_ORG: ${{ vars.NOOP_FORGEJO_ORG }}",
        "FORGE_REPO: ${{ vars.NOOP_FORGEJO_REPO }}",
        "NOOP_FORGEJO_TOKEN: ${{ secrets.NOOP_FORGEJO_TOKEN }}",
        "timeout-minutes: 45",
        'gh release download "$TAG"',
        'test "$(stat -c %s "$DOWNLOAD_DIR/$asset")" = "$SIZE"',
        'sha256sum --check "NOOP-android-v${VERSION}.apk.sha256"',
        'test "$APPLE_VERSION" = "$VERSION"',
        'test "$ANDROID_VERSION" = "$VERSION"',
        'export FORGE_TARGET_COMMITISH="$RELEASE_SHA"',
        'Tools/forgejo-release.sh "$VERSION"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"Forgejo release workflow lacks {item}")
    helper_path = root / "Tools" / "forgejo-release.sh"
    try:
        helper = helper_path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("Forgejo release helper is missing") from error
    for item in (
        "Tools/forgejo-version-gate.py",
        'releases?limit=50&page=$page',
        "Forgejo release history exceeded the bounded page limit",
        "--max-filesize 10485760",
        'case "$REL_STATUS" in',
        "Forgejo release lookup returned an unexpected status",
        "--connect-timeout 10 --max-time 600",
        "--location -fsS --output",
        "Forgejo release asset set is not exact",
        '.type == "attachment"',
        "return_release_to_draft",
    ):
        if item not in helper:
            raise GateError(f"Forgejo release helper lacks {item}")
    gate = helper.index("Tools/forgejo-version-gate.py")
    for mutation in (
        'api -X POST "$API/repos/$ORG/$REPO/releases"',
        'api -X PATCH "$API/repos/$ORG/$REPO/releases/$REL_ID"',
    ):
        if gate >= helper.index(mutation):
            raise GateError(
                "Forgejo version gate must run before release mutation"
            )


def check_release_control_test_suite(root: Path) -> None:
    path = root / ".github" / "workflows" / "release-controls.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("release controls workflow is missing") from error
    required_modules = (
        "Tools.tests.test_forgejo_release_helper",
        "Tools.tests.test_forgejo_version_gate",
        "Tools.tests.test_github_release_publish",
        "Tools.tests.test_github_release_tag_gate",
        "Tools.tests.test_homebrew_helper",
        "Tools.tests.test_homebrew_version_gate",
        "Tools.tests.test_testing_release_workflow",
        "Tools.tests.test_trusted_release_controls",
    )
    for module in required_modules:
        if module not in text:
            raise GateError(
                f"release controls workflow does not run {module}"
            )
    for command in (
        "bash -n Tools/release.sh Tools/publish-testing-snapshot.sh",
        "shellcheck Tools/release.sh Tools/publish-testing-snapshot.sh",
    ):
        if command not in text:
            raise GateError(
                f"release controls workflow does not run {command}"
            )


def check_local_release_entrypoint(root: Path) -> None:
    path = root / "Tools" / "release.sh"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("local release dispatcher is missing") from error
    required_text = (
        '"$SOURCE_TREE/Tools/release-control-gate.py" check',
        '"$SOURCE_TREE/Tools/required-ci-gate.py"',
        '"$SOURCE_TREE/Tools/github-release-publish.py"',
        "verify-github",
        "--check-policy-only",
        '--protected-main-sha "$SOURCE_SHA"',
        'gh run watch "$RUN_ID"',
        "actions/runs/${RUN_ID}",
        'run.get("path") == ".github/workflows/release.yml"',
        'run.get("conclusion") == "success"',
        'LATEST_MAIN="$(git rev-parse origin/main)"',
        'if [ "$LATEST_MAIN" != "$SOURCE_SHA" ]',
        'git worktree add --quiet --detach "$SOURCE_TREE" "$SOURCE_SHA"',
        'python3 "$SOURCE_TREE/Tools/github-release-publish.py"',
        'check --root "$SOURCE_TREE"',
        'gh run download "$RUN_ID"',
        "production-release-candidate-${RUN_ID}-${RUN_ATTEMPT}",
        "git status --porcelain=v1 --untracked-files=normal",
        "git diff --quiet",
        "git diff --cached --quiet",
        "git fetch --quiet origin main --tags",
        'gh workflow run release.yml',
        "--ref main",
        '--field "release_sha=$SOURCE_SHA"',
        'gh workflow run homebrew-cask.yml',
        '--field "publish_forgejo=$PUBLISH_HOMEBREW_FORGEJO"',
        'gh workflow run forgejo-release.yml',
        '--tag "v${VERSION}"',
        '--expected-sha "$SOURCE_SHA"',
        '--manifest "$MANIFEST"',
        '--run-id "$RUN_ID"',
        '--run-attempt "$RUN_ATTEMPT"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"local release dispatcher lacks {item}")
    forbidden = (
        "gh release create",
        "gh release edit",
        "gh release upload",
        "update-altstore-source.sh",
        "git push",
    )
    for item in forbidden:
        if item in text:
            raise GateError(
                f"local release dispatcher retains direct publication: {item}"
            )
    _reject_owner_script_mutations(text, "local release dispatcher")
    if (root / "Tools" / "update-altstore-source.sh").exists():
        raise GateError("obsolete checked-in AltStore manifest mutator remains")
    _require_reviewed_source_digest(root, "Tools/release.sh")


def check_local_testing_entrypoint(root: Path) -> None:
    path = root / "Tools" / "publish-testing-snapshot.sh"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("local testing snapshot publisher is missing") from error
    required_text = (
        "^testing-snapshot-([0-9]+)-([0-9]+)$",
        "actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}",
        'run.get("path") == ".github/workflows/testing-build.yml"',
        'run.get("head_branch") == "main"',
        'run.get("display_title") == f"NOOP testing candidate @ {sha}"',
        'run.get("conclusion") == "success"',
        'if [ "$SOURCE_SHA" != "$TRUSTED_SHA" ]',
        'git status --porcelain=v1 --untracked-files=normal',
        'git worktree add --quiet --detach "$SOURCE_TREE" "$TRUSTED_SHA"',
        'if [ "$(git rev-parse origin/main)" != "$TRUSTED_SHA" ]',
        'python3 "$SOURCE_TREE/Tools/github-release-publish.py"',
        'check --root "$SOURCE_TREE"',
        'gh run download "$RUN_ID"',
        "testing-release-candidate-${RUN_ID}-${RUN_ATTEMPT}",
        '"$SOURCE_TREE/Tools/release-control-gate.py" check',
        '"$SOURCE_TREE/Tools/required-ci-gate.py"',
        '"$SOURCE_TREE/Tools/github-release-publish.py"',
        "--check-policy-only",
        "--testing-snapshot",
        "verify-github",
        '--sha "$TRUSTED_SHA"',
        '--protected-main-sha "$TRUSTED_SHA"',
        '--tag "$TAG"',
        '--expected-sha "$SOURCE_SHA"',
        '--manifest "$MANIFEST"',
        '--run-id "$RUN_ID"',
        '--run-attempt "$RUN_ATTEMPT"',
    )
    for item in required_text:
        if item not in text:
            raise GateError(f"local testing snapshot publisher lacks {item}")
    for forbidden in (
        "gh release create",
        "gh release edit",
        "gh release upload",
        "gh release delete",
    ):
        if forbidden in text:
            raise GateError(
                "local testing snapshot publisher bypasses the exact publisher"
            )
    _reject_owner_script_mutations(text, "local testing snapshot publisher")
    _require_reviewed_source_digest(
        root, "Tools/publish-testing-snapshot.sh"
    )


def check_repository(root: Path = ROOT, config_path: Path = DEFAULT_CONFIG) -> None:
    config = load_config(config_path)
    check_reviewed_release_sources(root)
    for workflow in config["universalWorkflows"]:
        check_universal_workflow(root, workflow)
    for workflow in config["workflows"]:
        check_workflow(root, workflow)
    check_required_context_ownership(root, config)
    check_trusted_release_workflow(root)
    check_release_workflow(root)
    check_testing_release_workflow(root)
    check_altstore_workflow(root)
    check_forgejo_workflow(root)
    check_homebrew_workflow(root)
    check_release_control_test_suite(root)
    check_local_release_entrypoint(root)
    check_local_testing_entrypoint(root)


def evaluate_check_runs(
    config: dict[str, Any], check_runs: list[dict[str, Any]]
) -> None:
    latest: dict[str, dict[str, Any]] = {}
    required_app_id = config["requiredCheckAppId"]
    expected_paths = required_workflow_paths(config)
    ownership_failures: set[str] = set()
    for run in check_runs:
        name = run.get("name")
        identifier = run.get("id")
        app = run.get("app")
        app_id = app.get("id") if isinstance(app, dict) else None
        if (
            not isinstance(name, str)
            or not isinstance(identifier, int)
            or app_id != required_app_id
        ):
            continue
        if name not in expected_paths:
            continue
        if (
            name == TRUSTED_CONTEXT
            and run.get("trustedScope") != "protected-main"
        ):
            continue
        if run.get("workflowPath") != expected_paths[name]:
            ownership_failures.add(f"{name}=unexpected-workflow")
            continue
        previous = latest.get(name)
        if previous is None or identifier > previous["id"]:
            latest[name] = run

    failures = sorted(ownership_failures)
    for context in config["requiredContexts"]:
        run = latest.get(context)
        if run is None:
            failures.append(f"{context}=missing")
            continue
        status = run.get("status")
        conclusion = run.get("conclusion")
        if status != "completed" or conclusion != "success":
            bounded_status = status if isinstance(status, str) else "unknown"
            bounded_conclusion = (
                conclusion if isinstance(conclusion, str) else "unknown"
            )
            failures.append(
                f"{context}={bounded_status}/{bounded_conclusion}"
            )
    if failures:
        raise GateError("required checks are not green: " + ", ".join(failures))


def _github_json(url: str, token: str, failure: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "noop-required-ci-gate",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        raise GateError(failure) from error


def _workflow_run_id(details_url: Any, repository: str) -> int:
    if not isinstance(details_url, str):
        raise GateError("required GitHub Actions check has no valid run URL")
    parsed = urllib.parse.urlsplit(details_url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.query
        or parsed.fragment
    ):
        raise GateError("required GitHub Actions check has no valid run URL")
    owner, name = repository.split("/", 1)
    pattern = re.compile(
        rf"/{re.escape(owner)}/{re.escape(name)}"
        r"/actions/runs/([1-9][0-9]*)/job/[1-9][0-9]*",
        re.IGNORECASE,
    )
    match = pattern.fullmatch(parsed.path)
    if match is None:
        raise GateError("required GitHub Actions check has no valid run URL")
    return int(match.group(1))


def _trusted_workflow_run_identity(
    check_run: dict[str, Any],
    repository: str,
    expected_sha: str,
) -> tuple[str, int, int]:
    external_id = check_run.get("external_id")
    match = (
        TRUSTED_EXTERNAL_ID.fullmatch(external_id)
        if isinstance(external_id, str)
        else None
    )
    if match is None or match.group(4) != expected_sha:
        raise GateError("trusted exact-head check identity is invalid")
    details_url = check_run.get("details_url")
    if not isinstance(details_url, str):
        raise GateError("trusted exact-head check has no valid run URL")
    parsed = urllib.parse.urlsplit(details_url)
    owner, name = repository.split("/", 1)
    actions_pattern = re.compile(
        rf"/{re.escape(owner)}/{re.escape(name)}"
        r"/actions/runs/([1-9][0-9]*)",
        re.IGNORECASE,
    )
    check_pattern = re.compile(
        rf"/{re.escape(owner)}/{re.escape(name)}"
        r"/runs/([1-9][0-9]*)",
        re.IGNORECASE,
    )
    actions_match = actions_pattern.fullmatch(parsed.path)
    check_match = check_pattern.fullmatch(parsed.path)
    scope = match.group(1)
    run_id = int(match.group(2))
    check_id = check_run.get("id")
    valid_check_id = (
        isinstance(check_id, int)
        and not isinstance(check_id, bool)
        and check_id > 0
    )
    valid_path = (
        actions_match is not None
        and int(actions_match.group(1)) == run_id
    ) or (
        check_match is not None
        and valid_check_id
        and int(check_match.group(1)) == check_id
    )
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.query
        or parsed.fragment
        or not valid_path
    ):
        raise GateError("trusted exact-head check has no valid run URL")
    return scope, run_id, int(match.group(3))


def _workflow_path_from_run(
    payload: Any, run_id: int, expected_sha: str
) -> str:
    if (
        not isinstance(payload, dict)
        or payload.get("id") != run_id
        or payload.get("head_sha") != expected_sha
        or not isinstance(payload.get("path"), str)
        or not payload["path"]
    ):
        raise GateError("GitHub Actions workflow run identity is invalid")
    return payload["path"]


def _workflow_path_from_trusted_run(
    payload: Any,
    *,
    scope: str,
    run_id: int,
    run_attempt: int,
    repository: str,
    expected_sha: str,
) -> str:
    head_repository = (
        payload.get("head_repository") if isinstance(payload, dict) else None
    )
    expected_event = (
        "pull_request_target" if scope == "pull-request" else "push"
    )
    if (
        not isinstance(payload, dict)
        or payload.get("id") != run_id
        or payload.get("run_attempt") != run_attempt
        or payload.get("event") != expected_event
        or payload.get("status") != "completed"
        or payload.get("path") != TRUSTED_WORKFLOW_PATH
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != repository
        or (
            scope == "protected-main"
            and payload.get("head_sha") != expected_sha
        )
    ):
        raise GateError("trusted GitHub Actions workflow run identity is invalid")
    return TRUSTED_WORKFLOW_PATH


def fetch_check_runs(
    repository: str,
    sha: str,
    token: str,
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    if SAFE_REPOSITORY.fullmatch(repository) is None:
        raise GateError("repository must be owner/name")
    if SAFE_SHA.fullmatch(sha) is None:
        raise GateError("release SHA must be a full lowercase commit SHA")
    if not token:
        raise GateError("GitHub token is unavailable")

    check_runs: list[dict[str, Any]] = []
    workflow_runs: dict[tuple[int, str, int], str] = {}
    required_contexts = set(config["requiredContexts"])
    required_app_id = config["requiredCheckAppId"]
    for page in range(1, 11):
        query = urllib.parse.urlencode({"per_page": 100, "page": page})
        url = (
            f"https://api.github.com/repos/{repository}/commits/{sha}/check-runs"
            f"?{query}"
        )
        payload = _github_json(url, token, "GitHub check-runs query failed")
        page_runs = payload.get("check_runs") if isinstance(payload, dict) else None
        if not isinstance(page_runs, list):
            raise GateError("GitHub check-runs response is invalid")
        for run in page_runs:
            if not isinstance(run, dict):
                raise GateError("GitHub check-runs response is invalid")
            app = run.get("app")
            app_id = app.get("id") if isinstance(app, dict) else None
            if (
                run.get("name") in required_contexts
                and app_id == required_app_id
            ):
                external_id = run.get("external_id")
                if run.get("name") == TRUSTED_CONTEXT and isinstance(
                    external_id, str
                ) and external_id.startswith(f"{TRUSTED_CONTEXT}:"):
                    scope, run_id, run_attempt = (
                        _trusted_workflow_run_identity(
                            run, repository, sha
                        )
                    )
                    cache_key = (run_id, scope, run_attempt)
                else:
                    run_id = _workflow_run_id(
                        run.get("details_url"), repository
                    )
                    run_attempt = 0
                    cache_key = (run_id, "native", run_attempt)
                if cache_key not in workflow_runs:
                    if len(workflow_runs) >= 100:
                        raise GateError(
                            "required workflow runs exceeded the bounded limit"
                        )
                    run_url = (
                        f"https://api.github.com/repos/{repository}"
                        f"/actions/runs/{run_id}"
                    )
                    run_payload = _github_json(
                        run_url,
                        token,
                        "GitHub Actions workflow-run query failed",
                    )
                    if cache_key[1] in {"pull-request", "protected-main"}:
                        workflow_runs[cache_key] = (
                            _workflow_path_from_trusted_run(
                                run_payload,
                                scope=cache_key[1],
                                run_id=run_id,
                                run_attempt=run_attempt,
                                repository=repository,
                                expected_sha=sha,
                            )
                        )
                    else:
                        workflow_runs[cache_key] = _workflow_path_from_run(
                            run_payload, run_id, sha
                        )
                run = dict(run)
                run["workflowPath"] = workflow_runs[cache_key]
                if cache_key[1] in {"pull-request", "protected-main"}:
                    run["trustedScope"] = cache_key[1]
            check_runs.append(run)
        if len(page_runs) < 100:
            return check_runs
    raise GateError("GitHub check-runs response exceeded the bounded page limit")


def command_check(args: argparse.Namespace) -> None:
    check_repository(Path(args.root).resolve(), Path(args.config).resolve())
    config = load_config(Path(args.config).resolve())
    print(
        "required-ci: "
        f"{len(config['workflows'])} conditional workflows, "
        f"{len(config['universalWorkflows'])} universal workflows, "
        f"{len(config['requiredContexts'])} contexts verified"
    )


def command_verify_github(args: argparse.Namespace) -> None:
    config = load_config(Path(args.config).resolve())
    token = os.environ.get(args.token_env, "")
    runs = fetch_check_runs(args.repository, args.sha, token, config)
    evaluate_check_runs(config, runs)
    print(
        "required-ci: "
        f"{len(config['requiredContexts'])}/"
        f"{len(config['requiredContexts'])} exact-SHA checks passed"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--config", default=str(DEFAULT_CONFIG))
    subparsers = result.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check")
    check.add_argument("--root", default=str(ROOT))
    check.set_defaults(handler=command_check)

    verify = subparsers.add_parser("verify-github")
    verify.add_argument("--repository", required=True)
    verify.add_argument("--sha", required=True)
    verify.add_argument("--token-env", default="GH_TOKEN")
    verify.set_defaults(handler=command_verify_github)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except GateError as error:
        print(f"required-ci: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
