from __future__ import annotations

import json
import re
from pathlib import Path
from typing import get_args

from app.managed_models import MANAGED_DOCUMENT_KINDS, ManagedDocumentKind

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


def test_uncalibrated_local_adc_tables_never_map_to_calibrated_metrics() -> None:
    mappings = _coverage()["sqlite_tables"]
    assert mappings["spo2Sample"]["target"] == "raw_ppg/spo2_optical_adc"
    assert mappings["skinTempSample"]["target"] == (
        "raw_auxiliary/skin_temperature_adc"
    )
    assert mappings["respSample"]["target"] == "raw_auxiliary/respiration_adc"
