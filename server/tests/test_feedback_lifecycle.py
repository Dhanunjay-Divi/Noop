from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.feedback_lifecycle import (
    feedback_lifecycle_worker,
    run_feedback_cleanup_once,
    run_feedback_retention_once,
)
from app.feedback_repository import (
    FeedbackNotFoundError,
    FeedbackQuotaExceededError,
    FeedbackReport,
    MemoryFeedbackRepository,
)
from app.managed_object_store import (
    ManagedObjectNotFoundError,
    ManagedObjectStoreError,
)


class DeletingStore:
    def __init__(self) -> None:
        self.deleted: list[str] = []
        self.deleted_event = asyncio.Event()

    async def delete(self, *, object_key: str, generation: int | None) -> None:
        assert generation is None
        self.deleted.append(object_key)
        self.deleted_event.set()


class MissingStore:
    async def delete(self, *, object_key: str, generation: int | None) -> None:
        del object_key
        assert generation is None
        raise ManagedObjectNotFoundError("missing")


class UnavailableStore:
    async def delete(self, *, object_key: str, generation: int | None) -> None:
        del object_key
        assert generation is None
        raise ManagedObjectStoreError("unavailable")


def _report(
    *,
    now: datetime,
    status: str,
    retained_until: datetime,
    upload_expires_at: datetime,
    suffix: str,
    created_at: datetime | None = None,
) -> FeedbackReport:
    report_created_at = created_at or now - timedelta(days=31)
    completed_at = report_created_at if status == "sent" else None
    return FeedbackReport(
        report_id=uuid4(),
        client_app_id="1:123456:ios:abcdef12",
        subject_hash="1" * 64,
        idempotency_hash=suffix * 64,
        request_hash=("f" if suffix != "f" else "e") * 64,
        platform="ios",
        app_version="9.2.0",
        archive_bytes=100,
        archive_sha256=("c" if suffix != "c" else "d") * 64,
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
    )


async def test_feedback_retention_physically_deletes_expired_metadata() -> None:
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
    store = DeletingStore()

    result = await run_feedback_retention_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        now=now,
    )

    assert result == {"claimed": 1, "deleted": 1, "failed": 0}
    assert store.deleted == [expired.object_key]
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


async def test_feedback_retention_finishes_missing_unuploaded_reservation() -> None:
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

    result = await run_feedback_retention_once(
        repository=repository,
        object_store=MissingStore(),  # type: ignore[arg-type]
        limit=10,
        now=now,
    )

    assert result == {"claimed": 1, "deleted": 1, "failed": 0}
    with pytest.raises(FeedbackNotFoundError):
        await repository.get(
            report_id=expired.report_id,
            client_app_id=expired.client_app_id,
        )


async def test_cancel_cleanup_waits_for_upload_capability_expiry() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="d",
    )
    await repository.reserve(report=report)
    deleting = await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now,
    )
    store = DeletingStore()

    before_expiry = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        now=now,
    )
    after_expiry = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=10,
        now=report.upload_expires_at,
    )

    assert deleting.status == "deleting"
    assert before_expiry == {"claimed": 0, "deleted": 0, "failed": 0}
    assert after_expiry == {"claimed": 1, "deleted": 1, "failed": 0}
    cleaned = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert cleaned.status == "deleted"
    assert cleaned.cleanup_after is None
    assert cleaned.cleanup_claimed_at is None
    assert store.deleted == [report.object_key]


async def test_delete_deadline_uses_latest_upload_expiry_atomically() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now + timedelta(minutes=5),
        suffix="h",
    )
    await repository.reserve(report=report)
    refreshed = await repository.activate_upload_capability(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        activated_at=now,
        upload_expires_at=now + timedelta(minutes=15),
    )

    deleting = await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now + timedelta(minutes=1),
    )

    assert refreshed.upload_expires_at == now + timedelta(minutes=15)
    assert deleting.cleanup_after == refreshed.upload_expires_at


@pytest.mark.parametrize("terminal_state", ("deleting", "rejected"))
async def test_live_cancelled_or_rejected_capability_counts_toward_pending_quota(
    terminal_state: str,
) -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    first = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="i",
        created_at=now,
    )
    second = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now + timedelta(minutes=15),
        suffix="j",
        created_at=now,
    )
    await repository.reserve(
        report=first,
        pending_byte_limit=150,
    )
    if terminal_state == "deleting":
        await repository.request_delete(
            report_id=first.report_id,
            client_app_id=first.client_app_id,
            requested_at=now,
        )
    else:
        await repository.mark_rejected(
            report_id=first.report_id,
            client_app_id=first.client_app_id,
            rejected_at=now,
        )

    with pytest.raises(FeedbackQuotaExceededError):
        await repository.reserve(
            report=second,
            pending_byte_limit=150,
        )


