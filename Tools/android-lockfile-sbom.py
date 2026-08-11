#!/usr/bin/env python3
"""Emit a deterministic CycloneDX inventory from Gradle's locked release runtime graph."""

from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path
from urllib.parse import quote


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: android-lockfile-sbom.py <gradle.lockfile> <output.cdx.json> <app-version>"
        )
    lockfile = Path(sys.argv[1])
    output = Path(sys.argv[2])
    app_version = sys.argv[3]
    coordinates: set[tuple[str, str, str]] = set()
    for raw_line in lockfile.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        coordinate, configurations = line.split("=", 1)
        if "fullReleaseRuntimeClasspath" not in configurations.split(","):
            continue
        parts = coordinate.rsplit(":", 2)
        if len(parts) == 3 and all(parts):
            coordinates.add((parts[0], parts[1], parts[2]))

    components = []
    for group, name, version in sorted(coordinates):
        purl = (
            f"pkg:maven/{quote(group, safe='.')}/{quote(name, safe='.-_')}@"
            f"{quote(version, safe='.-_')}"
        )
        components.append(
            {
                "type": "library",
                "bom-ref": purl,
                "group": group,
                "name": name,
                "version": version,
                "purl": purl,
            }
        )

    identity = app_version + "\n" + "\n".join(
        component["bom-ref"] for component in components
    )
    bom = {
        "$schema": "https://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, identity)}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "NOOP Android",
                "version": app_version,
            },
            "properties": [
                {
                    "name": "noop:sbom:source",
                    "value": "android/app/gradle.lockfile:fullReleaseRuntimeClasspath",
                }
            ],
        },
        "components": components,
    }
    output.write_text(json.dumps(bom, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {len(components)} locked runtime components to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
