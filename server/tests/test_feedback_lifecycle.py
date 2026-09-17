from __future__ import annotations

import asyncio
import hashlib
from contextlib import asynccontextmanager
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app import feedback_lifecycle
from app.config import Settings
from app.feedback_lifecycle import (
    feedback_lifecycle_worker,
    run_feedback_cleanup_once,
    run_feedback_lifecycle_once,
    run_feedback_retention_once,
    run_feedback_tombstone_retention_once,
)
from app.feedback_repository import (
    FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME,
    FeedbackConflictError,
    FeedbackGoneError,
    FeedbackIdempotencyTombstone,
    FeedbackNotFoundError,
    FeedbackQuotaExceededError,
    FeedbackReport,
    FeedbackTombstoneRetentionResult,
    MemoryFeedbackRepository,
)
from app.managed_object_store import (
    ManagedObjectMetadata,
    ManagedObjectNotFoundError,
    ManagedObjectStoreError,
)
from app.repository import MigrationManifestMismatchError


CONFIRMATION_DELAY_SECONDS = 60
FINALIZATION_GRACE = timedelta(minutes=5)


class TrackingStore:
    def __init__(self, *, present: bool = True, unavailable: bool = False) -> None:
        self.present = present
        self.unavailable = unavailable
        self.generation = 42
        self.deleted: list[tuple[str, int | None]] = []
        self.deleted_event = asyncio.Event()

    async def latest_metadata(self, *, object_key: str) -> ManagedObjectMetadata:
        if self.unavailable:
            raise ManagedObjectStoreError("unavailable")
        if not self.present:
            raise ManagedObjectNotFoundError("missing")
        return ManagedObjectMetadata(
            object_key=object_key,
            generation=self.generation,
            metageneration=1,
            crc32c="AAAAAA==",
            size=100,
            content_type="application/zip",
            metadata={},
        )

    async def delete(self, *, object_key: str, generation: int | None) -> None:
        if self.unavailable:
            raise ManagedObjectStoreError("unavailable")
        if not self.present:
            raise ManagedObjectNotFoundError("missing")
        if generation is not None and generation != self.generation:
            raise ManagedObjectNotFoundError("missing")
        self.deleted.append((object_key, generation))
        self.present = False
        self.deleted_event.set()


class FailingCleanupRepository(MemoryFeedbackRepository):
    async def claim_cleanup(self, **_kwargs):
        raise RuntimeError("synthetic cleanup stage failure")


class TrackingLifecycleRepository(MemoryFeedbackRepository):
    def __init__(self) -> None:
        super().__init__()
        self.cleanup_claimed = False
        self.retention_claimed = False

    async def claim_cleanup(self, **kwargs):
        self.cleanup_claimed = True
        return await super().claim_cleanup(**kwargs)

    async def claim_expired(self, **kwargs):
        self.retention_claimed = True
        return await super().claim_expired(**kwargs)


class SaturatedTombstoneRetentionRepository(MemoryFeedbackRepository):
    async def purge_expired_tombstones(self, **_kwargs):
        return FeedbackTombstoneRetentionResult(
            purged_count=20,
            remaining_expired_count=(
                feedback_lifecycle._TOMBSTONE_REMAINING_COUNT_OBSERVABILITY_MAX + 1
            ),
            oldest_expired_age_seconds=(
                feedback_lifecycle._TOMBSTONE_AGE_OBSERVABILITY_MAX_SECONDS + 1
            ),
        )


class StaleMigrationPrimary:
    def __init__(self) -> None:
        self.started = False
        self.shutdown_called = False

    async def startup(self) -> None:
        self.started = True

    @asynccontextmanager
    async def maintenance_guard(self):
        raise MigrationManifestMismatchError(
            "database migration manifest does not match this build"
        )
        yield

    async def shutdown(self) -> None:
        self.shutdown_called = True


