from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from app.config import Settings
from app.feedback_repository import FeedbackRepository
from app.feedback_repository import PostgresFeedbackRepository
from app.managed_object_store import (
    GCSV4ObjectStore,
    IAMBlobSigner,
    ManagedObjectNotFoundError,
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.observability import emit_operational_event
from app.repository import PostgresRepository


@dataclass(frozen=True, slots=True)
class FeedbackLifecycleResult:
    cleanup_claimed: int = 0
    cleanup_deleted: int = 0
    cleanup_rescheduled: int = 0
    cleanup_failed: int = 0
    retention_claimed: int = 0
    retention_deleted: int = 0
    retention_rescheduled: int = 0
    retention_failed: int = 0
    stage_failures: int = 0


async def run_feedback_cleanup_once(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    limit: int,
    confirmation_delay_seconds: int,
    now: datetime | None = None,
) -> dict[str, int]:
    reference = now or datetime.now(UTC)
    claimed = await repository.claim_cleanup(now=reference, limit=limit)
    deleted = 0
    rescheduled = 0
    failed = 0
    for report in claimed:
        claim_token = report.cleanup_claimed_at
        if claim_token is None:
            failed += 1
            continue
        next_check_at = reference + timedelta(seconds=confirmation_delay_seconds)
        if report.cleanup_phase == "delete_pending":
            try:
                await object_store.delete(
                    object_key=report.object_key,
                    generation=None,
                )
            except ManagedObjectNotFoundError:
                pass
            except ManagedObjectStoreError:
                failed += 1
                await repository.release_cleanup(
                    report_id=report.report_id,
                    claim_token=claim_token,
                )
                continue
            scheduled = await repository.schedule_cleanup_confirmation(
                report_id=report.report_id,
                claim_token=claim_token,
                next_check_at=next_check_at,
            )
            rescheduled += int(scheduled)
            failed += int(not scheduled)
            continue
        if report.cleanup_phase != "confirm_absent":
            failed += 1
            await repository.release_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
            )
            continue

        try:
            metadata = await object_store.latest_metadata(
                object_key=report.object_key,
            )
        except ManagedObjectNotFoundError:
            finished = await repository.finish_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
                completed_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
            continue
        except ManagedObjectStoreError:
            failed += 1
            await repository.release_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
            )
            continue

        try:
            await object_store.delete(
                object_key=report.object_key,
                generation=metadata.generation,
            )
        except ManagedObjectNotFoundError:
            pass
        except ManagedObjectStoreError:
            failed += 1
            await repository.release_cleanup(
                report_id=report.report_id,
                claim_token=claim_token,
            )
            continue
        scheduled = await repository.schedule_cleanup_confirmation(
            report_id=report.report_id,
            claim_token=claim_token,
            next_check_at=next_check_at,
        )
        rescheduled += int(scheduled)
        failed += int(not scheduled)
    emit_operational_event(
        "feedback.cleanup",
        service="noop-feedback-lifecycle",
        outcome="completed" if failed == 0 else "partial",
        claimed_count=len(claimed),
        deleted_count=deleted,
        rescheduled_count=rescheduled,
        failed_count=failed,
    )
    return {
        "claimed": len(claimed),
        "deleted": deleted,
        "rescheduled": rescheduled,
        "failed": failed,
    }


async def run_feedback_retention_once(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    limit: int,
    confirmation_delay_seconds: int,
    now: datetime | None = None,
) -> dict[str, int]:
    reference = now or datetime.now(UTC)
    claimed = await repository.claim_expired(now=reference, limit=limit)
    deleted = 0
    rescheduled = 0
    failed = 0
    for report in claimed:
        claim_token = report.cleanup_claimed_at
        if claim_token is None:
            failed += 1
            continue
        if report.object_absence_confirmed_at is not None:
            finished = await repository.finish_expired(
                report_id=report.report_id,
                claim_token=claim_token,
                deleted_at=reference,
            )
            deleted += int(finished)
            failed += int(not finished)
            continue
        try:
            await object_store.delete(
                object_key=report.object_key,
                generation=None,
            )
        except ManagedObjectNotFoundError:
            pass
        except ManagedObjectStoreError:
            failed += 1
            await repository.release_expired(
                report_id=report.report_id,
                claim_token=claim_token,
            )
            continue
        scheduled = await repository.schedule_expired_confirmation(
            report_id=report.report_id,
            claim_token=claim_token,
            next_check_at=reference + timedelta(seconds=confirmation_delay_seconds),
        )
        rescheduled += int(scheduled)
        failed += int(not scheduled)
    emit_operational_event(
        "feedback.retention",
        service="noop-feedback-lifecycle",
        outcome="completed" if failed == 0 else "partial",
        claimed_count=len(claimed),
        deleted_count=deleted,
        rescheduled_count=rescheduled,
        failed_count=failed,
    )
    return {
        "claimed": len(claimed),
        "deleted": deleted,
        "rescheduled": rescheduled,
        "failed": failed,
    }


