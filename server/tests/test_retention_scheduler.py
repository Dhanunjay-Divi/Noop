from __future__ import annotations

from datetime import UTC, datetime, timedelta
import asyncio

import pytest

from app.config import Settings
from app.main import _run_retention_once
from app.models import SyncPayload
from app.repository import MemoryRepository, SyncRetiredError

from test_api import client_payload


TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"


def settings(retention_days: int | None) -> Settings:
    return Settings(
        api_token=TOKEN,
        database_url=None,
        retention_days=retention_days,
        retention_interval_hours=6,
    )


@pytest.mark.asyncio
async def test_scheduled_cycle_uses_the_same_global_retention_contract() -> None:
    repository = MemoryRepository()
    payload = SyncPayload.model_validate(client_payload())
    await repository.sync(payload, "a" * 64)

    # Receipts age from server receipt time (not an untrusted client timestamp),
    # so advance the scheduler clock beyond both the data and receipt windows.
    now = datetime.now(UTC) + timedelta(days=31)
    counts = await _run_retention_once(
        repository,
        settings(30),
        now=now,
    )

    assert counts["metric_samples"] == 11
    assert counts["sync_batches"] == 1
    with pytest.raises(SyncRetiredError):
        await repository.sync(payload, "a" * 64)


@pytest.mark.asyncio
async def test_disabled_scheduled_retention_is_a_noop() -> None:
    repository = MemoryRepository()

    counts = await _run_retention_once(
        repository,
        settings(None),
        now=datetime(2026, 8, 11, tzinfo=UTC),
    )

    assert counts == {}


@pytest.mark.asyncio
async def test_memory_retention_cycles_use_a_dedicated_serialization_lock() -> None:
    repository = MemoryRepository()
    await repository._retention_lock.acquire()
    cycle = asyncio.create_task(
        repository.purge_before(
            datetime(2026, 8, 11, tzinfo=UTC),
            replay_guard_until=datetime(2026, 9, 10, tzinfo=UTC),
        )
    )
    await asyncio.sleep(0)
    assert cycle.done() is False

    repository._retention_lock.release()
    await cycle
