#!/usr/bin/env python3
"""Validate required CI workflows and exact-SHA GitHub check results."""

from __future__ import annotations

import argparse
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


class GateError(RuntimeError):
    """A required CI invariant is absent or invalid."""


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
        raise GateError("required CI config fields do not match schema version 1")
    if config["schemaVersion"] != 1 or config["sourceBranch"] != "main":
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
    for event in ("pull_request", "push"):
        if re.search(rf"^  {event}:", before_jobs, re.MULTILINE) is None:
            raise GateError(f"{workflow['path']} must run for {event}")
    if re.search(r"^\s+paths(?:-ignore)?:", before_jobs, re.MULTILINE):
        raise GateError(
            f"{workflow['path']} universal check cannot use event-level path filters"
        )
    required_job = workflow["requiredJob"]
    section = _job_section(text, required_job)
    if f"name: {required_job}" not in section:
        raise GateError(
            f"{workflow['path']} universal job lacks stable name {required_job}"
        )


def check_release_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "release.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("release workflow is missing") from error
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
        "--release-sha \"$GITHUB_SHA\"",
        "--sha \"$GITHUB_SHA\"",
        "git diff --exit-code",
        "uses: ./.github/workflows/altstore-source.yml",
        "uses: ./.github/workflows/forgejo-release.yml",
        "uses: ./.github/workflows/homebrew-cask.yml",
        "publish_forgejo:",
        "publish_homebrew:",
        "publish_homebrew_forgejo:",
        "The Homebrew Forgejo mirror requires Homebrew publication.",
        "if: ${{ inputs.publish_forgejo }}",
        "if: ${{ inputs.publish_homebrew }}",
        "Reverify required checks before publication",
        "--sha \"$RELEASE_SHA\"",
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
            "release workflow must verify exact-SHA checks before draft and publish"
        )
    if re.search(
        r"git\s+push[^\n]*(?:HEAD:)?(?:refs/heads/)?main(?:[\s\"']|$)",
        text,
    ):
        raise GateError("release workflow cannot push directly to main")
    for job_id in ("altstore", "homebrew", "forgejo"):
        section = _job_section(text, job_id)
        if "actions: read" not in section:
            raise GateError(
                f"release workflow job {job_id} cannot inspect workflow runs"
            )
    homebrew = _job_section(text, "homebrew")
    forgejo = _job_section(text, "forgejo")
    for item in (
        "NOOP_HOMEBREW_TAP_TOKEN: ${{ secrets.NOOP_HOMEBREW_TAP_TOKEN }}",
        "NOOP_HOMEBREW_FORGE_TOKEN: ${{ "
        "inputs.publish_homebrew_forgejo && "
        "secrets.NOOP_HOMEBREW_FORGE_TOKEN || '' }}",
    ):
        if item not in homebrew:
            raise GateError(f"Homebrew release job lacks scoped secret {item}")
    if "NOOP_FORGEJO_TOKEN: ${{ secrets.NOOP_FORGEJO_TOKEN }}" not in forgejo:
        raise GateError("Forgejo release job lacks its scoped write secret")
    if "secrets: inherit" in homebrew or "secrets: inherit" in forgejo:
        raise GateError("release mirror jobs cannot inherit unrelated secrets")


def check_altstore_workflow(root: Path) -> None:
    path = root / ".github" / "workflows" / "altstore-source.yml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("AltStore source workflow is missing") from error
    required_text = (
        "actions: read",
        "workflow_call:",
        "workflow_dispatch:",
        'test "$GITHUB_REF" = "refs/heads/main"',
        "Tools/required-ci-gate.py verify-github",
        'git merge-base --is-ancestor "$RELEASE_SHA" "$GITHUB_SHA"',
        "Tools/altstore-source.py update",
        "releases/download/${CHANNEL_TAG}/altstore-source.json",
        "gh release upload \"$CHANNEL_TAG\" \"$MANIFEST\"",
        "curl --fail --silent --show-error --location",
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
        "Tools.tests.test_homebrew_helper",
        "Tools.tests.test_homebrew_version_gate",
    )
    for module in required_modules:
        if module not in text:
            raise GateError(
                f"release controls workflow does not run {module}"
            )


def check_local_release_entrypoint(root: Path) -> None:
    path = root / "Tools" / "release.sh"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError("local release dispatcher is missing") from error
    required_text = (
        "Tools/release-control-gate.py check",
        "Tools/required-ci-gate.py verify-github",
        "git status --porcelain=v1 --untracked-files=normal",
        "git diff --quiet",
        "git diff --cached --quiet",
        "git fetch --quiet origin main --tags",
        'gh workflow run release.yml',
        "--ref main",
        '--field "release_sha=$SOURCE_SHA"',
        '--field "publish_forgejo=$PUBLISH_FORGEJO"',
        '--field "publish_homebrew=$PUBLISH_HOMEBREW"',
        '--field "publish_homebrew_forgejo=$PUBLISH_HOMEBREW_FORGEJO"',
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
    if (root / "Tools" / "update-altstore-source.sh").exists():
        raise GateError("obsolete checked-in AltStore manifest mutator remains")


def check_repository(root: Path = ROOT, config_path: Path = DEFAULT_CONFIG) -> None:
    config = load_config(config_path)
    for workflow in config["universalWorkflows"]:
        check_universal_workflow(root, workflow)
    for workflow in config["workflows"]:
        check_workflow(root, workflow)
    check_required_context_ownership(root, config)
    check_release_workflow(root)
    check_altstore_workflow(root)
    check_forgejo_workflow(root)
    check_homebrew_workflow(root)
    check_release_control_test_suite(root)
    check_local_release_entrypoint(root)


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
    workflow_runs: dict[int, str] = {}
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
                run_id = _workflow_run_id(run.get("details_url"), repository)
                if run_id not in workflow_runs:
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
                    workflow_runs[run_id] = _workflow_path_from_run(
                        run_payload, run_id, sha
                    )
                run = dict(run)
                run["workflowPath"] = workflow_runs[run_id]
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