async def test_feedback_lifecycle_rejects_forward_schema_before_mutation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(
        api_token=None,
        database_url="postgresql://synthetic.invalid/noop",
        feedback_lifecycle_enabled=True,
        feedback_bucket="synthetic-feedback-bucket",
        managed_signer_email="feedback@synthetic.invalid",
    )
    primary = StaleMigrationPrimary()

    monkeypatch.setattr(
        feedback_lifecycle.Settings,
        "from_env",
        classmethod(lambda cls: settings),
    )
    monkeypatch.setattr(
        feedback_lifecycle,
        "PostgresRepository",
        lambda *args, **kwargs: primary,
    )

    def reject_mutating_dependency(*args, **kwargs):
        raise AssertionError("mutating feedback dependency was constructed")

    monkeypatch.setattr(
        feedback_lifecycle,
        "PostgresFeedbackRepository",
        reject_mutating_dependency,
    )

    with pytest.raises(MigrationManifestMismatchError):
        await feedback_lifecycle._run()

    assert primary.started is True
    assert primary.shutdown_called is True


async def test_feedback_cycle_revalidates_manifest_before_claiming_data() -> None:
    repository = TrackingLifecycleRepository()

    @asynccontextmanager
    async def reject_stale_manifest():
        raise MigrationManifestMismatchError(
            "database migration manifest does not match this build"
        )
        yield

    with pytest.raises(MigrationManifestMismatchError):
        await run_feedback_lifecycle_once(
            repository=repository,
            object_store=TrackingStore(),  # type: ignore[arg-type]
            batch_size=10,
            confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
            maintenance_guard=reject_stale_manifest,
        )

    assert repository.cleanup_claimed is False
    assert repository.retention_claimed is False


async def test_feedback_worker_retries_manifest_failure_with_bounded_event(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = TrackingLifecycleRepository()
    events: list[tuple[str, dict[str, object]]] = []
    manifest_calls = 0
    retried = asyncio.Event()
    hold_third_check = asyncio.Event()

    @asynccontextmanager
    async def flaky_manifest_guard():
        nonlocal manifest_calls
        manifest_calls += 1
        if manifest_calls == 1:
            raise RuntimeError("private synthetic database detail")
        if manifest_calls == 2:
            retried.set()
        else:
            await hold_third_check.wait()
        yield

    monkeypatch.setattr(
        feedback_lifecycle,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )
    task = asyncio.create_task(
        feedback_lifecycle_worker(
            repository=repository,
            object_store=TrackingStore(),  # type: ignore[arg-type]
            interval_seconds=0,
            batch_size=10,
            confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
            maintenance_guard=flaky_manifest_guard,
        )
    )
    try:
        await asyncio.wait_for(retried.wait(), timeout=1)
        await asyncio.sleep(0)
        assert task.done() is False
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    manifest_events = [
        fields
        for event, fields in events
        if event == "feedback.lifecycle_manifest_check"
    ]
    assert len(manifest_events) == 1
    assert manifest_events[0]["service"] == "noop-feedback-lifecycle"
    assert manifest_events[0]["severity"] == "ERROR"
    assert manifest_events[0]["outcome"] == "failed"
    assert manifest_events[0]["failure_kind"] == "RuntimeError"
    assert isinstance(manifest_events[0]["duration_ms"], int)
    assert "private synthetic database detail" not in repr(events)
    assert manifest_calls >= 2


def _report(
    *,
    now: datetime,
    status: str,
    retained_until: datetime,
    upload_expires_at: datetime,
    suffix: str,
    created_at: datetime | None = None,
    subject_hash: str = "0" * 64,
    principal_hash: str = "1" * 64,
    cleanup_after: datetime | None = None,
    object_absence_confirmed_at: datetime | None = None,
) -> FeedbackReport:
    report_created_at = created_at or now - timedelta(days=31)
    completed_at = report_created_at if status == "sent" else None
    needs_cleanup = status in {"reserved", "rejected", "deleting"}
    return FeedbackReport(
        report_id=uuid4(),
        client_app_id="1:123456:ios:abcdef12",
        subject_hash=subject_hash,
        principal_hash_version=1,
        principal_hash=principal_hash,
        idempotency_hash=hashlib.sha256(f"idempotency-{suffix}".encode()).hexdigest(),
        request_hash=hashlib.sha256(f"request-{suffix}".encode()).hexdigest(),
        platform="ios",
        app_version="9.2.0",
        archive_bytes=100,
        archive_sha256=hashlib.sha256(f"archive-{suffix}".encode()).hexdigest(),
        includes_user_note=False,
        includes_screenshot=False,
        receipt=f"NF-{suffix.upper() * 16}",
        object_key=f"v1/feedback/2026/09/12/{uuid4()}.zip",
        status=status,
        object_generation=42 if status == "sent" else None,
        created_at=report_created_at,
        upload_expires_at=upload_expires_at,
        completed_at=completed_at,
        retained_until=retained_until,
        deleted_at=None,
        cleanup_after=(
            cleanup_after
            if cleanup_after is not None
            else upload_expires_at + FINALIZATION_GRACE
            if needs_cleanup
            else None
        ),
        cleanup_phase="delete_pending" if needs_cleanup else None,
        object_absence_confirmed_at=object_absence_confirmed_at,
    )


async def test_feedback_retention_requires_confirmed_absence_before_metadata_delete() -> (
    None
):
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=31),
        suffix="a",
    )
    current = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="b",
    )
    await repository.reserve(report=expired)
    await repository.reserve(report=current)
    store = TrackingStore()

    first_pass = await run_feedback_retention_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )
    before_confirmation = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now + timedelta(seconds=CONFIRMATION_DELAY_SECONDS - 1),
    )
    confirmation_at = now + timedelta(seconds=CONFIRMATION_DELAY_SECONDS)
    confirmation = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=confirmation_at,
    )
    purge = await run_feedback_retention_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=confirmation_at,
    )

    assert first_pass == {
        "claimed": 1,
        "deleted": 0,
        "rescheduled": 1,
        "failed": 0,
    }
    assert before_confirmation == {
        "claimed": 0,
        "deleted": 0,
        "rescheduled": 0,
        "failed": 0,
    }
    assert confirmation == {
        "claimed": 1,
        "deleted": 1,
        "rescheduled": 0,
        "failed": 0,
    }
    assert purge == {
        "claimed": 1,
        "deleted": 1,
        "rescheduled": 0,
        "failed": 0,
    }
    assert store.deleted == [(expired.object_key, None)]
    with pytest.raises(FeedbackNotFoundError):
        await repository.get(
            report_id=expired.report_id,
            client_app_id=expired.client_app_id,
        )
    assert (
        await repository.get(
            report_id=current.report_id,
            client_app_id=current.client_app_id,
        )
    ).status == "reserved"


