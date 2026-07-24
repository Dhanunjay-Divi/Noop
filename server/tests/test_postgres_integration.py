from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import pytest

from app.models import SyncPayload
from app.repository import PostgresRepository

FIXTURES = Path(__file__).resolve().parent / "data"
DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")


def _load_fixture(name: str) -> SyncPayload:
    return SyncPayload.model_validate_json(
        (FIXTURES / name).read_text(encoding="utf-8")
    )


def _payload_hash(payload: SyncPayload) -> str:
    canonical = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_timescaledb_migrations_idempotency_rr_and_row_provenance() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    raw = _load_fixture("apple_sync_v1.json")
    official = _load_fixture("official_reference_sync_v1.json")

    await repository.startup()
    try:
        await repository.delete_device(raw.source.device_id)
        await repository.delete_device(official.source.device_id)

        accepted = await repository.sync(raw, _payload_hash(raw))
        duplicate = await repository.sync(raw, _payload_hash(raw))
        official_result = await repository.sync(official, _payload_hash(official))

        assert accepted.duplicate is False
        assert duplicate.duplicate is True
        assert official_result.counts.daily_metrics == 4

        rr = await repository.metric_range(
            raw.source.device_id,
            "rr",
            raw.streams.rr[0].recorded_at.replace(hour=0, minute=0, second=0),
            raw.streams.rr[0].recorded_at.replace(
                hour=23, minute=59, second=59, microsecond=999_999
            ),
            100,
        )
        assert [(row["value"], row["metadata"]["seq"]) for row in rr] == [
            (810.0, "0"),
            (825.0, "0"),
            (810.0, "1"),
        ]
        assert all(row["sync_batch_id"] == raw.batch_id for row in rr)
        assert all(
            row["source_metadata"]["logical_source_id"] == "strap-abc-strap"
            for row in rr
        )

        export = await repository.export_device(official.source.device_id, None, None)
        assert export["daily_metrics"][0]["source_metadata"]["namespace"] == (
            "official_reference"
        )
        assert export["sleep_sessions"][0]["sync_batch_id"] == official.batch_id

        pool = repository._require_pool()
        async with pool.acquire() as connection:
            migration_count = await connection.fetchval(
                "SELECT count(*) FROM noop_schema_migrations"
            )
            assert migration_count == 2
            await repository._run_migrations(connection)
            assert (
                await connection.fetchval("SELECT count(*) FROM noop_schema_migrations")
                == migration_count
            )
            assert (
                await connection.fetchval(
                    """
                    SELECT count(*)
                    FROM metric_samples
                    WHERE device_id = $1 AND metric = 'rr'
                    """,
                    raw.source.device_id,
                )
                == 3
            )
    finally:
        await repository.delete_device(raw.source.device_id)
        await repository.delete_device(official.source.device_id)
        await repository.shutdown()
