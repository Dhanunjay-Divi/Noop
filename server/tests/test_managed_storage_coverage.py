from __future__ import annotations

import json
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import get_args
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.managed_models import (
    MANAGED_CLIENT_ENCRYPTED_DOCUMENT_KINDS,
    MANAGED_DOCUMENT_CONTENT_MODES,
    MANAGED_DOCUMENT_KINDS,
    MANAGED_SERVER_READABLE_DOCUMENT_KINDS,
    ManagedDocumentKind,
    ManagedDocumentMutation,
)

ROOT = Path(__file__).resolve().parents[2]
COVERAGE = ROOT / "server" / "schemas" / "managed" / "mobile-storage-map-v1.json"
IOS_DATA = ROOT / "Packages" / "WhoopStore" / "Sources" / "WhoopStore"
ANDROID_DATA = (
    ROOT / "android" / "app" / "src" / "main" / "java" / "com" / "noop" / "data"
)
SCHEMA_SEEDS = [
    ROOT / "server" / "migrations" / "017_managed_storage_schema_seed.sql",
    ROOT / "server" / "migrations" / "020_managed_storage_stream_coverage.sql",
]


def _coverage() -> dict:
    return json.loads(COVERAGE.read_text())


def _day_ownership_payload(
    *,
    key_day: str = "2026-09-11",
    record_day: str = "2026-09-11",
    device_id: str = "test-device",
    locked: object = 0,
) -> dict:
    return {
        "schema_version": 1,
        "table": "dayOwnership",
        "key": {"day": key_day},
        "record": {
            "day": record_day,
            "deviceId": device_id,
            "locked": locked,
        },
    }


def _ios_tables() -> set[str]:
    source = "\n".join(path.read_text() for path in IOS_DATA.glob("*.swift"))
    tables = set(re.findall(r'create\(table:\s*"([^"]+)"', source))
    tables.update(
        re.findall(
            r"CREATE TABLE IF NOT EXISTS\s+([A-Za-z][A-Za-z0-9_]*)",
            source,
        )
    )
    renamed_migration_tables = set(
        re.findall(r'rename\(table:\s*"([^"]+)"\s*,\s*to:', source)
    )
    return {
        table
        for table in tables
        if not table.endswith("_new") and table not in renamed_migration_tables
    }


def _android_tables() -> set[str]:
    source = "\n".join(path.read_text() for path in ANDROID_DATA.glob("*.kt"))
    return set(
        re.findall(
            r'@Entity\s*\(.*?tableName\s*=\s*"([^"]+)"',
            source,
            flags=re.DOTALL,
        )
    )


def test_every_mobile_sqlite_table_has_an_explicit_storage_classification() -> None:
    mappings = _coverage()["sqlite_tables"]
    ios_mapped = {
        table for table, contract in mappings.items() if "ios" in contract["platforms"]
    }
    android_mapped = {
        table
        for table, contract in mappings.items()
        if "android" in contract["platforms"]
    }

    assert ios_mapped == _ios_tables()
    assert android_mapped == _android_tables()


def test_every_storage_target_resolves_to_a_registered_contract() -> None:
    coverage = _coverage()
    seed_sql = "\n".join(path.read_text() for path in SCHEMA_SEEDS)
    allowed_classes = {
        "chunk_stream",
        "local_operational",
        "managed_document",
        "opaque_backup_only",
    }

    for table, contract in coverage["sqlite_tables"].items():
        assert contract["classification"] in allowed_classes, table
        target = contract["target"]
        if contract["classification"] == "chunk_stream":
            data_class, stream_key = target.split("/", maxsplit=1)
            assert f"'{data_class}'" in seed_sql, table
            assert f"'{stream_key}'" in seed_sql, table
        elif contract["classification"] == "managed_document":
            assert target in MANAGED_DOCUMENT_KINDS, table
            assert contract["content_mode"] in {
                "client_encrypted",
                "server_readable",
            }
        elif contract["classification"] == "local_operational":
            assert target is None, table
        else:
            assert target == "encrypted_backup", table

    for target in coverage["preference_domains"].values():
        assert target in MANAGED_DOCUMENT_KINDS


def test_document_literal_and_runtime_registry_cannot_drift() -> None:
    assert set(get_args(ManagedDocumentKind)) == MANAGED_DOCUMENT_KINDS