async def test_feedback_retention_retires_idempotency_key_for_bounded_window() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=28),
        suffix="q",
        object_absence_confirmed_at=now - timedelta(minutes=1),
    )
    await repository.reserve(report=expired)
    pre_delete_replay = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="q",
        created_at=now,
    )
    with pytest.raises(FeedbackNotFoundError):
        await repository.reserve(report=pre_delete_replay)
    with pytest.raises(FeedbackNotFoundError):
        await repository.get_by_idempotency(
            client_app_id=expired.client_app_id,
            principal_hash_version=expired.principal_hash_version,
            principal_hash=expired.principal_hash,
            idempotency_hash=expired.idempotency_hash,
            now=now,
        )
    claim = (await repository.claim_expired(now=now, limit=1))[0]
    assert claim.cleanup_claimed_at is not None
    assert await repository.finish_expired(
        report_id=expired.report_id,
        claim_token=claim.cleanup_claimed_at,
        deleted_at=now,
    )

    replay = _report(
        now=now + timedelta(seconds=1),
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="q",
        created_at=now + timedelta(seconds=1),
    )
    with pytest.raises(FeedbackGoneError):
        await repository.reserve(report=replay)
    with pytest.raises(FeedbackGoneError):
        await repository.get_by_idempotency(
            client_app_id=expired.client_app_id,
            principal_hash_version=expired.principal_hash_version,
            principal_hash=expired.principal_hash,
            idempotency_hash=expired.idempotency_hash,
            now=now + timedelta(seconds=1),
        )

    expires_at = expired.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
    assert await run_feedback_tombstone_retention_once(
        repository=repository,
        limit=10,
        now=expires_at - timedelta(microseconds=1),
    ) == FeedbackTombstoneRetentionResult(
        purged_count=0,
        remaining_expired_count=0,
        oldest_expired_age_seconds=0,
    )
    assert await run_feedback_tombstone_retention_once(
        repository=repository,
        limit=10,
        now=expires_at,
    ) == FeedbackTombstoneRetentionResult(
        purged_count=1,
        remaining_expired_count=0,
        oldest_expired_age_seconds=0,
    )
    replacement = _report(
        now=expires_at,
        status="reserved",
        retained_until=expires_at + timedelta(days=28),
        upload_expires_at=expires_at + timedelta(minutes=15),
        suffix="q",
        created_at=expires_at,
    )
    reserved, created = await repository.reserve(report=replacement)
    assert created is True
    assert reserved.report_id == replacement.report_id


