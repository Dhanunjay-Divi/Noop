from __future__ import annotations

import asyncio
from datetime import UTC, datetime

from app.feedback_repository import FeedbackRepository
from app.managed_object_store import (
    ManagedObjectNotFoundError,
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.observability import emit_operational_event


async def run_feedback_cleanup_once(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    limit: int,
    now: datetime | None = None,
) -> dict[str, int]:
    reference = now or datetime.now(UTC)
    claimed = await repository.claim_cleanup(now=reference, limit=limit)
    deleted = 0
    failed = 0
    for report in claimed:
        claim_token = report.cleanup_claimed_at
        if claim_token is None:
            failed += 1
            continue
        try:
            await object_store.delete(
                object_key=report.object_key,
                generation=None,
            )
        except ManagedObjectNotFoundError:
            finished = await repository.finish_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
                completed_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
        except ManagedObjectStoreError:
            failed += 1
            await repository.release_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
            )
        else:
            finished = await repository.finish_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
                completed_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
    emit_operational_event(
        "feedback.cleanup",
        service="noop-managed-api",
        outcome="completed" if failed == 0 else "partial",
        claimed_count=len(claimed),
        deleted_count=deleted,
        failed_count=failed,
    )
    return {
        "claimed": len(claimed),
        "deleted": deleted,
        "failed": failed,
    }


async def run_feedback_retention_once(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    limit: int,
    now: datetime | None = None,
) -> dict[str, int]:
    reference = now or datetime.now(UTC)
    claimed = await repository.claim_expired(now=reference, limit=limit)
    deleted = 0
    failed = 0
    for report in claimed:
        claim_token = report.cleanup_claimed_at
        if claim_token is None:
            failed += 1
            continue
        try:
            await object_store.delete(
                object_key=report.object_key,
                generation=None,
            )
        except ManagedObjectNotFoundError:
            finished = await repository.finish_expired(
                report_id=report.report_id,
                claim_token=claim_token,
                deleted_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
        except ManagedObjectStoreError:
            failed += 1
            await repository.release_expired(
                report_id=report.report_id,
                claim_token=claim_token,
            )
        else:
            finished = await repository.finish_expired(
                report_id=report.report_id,
                claim_token=claim_token,
                deleted_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
    emit_operational_event(
        "feedback.retention",
        service="noop-managed-api",
        outcome="completed" if failed == 0 else "partial",
        claimed_count=len(claimed),
        deleted_count=deleted,
        failed_count=failed,
    )
    return {
        "claimed": len(claimed),
        "deleted": deleted,
        "failed": failed,
    }


async def feedback_lifecycle_worker(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    interval_seconds: int,
    batch_size: int,
) -> None:
    while True:
        try:
            await run_feedback_cleanup_once(
                repository=repository,
                object_store=object_store,
                limit=batch_size,
            )
            await run_feedback_retention_once(
                repository=repository,
                object_store=object_store,
                limit=batch_size,
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            emit_operational_event(
                "feedback.lifecycle",
                service="noop-managed-api",
                severity="ERROR",
                outcome="failed",
                failure_kind="lifecycle_cycle_failed",
            )
        await asyncio.sleep(interval_seconds)
