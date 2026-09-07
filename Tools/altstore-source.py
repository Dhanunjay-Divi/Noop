#!/usr/bin/env python3
"""Build a fail-closed AltStore source from reviewed release metadata."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


class SourceError(RuntimeError):
    """The source template or requested release metadata is invalid."""


def parse_version(value: str) -> tuple[int, int, int]:
    if VERSION_PATTERN.fullmatch(value) is None:
        raise SourceError("version must use numeric semantic version x.y.z")
    return tuple(int(component) for component in value.split("."))  # type: ignore[return-value]


def require_https(value: str, label: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SourceError(f"{label} must be an absolute HTTPS URL")


def update_source(
    payload: Any,
    *,
    source_url: str,
    version: str,
    build: str,
    published_date: str,
    description: str,
    download_url: str,
    size: int,
) -> dict[str, Any]:
    target_version = parse_version(version)
    if not build.isdigit() or int(build) <= 0:
        raise SourceError("build must be a positive integer")
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", published_date) is None:
        raise SourceError("publication date must use YYYY-MM-DD")
    try:
        date.fromisoformat(published_date)
    except ValueError as error:
        raise SourceError("publication date must use YYYY-MM-DD") from error
    if not isinstance(description, str) or not description.strip():
        raise SourceError("description must be non-empty")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise SourceError("asset size must be a positive integer")
    require_https(source_url, "source URL")
    require_https(download_url, "download URL")

    if not isinstance(payload, dict):
        raise SourceError("source root must be an object")
    result = copy.deepcopy(payload)
    apps = result.get("apps")
    if not isinstance(apps, list) or not apps or not isinstance(apps[0], dict):
        raise SourceError("source must contain a primary app")
    app = apps[0]
    versions = app.get("versions")
    if not isinstance(versions, list):
        raise SourceError("primary app versions must be an array")

    parsed_versions: list[tuple[int, int, int]] = []
    seen_versions: set[str] = set()
    for entry in versions:
        if not isinstance(entry, dict):
            raise SourceError("source version entry must be an object")
        entry_version = entry.get("version")
        entry_build = entry.get("buildVersion")
        if not isinstance(entry_version, str):
            raise SourceError("source version entry is invalid")
        parsed = parse_version(entry_version)
        if entry_version in seen_versions:
            raise SourceError("source versions must be unique")
        seen_versions.add(entry_version)
        parsed_versions.append(parsed)
        if (
            not isinstance(entry_build, str)
            or not entry_build.isdigit()
            or int(entry_build) <= 0
        ):
            raise SourceError("source build version is invalid")
        if parsed > target_version:
            raise SourceError("source version cannot move backward")
        if entry_version == version and int(entry_build) > int(build):
            raise SourceError("source build cannot move backward")
    if parsed_versions != sorted(parsed_versions, reverse=True):
        raise SourceError("source versions must be newest first")

    min_os = app.get("minOSVersion")
    if not isinstance(min_os, str) or not min_os:
        min_os = "17.0"
        if versions and isinstance(versions[0], dict):
            candidate = versions[0].get("minOSVersion")
            if isinstance(candidate, str) and candidate:
                min_os = candidate

    retained: list[Any] = []
    for entry in versions:
        if entry.get("version") != version:
            retained.append(entry)

    entry = {
        "version": version,
        "buildVersion": build,
        "date": published_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size,
        "minOSVersion": min_os,
    }
    result["sourceURL"] = source_url
    app["versions"] = [entry, *retained]
    app["version"] = version
    app["buildVersion"] = build
    app["versionDate"] = published_date
    app["versionDescription"] = description
    app["downloadURL"] = download_url
    app["size"] = size
    return result


def command_update(args: argparse.Namespace) -> None:
    try:
        payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SourceError("source input is unavailable or invalid JSON") from error
    updated = update_source(
        payload,
        source_url=args.source_url,
        version=args.version,
        build=args.build,
        published_date=args.date,
        description=args.description,
        download_url=args.download_url,
        size=args.size,
    )
    Path(args.output).write_text(
        json.dumps(updated, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    print(f"altstore-source: prepared version {args.version}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    update = subparsers.add_parser("update")
    update.add_argument("--input", required=True)
    update.add_argument("--output", required=True)
    update.add_argument("--source-url", required=True)
    update.add_argument("--version", required=True)
    update.add_argument("--build", required=True)
    update.add_argument("--date", required=True)
    update.add_argument("--description", required=True)
    update.add_argument("--download-url", required=True)
    update.add_argument("--size", required=True, type=int)
    update.set_defaults(handler=command_update)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except SourceError as error:
        print(f"altstore-source: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