async def test_feedback_tombstone_retention_reports_post_purge_backlog(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    now = datetime.now(UTC).replace(microsecond=0)
    repository = MemoryFeedbackRepository()
    events: list[tuple[str, dict[str, object]]] = []
    for offset, age_seconds in enumerate((180, 120, 60), start=1):
        principal_hash = hashlib.sha256(f"principal-{offset}".encode()).hexdigest()
        idempotency_hash = hashlib.sha256(f"key-{offset}".encode()).hexdigest()
        expires_at = now - timedelta(seconds=age_seconds)
        key = (
            "1:123456789012:ios:0123456789abcdef",
            1,
            principal_hash,
            idempotency_hash,
        )
        repository._tombstones[key] = FeedbackIdempotencyTombstone(
            client_app_id=key[0],
            principal_hash_version=key[1],
            principal_hash=key[2],
            idempotency_hash=key[3],
            reserved_at=(expires_at - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME),
            expires_at=expires_at,
        )

    monkeypatch.setattr(
        feedback_lifecycle,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )

    result = await run_feedback_tombstone_retention_once(
        repository=repository,
        limit=1,
        now=now,
    )

    assert result == FeedbackTombstoneRetentionResult(
        purged_count=1,
        remaining_expired_count=2,
        oldest_expired_age_seconds=120,
    )
    assert events == [
        (
            "feedback.idempotency_tombstone_retention",
            {
                "service": "noop-feedback-lifecycle",
                "outcome": "backlog_remaining",
                "purged_count": 1,
                "remaining_expired_count": 2,
                "remaining_expired_count_saturated": False,
                "oldest_expired_age_seconds": 120,
                "oldest_expired_age_saturated": False,
            },
        )
    ]
    assert principal_hash not in repr(events)
    assert idempotency_hash not in repr(events)


async def test_feedback_tombstone_retention_observability_is_bounded(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[tuple[str, dict[str, object]]] = []
    monkeypatch.setattr(
        feedback_lifecycle,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )

    result = await run_feedback_tombstone_retention_once(
        repository=SaturatedTombstoneRetentionRepository(),
        limit=20,
    )

    assert result.remaining_expired_count == (
        feedback_lifecycle._TOMBSTONE_REMAINING_COUNT_OBSERVABILITY_MAX + 1
    )
    assert events[0][1]["remaining_expired_count"] == (
        feedback_lifecycle._TOMBSTONE_REMAINING_COUNT_OBSERVABILITY_MAX
    )
    assert events[0][1]["remaining_expired_count_saturated"] is True
    assert events[0][1]["oldest_expired_age_seconds"] == (
        feedback_lifecycle._TOMBSTONE_AGE_OBSERVABILITY_MAX_SECONDS
    )
    assert events[0][1]["oldest_expired_age_saturated"] is True


async def test_feedback_retention_skips_already_expired_tombstone_horizon() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(days=17),
        upload_expires_at=now - timedelta(days=44),
        suffix="z",
        created_at=(
            now - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME - timedelta(seconds=1)
        ),
        object_absence_confirmed_at=now - timedelta(days=17),
    )
    await repository.reserve(report=expired)
    repository._reports[expired.report_id] = replace(
        expired,
        cleanup_claimed_at=now,
    )

    assert await repository.finish_expired(
        report_id=expired.report_id,
        claim_token=now,
        deleted_at=now,
    )
    replacement = replace(
        expired,
        report_id=uuid4(),
        status="reserved",
        created_at=now,
        upload_expires_at=now + timedelta(minutes=15),
        retained_until=now + timedelta(days=28),
        completed_at=None,
        cleanup_after=now + timedelta(minutes=20),
        cleanup_phase="delete_pending",
        cleanup_claimed_at=None,
        object_absence_confirmed_at=None,
    )
    reserved, created = await repository.reserve(report=replacement)
    assert created is True
    assert reserved.report_id == replacement.report_id


async def test_lingering_report_releases_key_at_total_lifetime() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    created_at = now - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
    lingering = _report(
        now=now,
        status="sent",
        retained_until=created_at + timedelta(days=28),
        upload_expires_at=created_at + timedelta(minutes=15),
        suffix="y",
        created_at=created_at,
        object_absence_confirmed_at=now - timedelta(minutes=1),
    )
    await repository.reserve(report=lingering)

    replacement = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="y",
        created_at=now,
    )
    reserved, created = await repository.reserve(report=replacement)

    assert created is True
    assert reserved.report_id == replacement.report_id
    assert (
        repository._reports[lingering.report_id].idempotency_hash
        != lingering.idempotency_hash
    )
    repository._reports[lingering.report_id] = replace(
        repository._reports[lingering.report_id],
        cleanup_claimed_at=now,
    )
    assert await repository.finish_expired(
        report_id=lingering.report_id,
        claim_token=now,
        deleted_at=now,
    )
    recovered = await repository.get_by_idempotency(
        client_app_id=replacement.client_app_id,
        principal_hash_version=replacement.principal_hash_version,
        principal_hash=replacement.principal_hash,
        idempotency_hash=replacement.idempotency_hash,
        now=now,
    )
    assert recovered.report_id == replacement.report_id
    assert repository._tombstones == {}


