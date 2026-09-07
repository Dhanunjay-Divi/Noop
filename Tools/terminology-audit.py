#!/usr/bin/env python3
"""Classify legacy terminology without rewriting persisted provenance.

The committed inventory contains paths, categories, counts, line numbers, token
counts, and content digests only. It does not copy source lines into release
evidence. The allowlist is a ratchet for active customer/core usage: any changed
or new occurrence requires an explicit reviewed snapshot update.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INVENTORY = ROOT / "release" / "terminology" / "legacy-inventory.json"
DEFAULT_ALLOWLIST = ROOT / "release" / "terminology" / "active-allowlist.json"
GENERATED_AUDIT_PATHS = {
    "release/terminology/active-allowlist.json",
    "release/terminology/legacy-inventory.json",
}
FORBIDDEN_EXEMPT_PATHS = {
    "Tools/terminology-audit.py",
    "Tools/tests/test_terminology_audit.py",
}
LEGACY = re.compile(
    r"(?i)(?<![a-z0-9])(?:my-whoop(?:-noop)?|openwhoop|whoop[a-z0-9_-]*)(?![a-z0-9])"
)
TEXT_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".css",
    ".csv",
    ".gradle",
    ".h",
    ".html",
    ".java",
    ".js",
    ".json",
    ".kt",
    ".kts",
    ".md",
    ".m",
    ".mm",
    ".plist",
    ".properties",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".sql",
    ".strings",
    ".swift",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xcconfig",
    ".xcstrings",
    ".xml",
    ".yaml",
    ".yml",
}
ACTIVE_CATEGORIES = {"customer", "core"}
FORBIDDEN_RULES = (
    (
        "legacy-source-first-party-label",
        re.compile(r"(?i)my-whoop.*noop band|noop band.*my-whoop"),
    ),
    (
        "compatibility-model-first-party-label",
        re.compile(r'(?i)(?:customerName|CUSTOMER_NAME)\s*=\s*"Noop Band"'),
    ),
    (
        "legacy-device-first-party-return",
        re.compile(r'(?i)(?:isWhoop|isNoopBand|isLegacyCompatibleBand).*"Noop Band"'),
    ),
    (
        "legacy-import-first-party-registration",
        re.compile(r'(?i)WhoopCsvDeviceRegistration\([^)]*"Noop Band"'),
    ),
    (
        "legacy-upsert-first-party-name",
        re.compile(r'(?i)upsertDevice\([^)]*name\s*[:=]\s*"Noop Band'),
    ),
)


class AuditError(RuntimeError):
    """A terminology invariant is missing or changed."""


@dataclass(frozen=True)
class Occurrence:
    path: str
    line: int
    token: str
    category: str
    fingerprint: str


def tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise AuditError("git tracked-file inventory failed")
    return sorted(
        item.decode("utf-8")
        for item in result.stdout.split(b"\0")
        if item and item.decode("utf-8") not in GENERATED_AUDIT_PATHS
    )


def is_text_path(path: str) -> bool:
    item = PurePosixPath(path)
    return item.suffix.lower() in TEXT_SUFFIXES or item.name in {
        "Dockerfile",
        "LICENSE",
        "Package.resolved",
    }


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith(("//", "/*", "*", "#", "<!--"))


def category_for(path: str, line: str, token: str) -> str:
    lowered = path.lower()
    parts = PurePosixPath(lowered).parts

    if (
        lowered.startswith("strand.xcodeproj/")
        or "/generated/" in lowered
        or "/schemas/" in lowered
        or lowered.endswith(".pbxproj")
    ):
        return "generated"
    if any(part in {"test", "tests", "fixtures", "examples"} for part in parts):
        return "fixture"
    if (
        lowered.startswith("docs/ops/rounds/")
        or lowered.startswith("docs/handoff/archive/")
        or "changelog" in lowered
        or "release-notes" in lowered
    ):
        return "historical"
    if (
        lowered.startswith("thirdpartynotices/")
        or "license" in lowered
        or "/provenance/" in lowered
        or lowered.startswith("docs/legal")
    ):
        return "legal"
    if any(term in lowered for term in ("import", "export", "csv")):
        return "import"
    if token.startswith("my-whoop") and (
        '"' in line
        or "'" in line
        or any(term in lowered for term in ("database", "migration", "store", "dao"))
    ):
        return "persisted"
    if any(
        term in lowered
        for term in (
            "whoopprotocol",
            "whoopstore",
            "/ble/whoop",
            "/protocol/whoop",
            "sourcecoordinator",
            "backfiller",
        )
    ):
        return "compatibility"
    customer_path = any(
        term in lowered
        for term in (
            "strand/screens/",
            "strand/onboarding/",
            "strand/resources/",
            "android/app/src/main/java/com/noop/ui/",
            "android/app/src/main/res/",
        )
    )
    if customer_path and not is_comment(line) and ('"' in line or "<string" in line):
        return "customer"
    if any(
        lowered.startswith(prefix)
        for prefix in (
            "strand/",
            "strandios/",
            "packages/",
            "android/app/src/main/",
            "server/",
            "tools/",
        )
    ):
        return "core"
    return "historical"


def fingerprint(path: str, token: str, line: str) -> str:
    normalized = " ".join(line.strip().split())
    payload = f"{path}\0{token.lower()}\0{normalized}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def scan(
    root: Path, files: Iterable[str] | None = None
) -> tuple[list[Occurrence], list[dict[str, object]]]:
    occurrences: list[Occurrence] = []
    forbidden: list[dict[str, object]] = []
    for path in files or tracked_files(root):
        if path in GENERATED_AUDIT_PATHS:
            continue
        lowered_path = path.lower()
        for match in LEGACY.finditer(lowered_path):
            token = match.group(0).lower()
            occurrences.append(
                Occurrence(
                    path=path,
                    line=0,
                    token=token,
                    category=category_for(path, "", token),
                    fingerprint=fingerprint(path, token, "@path"),
                )
            )
        if not is_text_path(path):
            continue
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            if path not in FORBIDDEN_EXEMPT_PATHS:
                for rule, pattern in FORBIDDEN_RULES:
                    if pattern.search(line):
                        forbidden.append(
                            {"path": path, "line": line_number, "rule": rule}
                        )
            for match in LEGACY.finditer(line):
                token = match.group(0).lower()
                occurrences.append(
                    Occurrence(
                        path=path,
                        line=line_number,
                        token=token,
                        category=category_for(path, line, token),
                        fingerprint=fingerprint(path, token, line),
                    )
                )
    return sorted(
        occurrences,
        key=lambda item: (item.path, item.line, item.category, item.token),
    ), forbidden


def grouped_inventory(occurrences: Iterable[Occurrence]) -> dict[str, object]:
    grouped: dict[tuple[str, str], list[Occurrence]] = defaultdict(list)
    category_counts: Counter[str] = Counter()
    for occurrence in occurrences:
        grouped[(occurrence.path, occurrence.category)].append(occurrence)
        category_counts[occurrence.category] += 1

    entries: list[dict[str, object]] = []
    for (path, category), rows in sorted(grouped.items()):
        tokens = Counter(row.token for row in rows)
        digest = hashlib.sha256(
            "\n".join(sorted(row.fingerprint for row in rows)).encode("ascii")
        ).hexdigest()
        entries.append(
            {
                "path": path,
                "category": category,
                "occurrenceCount": len(rows),
                "lineNumbers": sorted(row.line for row in rows),
                "tokenCounts": dict(sorted(tokens.items())),
                "sha256": digest,
            }
        )
    return {
        "schemaVersion": 1,
        "scanner": "Tools/terminology-audit.py",
        "occurrenceCount": sum(category_counts.values()),
        "categoryCounts": dict(sorted(category_counts.items())),
        "entries": entries,
    }


def active_allowlist(inventory: dict[str, object]) -> dict[str, object]:
    entries = []
    for entry in inventory["entries"]:
        if entry["category"] not in ACTIVE_CATEGORIES:
            continue
        category = entry["category"]
        entries.append(
            {
                "path": entry["path"],
                "category": category,
                "occurrenceCount": entry["occurrenceCount"],
                "sha256": entry["sha256"],
                "owner": "project team",
                "reason": (
                    "Existing customer wording pending reviewed provenance/localization migration."
                    if category == "customer"
                    else "Existing active symbol retained behind the additive compatibility migration."
                ),
                "removalCondition": (
                    "Remove or neutralize the occurrence without changing persisted provenance, "
                    "then regenerate this ratchet."
                ),
            }
        )
    return {
        "schemaVersion": 1,
        "policy": "No new or changed active customer/core legacy terminology.",
        "entries": entries,
    }


def read_json(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"{label} is missing or invalid") from error
    if not isinstance(value, dict):
        raise AuditError(f"{label} must be an object")
    return value


def write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def check(root: Path, inventory_path: Path, allowlist_path: Path) -> None:
    occurrences, forbidden = scan(root)
    if forbidden:
        first = forbidden[0]
        raise AuditError(
            "forbidden legacy-to-first-party mapping: "
            f"{first['path']}:{first['line']} ({first['rule']})"
        )
    current = grouped_inventory(occurrences)
    expected = read_json(inventory_path, "terminology inventory")
    if current != expected:
        raise AuditError(
            "terminology inventory changed; review classification and regenerate the snapshot"
        )
    current_allowlist = active_allowlist(current)
    expected_allowlist = read_json(allowlist_path, "terminology allowlist")
    if current_allowlist != expected_allowlist:
        raise AuditError(
            "active terminology allowlist changed; new or modified customer/core usage is unreviewed"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check", "snapshot", "summary"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory.resolve()
    allowlist_path = args.allowlist.resolve()
    try:
        if args.command == "check":
            check(root, inventory_path, allowlist_path)
            print("Terminology inventory and active-use ratchet passed.")
            return 0
        occurrences, forbidden = scan(root)
        inventory = grouped_inventory(occurrences)
        if args.command == "summary":
            print(
                json.dumps(
                    {
                        "occurrenceCount": inventory["occurrenceCount"],
                        "categoryCounts": inventory["categoryCounts"],
                        "forbiddenCount": len(forbidden),
                    },
                    sort_keys=True,
                )
            )
            return 1 if forbidden else 0
        if forbidden:
            first = forbidden[0]
            raise AuditError(
                "snapshot refused while a forbidden mapping remains: "
                f"{first['path']}:{first['line']} ({first['rule']})"
            )
        write_json(inventory_path, inventory)
        write_json(allowlist_path, active_allowlist(inventory))
        print(
            f"Recorded {inventory['occurrenceCount']} classified legacy occurrences "
            f"across {len(inventory['entries'])} path/category groups."
        )
        return 0
    except AuditError as error:
        print(f"terminology audit failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
