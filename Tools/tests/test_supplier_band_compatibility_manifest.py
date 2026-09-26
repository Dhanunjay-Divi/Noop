#!/usr/bin/env python3
"""Validate the shared supplier-band runtime compatibility allowlist."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = (
    ROOT
    / "release"
    / "supplier"
    / "runtime"
    / "noop-band-compatibility.json"
)
ROW_FIELDS = {
    "platform",
    "modelCode",
    "hardwareRevision",
    "firmwareRevision",
    "protocolVersion",
    "wrapperRevision",
}
PLATFORMS = {"apple", "android"}
MAX_FIELD_LENGTH = 64
MAX_MANIFEST_BYTES = 64 * 1024
MAX_APPROVED_BANDS = 256
REJECTED_PLACEHOLDERS = {"all", "any", "default", "unknown"}
WRAPPER_BY_PLATFORM = {
    "apple": "veepoo-apple-display-v1",
    "android": "veepoo-android-display-v2",
}


def load_manifest(path: Path = MANIFEST) -> dict[str, object]:
    raw = path.read_bytes()
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ValueError("supplier compatibility manifest is oversized")
    document = json.loads(raw.decode("utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "approvedBands",
    }:
        raise ValueError("supplier compatibility manifest fields are invalid")
    if type(document["schemaVersion"]) is not int or (
        document["schemaVersion"] != 1
    ):
        raise ValueError("supplier compatibility schemaVersion must be 1")
    rows = document["approvedBands"]
    if not isinstance(rows, list) or len(rows) > MAX_APPROVED_BANDS:
        raise ValueError("supplier compatibility rows must be an array")

    identities: set[tuple[str, ...]] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or set(row) != ROW_FIELDS:
            raise ValueError(
                f"supplier compatibility row {index} fields are invalid"
            )
        values: list[str] = []
        for field in sorted(ROW_FIELDS):
            value = row[field]
            if (
                not isinstance(value, str)
                or not value
                or value != value.strip()
                or len(value) > MAX_FIELD_LENGTH
                or any(
                    ord(character) < 0x20 or ord(character) > 0x7E
                    for character in value
                )
                or "*" in value
                or "?" in value
                or value.lower() in REJECTED_PLACEHOLDERS
            ):
                raise ValueError(
                    f"supplier compatibility row {index}.{field} is invalid"
                )
            values.append(value)
        if row["platform"] not in PLATFORMS:
            raise ValueError(
                f"supplier compatibility row {index}.platform is invalid"
            )
        if row["protocolVersion"] != "noop-band-v1":
            raise ValueError(
                f"supplier compatibility row {index}.protocolVersion is invalid"
            )
        if (
            row["wrapperRevision"]
            != WRAPPER_BY_PLATFORM[row["platform"]]
        ):
            raise ValueError(
                f"supplier compatibility row {index}.wrapperRevision is invalid"
            )
        identity = tuple(values)
        if identity in identities:
            raise ValueError("supplier compatibility rows must be unique")
        identities.add(identity)
    return document


class SupplierBandCompatibilityManifestTests(unittest.TestCase):
    def test_manifest_is_strict_and_duplicate_free(self) -> None:
        document = load_manifest()
        self.assertEqual(document["schemaVersion"], 1)

    def test_both_apps_embed_the_same_manifest(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        resource = "release/supplier/runtime/noop-band-compatibility.json"
        self.assertEqual(project.count(f"- path: {resource}"), 2)

        gradle = (
            ROOT / "android" / "app" / "build.gradle.kts"
        ).read_text(encoding="utf-8")
        self.assertEqual(
            gradle.count(
                'rootProject.file("../release/supplier/runtime")'
            ),
            1,
        )

    def test_invalid_placeholders_and_platform_metadata_are_rejected(
        self,
    ) -> None:
        valid_row = {
            "platform": "apple",
            "modelCode": "42",
            "hardwareRevision": "HW-1",
            "firmwareRevision": "FW-1",
            "protocolVersion": "noop-band-v1",
            "wrapperRevision": "veepoo-apple-display-v1",
        }
        invalid_rows = []
        for placeholder in sorted(REJECTED_PLACEHOLDERS):
            invalid_rows.append({**valid_row, "modelCode": placeholder})
        invalid_rows.extend(
            [
                {**valid_row, "modelCode": "A" * 65},
                {**valid_row, "protocolVersion": "noop-band-v2"},
                {
                    **valid_row,
                    "wrapperRevision": "veepoo-android-display-v2",
                },
                {**valid_row, "platform": "unsupported"},
            ]
        )

        for row in invalid_rows:
            with self.subTest(row=row):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "manifest.json"
                    path.write_text(
                        json.dumps(
                            {
                                "schemaVersion": 1,
                                "approvedBands": [row],
                            }
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaises(ValueError):
                        load_manifest(path)


if __name__ == "__main__":
    unittest.main()