async def test_retention_confirmation_repository_blocks_early_cleanup_claim() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=31),
        suffix="p",
    )
    await repository.reserve(report=report)

    retention_claim = (await repository.claim_expired(now=now, limit=1))[0]
    assert retention_claim.cleanup_claimed_at is not None
    next_check_at = now + timedelta(seconds=CONFIRMATION_DELAY_SECONDS)
    assert await repository.schedule_expired_confirmation(
        report_id=report.report_id,
        claim_token=retention_claim.cleanup_claimed_at,
        next_check_at=next_check_at,
    )

    assert await repository.claim_cleanup(now=now, limit=1) == []
    assert (
        await repository.claim_cleanup(
            now=next_check_at - timedelta(microseconds=1),
            limit=1,
        )
        == []
    )
    due = await repository.claim_cleanup(now=next_check_at, limit=1)
    assert len(due) == 1
    assert due[0].cleanup_phase == "confirm_absent"


async def test_feedback_retention_does_not_bypass_pending_cleanup() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="reserved",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=31),
        suffix="c",
    )
    await repository.reserve(report=expired)

    retention = await run_feedback_retention_once(
        repository=repository,
        object_store=TrackingStore(present=False),  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )

    assert retention == {
        "claimed": 0,
        "deleted": 0,
        "rescheduled": 0,
        "failed": 0,
    }
    pending = await repository.get(
        report_id=expired.report_id,
        client_app_id=expired.client_app_id,
    )
    assert pending.cleanup_phase == "delete_pending"


