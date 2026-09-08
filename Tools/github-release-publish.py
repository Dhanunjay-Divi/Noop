#!/usr/bin/env python3
"""Publish one reviewed GitHub release under immutable repository controls."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any


SAFE_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_TESTING_TAG = re.compile(r"^testing-snapshot-[0-9]+-[0-9]+$")
SAFE_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_SHA = re.compile(r"^[0-9a-f]{40}$")
SAFE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_BODY_DIGEST = re.compile(r"^[0-9a-f]{64}$")
MAX_RESPONSE_BYTES = 10 * 1024 * 1024
MAX_MANIFEST_BYTES = 64 * 1024
MAX_POLICY_BYTES = 64 * 1024
MANIFEST_SCHEMA_VERSION = 1
GITHUB_ACTIONS_APP_ID = 15368
TRUSTED_CONTEXT = "trusted-release-controls"
POLICY_RULESET_NAME = "Immutable production release tags"
POLICY_CREATION_RULESET_NAME = "Owner-only production release tag creation"
POLICY_TAG_PATTERN = "refs/tags/v*"
TESTING_POLICY_RULESET_NAME = "Stable testing snapshot targets"
TESTING_POLICY_CREATION_RULESET_NAME = (
    "Owner-only testing snapshot tag creation"
)
TESTING_POLICY_TAG_PATTERN = "refs/tags/testing-snapshot-*"
ADMIN_BYPASS_ACTOR = {
    "actor_id": 5,
    "actor_type": "RepositoryRole",
    "bypass_mode": "always",
}

TAG_GATE_PATH = Path(__file__).with_name("github-release-tag-gate.py")
REQUIRED_CI_PATH = Path(__file__).resolve().parent.parent / "release" / "required-ci.json"
TAG_GATE_SPEC = importlib.util.spec_from_file_location(
    "github_release_tag_gate", TAG_GATE_PATH
)
if TAG_GATE_SPEC is None or TAG_GATE_SPEC.loader is None:
    raise RuntimeError("release tag gate cannot be loaded")
TAG_GATE = importlib.util.module_from_spec(TAG_GATE_SPEC)
TAG_GATE_SPEC.loader.exec_module(TAG_GATE)


class PublishError(RuntimeError):
    """The reviewed release cannot be published safely."""


def load_release_activation_contract(
    path: Path = REQUIRED_CI_PATH,
) -> tuple[int, list[str]]:
    try:
        if path.is_symlink() or not path.is_file():
            raise PublishError("release activation contract is unavailable")
        data = path.read_bytes()
    except OSError as error:
        raise PublishError("release activation contract is unavailable") from error
    if not data or len(data) > MAX_POLICY_BYTES:
        raise PublishError("release activation contract size is invalid")
    try:
        payload = json.loads(data)
    except json.JSONDecodeError as error:
        raise PublishError("release activation contract is invalid JSON") from error
    if not isinstance(payload, dict):
        raise PublishError("release activation contract is invalid")
    contexts = payload.get("requiredContexts")
    universal = payload.get("universalWorkflows")
    app_id = payload.get("requiredCheckAppId")
    if (
        payload.get("schemaVersion") != 2
        or payload.get("sourceBranch") != "main"
        or app_id != GITHUB_ACTIONS_APP_ID
        or not isinstance(contexts, list)
        or contexts != sorted(set(contexts))
        or TRUSTED_CONTEXT not in contexts
        or not isinstance(universal, list)
    ):
        raise PublishError(
            "trusted release-control activation is not complete"
        )
    trusted = [
        item
        for item in universal
        if isinstance(item, dict)
        and item.get("requiredJob") == TRUSTED_CONTEXT
    ]
    if trusted != [
        {
            "path": ".github/workflows/trusted-release-controls.yml",
            "pullRequestEvent": "pull_request_target",
            "requiredJob": TRUSTED_CONTEXT,
        }
    ]:
        raise PublishError(
            "trusted release-control activation is not complete"
        )
    return app_id, contexts


class GitHubClient:
    def __init__(self, token: str) -> None:
        if not token:
            raise PublishError("GitHub token is unavailable")
        self.token = token

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        payload: dict[str, Any] | None = None,
    ) -> Any:
        body = None
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "noop-release-publisher",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"https://api.github.com{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                response_body = response.read(MAX_RESPONSE_BYTES + 1)
        except (OSError, urllib.error.HTTPError) as error:
            raise PublishError("GitHub release operation failed") from error
        if len(response_body) > MAX_RESPONSE_BYTES:
            raise PublishError("GitHub response exceeded the size limit")
        try:
            return json.loads(response_body)
        except json.JSONDecodeError as error:
            raise PublishError("GitHub response is invalid") from error


def expected_asset_names(version: str) -> list[str]:
    return sorted(
        [
            f"NOOP-android-v{version}.apk",
            f"NOOP-android-v{version}.apk.sha256",
            f"NOOP-android-v{version}.cdx.json",
            f"NOOP-macos-v{version}.zip",
            f"NOOP-ios-unsigned-v{version}.ipa",
        ]
    )


def _release_id(payload: Any) -> int:
    if not isinstance(payload, dict):
        raise PublishError("GitHub release response is invalid")
    release_id = payload.get("id")
    if (
        not isinstance(release_id, int)
        or isinstance(release_id, bool)
        or release_id <= 0
    ):
        raise PublishError("GitHub release identity is invalid")
    return release_id


def release_asset_records(payload: Any, version: str) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        raise PublishError("GitHub release response is invalid")
    assets = payload.get("assets")
    if not isinstance(assets, list):
        raise PublishError("GitHub release asset inventory is invalid")
    records: list[dict[str, Any]] = []
    for asset in assets:
        if not isinstance(asset, dict):
            raise PublishError("GitHub release asset inventory is invalid")
        asset_id = asset.get("id")
        name = asset.get("name")
        size = asset.get("size")
        state = asset.get("state")
        digest = asset.get("digest")
        if (
            not isinstance(asset_id, int)
            or isinstance(asset_id, bool)
            or asset_id <= 0
            or not isinstance(name, str)
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
            or state != "uploaded"
            or not isinstance(digest, str)
            or SAFE_DIGEST.fullmatch(digest) is None
        ):
            raise PublishError("GitHub release asset inventory is invalid")
        records.append(
            {
                "id": asset_id,
                "name": name,
                "size": size,
                "digest": digest,
            }
        )
    records.sort(key=lambda item: item["name"])
    if [item["name"] for item in records] != expected_asset_names(version):
        raise PublishError("GitHub release asset set is not exact")
    if len({item["id"] for item in records}) != len(records):
        raise PublishError("GitHub release asset identity is not unique")
    return records


def release_metadata(payload: Any) -> dict[str, str]:
    if not isinstance(payload, dict):
        raise PublishError("GitHub release response is invalid")
    name = payload.get("name")
    body = payload.get("body")
    target = payload.get("target_commitish")
    if (
        not isinstance(name, str)
        or not name
        or not isinstance(body, str)
        or not isinstance(target, str)
        or SAFE_SHA.fullmatch(target) is None
    ):
        raise PublishError("GitHub release metadata is invalid")
    return {
        "name": name,
        "bodySha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
        "targetCommitish": target,
    }


def verify_release(
    payload: Any,
    *,
    tag: str,
    version: str,
    draft: bool,
    prerelease: bool = False,
    release_id: int | None = None,
    require_immutable: bool = False,
    expected_assets: list[dict[str, Any]] | None = None,
    expected_metadata: dict[str, str] | None = None,
) -> int:
    actual_id = _release_id(payload)
    if release_id is not None and actual_id != release_id:
        raise PublishError("GitHub release identity changed")
    if (
        payload.get("tag_name") != tag
        or payload.get("draft") is not draft
        or payload.get("prerelease") is not prerelease
    ):
        raise PublishError("GitHub release state is invalid")
    if require_immutable and payload.get("immutable") is not True:
        raise PublishError("published GitHub release is not immutable")
    actual_assets = release_asset_records(payload, version)
    if expected_assets is not None and actual_assets != expected_assets:
        raise PublishError("GitHub release asset identity or digest changed")
    actual_metadata = release_metadata(payload)
    if expected_metadata is not None and actual_metadata != expected_metadata:
        raise PublishError("GitHub release metadata changed")
    return actual_id


def _validate_run_identity(run_id: int, run_attempt: int) -> None:
    if (
        not isinstance(run_id, int)
        or isinstance(run_id, bool)
        or run_id <= 0
        or not isinstance(run_attempt, int)
        or isinstance(run_attempt, bool)
        or run_attempt <= 0
    ):
        raise PublishError("workflow run identity is invalid")


def _validate_testing_run_tag(tag: str, run_id: int, run_attempt: int) -> None:
    _validate_run_identity(run_id, run_attempt)
    if tag != f"testing-snapshot-{run_id}-{run_attempt}":
        raise PublishError("testing tag does not match the workflow run")


def create_candidate_manifest(
    payload: Any,
    *,
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    run_id: int,
    run_attempt: int,
    prerelease: bool,
) -> dict[str, Any]:
    _validate_run_identity(run_id, run_attempt)
    if prerelease:
        _validate_testing_run_tag(tag, run_id, run_attempt)
    release_id = verify_release(
        payload,
        tag=tag,
        version=version,
        draft=True,
        prerelease=prerelease,
    )
    metadata = release_metadata(payload)
    return {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "repository": repository,
        "tag": tag,
        "version": version,
        "expectedSha": expected_sha,
        "runId": run_id,
        "runAttempt": run_attempt,
        "releaseId": release_id,
        "prerelease": prerelease,
        "assets": release_asset_records(payload, version),
        **metadata,
    }


def validate_candidate_manifest(
    payload: Any,
    *,
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    run_id: int,
    run_attempt: int,
    prerelease: bool,
) -> tuple[int, list[dict[str, Any]], dict[str, str]]:
    _validate_run_identity(run_id, run_attempt)
    if prerelease:
        _validate_testing_run_tag(tag, run_id, run_attempt)
    required_keys = {
        "schemaVersion",
        "repository",
        "tag",
        "version",
        "expectedSha",
        "runId",
        "runAttempt",
        "releaseId",
        "prerelease",
        "assets",
        "name",
        "bodySha256",
        "targetCommitish",
    }
    if not isinstance(payload, dict) or set(payload) != required_keys:
        raise PublishError("release candidate manifest schema is invalid")
    if (
        payload.get("schemaVersion") != MANIFEST_SCHEMA_VERSION
        or payload.get("repository") != repository
        or payload.get("tag") != tag
        or payload.get("version") != version
        or payload.get("expectedSha") != expected_sha
        or payload.get("runId") != run_id
        or payload.get("runAttempt") != run_attempt
        or payload.get("prerelease") is not prerelease
    ):
        raise PublishError("release candidate manifest identity is invalid")
    release_id = payload.get("releaseId")
    if (
        not isinstance(release_id, int)
        or isinstance(release_id, bool)
        or release_id <= 0
    ):
        raise PublishError("release candidate manifest identity is invalid")
    assets = payload.get("assets")
    if not isinstance(assets, list):
        raise PublishError("release candidate manifest assets are invalid")
    expected_asset_keys = {"id", "name", "size", "digest"}
    for asset in assets:
        if (
            not isinstance(asset, dict)
            or set(asset) != expected_asset_keys
            or not isinstance(asset.get("id"), int)
            or isinstance(asset.get("id"), bool)
            or asset["id"] <= 0
            or not isinstance(asset.get("name"), str)
            or not isinstance(asset.get("size"), int)
            or isinstance(asset.get("size"), bool)
            or asset["size"] <= 0
            or not isinstance(asset.get("digest"), str)
            or SAFE_DIGEST.fullmatch(asset["digest"]) is None
        ):
            raise PublishError("release candidate manifest assets are invalid")
    if assets != sorted(assets, key=lambda item: item["name"]):
        raise PublishError("release candidate manifest assets are not canonical")
    if [asset["name"] for asset in assets] != expected_asset_names(version):
        raise PublishError("release candidate manifest asset set is not exact")
    if len({asset["id"] for asset in assets}) != len(assets):
        raise PublishError("release candidate manifest asset identity is not unique")
    metadata = {
        "name": payload.get("name"),
        "bodySha256": payload.get("bodySha256"),
        "targetCommitish": payload.get("targetCommitish"),
    }
    if (
        not isinstance(metadata["name"], str)
        or not metadata["name"]
        or not isinstance(metadata["bodySha256"], str)
        or SAFE_BODY_DIGEST.fullmatch(metadata["bodySha256"]) is None
        or not isinstance(metadata["targetCommitish"], str)
        or metadata["targetCommitish"] != expected_sha
    ):
        raise PublishError("release candidate manifest metadata is invalid")
    return release_id, assets, metadata


def load_candidate_manifest(
    path: Path,
    **identity: Any,
) -> tuple[int, list[dict[str, Any]], dict[str, str]]:
    try:
        if path.is_symlink() or not path.is_file():
            raise PublishError("release candidate manifest is not a regular file")
        data = path.read_bytes()
    except OSError as error:
        raise PublishError("release candidate manifest cannot be read") from error
    if not data or len(data) > MAX_MANIFEST_BYTES:
        raise PublishError("release candidate manifest size is invalid")
    try:
        payload = json.loads(data)
    except json.JSONDecodeError as error:
        raise PublishError("release candidate manifest is invalid JSON") from error
    return validate_candidate_manifest(payload, **identity)


def verify_repository_policy(
    client: Any,
    repository: str,
    *,
    testing_snapshot: bool = False,
    activation_contract: tuple[int, list[str]] | None = None,
    protected_main_sha: str | None = None,
) -> None:
    required_app_id, required_contexts = (
        activation_contract
        if activation_contract is not None
        else load_release_activation_contract()
    )
    if protected_main_sha is not None:
        if SAFE_SHA.fullmatch(protected_main_sha) is None:
            raise PublishError("protected main SHA is invalid")
        main_ref = client.request(
            f"/repos/{repository}/git/ref/heads/main"
        )
        main_object = (
            main_ref.get("object") if isinstance(main_ref, dict) else None
        )
        if (
            not isinstance(main_ref, dict)
            or main_ref.get("ref") != "refs/heads/main"
            or not isinstance(main_object, dict)
            or main_object.get("type") != "commit"
            or main_object.get("sha") != protected_main_sha
        ):
            raise PublishError(
                "protected main advanced from the reviewed publisher source"
            )
    branch = client.request(
        f"/repos/{repository}/branches/main/protection/required_status_checks"
    )
    checks = branch.get("checks") if isinstance(branch, dict) else None
    contexts = branch.get("contexts") if isinstance(branch, dict) else None
    if (
        not isinstance(branch, dict)
        or branch.get("strict") is not True
        or not isinstance(checks, list)
        or not isinstance(contexts, list)
        or len(contexts) != len(required_contexts)
        or sorted(contexts) != required_contexts
        or len(checks) != len(required_contexts)
        or any(
            not isinstance(check, dict)
            or set(check) != {"app_id", "context"}
            or check.get("app_id") != required_app_id
            or check.get("context") not in required_contexts
            for check in checks
        )
        or {check["context"] for check in checks} != set(required_contexts)
    ):
        raise PublishError(
            "protected main does not enforce the exact release checks"
        )
    owner = repository.split("/", 1)[0]
    actor = client.request("/user")
    if (
        not isinstance(actor, dict)
        or actor.get("login") != owner
        or actor.get("type") != "User"
    ):
        raise PublishError(
            "release publisher is not the repository owner"
        )
    collaborators = client.request(
        f"/repos/{repository}/collaborators?affiliation=all&per_page=100"
    )
    if not isinstance(collaborators, list) or len(collaborators) >= 100:
        raise PublishError(
            "repository collaborator inventory is invalid or ambiguous"
        )
    owner_is_admin = False
    for collaborator in collaborators:
        permissions = (
            collaborator.get("permissions")
            if isinstance(collaborator, dict)
            else None
        )
        login = collaborator.get("login") if isinstance(collaborator, dict) else None
        if (
            not isinstance(login, str)
            or not login
            or not isinstance(permissions, dict)
            or any(
                not isinstance(permissions.get(key), bool)
                for key in ("admin", "maintain", "push")
            )
        ):
            raise PublishError(
                "repository collaborator inventory is invalid or ambiguous"
            )
        can_write = any(
            permissions[key] for key in ("admin", "maintain", "push")
        )
        if login == owner:
            owner_is_admin = permissions["admin"]
        elif can_write:
            raise PublishError(
                "release publication requires the owner to be the only writer"
            )
    if not owner_is_admin:
        raise PublishError(
            "repository owner is not the exclusive release administrator"
        )
    ruleset_name = (
        TESTING_POLICY_RULESET_NAME
        if testing_snapshot
        else POLICY_RULESET_NAME
    )
    creation_ruleset_name = (
        TESTING_POLICY_CREATION_RULESET_NAME
        if testing_snapshot
        else POLICY_CREATION_RULESET_NAME
    )
    tag_pattern = (
        TESTING_POLICY_TAG_PATTERN
        if testing_snapshot
        else POLICY_TAG_PATTERN
    )
    required_rule_types = {"update", "deletion"}
    immutable = client.request(f"/repos/{repository}/immutable-releases")
    if not isinstance(immutable, dict) or immutable.get("enabled") is not True:
        raise PublishError("immutable GitHub releases are not enabled")

    summaries = client.request(
        f"/repos/{repository}/rulesets?per_page=100"
    )
    if not isinstance(summaries, list):
        raise PublishError("GitHub release tag ruleset inventory is invalid")
    if len(summaries) >= 100:
        raise PublishError("GitHub release tag ruleset inventory is ambiguous")
    matching_ids: dict[str, list[int]] = {
        ruleset_name: [],
        creation_ruleset_name: [],
    }
    for summary in summaries:
        if not isinstance(summary, dict):
            raise PublishError("GitHub release tag ruleset inventory is invalid")
        if (
            summary.get("name") in matching_ids
            and summary.get("target") == "tag"
            and summary.get("enforcement") == "active"
        ):
            ruleset_id = summary.get("id")
            if (
                not isinstance(ruleset_id, int)
                or isinstance(ruleset_id, bool)
                or ruleset_id <= 0
            ):
                raise PublishError("GitHub release tag ruleset identity is invalid")
            matching_ids[summary["name"]].append(ruleset_id)
    if any(len(ids) != 1 for ids in matching_ids.values()):
        raise PublishError(
            "exactly one active immutable and creation tag ruleset is required"
        )

    ruleset_contracts = (
        (
            ruleset_name,
            required_rule_types,
            [],
            "never",
            "immutable",
        ),
        (
            creation_ruleset_name,
            {"creation"},
            [ADMIN_BYPASS_ACTOR],
            "always",
            "creation",
        ),
    )
    for (
        expected_name,
        expected_rule_types,
        expected_bypass,
        expected_current_bypass,
        purpose,
    ) in ruleset_contracts:
        detail = client.request(
            f"/repos/{repository}/rulesets/{matching_ids[expected_name][0]}"
        )
        if not isinstance(detail, dict):
            raise PublishError("GitHub release tag ruleset is invalid")
        conditions = detail.get("conditions")
        ref_name = (
            conditions.get("ref_name")
            if isinstance(conditions, dict)
            else None
        )
        rules = detail.get("rules")
        if (
            detail.get("name") != expected_name
            or detail.get("target") != "tag"
            or detail.get("enforcement") != "active"
            or detail.get("source_type") != "Repository"
            or detail.get("source") != repository
            or detail.get("bypass_actors") != expected_bypass
            or detail.get("current_user_can_bypass")
            != expected_current_bypass
            or not isinstance(ref_name, dict)
            or ref_name.get("include") != [tag_pattern]
            or ref_name.get("exclude") != []
            or not isinstance(rules, list)
        ):
            raise PublishError(
                f"GitHub release tag {purpose} ruleset is not fail closed"
            )
        if (
            len(rules) != len(expected_rule_types)
            or any(
                not isinstance(rule, dict)
                or set(rule) != {"type"}
                or rule.get("type") not in expected_rule_types
                for rule in rules
            )
            or {rule["type"] for rule in rules}
            != expected_rule_types
        ):
            raise PublishError(
                f"GitHub release tag {purpose} ruleset lacks exact controls"
            )


def _confirm_published_release(
    client: Any,
    path: str,
    *,
    tag: str,
    version: str,
    prerelease: bool,
    release_id: int,
    expected_assets: list[dict[str, Any]],
    expected_metadata: dict[str, str],
    attempts: int = 3,
    sleeper: Callable[[float], None] = time.sleep,
) -> Any:
    last_error: PublishError | None = None
    for attempt in range(attempts):
        try:
            payload = client.request(path)
            verify_release(
                payload,
                tag=tag,
                version=version,
                draft=False,
                prerelease=prerelease,
                release_id=release_id,
                require_immutable=True,
                expected_assets=expected_assets,
                expected_metadata=expected_metadata,
            )
            return payload
        except PublishError as error:
            last_error = error
            if attempt + 1 < attempts:
                sleeper(1.0)
    detail = str(last_error) if last_error is not None else "unknown state"
    raise PublishError(
        f"published GitHub release state could not be confirmed: {detail}"
    ) from last_error


def _publish_exact_release(
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    token: str,
    *,
    prerelease: bool,
    client: Any | None = None,
    tag_verifier: Callable[[], None] | None = None,
    tag_absence_verifier: Callable[[], None] | None = None,
    policy_verifier: Callable[[], None] | None = None,
    expected_release_id: int,
    expected_assets: list[dict[str, Any]],
    expected_metadata: dict[str, str],
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    if not token:
        raise PublishError("GitHub token is unavailable")

    api = client or GitHubClient(token)
    verify_tag = tag_verifier or (
        lambda: TAG_GATE.verify_remote_tag(
            repository,
            tag,
            expected_sha,
            token,
            fetcher=lambda path: api.request(path),
            testing_snapshot=prerelease,
        )
    )
    verify_tag_absent = tag_absence_verifier or (
        lambda: TAG_GATE.verify_remote_tag_absent(
            repository,
            tag,
            token,
            testing_snapshot=prerelease,
        )
    )

    encoded_tag = urllib.parse.quote(tag, safe="")
    draft_payload = api.request(
        f"/repos/{repository}/releases/tags/{encoded_tag}"
    )
    if not isinstance(draft_payload, dict):
        raise PublishError("GitHub release response is invalid")
    if draft_payload.get("draft") is False:
        release_id = verify_release(
            draft_payload,
            tag=tag,
            version=version,
            draft=False,
            prerelease=prerelease,
            release_id=expected_release_id,
            require_immutable=True,
            expected_assets=expected_assets,
            expected_metadata=expected_metadata,
        )
        try:
            verify_tag()
        except TAG_GATE.GateError as error:
            raise PublishError(str(error)) from error
        if policy_verifier is not None:
            policy_verifier()
        _confirm_published_release(
            api,
            f"/repos/{repository}/releases/{release_id}",
            tag=tag,
            version=version,
            prerelease=prerelease,
            release_id=release_id,
            expected_assets=expected_assets,
            expected_metadata=expected_metadata,
            sleeper=sleeper,
        )
        if policy_verifier is not None:
            policy_verifier()
        return

    release_id = verify_release(
        draft_payload,
        tag=tag,
        version=version,
        draft=True,
        prerelease=prerelease,
        release_id=expected_release_id,
        expected_assets=expected_assets,
        expected_metadata=expected_metadata,
    )
    try:
        verify_tag_absent()
    except TAG_GATE.GateError as error:
        raise PublishError(str(error)) from error
    if policy_verifier is not None:
        policy_verifier()

    if policy_verifier is not None:
        policy_verifier()
    try:
        verify_tag_absent()
    except TAG_GATE.GateError as error:
        raise PublishError(str(error)) from error
    final_draft = api.request(
        f"/repos/{repository}/releases/{release_id}"
    )
    verify_release(
        final_draft,
        tag=tag,
        version=version,
        draft=True,
        prerelease=prerelease,
        release_id=release_id,
        expected_assets=expected_assets,
        expected_metadata=expected_metadata,
    )

    publication_error: PublishError | None = None
    try:
        api.request(
            f"/repos/{repository}/releases/{release_id}",
            method="PATCH",
            payload={
                "draft": False,
                "prerelease": prerelease,
                "make_latest": "false" if prerelease else "true",
            },
        )
    except PublishError as error:
        publication_error = error

    try:
        _confirm_published_release(
            api,
            f"/repos/{repository}/releases/{release_id}",
            tag=tag,
            version=version,
            prerelease=prerelease,
            release_id=release_id,
            expected_assets=expected_assets,
            expected_metadata=expected_metadata,
            sleeper=sleeper,
        )
        verify_tag()
        if policy_verifier is not None:
            policy_verifier()
    except TAG_GATE.GateError as error:
        raise PublishError(str(error)) from error
    except PublishError:
        if publication_error is not None:
            raise PublishError(
                "release publication failed and no valid immutable release was confirmed"
            ) from publication_error
        raise

    _confirm_published_release(
        api,
        f"/repos/{repository}/releases/{release_id}",
        tag=tag,
        version=version,
        prerelease=prerelease,
        release_id=release_id,
        expected_assets=expected_assets,
        expected_metadata=expected_metadata,
        sleeper=sleeper,
    )


def _validate_common_inputs(
    repository: str,
    version: str,
    expected_sha: str,
) -> None:
    if SAFE_REPOSITORY.fullmatch(repository) is None:
        raise PublishError("repository must be owner/name")
    if SAFE_VERSION.fullmatch(version) is None:
        raise PublishError("release version must be X.Y.Z")
    if SAFE_SHA.fullmatch(expected_sha) is None:
        raise PublishError("expected SHA must be a full lowercase commit SHA")


def verify_draft_candidate(
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    token: str,
    *,
    testing_snapshot: bool = False,
    client: Any | None = None,
    tag_absence_verifier: Callable[[], None] | None = None,
    run_id: int | None = None,
    run_attempt: int | None = None,
    expected_name: str | None = None,
    expected_body_sha256: str | None = None,
    expected_target: str | None = None,
) -> dict[str, Any] | None:
    _validate_common_inputs(repository, version, expected_sha)
    expected_pattern = SAFE_TESTING_TAG if testing_snapshot else SAFE_TAG
    if expected_pattern.fullmatch(tag) is None:
        raise PublishError("release candidate tag is invalid")
    if not testing_snapshot and tag != f"v{version}":
        raise PublishError("release version and tag do not match")
    api = client or GitHubClient(token)
    verify_tag_absent = tag_absence_verifier or (
        lambda: TAG_GATE.verify_remote_tag_absent(
            repository,
            tag,
            token,
            testing_snapshot=testing_snapshot,
        )
    )
    encoded_tag = urllib.parse.quote(tag, safe="")
    payload = api.request(
        f"/repos/{repository}/releases/tags/{encoded_tag}"
    )
    metadata_values = (
        expected_name,
        expected_body_sha256,
        expected_target,
    )
    if any(value is not None for value in metadata_values) and not all(
        value is not None for value in metadata_values
    ):
        raise PublishError("all expected release metadata is required")
    expected_metadata = None
    if all(value is not None for value in metadata_values):
        assert expected_name is not None
        assert expected_body_sha256 is not None
        assert expected_target is not None
        if (
            not expected_name
            or SAFE_BODY_DIGEST.fullmatch(expected_body_sha256) is None
            or expected_target != expected_sha
        ):
            raise PublishError("expected release metadata is invalid")
        expected_metadata = {
            "name": expected_name,
            "bodySha256": expected_body_sha256,
            "targetCommitish": expected_target,
        }
    verify_release(
        payload,
        tag=tag,
        version=version,
        draft=True,
        prerelease=testing_snapshot,
        expected_metadata=expected_metadata,
    )
    try:
        verify_tag_absent()
    except TAG_GATE.GateError as error:
        raise PublishError(str(error)) from error
    if run_id is None and run_attempt is None:
        return None
    if run_id is None or run_attempt is None:
        raise PublishError("both workflow run fields are required")
    if testing_snapshot:
        _validate_testing_run_tag(tag, run_id, run_attempt)
    return create_candidate_manifest(
        payload,
        repository=repository,
        tag=tag,
        version=version,
        expected_sha=expected_sha,
        run_id=run_id,
        run_attempt=run_attempt,
        prerelease=testing_snapshot,
    )


def publish_release(
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    token: str,
    *,
    candidate_manifest: Any,
    run_id: int,
    run_attempt: int,
    client: Any | None = None,
    tag_verifier: Callable[[], None] | None = None,
    tag_absence_verifier: Callable[[], None] | None = None,
    policy_verifier: Callable[[], None] | None = None,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    _validate_common_inputs(repository, version, expected_sha)
    if SAFE_TAG.fullmatch(tag) is None or tag != f"v{version}":
        raise PublishError("release version and tag do not match")
    release_id, assets, metadata = validate_candidate_manifest(
        candidate_manifest,
        repository=repository,
        tag=tag,
        version=version,
        expected_sha=expected_sha,
        run_id=run_id,
        run_attempt=run_attempt,
        prerelease=False,
    )
    api = client or GitHubClient(token)
    verify_policy = policy_verifier or (
        lambda: verify_repository_policy(
            api,
            repository,
            protected_main_sha=expected_sha,
        )
    )
    verify_policy()
    _publish_exact_release(
        repository,
        tag,
        version,
        expected_sha,
        token,
        prerelease=False,
        client=api,
        tag_verifier=tag_verifier,
        tag_absence_verifier=tag_absence_verifier,
        policy_verifier=verify_policy,
        expected_release_id=release_id,
        expected_assets=assets,
        expected_metadata=metadata,
        sleeper=sleeper,
    )


def publish_testing_snapshot(
    repository: str,
    tag: str,
    version: str,
    expected_sha: str,
    token: str,
    *,
    candidate_manifest: Any,
    run_id: int,
    run_attempt: int,
    client: Any | None = None,
    tag_verifier: Callable[[], None] | None = None,
    tag_absence_verifier: Callable[[], None] | None = None,
    policy_verifier: Callable[[], None] | None = None,
    protected_main_sha: str | None = None,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    _validate_common_inputs(repository, version, expected_sha)
    if SAFE_TESTING_TAG.fullmatch(tag) is None:
        raise PublishError("testing tag must identify one workflow attempt")
    _validate_testing_run_tag(tag, run_id, run_attempt)
    release_id, assets, metadata = validate_candidate_manifest(
        candidate_manifest,
        repository=repository,
        tag=tag,
        version=version,
        expected_sha=expected_sha,
        run_id=run_id,
        run_attempt=run_attempt,
        prerelease=True,
    )
    api = client or GitHubClient(token)
    verify_policy = policy_verifier or (
        lambda: verify_repository_policy(
            api,
            repository,
            testing_snapshot=True,
            protected_main_sha=protected_main_sha,
        )
    )
    verify_policy()
    _publish_exact_release(
        repository,
        tag,
        version,
        expected_sha,
        token,
        prerelease=True,
        client=api,
        tag_verifier=tag_verifier,
        tag_absence_verifier=tag_absence_verifier,
        policy_verifier=verify_policy,
        expected_release_id=release_id,
        expected_assets=assets,
        expected_metadata=metadata,
        sleeper=sleeper,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--version")
    parser.add_argument("--expected-sha")
    parser.add_argument("--check-policy-only", action="store_true")
    parser.add_argument("--verify-draft-only", action="store_true")
    parser.add_argument("--testing-snapshot", action="store_true")
    parser.add_argument("--manifest")
    parser.add_argument("--write-manifest")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--run-attempt", type=int)
    parser.add_argument("--expected-name")
    parser.add_argument("--expected-body-sha256")
    parser.add_argument("--expected-target")
    parser.add_argument("--protected-main-sha")
    args = parser.parse_args()
    try:
        token = os.environ.get("GH_TOKEN", "")
        if args.check_policy_only:
            if args.verify_draft_only or args.manifest or args.write_manifest or any(
                value is not None
                for value in (
                    args.tag,
                    args.version,
                    args.expected_sha,
                    args.run_id,
                    args.run_attempt,
                    args.expected_name,
                    args.expected_body_sha256,
                    args.expected_target,
                )
            ):
                raise PublishError(
                    "policy-only verification cannot include release inputs"
                )
            if SAFE_REPOSITORY.fullmatch(args.repository) is None:
                raise PublishError("repository must be owner/name")
            if (
                not isinstance(args.protected_main_sha, str)
                or SAFE_SHA.fullmatch(args.protected_main_sha) is None
            ):
                raise PublishError(
                    "policy-only verification requires protected main SHA"
                )
            client = GitHubClient(token)
            verify_repository_policy(
                client,
                args.repository,
                testing_snapshot=args.testing_snapshot,
                protected_main_sha=args.protected_main_sha,
            )
            print("release-policy: immutable release controls verified")
            return 0
        if any(
            value is None
            for value in (args.tag, args.version, args.expected_sha)
        ):
            raise PublishError("tag, version, and expected SHA are required")
        if args.verify_draft_only:
            if args.manifest or args.protected_main_sha is not None:
                raise PublishError(
                    "draft verification cannot consume publication policy inputs"
                )
            if bool(args.write_manifest) != bool(
                args.run_id is not None and args.run_attempt is not None
            ):
                raise PublishError(
                    "manifest output requires both workflow run fields"
                )
            manifest = verify_draft_candidate(
                args.repository,
                args.tag,
                args.version,
                args.expected_sha,
                token,
                testing_snapshot=args.testing_snapshot,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
                expected_name=args.expected_name,
                expected_body_sha256=args.expected_body_sha256,
                expected_target=args.expected_target,
            )
            if args.write_manifest:
                assert manifest is not None
                output = Path(args.write_manifest)
                try:
                    output.write_text(
                        json.dumps(
                            manifest,
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                except OSError as error:
                    raise PublishError(
                        "release candidate manifest cannot be written"
                    ) from error
            print(f"release-publish: {args.tag} draft is exact")
            return 0
        if (
            args.manifest is None
            or args.write_manifest is not None
            or args.run_id is None
            or args.run_attempt is None
        ):
            raise PublishError(
                "publication requires one candidate manifest and workflow run"
            )
        if (
            not isinstance(args.protected_main_sha, str)
            or SAFE_SHA.fullmatch(args.protected_main_sha) is None
        ):
            raise PublishError("publication requires protected main SHA")
        if (
            not args.testing_snapshot
            and args.protected_main_sha != args.expected_sha
        ):
            raise PublishError(
                "production publication requires the exact protected main SHA"
            )
        if any(
            value is not None
            for value in (
                args.expected_name,
                args.expected_body_sha256,
                args.expected_target,
            )
        ):
            raise PublishError(
                "publication metadata must come from the candidate manifest"
            )
        release_id, assets, metadata = load_candidate_manifest(
            Path(args.manifest),
            repository=args.repository,
            tag=args.tag,
            version=args.version,
            expected_sha=args.expected_sha,
            run_id=args.run_id,
            run_attempt=args.run_attempt,
            prerelease=args.testing_snapshot,
        )
        candidate_manifest = {
            "schemaVersion": MANIFEST_SCHEMA_VERSION,
            "repository": args.repository,
            "tag": args.tag,
            "version": args.version,
            "expectedSha": args.expected_sha,
            "runId": args.run_id,
            "runAttempt": args.run_attempt,
            "releaseId": release_id,
            "prerelease": args.testing_snapshot,
            "assets": assets,
            **metadata,
        }
        publisher = (
            publish_testing_snapshot
            if args.testing_snapshot
            else publish_release
        )
        publish_arguments = {
            "candidate_manifest": candidate_manifest,
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
        }
        if args.testing_snapshot:
            publish_arguments["protected_main_sha"] = args.protected_main_sha
        publisher(
            args.repository,
            args.tag,
            args.version,
            args.expected_sha,
            token,
            **publish_arguments,
        )
    except PublishError as error:
        print(f"release-publish: {error}", file=sys.stderr)
        return 1
    print(f"release-publish: {args.tag} published from the reviewed commit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
