from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app import managed_lifecycle
from app.managed_lifecycle import ManagedLifecycleResult, ManagedLifecycleRunner
from app.managed_identity_deletion import ManagedIdentityDeletionError
from app.managed_object_store import ManagedObjectStoreError
from app.managed_repository import ManagedProcessingBusyError
from app.managed_safety_repository import ManagedPushBatchResult


class FakeLifecycleRepository:
    def __init__(self, *, acquired: bool = True) -> None:
        self.now = datetime(2026, 9, 3, 12, tzinfo=UTC)
        self.acquired = acquired
        self.released_lease = False
        self.deleted: list = []
        self.purged = {
            "change_events": 2,
            "access_grants": 1,
        }
        self.pending_exports = [
            {
                "account_id": uuid4(),
                "export_job_id": uuid4(),
                "output_object_key": "e1/tenant/export",
                "output_generation": 99,
            }
        ]
        self.deleted_exports: list = []
        self.pending = [
            {
                "account_id": uuid4(),
                "chunk_id": uuid4(),
                "object_key": "v1/tenant/first",
                "object_generation": 41,
            },
            {
                "account_id": uuid4(),
                "chunk_id": uuid4(),
                "object_key": "v1/tenant/abandoned",
                "object_generation": None,
            },
        ]
        self.erasure_claims = [{"chunk_id": self.pending[0]["chunk_id"]}]
        self.completed_erasures = [{"erasure_job_id": uuid4()}]
        self.pending_identities = [
            {
                "account_id": uuid4(),
                "erasure_job_id": uuid4(),
                "request_id": uuid4(),
                "identity_deletion_ticket": b"sealed-ticket",
            }
        ]
        self.deleted_identities: list = []
        self.failed_identities: list = []
        self.reconciliation_candidates: list[dict] = []

    async def coordination_now(self):
        return self.now

    async def acquire_worker_lease(self, **kwargs):
        return self.acquired

    async def release_worker_lease(self, **kwargs):
        self.released_lease = True

    async def release_expired_reservations(self, **kwargs):
        return [{"chunk_id": self.pending[1]["chunk_id"]}]

    async def processing_reconciliation_candidates(self, **kwargs):
        return self.reconciliation_candidates

    async def claim_retention_deletions(self, **kwargs):
        return [{"chunk_id": self.pending[0]["chunk_id"]}]

    async def pending_chunk_deletions(self, **kwargs):
        return self.pending

    async def claim_erasure_deletions(self, **kwargs):
        return self.erasure_claims

    async def finalize_erasure_jobs(self, **kwargs):
        return self.completed_erasures

    async def pending_identity_deletions(self, **kwargs):
        return self.pending_identities

    async def mark_identity_deletion_succeeded(self, **kwargs):
        self.deleted_identities.append(kwargs["erasure_job_id"])

    async def mark_identity_deletion_failed(self, **kwargs):
        self.failed_identities.append(kwargs["erasure_job_id"])

    async def pending_export_deletions(self, **kwargs):
        return self.pending_exports

    async def mark_export_deleted(self, **kwargs):
        self.deleted_exports.append(kwargs["export_job_id"])

    async def mark_chunk_deleted(self, **kwargs):
        self.deleted.append(kwargs["chunk_id"])

    async def purge_expired_control_rows(self, **kwargs):
        return self.purged


class FakeObjectStore:
    def __init__(self, *, failing_key: str | None = None) -> None:
        self.failing_key = failing_key
        self.deletes: list[tuple[str, int | None]] = []

    async def delete(self, *, object_key: str, generation: int | None):
        self.deletes.append((object_key, generation))
        if object_key == self.failing_key:
            raise ManagedObjectStoreError("temporary")


class FakeIdentityDeleter:
    def __init__(self, *, failing: bool = False) -> None:
        self.failing = failing
        self.deleted: list[tuple[bytes, object, object]] = []

    async def delete(self, *, ticket, account_id, request_id):
        self.deleted.append((ticket, account_id, request_id))
        if self.failing:
            raise ManagedIdentityDeletionError("temporary")


class FakeChunkProcessor:
    def __init__(
        self,
        *,
        failing_key: str | None = None,
        busy_key: str | None = None,
    ) -> None:
        self.failing_key = failing_key
        self.busy_key = busy_key
        self.processed: list[tuple[str, int, str]] = []

    async def process(
        self,
        *,
        object_key: str,
        generation: int,
        queue_event_hash: str,
    ):
        self.processed.append((object_key, generation, queue_event_hash))
        if object_key == self.failing_key:
            raise ManagedObjectStoreError("temporary")
        if object_key == self.busy_key:
            raise ManagedProcessingBusyError("busy")


class FakeSafetyPushService:
    def __init__(self, result: ManagedPushBatchResult) -> None:
        self.result = result
        self.limits: list[int] = []

    async def dispatch_due(self, *, limit: int) -> ManagedPushBatchResult:
        self.limits.append(limit)
        return self.result


@pytest.mark.asyncio
async def test_lifecycle_replays_pending_deletes_and_releases_lease() -> None:
    repository = FakeLifecycleRepository()
    store = FakeObjectStore()
    identity_deleter = FakeIdentityDeleter()

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        identity_deleter,
        FakeChunkProcessor(),  # type: ignore[arg-type]
        batch_size=10,
    ).run_once(owner_id=uuid4())

    assert result.lease_acquired is True
    assert result.reservations_released == 1
    assert result.retention_claimed == 1
    assert result.objects_deleted == 2
    assert result.object_delete_failures == 0
    assert result.control_rows_purged == 3
    assert result.erasure_deletions_claimed == 1
    assert result.erasure_jobs_completed == 2
    assert result.identity_deletions_claimed == 1
    assert result.identities_deleted == 1
    assert result.identity_delete_failures == 0
    assert result.exports_deleted == 1
    assert result.export_delete_failures == 0
    assert store.deletes == [
        ("v1/tenant/first", 41),
        ("v1/tenant/abandoned", None),
        ("e1/tenant/export", 99),
    ]
    assert set(repository.deleted) == {row["chunk_id"] for row in repository.pending}
    assert repository.deleted_identities == [
        repository.pending_identities[0]["erasure_job_id"]
    ]
    assert repository.released_lease is True