async def test_cancel_cleanup_waits_for_expiry_grace_and_confirms_absence() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="d",
        created_at=now,
    )
    await repository.reserve(report=report)
    deadline = report.upload_expires_at + FINALIZATION_GRACE
    deleting = await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now,
        cleanup_after=deadline,
    )
    store = TrackingStore()

    before_deadline = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=deadline - timedelta(seconds=1),
    )
    first_pass = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=deadline,
    )
    confirmation = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=deadline + timedelta(seconds=CONFIRMATION_DELAY_SECONDS),
    )

    assert deleting.status == "deleting"
    assert before_deadline == {
        "claimed": 0,
        "deleted": 0,
        "rescheduled": 0,
        "failed": 0,
    }
    assert first_pass == {
        "claimed": 1,
        "deleted": 0,
        "rescheduled": 1,
        "failed": 0,
    }
    assert confirmation == {
        "claimed": 1,
        "deleted": 1,
        "rescheduled": 0,
        "failed": 0,
    }
    cleaned = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert cleaned.status == "deleted"
    assert cleaned.cleanup_after is None
    assert cleaned.cleanup_phase is None
    assert cleaned.cleanup_claimed_at is None
    assert store.deleted == [(report.object_key, None)]


async def test_abandoned_reserved_upload_is_cleaned_after_expiry_grace() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now - timedelta(minutes=10),
        cleanup_after=now,
        suffix="e",
    )
    await repository.reserve(report=report)
    store = TrackingStore(present=False)

    first = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )
    second = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now + timedelta(seconds=CONFIRMATION_DELAY_SECONDS),
    )

    assert first["rescheduled"] == 1
    assert second["deleted"] == 1
    assert (
        await repository.get(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
        )
    ).status == "deleted"


async def test_cleanup_deletes_late_object_and_reschedules_confirmation() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now - timedelta(minutes=10),
        cleanup_after=now,
        suffix="f",
    )
    await repository.reserve(report=report)
    store = TrackingStore(present=False)

    await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )
    store.present = True
    second = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now + timedelta(seconds=CONFIRMATION_DELAY_SECONDS),
    )
    third = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now + timedelta(seconds=2 * CONFIRMATION_DELAY_SECONDS),
    )

    assert second == {
        "claimed": 1,
        "deleted": 0,
        "rescheduled": 1,
        "failed": 0,
    }
    assert store.deleted == [(report.object_key, store.generation)]
    assert third["deleted"] == 1


async def test_delete_deadline_uses_latest_upload_expiry_atomically() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now + timedelta(minutes=5),
        suffix="g",
        created_at=now,
    )
    await repository.reserve(report=report)
    capability_expiry = now + timedelta(minutes=15)
    cleanup_after = capability_expiry + FINALIZATION_GRACE
    refreshed = await repository.activate_upload_capability(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        activated_at=now,
        upload_expires_at=capability_expiry,
        cleanup_after=cleanup_after,
    )
    deleting = await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now + timedelta(minutes=1),
        cleanup_after=cleanup_after,
    )

    assert refreshed.upload_expires_at == capability_expiry
    assert refreshed.cleanup_after == cleanup_after
    assert deleting.cleanup_after == cleanup_after


@pytest.mark.parametrize("terminal_state", ("deleting", "rejected"))
async def test_live_terminal_capability_counts_toward_pending_quota(
    terminal_state: str,
) -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    first = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="h",
        created_at=now,
    )
    second = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="i",
        created_at=now,
    )
    await repository.reserve(report=first, pending_byte_limit=150)
    cleanup_after = first.upload_expires_at + FINALIZATION_GRACE
    if terminal_state == "deleting":
        await repository.request_delete(
            report_id=first.report_id,
            client_app_id=first.client_app_id,
            requested_at=now,
            cleanup_after=cleanup_after,
        )
    else:
        await repository.mark_rejected(
            report_id=first.report_id,
            client_app_id=first.client_app_id,
            rejected_at=now,
            cleanup_after=cleanup_after,
        )

    with pytest.raises(FeedbackQuotaExceededError):
        await repository.reserve(report=second, pending_byte_limit=150)


async def test_mark_sent_cannot_race_active_cleanup_claim() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now - timedelta(minutes=10),
        cleanup_after=now,
        suffix="j",
    )
    await repository.reserve(report=report)
    claimed = await repository.claim_cleanup(now=now, limit=1)
    assert len(claimed) == 1

    with pytest.raises(FeedbackConflictError):
        await repository.mark_sent(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            object_generation=42,
            completed_at=now,
        )


