from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import asdict, dataclass
from uuid import UUID, uuid4

from app.config import Settings
from app.managed_identity_deletion import (
    IdentityToolkitAccountDeleter,
    ManagedIdentityDeleting,
    ManagedIdentityDeletionError,
    ManagedIdentityDeletionTicketCodec,
)
from app.managed_object_store import (
    GCSV4ObjectStore,
    IAMBlobSigner,
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.managed_processing import ManagedChunkProcessor
from app.managed_push import (
    FirebaseCloudMessagingProvider,
    ManagedPushTokenCodec,
)
from app.managed_repository import (
    ManagedConflictError,
    ManagedNotFoundError,
    ManagedProcessingBusyError,
    PostgresManagedRepository,
)
from app.managed_safety_repository import (
    ManagedSafetyPushService,
    PostgresManagedSafetyRepository,
)
from app.repository import PostgresRepository
from app.observability import emit_operational_event

LIFECYCLE_LEASE = "managed_storage_lifecycle"


@dataclass(frozen=True, slots=True)
class ManagedLifecycleResult:
    lease_acquired: bool
    chunks_reconciled: int = 0
    chunk_reconciliation_deferred: int = 0
    chunk_reconciliation_failures: int = 0
    reservations_released: int = 0
    retention_claimed: int = 0
    objects_deleted: int = 0
    object_delete_failures: int = 0
    control_rows_purged: int = 0
    erasure_deletions_claimed: int = 0
    erasure_jobs_completed: int = 0
    identity_deletions_claimed: int = 0
    identities_deleted: int = 0
    identity_delete_failures: int = 0
    exports_deleted: int = 0
    export_delete_failures: int = 0
    safety_push_claimed: int = 0
    safety_push_provider_accepted: int = 0
    safety_push_retryable_failures: int = 0
    safety_push_terminal_failures: int = 0
    safety_push_receipt_failures: int = 0


class ManagedLifecycleRunner:
    def __init__(
        self,
        repository: PostgresManagedRepository,
        object_store: ManagedObjectStoring,
        identity_deleter: ManagedIdentityDeleting,
        chunk_processor: ManagedChunkProcessor,
        safety_repository: PostgresManagedSafetyRepository | None = None,
        safety_push_service: ManagedSafetyPushService | None = None,
        *,
        batch_size: int = 200,
        reconciliation_batch_size: int = 20,
        lease_seconds: int = 1_800,
        delete_concurrency: int = 4,
    ) -> None:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        if not 1 <= reconciliation_batch_size <= 200:
            raise ValueError("reconciliation_batch_size must be between 1 and 200")
        if not 60 <= lease_seconds <= 3_600:
            raise ValueError("lease_seconds must be between 60 and 3600")
        if not 1 <= delete_concurrency <= 32:
            raise ValueError("delete_concurrency must be between 1 and 32")
        self.repository = repository
        self.object_store = object_store
        self.identity_deleter = identity_deleter
        self.chunk_processor = chunk_processor
        self.safety_repository = safety_repository
        self.safety_push_service = safety_push_service
        self.batch_size = batch_size
        self.reconciliation_batch_size = reconciliation_batch_size
        self.lease_seconds = lease_seconds
        self.delete_concurrency = delete_concurrency

    async def run_once(
        self,
        *,
        owner_id: UUID | None = None,
    ) -> ManagedLifecycleResult:
        owner = owner_id or uuid4()
        now = await self.repository.coordination_now()
        acquired = await self.repository.acquire_worker_lease(
            lease_name=LIFECYCLE_LEASE,
            owner_id=owner,
            now=now,
            lease_seconds=self.lease_seconds,
        )
        if not acquired:
            return ManagedLifecycleResult(lease_acquired=False)

        try:
            (
                reconciled,
                deferred,
                reconciliation_failures,
            ) = await self._reconcile_chunks(now=now)
            released = await self.repository.release_expired_reservations(
                now=now,
                batch_size=self.batch_size,
            )
            retained = await self.repository.claim_retention_deletions(
                now=now,
                batch_size=self.batch_size,
            )
            erasure_claims = await self.repository.claim_erasure_deletions(
                now=now,
                batch_size=self.batch_size,
            )
            pending = await self.repository.pending_chunk_deletions(
                batch_size=min(self.batch_size * 2, 1_000),
            )
            deleted, failures = await self._delete_pending(pending, now=now)
            pending_exports = await self.repository.pending_export_deletions(
                now=now,
                batch_size=self.batch_size,
            )
            exports_deleted, export_failures = await self._delete_pending_exports(
                pending_exports,
                now=now,
            )
            completed_erasures = await self.repository.finalize_erasure_jobs(
                now=now,
                batch_size=self.batch_size,
            )
            pending_identities = await self.repository.pending_identity_deletions(
                now=now,
                batch_size=self.batch_size,
            )
            (
                identities_deleted,
                identity_failures,
            ) = await self._delete_pending_identities(
                pending_identities,
                now=now,
            )
            purged = await self.repository.purge_expired_control_rows(
                now=now,
                batch_size=self.batch_size,
            )
            push_result = None
            if self.safety_push_service is not None:
                push_result = await self.safety_push_service.dispatch_due(
                    limit=min(self.batch_size, 200),
                )
            if self.safety_repository is not None:
                purged.update(
                    await self.safety_repository.purge_expired_rows(
                        now=now,
                        batch_size=self.batch_size,
                    )
                )
            return ManagedLifecycleResult(
                lease_acquired=True,
                chunks_reconciled=reconciled,
                chunk_reconciliation_deferred=deferred,
                chunk_reconciliation_failures=reconciliation_failures,
                reservations_released=len(released),
                retention_claimed=len(retained),
                objects_deleted=deleted,
                object_delete_failures=failures,
                control_rows_purged=sum(purged.values()),
                erasure_deletions_claimed=len(erasure_claims),
                erasure_jobs_completed=(len(completed_erasures) + identities_deleted),
                identity_deletions_claimed=len(pending_identities),
                identities_deleted=identities_deleted,
                identity_delete_failures=identity_failures,
                exports_deleted=exports_deleted,
                export_delete_failures=export_failures,
                safety_push_claimed=(
                    push_result.claimed if push_result is not None else 0
                ),
                safety_push_provider_accepted=(
                    push_result.provider_accepted if push_result is not None else 0
                ),
                safety_push_retryable_failures=(
                    push_result.retryable_failures if push_result is not None else 0
                ),
                safety_push_terminal_failures=(
                    push_result.terminal_failures if push_result is not None else 0
                ),
                safety_push_receipt_failures=(
                    push_result.receipt_failures if push_result is not None else 0
                ),
            )
        finally:
            await self.repository.release_worker_lease(
                lease_name=LIFECYCLE_LEASE,
                owner_id=owner,
            )

    async def _reconcile_chunks(self, *, now) -> tuple[int, int, int]:
        rows = await self.repository.processing_reconciliation_candidates(
            now=now,
            batch_size=self.reconciliation_batch_size,
        )
        semaphore = asyncio.Semaphore(self.delete_concurrency)

        async def reconcile(row: dict) -> str:
            async with semaphore:
                event_hash = hashlib.sha256(
                    (
                        f"reconcile:{row['object_key']}:{row['object_generation']}"
                    ).encode("utf-8")
                ).hexdigest()
                try:
                    await self.chunk_processor.process(
                        object_key=str(row["object_key"]),
                        generation=int(row["object_generation"]),
                        queue_event_hash=event_hash,
                    )
                except (ManagedNotFoundError, ManagedProcessingBusyError):
                    return "deferred"
                except (ManagedConflictError, ManagedObjectStoreError):
                    return "failed"
                return "reconciled"

        outcomes = await asyncio.gather(*(reconcile(row) for row in rows))
        return (
            outcomes.count("reconciled"),
            outcomes.count("deferred"),
            outcomes.count("failed"),
        )

    async def _delete_pending(
        self,
        rows: list[dict],
        *,
        now,
    ) -> tuple[int, int]:
        semaphore = asyncio.Semaphore(self.delete_concurrency)

        async def delete(row: dict) -> bool:
            async with semaphore:
                try:
                    await self.object_store.delete(
                        object_key=str(row["object_key"]),
                        generation=(
                            int(row["object_generation"])
                            if row["object_generation"] is not None
                            else None
                        ),
                    )
                except ManagedObjectStoreError:
                    return False
                await self.repository.mark_chunk_deleted(
                    account_id=row["account_id"],
                    chunk_id=row["chunk_id"],
                    now=now,
                )
                return True

        outcomes = await asyncio.gather(*(delete(row) for row in rows))
        deleted = sum(outcomes)
        return deleted, len(outcomes) - deleted

    async def _delete_pending_identities(
        self,
        rows: list[dict],
        *,
        now,
    ) -> tuple[int, int]:
        semaphore = asyncio.Semaphore(self.delete_concurrency)

        async def delete(row: dict) -> bool:
            async with semaphore:
                try:
                    await self.identity_deleter.delete(
                        ticket=bytes(row["identity_deletion_ticket"]),
                        account_id=row["account_id"],
                        request_id=row["request_id"],
                    )
                except ManagedIdentityDeletionError as error:
                    detail = hashlib.sha256(
                        (f"{type(error).__name__}:{str(error)}").encode("utf-8")
                    ).hexdigest()
                    await self.repository.mark_identity_deletion_failed(
                        account_id=row["account_id"],
                        erasure_job_id=row["erasure_job_id"],
                        error_detail_sha256=detail,
                        now=now,
                    )
                    return False
                await self.repository.mark_identity_deletion_succeeded(
                    account_id=row["account_id"],
                    erasure_job_id=row["erasure_job_id"],
                    now=now,
                )
                return True

        outcomes = await asyncio.gather(*(delete(row) for row in rows))
        deleted = sum(outcomes)
        return deleted, len(outcomes) - deleted

    async def _delete_pending_exports(
        self,
        rows: list[dict],
        *,
        now,
    ) -> tuple[int, int]:
        semaphore = asyncio.Semaphore(self.delete_concurrency)

        async def delete(row: dict) -> bool:
            async with semaphore:
                try:
                    await self.object_store.delete(
                        object_key=str(row["output_object_key"]),
                        generation=int(row["output_generation"]),
                    )
                except ManagedObjectStoreError:
                    return False
                await self.repository.mark_export_deleted(
                    account_id=row["account_id"],
                    export_job_id=row["export_job_id"],
                    now=now,
                )
                return True

        outcomes = await asyncio.gather(*(delete(row) for row in rows))
        deleted = sum(outcomes)
        return deleted, len(outcomes) - deleted


async def _run() -> ManagedLifecycleResult:
    settings = Settings.from_env()
    settings.validate_for_startup(
        needs_database=True,
        needs_api_token=False,
    )
    if (
        not settings.managed_project_id
        or not settings.managed_raw_bucket
        or not settings.managed_signer_email
        or len((settings.managed_replay_secret or "").encode("utf-8")) < 32
    ):
        raise RuntimeError(
            "managed lifecycle requires NOOP_MANAGED_PROJECT_ID, "
            "NOOP_MANAGED_RAW_BUCKET, and NOOP_MANAGED_SIGNER_EMAIL "
            "plus a 32-byte "
            "NOOP_MANAGED_REPLAY_SECRET"
        )
    primary = PostgresRepository(
        settings.database_url or "",
        pool_min_size=settings.pool_min_size,
        pool_max_size=settings.pool_max_size,
        statement_cache_size=settings.database_statement_cache_size,
        run_migrations=False,
        database_engine=settings.database_engine,
    )
    repository = PostgresManagedRepository(
        primary,
        home_region=settings.managed_home_region,
        residency_policy_version=settings.managed_residency_policy_version,
        default_plan_code=settings.managed_default_plan_code,
        default_plan_revision=settings.managed_default_plan_revision,
        consent_policy_kind=settings.managed_consent_policy_kind,
        entitlement_mode=settings.managed_entitlement_mode,
        replay_secret=settings.managed_replay_secret or "",
    )
    safety_repository = PostgresManagedSafetyRepository(primary)
    object_store = GCSV4ObjectStore(
        bucket=settings.managed_raw_bucket or "",
        signer=IAMBlobSigner(settings.managed_signer_email or ""),
    )
    chunk_processor = ManagedChunkProcessor(
        repository,
        object_store,
        processor_revision="managed-json-v1",
    )
    identity_ticket_codec = ManagedIdentityDeletionTicketCodec(
        settings.managed_replay_secret or ""
    )
    identity_deleter = IdentityToolkitAccountDeleter(
        project_id=settings.managed_project_id or "",
        ticket_codec=identity_ticket_codec,
    )
    safety_push_service = None
    if settings.managed_push_retry_enabled:
        safety_push_service = ManagedSafetyPushService(
            repository=safety_repository,
            token_codec=ManagedPushTokenCodec(
                settings.managed_push_token_secret or "",
                previous_secrets=(
                    (settings.managed_push_token_previous_secret,)
                    if settings.managed_push_token_previous_secret
                    else ()
                ),
            ),
            provider=FirebaseCloudMessagingProvider(
                project_id=settings.managed_project_id or "",
                timeout_seconds=settings.managed_push_timeout_seconds,
            ),
            max_concurrency=settings.managed_push_max_concurrency,
        )
    await primary.startup()
    try:
        return await ManagedLifecycleRunner(
            repository,
            object_store,
            identity_deleter,
            chunk_processor,
            safety_repository,
            safety_push_service,
        ).run_once()
    finally:
        await primary.shutdown()


def main() -> None:
    operation_id = uuid4().hex
    started = time.monotonic()
    emit_operational_event(
        "managed_lifecycle.run",
        service="noop-managed-lifecycle",
        operation_id=operation_id,
        outcome="started",
    )
    try:
        result = asyncio.run(_run())
    except Exception as error:
        emit_operational_event(
            "managed_lifecycle.run",
            severity="ERROR",
            service="noop-managed-lifecycle",
            operation_id=operation_id,
            outcome="failed",
            failure_kind=type(error).__name__,
            duration_ms=max(0, int((time.monotonic() - started) * 1_000)),
        )
        raise SystemExit(1) from None

    has_failures = bool(
        result.object_delete_failures
        or result.chunk_reconciliation_failures
        or result.export_delete_failures
        or result.identity_delete_failures
        or result.safety_push_receipt_failures
    )
    emit_operational_event(
        "managed_lifecycle.run",
        severity="ERROR" if has_failures else "INFO",
        service="noop-managed-lifecycle",
        operation_id=operation_id,
        outcome="partial_failure" if has_failures else "completed",
        duration_ms=max(0, int((time.monotonic() - started) * 1_000)),
        **asdict(result),
    )
    if has_failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