async def run_feedback_lifecycle_once(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    batch_size: int,
    confirmation_delay_seconds: int,
    now: datetime | None = None,
) -> FeedbackLifecycleResult:
    cleanup = {"claimed": 0, "deleted": 0, "rescheduled": 0, "failed": 0}
    retention = {"claimed": 0, "deleted": 0, "rescheduled": 0, "failed": 0}
    stage_failures = 0
    try:
        cleanup = await run_feedback_cleanup_once(
            repository=repository,
            object_store=object_store,
            limit=batch_size,
            confirmation_delay_seconds=confirmation_delay_seconds,
            now=now,
        )
    except asyncio.CancelledError:
        raise
    except Exception:
        stage_failures += 1
        emit_operational_event(
            "feedback.lifecycle_stage",
            service="noop-feedback-lifecycle",
            severity="ERROR",
            outcome="failed",
            failure_kind="cleanup_stage_failed",
        )
    try:
        retention = await run_feedback_retention_once(
            repository=repository,
            object_store=object_store,
            limit=batch_size,
            confirmation_delay_seconds=confirmation_delay_seconds,
            now=now,
        )
    except asyncio.CancelledError:
        raise
    except Exception:
        stage_failures += 1
        emit_operational_event(
            "feedback.lifecycle_stage",
            service="noop-feedback-lifecycle",
            severity="ERROR",
            outcome="failed",
            failure_kind="retention_stage_failed",
        )
    return FeedbackLifecycleResult(
        cleanup_claimed=cleanup["claimed"],
        cleanup_deleted=cleanup["deleted"],
        cleanup_rescheduled=cleanup["rescheduled"],
        cleanup_failed=cleanup["failed"],
        retention_claimed=retention["claimed"],
        retention_deleted=retention["deleted"],
        retention_rescheduled=retention["rescheduled"],
        retention_failed=retention["failed"],
        stage_failures=stage_failures,
    )


async def feedback_lifecycle_worker(
    *,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    interval_seconds: int,
    batch_size: int,
    confirmation_delay_seconds: int,
) -> None:
    while True:
        await run_feedback_lifecycle_once(
            repository=repository,
            object_store=object_store,
            batch_size=batch_size,
            confirmation_delay_seconds=confirmation_delay_seconds,
        )
        await asyncio.sleep(interval_seconds)


async def _run() -> FeedbackLifecycleResult:
    settings = Settings.from_env()
    if not settings.feedback_lifecycle_enabled:
        raise RuntimeError("NOOP_FEEDBACK_LIFECYCLE_ENABLED must be true")
    settings.validate_for_startup(needs_database=True, needs_api_token=False)
    primary = PostgresRepository(
        settings.database_url or "",
        pool_min_size=settings.pool_min_size,
        pool_max_size=settings.pool_max_size,
        statement_cache_size=settings.database_statement_cache_size,
        run_migrations=False,
        database_engine=settings.database_engine,
    )
    repository = PostgresFeedbackRepository(primary)
    object_store = GCSV4ObjectStore(
        bucket=settings.feedback_bucket or "",
        signer=IAMBlobSigner(settings.managed_signer_email or ""),
    )
    await primary.startup()
    try:
        return await run_feedback_lifecycle_once(
            repository=repository,
            object_store=object_store,
            batch_size=settings.feedback_lifecycle_batch_size,
            confirmation_delay_seconds=(
                settings.feedback_cleanup_confirmation_delay_seconds
            ),
        )
    finally:
        await primary.shutdown()


def main() -> None:
    operation_id = uuid4().hex
    started = time.monotonic()
    emit_operational_event(
        "feedback.lifecycle_run",
        service="noop-feedback-lifecycle",
        operation_id=operation_id,
        outcome="started",
    )
    try:
        result = asyncio.run(_run())
    except Exception as error:
        emit_operational_event(
            "feedback.lifecycle_run",
            service="noop-feedback-lifecycle",
            severity="ERROR",
            operation_id=operation_id,
            outcome="failed",
            failure_kind=type(error).__name__,
            duration_ms=max(0, int((time.monotonic() - started) * 1_000)),
        )
        raise SystemExit(1) from None
    failures = result.cleanup_failed + result.retention_failed + result.stage_failures
    emit_operational_event(
        "feedback.lifecycle_run",
        service="noop-feedback-lifecycle",
        severity="ERROR" if failures else "INFO",
        operation_id=operation_id,
        outcome="partial_failure" if failures else "completed",
        duration_ms=max(0, int((time.monotonic() - started) * 1_000)),
        cleanup_claimed=result.cleanup_claimed,
        cleanup_deleted=result.cleanup_deleted,
        cleanup_rescheduled=result.cleanup_rescheduled,
        cleanup_failed=result.cleanup_failed,
        retention_claimed=result.retention_claimed,
        retention_deleted=result.retention_deleted,
        retention_rescheduled=result.retention_rescheduled,
        retention_failed=result.retention_failed,
        stage_failures=result.stage_failures,
    )
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