async def test_stale_cleanup_owner_cannot_transition_reclaimed_row() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="deleting",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now - timedelta(hours=1),
        cleanup_after=now - timedelta(hours=1),
        suffix="k",
    )
    await repository.reserve(report=report)
    old_claim = (
        await repository.claim_cleanup(now=now - timedelta(minutes=31), limit=1)
    )[0]
    new_claim = (await repository.claim_cleanup(now=now, limit=1))[0]
    assert old_claim.cleanup_claimed_at is not None
    assert new_claim.cleanup_claimed_at is not None

    assert not await repository.schedule_cleanup_confirmation(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
        next_check_at=now + timedelta(minutes=1),
    )
    assert not await repository.release_cleanup(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
    )
    assert await repository.schedule_cleanup_confirmation(
        report_id=report.report_id,
        claim_token=new_claim.cleanup_claimed_at,
        next_check_at=now + timedelta(minutes=1),
    )


async def test_stale_retention_owner_is_recovered_after_thirty_minutes() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="deleted",
        retained_until=now - timedelta(hours=1),
        upload_expires_at=now - timedelta(days=28),
        suffix="l",
        object_absence_confirmed_at=now - timedelta(hours=2),
    )
    await repository.reserve(report=report)
    old_claim = (
        await repository.claim_expired(now=now - timedelta(minutes=31), limit=1)
    )[0]
    new_claim = (await repository.claim_expired(now=now, limit=1))[0]
    assert old_claim.cleanup_claimed_at is not None
    assert new_claim.cleanup_claimed_at is not None
    assert not await repository.finish_expired(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
        deleted_at=now,
    )
    assert await repository.finish_expired(
        report_id=report.report_id,
        claim_token=new_claim.cleanup_claimed_at,
        deleted_at=now,
    )


async def test_cleanup_failure_releases_claim_for_retry() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="deleting",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now - timedelta(minutes=10),
        cleanup_after=now,
        suffix="m",
    )
    await repository.reserve(report=report)

    result = await run_feedback_cleanup_once(
        repository=repository,
        object_store=TrackingStore(unavailable=True),  # type: ignore[arg-type]
        limit=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )

    assert result == {
        "claimed": 1,
        "deleted": 0,
        "rescheduled": 0,
        "failed": 1,
    }
    pending = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert pending.cleanup_claimed_at is None


async def test_feedback_worker_runs_lifecycle_before_first_sleep() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=31),
        suffix="n",
    )
    await repository.reserve(report=expired)
    store = TrackingStore()
    task = asyncio.create_task(
        feedback_lifecycle_worker(
            repository=repository,
            object_store=store,  # type: ignore[arg-type]
            interval_seconds=3_600,
            batch_size=10,
            confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        )
    )
    try:
        await asyncio.wait_for(store.deleted_event.wait(), timeout=1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    pending = await repository.get(
        report_id=expired.report_id,
        client_app_id=expired.client_app_id,
    )
    assert pending.status == "deleting"
    assert pending.cleanup_phase == "confirm_absent"
    assert pending.object_absence_confirmed_at is None


async def test_feedback_lifecycle_stage_failure_does_not_skip_retention() -> None:
    now = datetime.now(UTC)
    repository = FailingCleanupRepository()
    expired = _report(
        now=now,
        status="deleted",
        retained_until=now - timedelta(hours=1),
        upload_expires_at=now - timedelta(days=28),
        suffix="o",
        object_absence_confirmed_at=now - timedelta(hours=2),
    )
    await repository.reserve(report=expired)

    result = await run_feedback_lifecycle_once(
        repository=repository,
        object_store=TrackingStore(),  # type: ignore[arg-type]
        batch_size=10,
        confirmation_delay_seconds=CONFIRMATION_DELAY_SECONDS,
        now=now,
    )

    assert result.stage_failures == 1
    assert result.retention_deleted == 1
    with pytest.raises(FeedbackNotFoundError):
        await repository.get(
            report_id=expired.report_id,
            client_app_id=expired.client_app_id,
        )
