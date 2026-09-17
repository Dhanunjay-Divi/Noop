from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
import pytest

from app import main as main_module
from app.config import Settings
from app.feedback_repository import MemoryFeedbackRepository
from app.main import _run_retention_once, _run_safety_retention_once, create_app
from app.models import SyncPayload
from app.repository import (
    MemoryRepository,
    MigrationManifestMismatchError,
    PostgresRepository,
    SyncRetiredError,
)
from app.safety_repository import MemorySafetyRepository

from test_api import client_payload


TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"


class StalePostgresRepository(PostgresRepository):
    def __init__(self) -> None:
        super().__init__(
            "postgresql://synthetic.invalid/noop",
            run_migrations=False,
        )
        self.started = False
        self.shutdown_called = False
        self.manifest_checked = False
        self.purge_called = False

    async def startup(self) -> None:
        self.started = True

    async def require_current_migration_manifest(self) -> None:
        self.manifest_checked = True
        raise MigrationManifestMismatchError(
            "database migration manifest does not match this build"
        )

    @asynccontextmanager
    async def maintenance_guard(self):
        await self.require_current_migration_manifest()
        yield

    async def shutdown(self) -> None:
        self.shutdown_called = True

    async def purge_before(self, *args, **kwargs) -> dict[str, int]:
        self.purge_called = True
        return {}


class TrackingSafetyRepository:
    def __init__(self) -> None:
        self.purge_called = False

    async def purge_retained_data(self, **_kwargs) -> dict[str, int]:
        self.purge_called = True
        return {}


class DriftingPostgresRepository(StalePostgresRepository):
    def __init__(self) -> None:
        super().__init__()
        self.manifest_checks = 0

    async def require_current_migration_manifest(self) -> None:
        self.manifest_checks += 1
        if self.manifest_checks > 1:
            raise MigrationManifestMismatchError(
                "database migration manifest does not match this build"
            )


class HealthyPostgresRepository(StalePostgresRepository):
    async def require_current_migration_manifest(self) -> None:
        self.manifest_checked = True


class TrackingSafetyRetentionRepository(TrackingSafetyRepository):
    async def coordination_now(self) -> datetime:
        return datetime(2026, 8, 11, tzinfo=UTC)


class AvailablePagingProvider:
    available = True


class FailingHeartbeatSafetyRepository(MemorySafetyRepository):
    async def record_worker_heartbeat(self, **_kwargs) -> None:
        raise RuntimeError("synthetic heartbeat failure")


def settings(retention_days: int | None) -> Settings:
    return Settings(
        api_token=TOKEN,
        database_url=None,
        retention_days=retention_days,
        retention_interval_hours=6,
    )


@pytest.mark.asyncio
async def test_api_lifecycle_gate_rejects_forward_schema_with_bounded_event(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = StalePostgresRepository()
    events: list[tuple[str, dict[str, object]]] = []
    monkeypatch.setattr(
        main_module,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
        ),
        repository=repository,
    )

    with pytest.raises(MigrationManifestMismatchError):
        async with app.router.lifespan_context(app):
            pass

    assert repository.started is True
    assert repository.manifest_checked is True
    assert repository.shutdown_called is True
    assert events == [
        (
            "runtime.startup",
            {
                "severity": "ERROR",
                "service": "noop-api",
                "outcome": "rejected",
                "failure_kind": "MigrationManifestMismatchError",
            },
        )
    ]
    assert "database migration manifest does not match this build" not in repr(events)


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
async def test_global_retention_revalidates_manifest_before_mutation() -> None:
    repository = StalePostgresRepository()

    with pytest.raises(MigrationManifestMismatchError):
        await _run_retention_once(
            repository,
            settings(30),
            now=datetime(2026, 8, 11, tzinfo=UTC),
        )

    assert repository.manifest_checked is True
    assert repository.purge_called is False


@pytest.mark.asyncio
async def test_safety_retention_revalidates_manifest_before_mutation() -> None:
    primary = StalePostgresRepository()
    repository = TrackingSafetyRepository()
    safety_settings = Settings(
        api_token=TOKEN,
        database_url=None,
        safety_incident_retention_days=30,
    )

    with pytest.raises(MigrationManifestMismatchError):
        await _run_safety_retention_once(
            repository,  # type: ignore[arg-type]
            safety_settings,
            manifest_repository=primary,
            now=datetime(2026, 8, 11, tzinfo=UTC),
        )

    assert primary.manifest_checked is True
    assert repository.purge_called is False


