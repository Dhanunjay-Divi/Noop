#!/usr/bin/env python3
"""Verify that a live GitHub release tag resolves to the reviewed commit."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import Any


SAFE_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_SHA = re.compile(r"^[0-9a-f]{40}$")
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_TAG_DEPTH = 5


class GateError(RuntimeError):
    """The live release tag cannot be trusted for publication."""


def _git_object(payload: Any, label: str) -> tuple[str, str]:
    if not isinstance(payload, dict):
        raise GateError(f"{label} response is invalid")
    target = payload.get("object")
    if not isinstance(target, dict):
        raise GateError(f"{label} target is invalid")
    object_type = target.get("type")
    sha = target.get("sha")
    if (
        object_type not in {"commit", "tag"}
        or not isinstance(sha, str)
        or SAFE_SHA.fullmatch(sha) is None
    ):
        raise GateError(f"{label} target is invalid")
    return object_type, sha


def resolve_tag_target(
    ref_payload: Any,
    tag: str,
    fetch_tag_object: Callable[[str], Any],
) -> str:
    if (
        not isinstance(ref_payload, dict)
        or ref_payload.get("ref") != f"refs/tags/{tag}"
    ):
        raise GateError("GitHub tag reference identity is invalid")
    object_type, sha = _git_object(ref_payload, "GitHub tag reference")
    seen: set[str] = set()
    for _ in range(MAX_TAG_DEPTH + 1):
        if object_type == "commit":
            return sha
        if sha in seen:
            raise GateError("GitHub annotated tag chain contains a cycle")
        seen.add(sha)
        tag_payload = fetch_tag_object(sha)
        if (
            not isinstance(tag_payload, dict)
            or tag_payload.get("sha") != sha
        ):
            raise GateError("GitHub annotated tag identity is invalid")
        object_type, sha = _git_object(
            tag_payload, "GitHub annotated tag"
        )
    raise GateError("GitHub annotated tag chain exceeds the depth limit")


def github_json(path: str, token: str) -> Any:
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "noop-release-tag-gate",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except (OSError, urllib.error.HTTPError) as error:
        raise GateError("GitHub release tag lookup failed") from error
    if len(body) > MAX_RESPONSE_BYTES:
        raise GateError("GitHub release tag response exceeded the size limit")
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise GateError("GitHub release tag response is invalid") from error


def verify_remote_tag(
    repository: str,
    tag: str,
    expected_sha: str,
    token: str,
    fetcher: Callable[[str], Any] | None = None,
) -> None:
    if SAFE_REPOSITORY.fullmatch(repository) is None:
        raise GateError("repository must be owner/name")
    if SAFE_TAG.fullmatch(tag) is None:
        raise GateError("release tag must be vX.Y.Z")
    if SAFE_SHA.fullmatch(expected_sha) is None:
        raise GateError("expected SHA must be a full lowercase commit SHA")
    if not token:
        raise GateError("GitHub token is unavailable")
    read = fetcher or (lambda path: github_json(path, token))
    encoded_tag = urllib.parse.quote(tag, safe="")
    ref_path = f"/repos/{repository}/git/ref/tags/{encoded_tag}"
    ref_payload = read(ref_path)
    actual_sha = resolve_tag_target(
        ref_payload,
        tag,
        lambda sha: read(f"/repos/{repository}/git/tags/{sha}"),
    )
    if actual_sha != expected_sha:
        raise GateError("live release tag points to a different commit")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-sha", required=True)
    args = parser.parse_args()
    try:
        verify_remote_tag(
            args.repository,
            args.tag,
            args.expected_sha,
            os.environ.get("GH_TOKEN", ""),
        )
    except GateError as error:
        print(f"release-tag: {error}", file=sys.stderr)
        return 1
    print(f"release-tag: {args.tag} targets the reviewed commit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