def test_document_content_modes_match_the_mobile_storage_contract() -> None:
    coverage = _coverage()
    expected_modes: dict[str, str] = {}
    for table, contract in coverage["sqlite_tables"].items():
        if contract["classification"] != "managed_document":
            continue
        target = contract["target"]
        prior = expected_modes.setdefault(target, contract["content_mode"])
        assert prior == contract["content_mode"], table
    for target in coverage["preference_domains"].values():
        prior = expected_modes.setdefault(target, "client_encrypted")
        assert prior == "client_encrypted", target

    # These extension targets have no current mobile source table. They must
    # remain encrypted rather than becoming implicit plaintext escape hatches.
    expected_modes["other"] = "client_encrypted"
    expected_modes["user_marker"] = "client_encrypted"

    assert expected_modes == MANAGED_DOCUMENT_CONTENT_MODES
    assert MANAGED_SERVER_READABLE_DOCUMENT_KINDS == {
        "day_ownership",
    }
    assert MANAGED_CLIENT_ENCRYPTED_DOCUMENT_KINDS == (
        MANAGED_DOCUMENT_KINDS - MANAGED_SERVER_READABLE_DOCUMENT_KINDS
    )


def test_document_mutation_rejects_a_kind_content_mode_mismatch() -> None:
    common = {
        "request_id": uuid4(),
        "document_id": uuid4(),
        "base_revision": 0,
        "updated_at": datetime.now(UTC),
    }

    ManagedDocumentMutation(
        **common,
        document_kind="day_ownership",
        content_mode="server_readable",
        payload_json=_day_ownership_payload(),
    )
    ManagedDocumentMutation(
        **common,
        document_kind="journal",
        content_mode="client_encrypted",
        client_key_id=uuid4(),
        payload_ciphertext_base64="AAAAAAAAAAAAAAAAAAAAAAA=",
    )

    with pytest.raises(ValidationError, match="client_encrypted"):
        ManagedDocumentMutation(
            **common,
            document_kind="journal",
            content_mode="server_readable",
            payload_json={"notes": "must not reach plaintext storage"},
        )
    with pytest.raises(ValidationError, match="registered schema"):
        ManagedDocumentMutation(
            **common,
            document_kind="day_ownership",
            content_mode="server_readable",
            payload_json={
                "schema_version": 1,
                "table": "dayOwnership",
                "key": {"day": "2026-09-11"},
                "record": {
                    "day": "2026-09-11",
                    "deviceId": "test-device",
                    "locked": 0,
                    "notes": "plaintext escape",
                },
            },
        )
    with pytest.raises(ValidationError, match="server_readable"):
        ManagedDocumentMutation(
            **common,
            document_kind="day_ownership",
            content_mode="client_encrypted",
            client_key_id=uuid4(),
            payload_ciphertext_base64="AAAAAAAAAAAAAAAAAAAAAAA=",
        )


@pytest.mark.parametrize(
    "payload",
    [
        {
            **_day_ownership_payload(),
            "schema_version": True,
        },
        _day_ownership_payload(key_day="2026-09-10"),
        _day_ownership_payload(key_day="2026-02-30", record_day="2026-02-30"),
        _day_ownership_payload(device_id=" test-device"),
        _day_ownership_payload(device_id="test\u0001device"),
        _day_ownership_payload(device_id="test\ud800device"),
        _day_ownership_payload(device_id="x" * 257),
        _day_ownership_payload(locked=2),
        _day_ownership_payload(locked=0.5),
        _day_ownership_payload(locked="1"),
    ],
)
def test_server_readable_day_ownership_schema_fails_closed(payload: dict) -> None:
    with pytest.raises(ValidationError, match="registered schema"):
        ManagedDocumentMutation(
            request_id=uuid4(),
            document_kind="day_ownership",
            document_id=uuid4(),
            base_revision=0,
            content_mode="server_readable",
            payload_json=payload,
            updated_at=datetime.now(UTC),
        )


def test_uncalibrated_local_adc_tables_never_map_to_calibrated_metrics() -> None:
    mappings = _coverage()["sqlite_tables"]
    assert mappings["spo2Sample"]["target"] == "raw_ppg/spo2_optical_adc"
    assert mappings["skinTempSample"]["target"] == (
        "raw_auxiliary/skin_temperature_adc"
    )
    assert mappings["respSample"]["target"] == "raw_auxiliary/respiration_adc"
