#!/usr/bin/env python3
"""Compare NOOP's reviewed upstream snapshot with GitHub's current public state.

The script is deliberately read-only.  CI uses its JSON/Markdown output to keep a
single review issue current; it never merges, cherry-picks, or rewrites the
reviewed baseline.  Updating ``docs/upstream-watch-baseline.json`` therefore
remains an explicit, reviewable repository change after the relevant tests pass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


API_ROOT = "https://api.github.com"


class GitHubReadError(RuntimeError):
    """A GitHub read failed; the watch must report unknown, never false-clear."""


@dataclass(frozen=True)
class Observation:
    repository: str
    default_branch: str
    head: str
    archived: bool
    latest_release: str | None
    advisory_ids: tuple[str, ...]
    open_pr_digest: str
    open_pr_count: int
    open_prs: tuple[dict[str, Any], ...]

    def comparable(self) -> dict[str, Any]:
        return {
            "default_branch": self.default_branch,
            "head": self.head,
            "archived": self.archived,
            "latest_release": self.latest_release,
            "advisory_ids": list(self.advisory_ids),
            "open_pr_digest": self.open_pr_digest,
            "open_pr_count": self.open_pr_count,
        }


class GitHubReader:
    def __init__(self, token: str | None = None) -> None:
        self.token = token

    def get(self, path: str, *, allow_not_found: bool = False) -> Any:
        request = urllib.request.Request(
            f"{API_ROOT}/{path.lstrip('/')}",
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "noop-upstream-watch",
                **({"Authorization": f"Bearer {self.token}"} if self.token else {}),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if allow_not_found and error.code == 404:
                return None
            raise GitHubReadError(f"GET {path} returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise GitHubReadError(f"GET {path} failed: {error}") from error


def _pr_fingerprint(prs: list[dict[str, Any]]) -> tuple[str, tuple[dict[str, Any], ...]]:
    stable = tuple(
        {
            "number": int(pr["number"]),
            "title": str(pr["title"]),
            "head": str(pr["head"]["sha"]),
            "draft": bool(pr.get("draft", False)),
            "url": str(pr["html_url"]),
        }
        for pr in sorted(prs, key=lambda item: int(item["number"]))
    )
    payload = json.dumps(stable, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest(), stable


def observe(reader: GitHubReader, repository: str) -> Observation:
    repo = reader.get(f"repos/{repository}")
    branch = str(repo["default_branch"])
    commit = reader.get(
        f"repos/{repository}/commits/{urllib.parse.quote(branch, safe='')}"
    )
    latest_release = reader.get(f"repos/{repository}/releases/latest", allow_not_found=True)
    advisories = reader.get(f"repos/{repository}/security-advisories?per_page=100")
    pulls = reader.get(
        f"repos/{repository}/pulls?state=open&sort=updated&direction=desc&per_page=100"
    )
    digest, stable_pulls = _pr_fingerprint(pulls)
    advisory_ids = tuple(
        sorted(str(item["ghsa_id"]) for item in advisories if item.get("ghsa_id"))
    )
    return Observation(
        repository=repository,
        default_branch=branch,
        head=str(commit["sha"]),
        archived=bool(repo["archived"]),
        latest_release=(str(latest_release["tag_name"]) if latest_release else None),
        advisory_ids=advisory_ids,
        open_pr_digest=digest,
        open_pr_count=len(stable_pulls),
        open_prs=stable_pulls,
    )


def compare(
    baseline: dict[str, Any], observations: list[Observation]
) -> tuple[bool, str, dict[str, Any]]:
    expected_repositories = baseline.get("repositories", {})
    lines = [
        "## NOOP upstream-watch report",
        "",
        f"Reviewed baseline: `{baseline.get('reviewed_at', 'unknown')}`",
        "",
        "This check is read-only. Review and test changes before updating the baseline; never auto-merge protocol code.",
        "",
    ]
    changed = False
    current: dict[str, Any] = {"repositories": {}}

    for observation in observations:
        actual = observation.comparable()
        current["repositories"][observation.repository] = actual
        expected = expected_repositories.get(observation.repository)
        repo_changed = expected != actual
        changed = changed or repo_changed
        lines.append(f"### {observation.repository} — {'review needed' if repo_changed else 'clear'}")
        lines.append("")
        lines.append(f"- Default branch/head: `{observation.default_branch}` / `{observation.head}`")
        lines.append(f"- Latest release: `{observation.latest_release or 'none'}`")
        lines.append(f"- Archived: `{str(observation.archived).lower()}`")
        lines.append(
            "- Public advisories: "
            + (", ".join(f"`{item}`" for item in observation.advisory_ids) or "none")
        )
        lines.append(f"- Open pull requests: `{observation.open_pr_count}`")
        if repo_changed and expected:
            for key, value in actual.items():
                if expected.get(key) != value:
                    lines.append(
                        f"  - `{key}` changed from `{expected.get(key)}` to `{value}`"
                    )
        elif repo_changed:
            lines.append("  - Repository is missing from the reviewed baseline.")
        if observation.open_prs:
            lines.append("- Current open PRs:")
            for pr in observation.open_prs:
                draft = " (draft)" if pr["draft"] else ""
                lines.append(f"  - [#{pr['number']} {pr['title']}]({pr['url']}){draft}")
        lines.append("")

    missing = sorted(set(expected_repositories) - {item.repository for item in observations})
    if missing:
        changed = True
        lines.extend(
            [
                "### Baseline configuration error",
                "",
                "Missing observations: " + ", ".join(f"`{item}`" for item in missing),
                "",
            ]
        )

    lines.append(
        "**Result:** "
        + ("upstream review is required." if changed else "no drift from the reviewed baseline.")
    )
    return changed, "\n".join(lines) + "\n", current


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args(argv)

    baseline = json.loads(args.baseline.read_text())
    repositories = list(baseline.get("repositories", {}))
    if not repositories:
        raise SystemExit("baseline contains no repositories")

    try:
        observations = [
            observe(GitHubReader(os.getenv("GITHUB_TOKEN")), repository)
            for repository in repositories
        ]
        changed, report, snapshot = compare(baseline, observations)
    except GitHubReadError as error:
        # A read error is actionable drift, not a green result.  Preserve the reason in
        # the same report path so the workflow can surface it in the tracking issue.
        changed = True
        report = (
            "## NOOP upstream-watch report\n\n"
            "**Result: review required because current upstream state could not be verified.**\n\n"
            f"`{error}`\n"
        )
        snapshot = {"error": str(error)}

    args.report.write_text(report)
    if args.snapshot:
        args.snapshot.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
    if args.github_output:
        with args.github_output.open("a") as handle:
            handle.write(f"changed={'true' if changed else 'false'}\n")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