@pytest.mark.asyncio
async def test_lifecycle_leaves_failed_object_pending_for_retry() -> None:
    repository = FakeLifecycleRepository()
    store = FakeObjectStore(failing_key="v1/tenant/first")

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        FakeIdentityDeleter(),
        FakeChunkProcessor(),  # type: ignore[arg-type]
    ).run_once(owner_id=uuid4())

    assert result.objects_deleted == 1
    assert result.object_delete_failures == 1
    assert result.exports_deleted == 1
    assert repository.deleted == [repository.pending[1]["chunk_id"]]
    assert repository.released_lease is True


@pytest.mark.asyncio
async def test_lifecycle_skips_when_another_worker_holds_lease() -> None:
    repository = FakeLifecycleRepository(acquired=False)
    store = FakeObjectStore()

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        FakeIdentityDeleter(),
        FakeChunkProcessor(),  # type: ignore[arg-type]
    ).run_once(owner_id=uuid4())

    assert result.lease_acquired is False
    assert store.deletes == []
    assert repository.released_lease is False


@pytest.mark.asyncio
async def test_lifecycle_retries_failed_identity_deletion() -> None:
    repository = FakeLifecycleRepository()
    store = FakeObjectStore()

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        FakeIdentityDeleter(failing=True),
        FakeChunkProcessor(),  # type: ignore[arg-type]
    ).run_once(owner_id=uuid4())

    assert result.identities_deleted == 0
    assert result.identity_delete_failures == 1
    assert result.erasure_jobs_completed == 1
    assert repository.deleted_identities == []
    assert repository.failed_identities == [
        repository.pending_identities[0]["erasure_job_id"]
    ]


@pytest.mark.asyncio
async def test_lifecycle_reconciles_stranded_uploads_and_reports_retry_state() -> None:
    repository = FakeLifecycleRepository()
    repository.reconciliation_candidates = [
        {
            "object_key": "v1/tenant/available",
            "object_generation": 41,
        },
        {
            "object_key": "v1/tenant/busy",
            "object_generation": 42,
        },
        {
            "object_key": "v1/tenant/unavailable",
            "object_generation": 43,
        },
    ]
    processor = FakeChunkProcessor(
        busy_key="v1/tenant/busy",
        failing_key="v1/tenant/unavailable",
    )

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        FakeObjectStore(),  # type: ignore[arg-type]
        FakeIdentityDeleter(),
        processor,  # type: ignore[arg-type]
    ).run_once(owner_id=uuid4())

    assert result.chunks_reconciled == 1
    assert result.chunk_reconciliation_deferred == 1
    assert result.chunk_reconciliation_failures == 1
    assert len(processor.processed) == 3
    assert all(len(queue_hash) == 64 for _, _, queue_hash in processor.processed)


@pytest.mark.asyncio
async def test_lifecycle_retries_due_managed_safety_pushes() -> None:
    repository = FakeLifecycleRepository()
    push = FakeSafetyPushService(
        ManagedPushBatchResult(
            claimed=4,
            provider_accepted=2,
            retryable_failures=1,
            terminal_failures=1,
        )
    )

    result = await ManagedLifecycleRunner(
        repository,  # type: ignore[arg-type]
        FakeObjectStore(),  # type: ignore[arg-type]
        FakeIdentityDeleter(),
        FakeChunkProcessor(),  # type: ignore[arg-type]
        safety_push_service=push,  # type: ignore[arg-type]
        batch_size=250,
    ).run_once(owner_id=uuid4())

    assert push.limits == [200]
    assert result.safety_push_claimed == 4
    assert result.safety_push_provider_accepted == 2
    assert result.safety_push_retryable_failures == 1
    assert result.safety_push_terminal_failures == 1
    assert result.safety_push_receipt_failures == 0


def test_lifecycle_cli_emits_bounded_failure_without_traceback(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    events: list[tuple[str, dict[str, object]]] = []

    async def fail() -> ManagedLifecycleResult:
        raise RuntimeError("private database detail")

    monkeypatch.setattr(managed_lifecycle, "_run", fail)
    monkeypatch.setattr(
        managed_lifecycle,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )

    with pytest.raises(SystemExit) as exit_info:
        managed_lifecycle.main()

    assert exit_info.value.code == 1
    assert capsys.readouterr().err == ""
    assert events[-1][0] == "managed_lifecycle.run"
    assert events[-1][1]["outcome"] == "failed"
    assert events[-1][1]["failure_kind"] == "RuntimeError"
    assert "private database detail" not in repr(events)


def test_lifecycle_cli_partial_failure_exits_without_exception_text(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    events: list[tuple[str, dict[str, object]]] = []

    async def partial() -> ManagedLifecycleResult:
        return ManagedLifecycleResult(
            lease_acquired=True,
            object_delete_failures=1,
        )

    monkeypatch.setattr(managed_lifecycle, "_run", partial)
    monkeypatch.setattr(
        managed_lifecycle,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )

    with pytest.raises(SystemExit) as exit_info:
        managed_lifecycle.main()

    assert exit_info.value.code == 1
    assert capsys.readouterr().err == ""
    assert events[-1][1]["outcome"] == "partial_failure"
