#!/usr/bin/env python3
"""Generate and verify NOOP's exact runtime notice inventory.

``check`` is the dependency-drift CI gate. ``distribution`` additionally
enforces unresolved source-provenance gates and is intentionally fail-closed.
``write`` is used only after a maintainer has reviewed new dependencies and
collected their license texts.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LICENSE_ROOT = ROOT / "ThirdPartyNotices" / "licenses"
INVENTORY_PATH = ROOT / "ThirdPartyNotices" / "runtime-inventory.json"
PREAMBLE_PATH = ROOT / "ThirdPartyNotices" / "NOTICE.preamble.md"
NOTICE_PATHS = [
    ROOT / "NOTICE",
    ROOT / "server" / "NOTICE",
    ROOT / "server" / "backup" / "NOTICE",
]
SERVER_LICENSE_PATHS = [
    ROOT / "server" / "LICENSE",
    ROOT / "server" / "backup" / "LICENSE",
]
RIGHTS_STATUS_PATH = ROOT / "docs" / "provenance" / "rights-status.json"
REQUIRED_RIGHTS_BLOCKERS = {
    "polyform-upstream-lineage",
    "unlicensed-whoop4-expression",
    "contributor-relicensing-rights",
}
REQUIRED_REFERENCE_REPOSITORIES = {
    "johnmiddleton12/wearable",
    "ryanbr/noop",
}
UNRESOLVED_PROVENANCE_MARKERS = {
    "LICENSE": (
        "PolyForm Noncommercial License 1.0.0",
        "Required Notice: Copyright 2026 NoopApp",
    ),
    "NOTICE": (
        "ryanbr/noop",
        "johnmiddleton12/my-whoop",
        "Attribution is not permission",
    ),
    "ThirdPartyNotices/NOTICE.preamble.md": (
        "ryanbr/noop",
        "johnmiddleton12/my-whoop",
        "Attribution is not permission",
    ),
    "ATTRIBUTION.md": (
        "ryanbr/noop",
        "johnmiddleton12/my-whoop",
    ),
    "README.md": (
        "PolyForm Noncommercial License 1.0.0",
        "ryanbr/noop",
        "johnmiddleton12/my-whoop",
    ),
    "TERMS.md": (
        "PolyForm Noncommercial",
        "One inherited source lineage",
        "licensed only for permitted non-commercial",
    ),
    "DISCLAIMER.md": (
        "PolyForm Noncommercial",
        "One inherited lineage",
    ),
}
TERMS_VERSION_SOURCES = {
    "TERMS.md": r"\*\*Version ([0-9]+\.[0-9]+)\*\*",
    "Strand/App/Terms.swift": r'currentVersion = "([0-9]+\.[0-9]+)"',
    "android/app/src/main/java/com/noop/ui/TermsGate.kt": (
        r'CURRENT_VERSION = "([0-9]+\.[0-9]+)"'
    ),
}

APPLE = {
    "grdb.swift": (
        "MIT",
        "https://github.com/groue/GRDB.swift",
        "apple/grdb.swift.txt",
    ),
    "networkimage": (
        "MIT",
        "https://github.com/gonzalezreal/NetworkImage",
        "apple/networkimage.txt",
    ),
    "swift-cmark": (
        "BSD-3-Clause AND bundled-component-terms",
        "https://github.com/swiftlang/swift-cmark",
        "apple/swift-cmark.txt",
    ),
    "swift-markdown-ui": (
        "MIT",
        "https://github.com/gonzalezreal/swift-markdown-ui",
        "apple/swift-markdown-ui.txt",
    ),
    "zipfoundation": (
        "MIT",
        "https://github.com/weichsel/ZIPFoundation",
        "apple/zipfoundation.txt",
    ),
}

PYTHON = {
    "annotated-doc": ("MIT", "https://github.com/fastapi/annotated-doc"),
    "annotated-types": ("MIT", "https://github.com/annotated-types/annotated-types"),
    "anyio": ("MIT", "https://github.com/agronholm/anyio"),
    "asyncpg": ("Apache-2.0", "https://github.com/MagicStack/asyncpg"),
    "click": ("BSD-3-Clause", "https://github.com/pallets/click"),
    "fastapi": ("MIT", "https://github.com/fastapi/fastapi"),
    "h11": ("MIT", "https://github.com/python-hyper/h11"),
    "httptools": ("MIT", "https://github.com/MagicStack/httptools"),
    "idna": ("BSD-3-Clause", "https://github.com/kjd/idna"),
    "pydantic": ("MIT", "https://github.com/pydantic/pydantic"),
    "pydantic-core": ("MIT", "https://github.com/pydantic/pydantic-core"),
    "python-dotenv": ("BSD-3-Clause", "https://github.com/theskumar/python-dotenv"),
    "pyyaml": ("MIT", "https://github.com/yaml/pyyaml"),
    "starlette": ("BSD-3-Clause", "https://github.com/Kludex/starlette"),
    "typing-extensions": ("PSF-2.0", "https://github.com/python/typing_extensions"),
    "typing-inspection": ("MIT", "https://github.com/pydantic/typing-inspection"),
    "uvicorn": ("BSD-3-Clause", "https://github.com/encode/uvicorn"),
    "uvloop": ("MIT AND Apache-2.0", "https://github.com/MagicStack/uvloop"),
    "watchfiles": ("MIT", "https://github.com/samuelcolvin/watchfiles"),
    "websockets": ("BSD-3-Clause", "https://github.com/python-websockets/websockets"),
}

ANDROID_APACHE_PREFIXES = (
    "androidx.",
    "com.google.code.findbugs:",
    "com.google.code.gson:",
    "com.google.crypto.tink:",
    "com.google.errorprone:",
    "com.google.guava:",
    "com.google.j2objc:",
    "com.squareup.okhttp3:",
    "com.squareup.okio:",
    "org.jetbrains:",
    "org.jetbrains.kotlin:",
    "org.jetbrains.kotlinx:",
)
ANDROID_APACHE_COORDINATES = {
    "com.google.zxing:core",
    "com.journeyapps:zxing-android-embedded",
}


class GateError(RuntimeError):
    pass


def canonical_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def license_file(relative: str) -> dict[str, str]:
    path = LICENSE_ROOT / relative
    if not path.is_file():
        raise GateError(f"missing reviewed license text: {path.relative_to(ROOT)}")
    return {"path": f"ThirdPartyNotices/licenses/{relative}", "sha256": sha256(path)}


def apple_components() -> list[dict[str, object]]:
    resolved = (
        ROOT
        / "Strand.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    )
    pins = json.loads(resolved.read_text(encoding="utf-8")).get("pins", [])
    identities = {pin["identity"] for pin in pins}
    if identities != set(APPLE):
        raise GateError(
            f"unreviewed Swift runtime graph: expected {sorted(APPLE)}, got {sorted(identities)}"
        )
    result = []
    for pin in sorted(pins, key=lambda item: item["identity"]):
        identity = pin["identity"]
        license_id, source, relative = APPLE[identity]
        state = pin["state"]
        result.append(
            {
                "ecosystem": "swiftpm",
                "name": identity,
                "version": state.get("version", ""),
                "revision": state.get("revision", ""),
                "license": license_id,
                "source": source,
                "licenseFiles": [license_file(relative)],
            }
        )
    return result


def android_coordinates() -> list[tuple[str, str, str]]:
    result = set()
    for raw in (
        (ROOT / "android/app/gradle.lockfile").read_text(encoding="utf-8").splitlines()
    ):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        coordinate, configurations = line.split("=", 1)
        if "fullReleaseRuntimeClasspath" not in configurations.split(","):
            continue
        parts = coordinate.rsplit(":", 2)
        if len(parts) != 3 or not all(parts):
            raise GateError(f"invalid locked Maven coordinate: {coordinate}")
        result.add(tuple(parts))
    if not result:
        raise GateError("Android release runtime lock is empty")
    return sorted(result)


def android_components() -> list[dict[str, object]]:
    result = []
    for group, artifact, version in android_coordinates():
        coordinate = f"{group}:{artifact}"
        files = []
        if coordinate == "androidx.glance:glance-appwidget-external-protobuf":
            license_id = "BSD-3-Clause"
            files.append(license_file("android/glance-external-protobuf-1.1.1.txt"))
        elif coordinate == "org.checkerframework:checker-qual":
            license_id = "MIT"
            files.append(license_file("android/checker-qual-3.12.0.txt"))
        elif (
            coordinate in ANDROID_APACHE_COORDINATES
            or coordinate.startswith(ANDROID_APACHE_PREFIXES)
        ):
            license_id = "Apache-2.0"
            files.append(license_file("android/Apache-2.0.txt"))
        else:
            raise GateError(f"unreviewed Maven license: {coordinate}:{version}")
        if coordinate == "com.squareup.okhttp3:okhttp":
            files.append(license_file("android/okhttp-publicsuffix-4.12.0-NOTICE.txt"))
        result.append(
            {
                "ecosystem": "maven",
                "name": coordinate,
                "version": version,
                "license": license_id,
                "source": f"https://search.maven.org/artifact/{group}/{artifact}/{version}/jar",
                "licenseFiles": files,
            }
        )
    return result


def requirement_entries(path: Path) -> dict[str, tuple[str, str]]:
    logical = []
    buffer = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        buffer += (" " if buffer else "") + stripped.rstrip("\\").strip()
        if not stripped.endswith("\\"):
            logical.append(buffer)
            buffer = ""
    if buffer:
        raise GateError(f"unterminated requirement continuation in {path}")
    result = {}
    for line in logical:
        match = re.match(r"^([A-Za-z0-9_.-]+)(\[[^]]+\])?==([^ ]+)(?:\s|$)", line)
        if not match:
            raise GateError(f"unrecognized locked requirement: {line}")
        hashes = re.findall(r"--hash=sha256:([0-9a-f]{64})(?:\s|$)", line)
        if not hashes:
            raise GateError(f"requirement is not hash locked: {match.group(1)}")
        name = canonical_name(match.group(1))
        if name in result:
            raise GateError(f"duplicate locked Python requirement: {name}")
        result[name] = (match.group(3), match.group(2) or "")
    return result


def python_components() -> list[dict[str, object]]:
    locked = requirement_entries(ROOT / "server/requirements.lock")
    if set(locked) != set(PYTHON):
        raise GateError(
            f"unreviewed Python runtime graph: expected {sorted(PYTHON)}, got {sorted(locked)}"
        )
    direct = {}
    for raw in (
        (ROOT / "server/requirements.txt").read_text(encoding="utf-8").splitlines()
    ):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)(\[[^]]+\])?==(.+)", line)
        if not match:
            raise GateError(f"server direct dependency is not exact: {line}")
        direct[canonical_name(match.group(1))] = (match.group(3), match.group(2) or "")
    for name, value in direct.items():
        if locked.get(name) != value:
            raise GateError(f"server lock disagrees with requirements.txt for {name}")
    result = []
    for name, (version, _extra) in sorted(locked.items()):
        license_id, source = PYTHON[name]
        result.append(
            {
                "ecosystem": "pypi",
                "name": name,
                "version": version,
                "license": license_id,
                "source": source,
                "licenseFiles": [license_file(f"python/{name}-{version}.txt")],
            }
        )
    return result


def container_components() -> list[dict[str, object]]:
    result = []
    for relative in ("server/Dockerfile", "server/backup/Dockerfile"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        match = re.search(r"^FROM\s+(\S+@sha256:[0-9a-f]{64})\s*$", text, re.MULTILINE)
        if not match:
            raise GateError(f"{relative} base image is not digest pinned")
        result.append({"ecosystem": "oci", "name": match.group(1), "usedBy": relative})
    compose = (ROOT / "server/compose.yaml").read_text(encoding="utf-8")
    for image in re.findall(
        r"^\s*image:\s*(\S+@sha256:[0-9a-f]{64})\s*$", compose, re.MULTILINE
    ):
        result.append(
            {
                "ecosystem": "oci",
                "name": image,
                "usedBy": "server/compose.yaml",
                "pulledOnly": True,
            }
        )
    return sorted(result, key=lambda item: (item["usedBy"], item["name"]))


def inventory() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "generatedFrom": [
            "Strand.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "android/app/gradle.lockfile:fullReleaseRuntimeClasspath",
            "server/requirements.lock",
        ],
        "components": apple_components() + android_components() + python_components(),
        "containers": container_components(),
    }


def render_notice(data: dict[str, object]) -> str:
    chunks = [
        PREAMBLE_PATH.read_text(encoding="utf-8").rstrip(),
        "",
        "Generated runtime inventory",
        "---------------------------",
        "",
    ]
    components = data["components"]
    for ecosystem in ("swiftpm", "maven", "pypi"):
        selected = [item for item in components if item["ecosystem"] == ecosystem]
        chunks.append(f"{ecosystem}: {len(selected)} components")
        for item in selected:
            revision = f" ({item['revision']})" if item.get("revision") else ""
            chunks.append(
                f"  - {item['name']} {item['version']}{revision} — {item['license']} — {item['source']}"
            )
        chunks.append("")
    chunks.append("Digest-pinned container inputs")
    for item in data["containers"]:
        suffix = " (pulled only)" if item.get("pulledOnly") else ""
        chunks.append(f"  - {item['name']} — {item['usedBy']}{suffix}")
    chunks.extend(
        ["", "Exact license and notice texts", "------------------------------", ""]
    )
    paths = {}
    for item in components:
        for entry in item["licenseFiles"]:
            paths[entry["path"]] = entry["sha256"]
    for relative, digest in sorted(paths.items()):
        chunks.append(f"===== {relative} (sha256:{digest}) =====")
        chunks.append((ROOT / relative).read_text(encoding="utf-8").rstrip())
        chunks.append("")
    chunks.append("Required Notice: Copyright 2026 NoopApp")
    return "\n".join(chunks).rstrip() + "\n"


def verified_rights_status() -> dict[str, object]:
    if not RIGHTS_STATUS_PATH.is_file():
        raise GateError(
            "repository rights status is missing; deleting provenance state does not clear it"
        )
    data = json.loads(RIGHTS_STATUS_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise GateError("repository rights status must be a JSON object")
    if data.get("schemaVersion") != 1:
        raise GateError("unsupported repository rights-status schema")
    if data.get("distributionStatus") not in {"blocked", "cleared"}:
        raise GateError("rights status must declare distributionStatus blocked or cleared")

    blockers = data.get("blockers")
    if not isinstance(blockers, list):
        raise GateError("rights status blockers must be a list")
    by_id = {}
    for blocker in blockers:
        if not isinstance(blocker, dict) or not isinstance(blocker.get("id"), str):
            raise GateError("every rights blocker must have a string id")
        blocker_id = blocker["id"]
        if blocker_id in by_id:
            raise GateError(f"duplicate rights blocker: {blocker_id}")
        if blocker.get("status") not in {"unresolved", "resolved"}:
            raise GateError(f"invalid status for rights blocker: {blocker_id}")
        by_id[blocker_id] = blocker

    missing = REQUIRED_RIGHTS_BLOCKERS - set(by_id)
    if missing:
        raise GateError(
            "required rights blockers were removed without resolution: "
            + ", ".join(sorted(missing))
        )

    unresolved = [
        blocker_id
        for blocker_id, blocker in by_id.items()
        if blocker["status"] == "unresolved"
    ]
    if unresolved:
        for relative, markers in UNRESOLVED_PROVENANCE_MARKERS.items():
            path = ROOT / relative
            if not path.is_file():
                raise GateError(
                    f"required provenance document is missing: {relative}"
                )
            text = path.read_text(encoding="utf-8")
            absent = [marker for marker in markers if marker not in text]
            if absent:
                raise GateError(
                    f"{relative} removed unresolved provenance marker(s): "
                    + ", ".join(absent)
                )

        references = json.loads(
            (ROOT / "docs/reference-repositories.lock.json").read_text(
                encoding="utf-8"
            )
        )
        repositories = (
            references.get("repositories", references)
            if isinstance(references, dict)
            else references
        )
        if not isinstance(repositories, list):
            raise GateError("reference repository lock must contain a repository list")
        repository_names = {
            item.get("repo")
            for item in repositories
            if isinstance(item, dict) and isinstance(item.get("repo"), str)
        }
        missing_repositories = REQUIRED_REFERENCE_REPOSITORIES - repository_names
        if missing_repositories:
            raise GateError(
                "reference lock removed unresolved provenance repository entries: "
                + ", ".join(sorted(missing_repositories))
            )

    for blocker_id, blocker in by_id.items():
        if blocker["status"] != "resolved":
            continue
        evidence = blocker.get("evidence")
        if not isinstance(evidence, dict):
            raise GateError(
                f"resolved rights blocker lacks structured evidence: {blocker_id}"
            )
        required_evidence = {
            "route",
            "affectedSourceManifest",
            "reviewedCommit",
            "independentReviewer",
            "evidenceLocationOrDigest",
        }
        missing_evidence = required_evidence - set(evidence)
        if missing_evidence:
            raise GateError(
                f"resolved rights blocker has incomplete evidence ({blocker_id}): "
                + ", ".join(sorted(missing_evidence))
            )
        empty_evidence = [
            key
            for key in required_evidence
            if not isinstance(evidence[key], str) or not evidence[key].strip()
        ]
        if empty_evidence:
            raise GateError(
                f"resolved rights blocker has empty evidence ({blocker_id}): "
                + ", ".join(sorted(empty_evidence))
            )
        if evidence["route"] not in {
            "rights-holder-license",
            "independent-replacement",
            "removal",
        }:
            raise GateError(f"invalid resolution route for rights blocker: {blocker_id}")

    if data["distributionStatus"] == "cleared" and unresolved:
        raise GateError(
            "rights status cannot be cleared while blockers remain unresolved: "
            + ", ".join(sorted(unresolved))
        )
    return data


def verified_terms_version() -> str:
    versions = {}
    for relative, pattern in TERMS_VERSION_SOURCES.items():
        path = ROOT / relative
        if not path.is_file():
            raise GateError(f"terms version source is missing: {relative}")
        match = re.search(pattern, path.read_text(encoding="utf-8"))
        if not match:
            raise GateError(f"terms version is missing or invalid: {relative}")
        versions[relative] = match.group(1)
    unique = set(versions.values())
    if len(unique) != 1:
        detail = ", ".join(
            f"{relative}={version}" for relative, version in sorted(versions.items())
        )
        raise GateError(f"terms acknowledgment versions disagree: {detail}")
    return unique.pop()


def checked_data() -> dict[str, object]:
    actual = inventory()
    if not INVENTORY_PATH.is_file():
        raise GateError(
            "runtime inventory is missing; review and run the gate in write mode"
        )
    expected = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))
    if actual != expected:
        raise GateError(
            "runtime dependency/license inventory drifted; review licenses before regenerating"
        )
    expected_notice = render_notice(actual)
    for path in NOTICE_PATHS:
        if not path.is_file() or path.read_text(encoding="utf-8") != expected_notice:
            raise GateError(
                f"generated notice is stale or missing: {path.relative_to(ROOT)}"
            )
    project_license = (ROOT / "LICENSE").read_bytes()
    for path in SERVER_LICENSE_PATHS:
        if not path.is_file() or path.read_bytes() != project_license:
            raise GateError(
                f"server project license is stale or missing: {path.relative_to(ROOT)}"
            )
    dockerfile = (ROOT / "server/Dockerfile").read_text(encoding="utf-8")
    if "--require-hashes --requirement requirements.lock" not in dockerfile:
        raise GateError("server image is not installing the exact hash-locked runtime")
    verified_rights_status()
    verified_terms_version()
    return actual


def distribution_gate() -> None:
    checked_data()
    rights_status = verified_rights_status()
    unresolved = sorted(
        blocker["id"]
        for blocker in rights_status["blockers"]
        if blocker["status"] == "unresolved"
    )
    if rights_status["distributionStatus"] != "cleared" or unresolved:
        details = ", ".join(unresolved) if unresolved else "manual clearance pending"
        raise GateError(
            "DISTRIBUTION BLOCKED: repository independence is not established "
            f"({details}). A new remote, fork detachment, renamed history, or deleted attribution "
            "does not grant source rights; resolve the recorded blockers with reviewed evidence."
        )


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"check", "write", "distribution"}:
        print(
            "usage: release-legal-gate.py {check|write|distribution}", file=sys.stderr
        )
        return 2
    try:
        if sys.argv[1] == "write":
            data = inventory()
            INVENTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
            INVENTORY_PATH.write_text(
                json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            notice = render_notice(data)
            for path in NOTICE_PATHS:
                path.write_text(notice, encoding="utf-8")
            project_license = (ROOT / "LICENSE").read_bytes()
            for path in SERVER_LICENSE_PATHS:
                path.write_bytes(project_license)
            print(
                f"Wrote {len(data['components'])} runtime components and {len(data['containers'])} container inputs"
            )
        elif sys.argv[1] == "check":
            data = checked_data()
            print(
                f"Legal inventory verified: {len(data['components'])} runtime components, {len(data['containers'])} container inputs"
            )
        else:
            distribution_gate()
            print("Distribution provenance gate passed")
    except (GateError, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
