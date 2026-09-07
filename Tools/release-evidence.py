#!/usr/bin/env python3
"""Generate and verify deterministic, privacy-safe NOOP release evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse


ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = "ThirdPartyNotices/runtime-inventory.json"
POLICY_PATH = "release/release-policy.json"
SCHEMA_PATH = "release/evidence/manifest.schema.json"
CANONICAL_REPOSITORY = "https://github.com/Dhanunjay-Divi/Noop"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$")
SAFE_CHECK = re.compile(r"^[a-z][a-z0-9-]{1,63}$")


class EvidenceError(RuntimeError):
    """Release evidence is incomplete, inconsistent, or unsafe."""


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise EvidenceError(f"git command failed: {' '.join(args)}")
    return result.stdout.decode("utf-8", errors="strict").strip()


def source_identity(root: Path, source_ref: str) -> dict[str, str]:
    commit = _git(root, "rev-parse", f"{source_ref}^{{commit}}")
    tree = _git(root, "rev-parse", f"{commit}^{{tree}}")
    if COMMIT.fullmatch(commit) is None or COMMIT.fullmatch(tree) is None:
        raise EvidenceError("source commit or tree is not a full Git object ID")
    return {
        "repository": CANONICAL_REPOSITORY,
        "commit": commit,
        "tree": tree,
    }


def blob_at(root: Path, commit: str, relative: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise EvidenceError(f"source input is absent at commit: {relative}")
    return result.stdout


def canonical_json(data: Any) -> bytes:
    return (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _swift_purl(item: dict[str, Any]) -> str:
    parsed = urlparse(item["source"])
    path = parsed.path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    segments = [quote(part, safe="._-") for part in path.split("/") if part]
    if len(segments) < 2:
        segments = ["unknown", quote(item["name"], safe="._-")]
    return f"pkg:swift/{'/'.join(segments)}@{quote(item['version'], safe='._-+')}"


def _component_purl(item: dict[str, Any]) -> tuple[str, str, str | None]:
    ecosystem = item["ecosystem"]
    name = item["name"]
    version = item["version"]
    if ecosystem == "maven":
        group, artifact = name.split(":", 1)
        purl = (
            f"pkg:maven/{quote(group, safe='._-')}/{quote(artifact, safe='._-')}"
            f"@{quote(version, safe='._-+')}"
        )
        return purl, artifact, group
    if ecosystem == "pypi":
        normalized = name.lower().replace("_", "-")
        return (
            f"pkg:pypi/{quote(normalized, safe='._-')}@"
            f"{quote(version, safe='._-+')}",
            name,
            None,
        )
    if ecosystem == "swiftpm":
        return _swift_purl(item), name, None
    raise EvidenceError(f"unsupported runtime ecosystem: {ecosystem}")


def _library_component(item: dict[str, Any]) -> dict[str, Any]:
    purl, name, group = _component_purl(item)
    component: dict[str, Any] = {
        "type": "library",
        "bom-ref": purl,
        "name": name,
        "version": item["version"],
        "purl": purl,
        "licenses": [{"expression": item["license"]}],
        "externalReferences": [{"type": "website", "url": item["source"]}],
        "properties": [
            {"name": "noop:ecosystem", "value": item["ecosystem"]},
        ],
    }
    if group is not None:
        component["group"] = group
    revision = item.get("revision")
    if revision:
        component["properties"].append(
            {"name": "noop:source-revision", "value": revision}
        )
    return component


def _container_component(item: dict[str, Any]) -> dict[str, Any]:
    image, digest = item["name"].rsplit("@sha256:", 1)
    if SHA256.fullmatch(digest) is None:
        raise EvidenceError("container inventory includes an invalid digest")
    leaf = image.rsplit("/", 1)[-1]
    name = leaf.rsplit(":", 1)[0]
    repository = image.rsplit(":", 1)[0] if ":" in leaf else image
    purl = (
        f"pkg:oci/{quote(name, safe='._-')}@sha256:{digest}"
        f"?repository_url={quote(repository, safe='._-/')}"
    )
    properties = [{"name": "noop:used-by", "value": item["usedBy"]}]
    if item.get("pulledOnly"):
        properties.append({"name": "noop:pulled-only", "value": "true"})
    return {
        "type": "container",
        "bom-ref": purl,
        "name": name,
        "version": f"sha256:{digest}",
        "purl": purl,
        "hashes": [{"alg": "SHA-256", "content": digest}],
        "properties": properties,
    }


def generate_sbom(root: Path, source_ref: str, version: str) -> dict[str, Any]:
    if SEMVER.fullmatch(version) is None:
        raise EvidenceError("release version must be SemVer")
    source = source_identity(root, source_ref)
    inventory_bytes = blob_at(root, source["commit"], INVENTORY_PATH)
    try:
        inventory = json.loads(inventory_bytes)
    except json.JSONDecodeError as error:
        raise EvidenceError("runtime inventory is invalid JSON") from error
    libraries = inventory.get("components")
    containers = inventory.get("containers")
    if not isinstance(libraries, list) or not isinstance(containers, list):
        raise EvidenceError("runtime inventory component lists are missing")
    components = [_library_component(item) for item in libraries]
    components.extend(_container_component(item) for item in containers)
    components.sort(key=lambda item: item["bom-ref"])
    identity = "\n".join(
        [
            source["commit"],
            source["tree"],
            version,
            sha256_bytes(inventory_bytes),
            *(item["bom-ref"] for item in components),
        ]
    )
    return {
        "$schema": "https://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, identity)}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": f"pkg:generic/noop@{quote(version, safe='._-+')}",
                "name": "NOOP",
                "version": version,
            },
            "properties": [
                {"name": "noop:source:commit", "value": source["commit"]},
                {"name": "noop:source:tree", "value": source["tree"]},
                {
                    "name": "noop:runtime-inventory:sha256",
                    "value": sha256_bytes(inventory_bytes),
                },
            ],
        },
        "components": components,
    }


def media_type(path: Path) -> str:
    name = path.name
    if name.endswith(".cdx.json"):
        return "application/vnd.cyclonedx+json"
    if name.endswith(".json"):
        return "application/json"
    if name.endswith(".sha256"):
        return "text/plain"
    return "application/octet-stream"


def artifact_record(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise EvidenceError(f"release artifact does not exist: {path.name}")
    if path.name != str(path.name) or SAFE_NAME.fullmatch(path.name) is None:
        raise EvidenceError("artifact basename is unsafe")
    data = path.read_bytes()
    return {
        "name": path.name,
        "sha256": sha256_bytes(data),
        "size": len(data),
        "mediaType": media_type(path),
    }


def load_check_report(path: Path) -> list[dict[str, str]]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError("release check report is missing or invalid") from error
    if not isinstance(report, dict) or set(report) != {"schemaVersion", "checks"}:
        raise EvidenceError("release check report fields are invalid")
    if report["schemaVersion"] != 1 or not isinstance(report["checks"], list):
        raise EvidenceError("release check report version is invalid")
    checks: list[dict[str, str]] = []
    for item in report["checks"]:
        if not isinstance(item, dict) or set(item) != {"name", "status"}:
            raise EvidenceError("release check result fields are invalid")
        if SAFE_CHECK.fullmatch(item["name"]) is None or item["status"] != "passed":
            raise EvidenceError("release evidence can contain only passed static checks")
        checks.append({"name": item["name"], "status": item["status"]})
    if not checks or checks != sorted(checks, key=lambda item: item["name"]):
        raise EvidenceError("release checks must be non-empty, unique, and sorted")
    if len({item["name"] for item in checks}) != len(checks):
        raise EvidenceError("release check names must be unique")
    return checks


def generate_manifest(
    root: Path,
    source_ref: str,
    version: str,
    artifacts: list[Path],
    check_report: Path,
) -> dict[str, Any]:
    if SEMVER.fullmatch(version) is None:
        raise EvidenceError("release version must be SemVer")
    source = source_identity(root, source_ref)
    policy_bytes = blob_at(root, source["commit"], POLICY_PATH)
    schema_bytes = blob_at(root, source["commit"], SCHEMA_PATH)
    records = sorted(
        (artifact_record(path) for path in artifacts), key=lambda item: item["name"]
    )
    if not records or len({item["name"] for item in records}) != len(records):
        raise EvidenceError("release artifact basenames must be non-empty and unique")
    return {
        "schemaVersion": 1,
        "product": "NOOP",
        "releaseVersion": version,
        "source": source,
        "policy": {
            "name": Path(POLICY_PATH).name,
            "sha256": sha256_bytes(policy_bytes),
        },
        "manifestSchema": {
            "name": Path(SCHEMA_PATH).name,
            "sha256": sha256_bytes(schema_bytes),
        },
        "artifacts": records,
        "checks": load_check_report(check_report),
    }


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise EvidenceError(f"{label} fields are invalid")
    return value


def validate_manifest(manifest: dict[str, Any]) -> None:
    _exact_keys(
        manifest,
        {
            "schemaVersion",
            "product",
            "releaseVersion",
            "source",
            "policy",
            "manifestSchema",
            "artifacts",
            "checks",
        },
        "manifest",
    )
    if (
        manifest["schemaVersion"] != 1
        or manifest["product"] != "NOOP"
        or SEMVER.fullmatch(manifest["releaseVersion"]) is None
    ):
        raise EvidenceError("manifest identity or version is invalid")
    source = _exact_keys(
        manifest["source"], {"repository", "commit", "tree"}, "source"
    )
    if (
        source["repository"] != CANONICAL_REPOSITORY
        or COMMIT.fullmatch(source["commit"]) is None
        or COMMIT.fullmatch(source["tree"]) is None
    ):
        raise EvidenceError("manifest source is invalid")
    for key in ("policy", "manifestSchema"):
        record = _exact_keys(manifest[key], {"name", "sha256"}, key)
        if (
            SAFE_NAME.fullmatch(record["name"]) is None
            or "/" in record["name"]
            or "\\" in record["name"]
            or SHA256.fullmatch(record["sha256"]) is None
        ):
            raise EvidenceError(f"{key} reference is invalid")

    artifacts = manifest["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise EvidenceError("manifest has no artifacts")
    names: list[str] = []
    for artifact in artifacts:
        _exact_keys(
            artifact, {"name", "sha256", "size", "mediaType"}, "artifact"
        )
        if (
            not isinstance(artifact["name"], str)
            or SAFE_NAME.fullmatch(artifact["name"]) is None
            or "/" in artifact["name"]
            or "\\" in artifact["name"]
            or SHA256.fullmatch(artifact["sha256"]) is None
            or not isinstance(artifact["size"], int)
            or artifact["size"] < 0
            or artifact["mediaType"]
            not in {
                "application/json",
                "application/octet-stream",
                "application/vnd.cyclonedx+json",
                "text/plain",
            }
        ):
            raise EvidenceError("artifact evidence is invalid")
        names.append(artifact["name"])
    if names != sorted(set(names)):
        raise EvidenceError("artifact evidence must be unique and sorted")

    checks = manifest["checks"]
    if not isinstance(checks, list) or not checks:
        raise EvidenceError("manifest has no static checks")
    check_names: list[str] = []
    for check in checks:
        _exact_keys(check, {"name", "status"}, "check")
        if SAFE_CHECK.fullmatch(check["name"]) is None or check["status"] != "passed":
            raise EvidenceError("static check evidence is invalid")
        check_names.append(check["name"])
    if check_names != sorted(set(check_names)):
        raise EvidenceError("static checks must be unique and sorted")


def verify_manifest(
    root: Path,
    manifest_path: Path,
    artifact_directory: Path,
    expected_ref: str | None,
) -> None:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError("release manifest is missing or invalid JSON") from error
    validate_manifest(manifest)
    source = manifest["source"]
    if expected_ref is not None and source != source_identity(root, expected_ref):
        raise EvidenceError("release manifest does not match the expected source ref")
    policy = blob_at(root, source["commit"], POLICY_PATH)
    schema = blob_at(root, source["commit"], SCHEMA_PATH)
    if sha256_bytes(policy) != manifest["policy"]["sha256"]:
        raise EvidenceError("release policy digest does not match source")
    if sha256_bytes(schema) != manifest["manifestSchema"]["sha256"]:
        raise EvidenceError("manifest schema digest does not match source")
    for record in manifest["artifacts"]:
        candidate = artifact_directory / record["name"]
        if not candidate.is_file():
            raise EvidenceError(f"manifest artifact is missing: {record['name']}")
        data = candidate.read_bytes()
        if len(data) != record["size"] or sha256_bytes(data) != record["sha256"]:
            raise EvidenceError(f"manifest artifact digest mismatch: {record['name']}")


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(data))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    sbom = subparsers.add_parser("sbom", help="generate the source-tied runtime SBOM")
    sbom.add_argument("--root", type=Path, default=ROOT)
    sbom.add_argument("--source-ref", default="HEAD")
    sbom.add_argument("--version", required=True)
    sbom.add_argument("--output", type=Path, required=True)

    manifest = subparsers.add_parser(
        "manifest", help="generate a source-tied artifact/check manifest"
    )
    manifest.add_argument("--root", type=Path, default=ROOT)
    manifest.add_argument("--source-ref", default="HEAD")
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--artifact", action="append", type=Path, required=True)
    manifest.add_argument("--checks", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)

    verify = subparsers.add_parser("verify", help="verify a manifest and its artifacts")
    verify.add_argument("--root", type=Path, default=ROOT)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--artifact-directory", type=Path, required=True)
    verify.add_argument("--expect-ref")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        root = args.root.resolve()
        if args.command == "sbom":
            sbom = generate_sbom(root, args.source_ref, args.version)
            write_json(args.output, sbom)
            print(
                f"Wrote deterministic SBOM with {len(sbom['components'])} components"
            )
        elif args.command == "manifest":
            manifest = generate_manifest(
                root,
                args.source_ref,
                args.version,
                args.artifact,
                args.checks,
            )
            write_json(args.output, manifest)
            print(
                f"Wrote release manifest with {len(manifest['artifacts'])} artifacts"
            )
        else:
            verify_manifest(
                root,
                args.manifest,
                args.artifact_directory,
                args.expect_ref,
            )
            print("Release evidence manifest verified")
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