def test_manual_global_retention_revalidates_manifest_before_mutation() -> None:
    repository = DriftingPostgresRepository()
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
            retention_days=30,
        ),
        repository=repository,
    )

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post(
            "/v1/admin/retention/run",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "X-Noop-Confirm": "PURGE",
            },
            json={},
        )

    assert response.status_code == 500
    assert repository.manifest_checks == 2
    assert repository.purge_called is False
    assert repository.shutdown_called is True


def test_manual_safety_retention_revalidates_manifest_before_mutation() -> None:
    repository = DriftingPostgresRepository()
    safety_repository = TrackingSafetyRetentionRepository()
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
            safety_incident_retention_days=30,
        ),
        repository=repository,
        safety_repository=safety_repository,  # type: ignore[arg-type]
    )

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post(
            "/v1/admin/safety/retention/run",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "X-Noop-Confirm": "PURGE SAFETY",
            },
        )

    assert response.status_code == 500
    assert repository.manifest_checks == 2
    assert safety_repository.purge_called is False
    assert repository.shutdown_called is True


@pytest.mark.asyncio
async def test_api_shutdown_closes_repository_after_feedback_task_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = HealthyPostgresRepository()

    async def fail_feedback_worker(**_kwargs) -> None:
        raise RuntimeError("synthetic feedback task failure")

    monkeypatch.setattr(
        main_module,
        "feedback_lifecycle_worker",
        fail_feedback_worker,
    )
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
            feedback_lifecycle_enabled=True,
            feedback_bucket="synthetic-feedback-bucket",
            managed_signer_email="feedback@synthetic.invalid",
        ),
        repository=repository,
        feedback_repository=MemoryFeedbackRepository(),
        feedback_object_store=object(),  # type: ignore[arg-type]
    )

    with pytest.raises(RuntimeError, match="synthetic feedback task failure"):
        async with app.router.lifespan_context(app):
            await asyncio.sleep(0)

    assert repository.shutdown_called is True


@pytest.mark.asyncio
async def test_api_startup_heartbeat_failure_cancels_started_tasks_and_closes_repository(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = HealthyPostgresRepository()

    async def wait_for_retention(*_args, **_kwargs) -> None:
        await asyncio.Event().wait()

    monkeypatch.setattr(main_module, "_retention_worker", wait_for_retention)
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
            retention_days=30,
        ),
        repository=repository,
        safety_repository=FailingHeartbeatSafetyRepository(),
        paging_provider=AvailablePagingProvider(),  # type: ignore[arg-type]
    )

    with pytest.raises(RuntimeError, match="synthetic heartbeat failure"):
        async with app.router.lifespan_context(app):
            pass

    assert not any(
        task.get_name() == "noop-retention" and not task.done()
        for task in asyncio.all_tasks()
    )
    assert repository.shutdown_called is True


@pytest.mark.asyncio
async def test_api_shutdown_awaits_every_task_when_first_task_already_failed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = HealthyPostgresRepository()
    cancelled = {
        "retention": asyncio.Event(),
        "safety_retention": asyncio.Event(),
        "feedback": asyncio.Event(),
    }

    async def fail_safety_worker(_self) -> None:
        raise RuntimeError("synthetic safety task failure")

    def waiting_worker(name: str):
        async def wait(*_args, **_kwargs) -> None:
            try:
                await asyncio.Event().wait()
            finally:
                cancelled[name].set()

        return wait

    monkeypatch.setattr(
        main_module.SafetyDeliveryWorker,
        "run",
        fail_safety_worker,
    )
    monkeypatch.setattr(
        main_module,
        "_retention_worker",
        waiting_worker("retention"),
    )
    monkeypatch.setattr(
        main_module,
        "_safety_retention_worker",
        waiting_worker("safety_retention"),
    )
    monkeypatch.setattr(
        main_module,
        "feedback_lifecycle_worker",
        waiting_worker("feedback"),
    )
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url="postgresql://synthetic.invalid/noop",
            retention_days=30,
            safety_incident_retention_days=30,
            feedback_lifecycle_enabled=True,
            feedback_bucket="synthetic-feedback-bucket",
            managed_signer_email="feedback@synthetic.invalid",
        ),
        repository=repository,
        safety_repository=MemorySafetyRepository(),
        paging_provider=AvailablePagingProvider(),  # type: ignore[arg-type]
        feedback_repository=MemoryFeedbackRepository(),
        feedback_object_store=object(),  # type: ignore[arg-type]
    )

    with pytest.raises(RuntimeError, match="synthetic safety task failure"):
        async with app.router.lifespan_context(app):
            await asyncio.sleep(0)

    assert all(event.is_set() for event in cancelled.values())
    assert repository.shutdown_called is True


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