async def test_stale_cleanup_owner_cannot_finish_or_release_new_claim() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=28),
        upload_expires_at=now - timedelta(minutes=30),
        suffix="k",
    )
    await repository.reserve(report=report)
    await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now - timedelta(minutes=30),
    )
    old_claim = (
        await repository.claim_cleanup(
            now=now - timedelta(minutes=16),
            limit=1,
        )
    )[0]
    new_claim = (await repository.claim_cleanup(now=now, limit=1))[0]
    assert old_claim.cleanup_claimed_at is not None
    assert new_claim.cleanup_claimed_at is not None

    assert not await repository.finish_cleanup(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
        completed_at=now,
    )
    assert not await repository.release_cleanup(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
    )
    current = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert current.status == "deleting"
    assert current.cleanup_claimed_at == new_claim.cleanup_claimed_at
    assert await repository.finish_cleanup(
        report_id=report.report_id,
        claim_token=new_claim.cleanup_claimed_at,
        completed_at=now,
    )


async def test_stale_retention_owner_cannot_finish_or_release_new_claim() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(minutes=30),
        upload_expires_at=now - timedelta(days=28),
        suffix="m",
    )
    await repository.reserve(report=report)
    old_claim = (
        await repository.claim_expired(
            now=now - timedelta(minutes=16),
            limit=1,
        )
    )[0]
    new_claim = (await repository.claim_expired(now=now, limit=1))[0]
    assert old_claim.cleanup_claimed_at is not None
    assert new_claim.cleanup_claimed_at is not None

    assert not await repository.finish_expired(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
        deleted_at=now,
    )
    assert not await repository.release_expired(
        report_id=report.report_id,
        claim_token=old_claim.cleanup_claimed_at,
    )
    current = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert current.cleanup_claimed_at == new_claim.cleanup_claimed_at
    assert await repository.finish_expired(
        report_id=report.report_id,
        claim_token=new_claim.cleanup_claimed_at,
        deleted_at=now,
    )
    with pytest.raises(FeedbackNotFoundError):
        await repository.get(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
        )


async def test_cleanup_failure_releases_claim_for_retry() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now - timedelta(seconds=1),
        suffix="e",
    )
    await repository.reserve(report=report)
    await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now,
    )

    result = await run_feedback_cleanup_once(
        repository=repository,
        object_store=UnavailableStore(),  # type: ignore[arg-type]
        limit=10,
        now=now,
    )

    assert result == {"claimed": 1, "deleted": 0, "failed": 1}
    pending = await repository.get(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
    )
    assert pending.status == "deleting"
    assert pending.cleanup_claimed_at is None


async def test_stale_cleanup_claim_is_recovered_after_lease() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    report = _report(
        now=now,
        status="reserved",
        retained_until=now + timedelta(days=30),
        upload_expires_at=now - timedelta(minutes=30),
        suffix="g",
    )
    await repository.reserve(report=report)
    await repository.request_delete(
        report_id=report.report_id,
        client_app_id=report.client_app_id,
        requested_at=now - timedelta(minutes=30),
    )
    claimed = await repository.claim_cleanup(
        now=now - timedelta(minutes=16),
        limit=1,
    )
    assert len(claimed) == 1
    store = DeletingStore()

    result = await run_feedback_cleanup_once(
        repository=repository,
        object_store=store,  # type: ignore[arg-type]
        limit=1,
        now=now,
    )

    assert result == {"claimed": 1, "deleted": 1, "failed": 0}
    assert (
        await repository.get(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
        )
    ).status == "deleted"


async def test_feedback_worker_runs_lifecycle_before_first_sleep() -> None:
    now = datetime.now(UTC)
    repository = MemoryFeedbackRepository()
    expired = _report(
        now=now,
        status="sent",
        retained_until=now - timedelta(seconds=1),
        upload_expires_at=now - timedelta(days=31),
        suffix="f",
    )
    await repository.reserve(report=expired)
    store = DeletingStore()
    task = asyncio.create_task(
        feedback_lifecycle_worker(
            repository=repository,
            object_store=store,  # type: ignore[arg-type]
            interval_seconds=3_600,
            batch_size=10,
        )
    )
    try:
        await asyncio.wait_for(store.deleted_event.wait(), timeout=1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    with pytest.raises(FeedbackNotFoundError):
        await repository.get(
            report_id=expired.report_id,
            client_app_id=expired.client_app_id,
        )
