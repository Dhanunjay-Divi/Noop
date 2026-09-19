from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol
from uuid import UUID

from app.feedback_principal import FEEDBACK_PRINCIPAL_HASH_VERSION
from app.repository import PostgresRepository


_CLAIM_LEASE = timedelta(minutes=30)
# Mobile automatic continuity is bounded to 29 days and five minutes. Give
# every server reservation a conservative 45-day total key lifetime so cleanup
# cannot reopen it during that client window, without retaining another 45 days
# after deletion.
FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME = timedelta(days=45)
FEEDBACK_TOMBSTONE_BACKLOG_COUNT_OBSERVABILITY_MAX = 1_000_000
_FEEDBACK_TOMBSTONE_BACKLOG_QUERY_LIMIT = (
    FEEDBACK_TOMBSTONE_BACKLOG_COUNT_OBSERVABILITY_MAX + 1
)
_PENDING_CAPABILITY_STATUSES = frozenset({"reserved", "rejected", "deleting"})
_CLEANUP_DELETE_PENDING = "delete_pending"
_CLEANUP_CONFIRM_ABSENT = "confirm_absent"


class FeedbackRepositoryError(Exception):
    """Base class for feedback metadata failures."""


class FeedbackNotFoundError(FeedbackRepositoryError):
    """The report does not exist for this attested application."""


class FeedbackGoneError(FeedbackRepositoryError):
    """The report expired and its idempotency key remains temporarily retired."""


class FeedbackConflictError(FeedbackRepositoryError):
    """An idempotency key or state transition conflicts with existing data."""


class FeedbackQuotaExceededError(FeedbackRepositoryError):
    """The authenticated account exceeded a bounded feedback submission quota."""

    def __init__(self, message: str, *, scope: str) -> None:
        super().__init__(message)
        self.scope = scope


@dataclass(frozen=True, slots=True)
class FeedbackReport:
    report_id: UUID
    client_app_id: str
    subject_hash: str
    principal_hash_version: int
    principal_hash: str
    idempotency_hash: str
    request_hash: str
    platform: str
    app_version: str
    archive_bytes: int
    archive_sha256: str
    includes_user_note: bool
    includes_screenshot: bool
    receipt: str
    object_key: str
    status: str
    object_generation: int | None
    created_at: datetime
    upload_expires_at: datetime
    completed_at: datetime | None
    retained_until: datetime
    deleted_at: datetime | None
    cleanup_after: datetime | None = None
    cleanup_phase: str | None = None
    cleanup_claimed_at: datetime | None = None
    object_absence_confirmed_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class FeedbackIdempotencyTombstone:
    client_app_id: str
    principal_hash_version: int
    principal_hash: str
    idempotency_hash: str
    reserved_at: datetime
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class FeedbackTombstoneRetentionResult:
    purged_count: int
    remaining_expired_count: int
    oldest_expired_age_seconds: int


def _require_authorizable_principal(report: FeedbackReport) -> None:
    if report.principal_hash_version != FEEDBACK_PRINCIPAL_HASH_VERSION:
        raise FeedbackConflictError(
            "legacy feedback principal is not remotely authorizable"
        )


def _idempotency_key_lifetime_elapsed(
    report: FeedbackReport,
    *,
    now: datetime,
) -> bool:
    return report.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME <= now


def _retired_idempotency_hash(report: FeedbackReport) -> str:
    return hashlib.sha256(
        (f"retired\0{report.report_id}\0{report.idempotency_hash}").encode("utf-8")
    ).hexdigest()


class FeedbackRepository(Protocol):
    async def reserve(
        self,
        *,
        report: FeedbackReport,
        daily_report_limit: int = 100,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_daily_report_limit: int = 1_000,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> tuple[FeedbackReport, bool]: ...

    async def activate_upload_capability(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        activated_at: datetime,
        upload_expires_at: datetime,
        cleanup_after: datetime,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> FeedbackReport: ...

    async def get(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
    ) -> FeedbackReport: ...

    async def get_by_idempotency(
        self,
        *,
        client_app_id: str,
        principal_hash_version: int,
        principal_hash: str,
        idempotency_hash: str,
        now: datetime | None = None,
    ) -> FeedbackReport: ...

    async def mark_sent(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        object_generation: int,
        completed_at: datetime,
    ) -> FeedbackReport: ...

    async def mark_rejected(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        rejected_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport: ...

    async def request_delete(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        requested_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport: ...

    async def claim_cleanup(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]: ...

    async def finish_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        completed_at: datetime,
    ) -> bool: ...

    async def schedule_cleanup_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool: ...

    async def schedule_expired_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool: ...

    async def release_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool: ...

    async def claim_expired(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]: ...

    async def finish_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        deleted_at: datetime,
    ) -> bool: ...

    async def release_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool: ...

    async def purge_expired_tombstones(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> FeedbackTombstoneRetentionResult: ...


class MemoryFeedbackRepository:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._reports: dict[UUID, FeedbackReport] = {}
        self._idempotency: dict[tuple[str, int, str, str], UUID] = {}
        self._tombstones: dict[
            tuple[str, int, str, str], FeedbackIdempotencyTombstone
        ] = {}

    async def reserve(
        self,
        *,
        report: FeedbackReport,
        daily_report_limit: int = 100,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_daily_report_limit: int = 1_000,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> tuple[FeedbackReport, bool]:
        _require_authorizable_principal(report)
        async with self._lock:
            key = (
                report.client_app_id,
                report.principal_hash_version,
                report.principal_hash,
                report.idempotency_hash,
            )
            existing_id = self._idempotency.get(key)
            if existing_id is not None:
                existing = self._reports[existing_id]
                if _idempotency_key_lifetime_elapsed(
                    existing,
                    now=report.created_at,
                ):
                    self._reports[existing_id] = replace(
                        existing,
                        idempotency_hash=_retired_idempotency_hash(existing),
                    )
                    self._idempotency.pop(key, None)
                elif existing.retained_until <= report.created_at:
                    raise FeedbackNotFoundError("feedback reservation was not found")
                elif existing.request_hash != report.request_hash:
                    raise FeedbackConflictError("feedback idempotency key was reused")
                else:
                    return existing, False
            tombstone = self._tombstones.get(key)
            if tombstone is not None:
                if tombstone.expires_at > report.created_at:
                    raise FeedbackGoneError("feedback reservation expired")
                self._tombstones.pop(key, None)
            quota_start = report.created_at - timedelta(days=1)
            subject_reports = [
                existing
                for existing in self._reports.values()
                if existing.client_app_id == report.client_app_id
                and existing.principal_hash_version == report.principal_hash_version
                and existing.principal_hash == report.principal_hash
            ]
            daily_reports = [
                existing
                for existing in subject_reports
                if existing.created_at >= quota_start
            ]
            if len(daily_reports) >= daily_report_limit:
                raise FeedbackQuotaExceededError(
                    "feedback daily report quota was exceeded",
                    scope="principal_daily",
                )
            pending_bytes = sum(
                existing.archive_bytes
                for existing in subject_reports
                if existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > report.created_at
            )
            if pending_bytes + report.archive_bytes > pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback pending byte quota was exceeded",
                    scope="principal_pending",
                )
            app_reports = [
                existing
                for existing in self._reports.values()
                if existing.client_app_id == report.client_app_id
            ]
            app_daily_reports = [
                existing
                for existing in app_reports
                if existing.created_at >= quota_start
            ]
            if len(app_daily_reports) >= app_daily_report_limit:
                raise FeedbackQuotaExceededError(
                    "feedback application daily quota was exceeded",
                    scope="app_daily",
                )
            app_pending_bytes = sum(
                existing.archive_bytes
                for existing in app_reports
                if existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > report.created_at
            )
            if app_pending_bytes + report.archive_bytes > app_pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback application pending byte quota was exceeded",
                    scope="app_pending",
                )
            self._reports[report.report_id] = report
            self._idempotency[key] = report.report_id
            return report, True

    async def activate_upload_capability(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        activated_at: datetime,
        upload_expires_at: datetime,
        cleanup_after: datetime,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            _require_authorizable_principal(report)
            if report.status != "reserved":
                return report
            if (
                report.cleanup_claimed_at is not None
                or report.cleanup_phase != _CLEANUP_DELETE_PENDING
            ):
                raise FeedbackConflictError(
                    "feedback upload cleanup has already started"
                )
            pending_bytes = sum(
                existing.archive_bytes
                for existing in self._reports.values()
                if existing.report_id != report.report_id
                and existing.client_app_id == report.client_app_id
                and existing.principal_hash_version == report.principal_hash_version
                and existing.principal_hash == report.principal_hash
                and existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > activated_at
            )
            if pending_bytes + report.archive_bytes > pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback pending byte quota was exceeded",
                    scope="principal_pending",
                )
            app_pending_bytes = sum(
                existing.archive_bytes
                for existing in self._reports.values()
                if existing.report_id != report.report_id
                and existing.client_app_id == report.client_app_id
                and existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > activated_at
            )
            if app_pending_bytes + report.archive_bytes > app_pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback application pending byte quota was exceeded",
                    scope="app_pending",
                )
            if (
                upload_expires_at > report.retained_until
                or cleanup_after > report.retained_until
            ):
                raise FeedbackConflictError(
                    "feedback upload deadline exceeds report retention"
                )
            report = replace(
                report,
                upload_expires_at=min(
                    report.retained_until,
                    max(report.upload_expires_at, upload_expires_at),
                ),
                cleanup_after=min(
                    report.retained_until,
                    max(
                        report.cleanup_after or cleanup_after,
                        cleanup_after,
                    ),
                ),
            )
            self._reports[report_id] = report
            return report

    async def get(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
    ) -> FeedbackReport:
        async with self._lock:
            return self._get(report_id, client_app_id)

    async def get_by_idempotency(
        self,
        *,
        client_app_id: str,
        principal_hash_version: int,
        principal_hash: str,
        idempotency_hash: str,
        now: datetime | None = None,
    ) -> FeedbackReport:
        async with self._lock:
            key = (
                client_app_id,
                principal_hash_version,
                principal_hash,
                idempotency_hash,
            )
            report_id = self._idempotency.get(key)
            if report_id is None:
                reference = now or datetime.now(UTC)
                tombstone = self._tombstones.get(key)
                if tombstone is not None:
                    if tombstone.expires_at <= reference:
                        self._tombstones.pop(key, None)
                    else:
                        raise FeedbackGoneError("feedback reservation expired")
                raise FeedbackNotFoundError("feedback report was not found")
            report = self._get(report_id, client_app_id)
            if report.retained_until <= (now or datetime.now(UTC)):
                raise FeedbackNotFoundError("feedback report was not found")
            _require_authorizable_principal(report)
            return report

    async def mark_sent(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        object_generation: int,
        completed_at: datetime,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            if report.status == "sent":
                return report
            if (
                report.status != "reserved"
                or report.cleanup_claimed_at is not None
                or report.cleanup_phase != _CLEANUP_DELETE_PENDING
                or report.cleanup_after is None
                or report.cleanup_after <= completed_at
            ):
                raise FeedbackConflictError("feedback report cannot be completed")
            report = replace(
                report,
                status="sent",
                object_generation=object_generation,
                completed_at=completed_at,
                cleanup_after=None,
                cleanup_phase=None,
                cleanup_claimed_at=None,
            )
            self._reports[report_id] = report
            return report

    async def mark_rejected(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        rejected_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            if (
                report.status != "reserved"
                or report.cleanup_claimed_at is not None
                or report.cleanup_phase != _CLEANUP_DELETE_PENDING
            ):
                raise FeedbackConflictError("feedback report cannot be rejected")
            report = replace(
                report,
                status="rejected",
                deleted_at=rejected_at,
                cleanup_after=min(
                    report.retained_until,
                    max(
                        cleanup_after,
                        report.cleanup_after or cleanup_after,
                    ),
                ),
                cleanup_phase=_CLEANUP_DELETE_PENDING,
                cleanup_claimed_at=None,
            )
            self._reports[report_id] = report
            return report

    async def request_delete(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        requested_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            if report.cleanup_claimed_at is not None:
                raise FeedbackConflictError("feedback cleanup is already active")
            if report.status == "deleted":
                return report
            report = replace(
                report,
                status="deleting",
                deleted_at=report.deleted_at or requested_at,
                cleanup_after=min(
                    report.retained_until,
                    max(
                        cleanup_after,
                        report.cleanup_after or cleanup_after,
                    ),
                ),
                cleanup_phase=_CLEANUP_DELETE_PENDING,
                cleanup_claimed_at=None,
            )
            self._reports[report_id] = report
            return report

    async def claim_cleanup(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]:
        async with self._lock:
            claimed: list[FeedbackReport] = []
            for report in sorted(
                self._reports.values(),
                key=lambda value: (
                    value.cleanup_after or value.retained_until,
                    str(value.report_id),
                ),
            ):
                if len(claimed) >= limit:
                    break
                if (
                    report.status in {"reserved", "rejected", "deleting"}
                    and report.cleanup_after is not None
                    and report.cleanup_phase
                    in {_CLEANUP_DELETE_PENDING, _CLEANUP_CONFIRM_ABSENT}
                    and report.cleanup_after <= now
                    and (
                        report.cleanup_claimed_at is None
                        or report.cleanup_claimed_at <= now - _CLAIM_LEASE
                    )
                ):
                    updated = replace(report, cleanup_claimed_at=now)
                    self._reports[report.report_id] = updated
                    claimed.append(updated)
            return claimed

    async def schedule_cleanup_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if (
                report is None
                or report.cleanup_claimed_at != claim_token
                or report.status not in {"reserved", "rejected", "deleting"}
            ):
                return False
            self._reports[report_id] = replace(
                report,
                cleanup_after=next_check_at,
                cleanup_phase=_CLEANUP_CONFIRM_ABSENT,
                cleanup_claimed_at=None,
                object_absence_confirmed_at=None,
            )
            return True

    async def schedule_expired_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if (
                report is None
                or report.cleanup_claimed_at != claim_token
                or report.cleanup_after is not None
                or report.cleanup_phase is not None
                or report.object_absence_confirmed_at is not None
                or report.retained_until > claim_token
            ):
                return False
            self._reports[report_id] = replace(
                report,
                status="deleting",
                deleted_at=report.deleted_at or claim_token,
                cleanup_after=next_check_at,
                cleanup_phase=_CLEANUP_CONFIRM_ABSENT,
                cleanup_claimed_at=None,
            )
            return True

    async def finish_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        completed_at: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if (
                report is None
                or report.cleanup_claimed_at != claim_token
                or report.status not in {"reserved", "rejected", "deleting"}
                or report.cleanup_phase != _CLEANUP_CONFIRM_ABSENT
            ):
                return False
            self._reports[report_id] = replace(
                report,
                status=(
                    "deleted"
                    if report.status in {"reserved", "deleting"}
                    else report.status
                ),
                deleted_at=report.deleted_at or completed_at,
                cleanup_after=None,
                cleanup_phase=None,
                cleanup_claimed_at=None,
                object_absence_confirmed_at=completed_at,
            )
            return True

    async def release_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if (
                report is None
                or report.cleanup_claimed_at != claim_token
                or report.status not in {"reserved", "rejected", "deleting"}
            ):
                return False
            self._reports[report_id] = replace(
                report,
                cleanup_claimed_at=None,
            )
            return True

    async def claim_expired(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]:
        async with self._lock:
            claimed: list[FeedbackReport] = []
            for report in sorted(
                self._reports.values(),
                key=lambda value: (value.retained_until, str(value.report_id)),
            ):
                if len(claimed) >= limit:
                    break
                if (
                    report.retained_until <= now
                    and report.cleanup_after is None
                    and report.cleanup_phase is None
                    and (
                        report.cleanup_claimed_at is None
                        or report.cleanup_claimed_at <= now - _CLAIM_LEASE
                    )
                ):
                    updated = replace(report, cleanup_claimed_at=now)
                    self._reports[report.report_id] = updated
                    claimed.append(updated)
            return claimed

    async def finish_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        deleted_at: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if (
                report is None
                or report.cleanup_claimed_at != claim_token
                or report.object_absence_confirmed_at is None
                or report.retained_until > claim_token
            ):
                return False
            key = (
                report.client_app_id,
                report.principal_hash_version,
                report.principal_hash,
                report.idempotency_hash,
            )
            expires_at = report.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
            owns_active_key = self._idempotency.get(key) == report_id
            if owns_active_key and expires_at > deleted_at:
                self._tombstones[key] = FeedbackIdempotencyTombstone(
                    client_app_id=report.client_app_id,
                    principal_hash_version=report.principal_hash_version,
                    principal_hash=report.principal_hash,
                    idempotency_hash=report.idempotency_hash,
                    reserved_at=report.created_at,
                    expires_at=expires_at,
                )
            self._reports.pop(report_id)
            if owns_active_key:
                self._idempotency.pop(key, None)
            return True

    async def release_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool:
        async with self._lock:
            report = self._reports.get(report_id)
            if report is None or report.cleanup_claimed_at != claim_token:
                return False
            self._reports[report_id] = replace(
                report,
                cleanup_claimed_at=None,
            )
            return True

    async def purge_expired_tombstones(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> FeedbackTombstoneRetentionResult:
        async with self._lock:
            expired = sorted(
                (
                    tombstone
                    for tombstone in self._tombstones.values()
                    if tombstone.expires_at <= now
                ),
                key=lambda value: (
                    value.expires_at,
                    value.client_app_id,
                    value.principal_hash,
                    value.idempotency_hash,
                ),
            )[:limit]
            for tombstone in expired:
                self._tombstones.pop(
                    (
                        tombstone.client_app_id,
                        tombstone.principal_hash_version,
                        tombstone.principal_hash,
                        tombstone.idempotency_hash,
                    ),
                    None,
                )
            remaining = [
                tombstone
                for tombstone in self._tombstones.values()
                if tombstone.expires_at <= now
            ]
            oldest_expired_age_seconds = (
                max(
                    0,
                    int(
                        (
                            now - min(tombstone.expires_at for tombstone in remaining)
                        ).total_seconds()
                    ),
                )
                if remaining
                else 0
            )
            return FeedbackTombstoneRetentionResult(
                purged_count=len(expired),
                remaining_expired_count=min(
                    len(remaining),
                    _FEEDBACK_TOMBSTONE_BACKLOG_QUERY_LIMIT,
                ),
                oldest_expired_age_seconds=oldest_expired_age_seconds,
            )

    def _get(self, report_id: UUID, client_app_id: str) -> FeedbackReport:
        report = self._reports.get(report_id)
        if report is None or report.client_app_id != client_app_id:
            raise FeedbackNotFoundError("feedback report was not found")
        return report


class PostgresFeedbackRepository:
    def __init__(self, primary: PostgresRepository) -> None:
        self.primary = primary

    async def reserve(
        self,
        *,
        report: FeedbackReport,
        daily_report_limit: int = 100,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_daily_report_limit: int = 1_000,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> tuple[FeedbackReport, bool]:
        _require_authorizable_principal(report)
        pool = self.primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():

                async def existing_report(
                    *,
                    principal_hash_version: int,
                    principal_hash: str,
                    idempotency_hash: str,
                ) -> Any:
                    return await connection.fetchrow(
                        """
                        SELECT *
                        FROM feedback_reports
                        WHERE client_app_id = $1
                          AND COALESCE(principal_hash_version, 0) = $2
                          AND COALESCE(principal_hash, subject_hash) = $3
                          AND idempotency_hash = $4
                        """,
                        report.client_app_id,
                        principal_hash_version,
                        principal_hash,
                        idempotency_hash,
                    )

                async def replay_candidate() -> Any:
                    return await existing_report(
                        principal_hash_version=report.principal_hash_version,
                        principal_hash=report.principal_hash,
                        idempotency_hash=report.idempotency_hash,
                    )

                existing = await replay_candidate()
                if existing is not None:
                    value = self._row(existing)
                    if (
                        _idempotency_key_lifetime_elapsed(
                            value,
                            now=report.created_at,
                        )
                        or value.retained_until <= report.created_at
                    ):
                        existing = None
                    elif value.request_hash != report.request_hash:
                        raise FeedbackConflictError(
                            "feedback idempotency key was reused"
                        )
                    else:
                        return value, False

                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended('noop-feedback-app:' || $1, 0)
                    )
                    """,
                    report.client_app_id,
                )
                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended(
                            'noop-feedback:' || $1 || ':' || $2 || ':' || $3,
                            0
                        )
                    )
                    """,
                    report.client_app_id,
                    str(report.principal_hash_version),
                    report.principal_hash,
                )
                existing = await replay_candidate()
                if existing is not None:
                    value = self._row(existing)
                    if _idempotency_key_lifetime_elapsed(
                        value,
                        now=report.created_at,
                    ):
                        await connection.execute(
                            """
                            UPDATE feedback_reports
                            SET idempotency_hash = $2
                            WHERE report_id = $1
                              AND idempotency_hash = $3
                            """,
                            value.report_id,
                            _retired_idempotency_hash(value),
                            value.idempotency_hash,
                        )
                    elif value.retained_until <= report.created_at:
                        raise FeedbackNotFoundError(
                            "feedback reservation was not found"
                        )
                    elif value.request_hash != report.request_hash:
                        raise FeedbackConflictError(
                            "feedback idempotency key was reused"
                        )
                    else:
                        return value, False
                tombstone = await connection.fetchrow(
                    """
                    SELECT expires_at
                    FROM feedback_idempotency_tombstones
                    WHERE client_app_id = $1
                      AND principal_hash_version = $2
                      AND principal_hash = $3
                      AND idempotency_hash = $4
                    FOR UPDATE
                    """,
                    report.client_app_id,
                    report.principal_hash_version,
                    report.principal_hash,
                    report.idempotency_hash,
                )
                if tombstone is not None:
                    if tombstone["expires_at"] > report.created_at:
                        raise FeedbackGoneError("feedback reservation expired")
                    await connection.execute(
                        """
                        DELETE FROM feedback_idempotency_tombstones
                        WHERE client_app_id = $1
                          AND principal_hash_version = $2
                          AND principal_hash = $3
                          AND idempotency_hash = $4
                          AND expires_at <= $5
                        """,
                        report.client_app_id,
                        report.principal_hash_version,
                        report.principal_hash,
                        report.idempotency_hash,
                        report.created_at,
                    )
                quota = await connection.fetchrow(
                    """
                    SELECT
                        count(*) FILTER (
                            WHERE created_at >= $4::timestamptz - INTERVAL '24 hours'
                        ) AS daily_reports,
                        COALESCE(sum(archive_bytes) FILTER (
                            WHERE status IN ('reserved', 'rejected', 'deleting')
                              AND upload_expires_at > $4::timestamptz
                        ), 0) AS pending_bytes
                    FROM feedback_reports
                    WHERE client_app_id = $1
                      AND COALESCE(principal_hash_version, 0) = $2
                      AND COALESCE(principal_hash, subject_hash) = $3
                    """,
                    report.client_app_id,
                    report.principal_hash_version,
                    report.principal_hash,
                    report.created_at,
                )
                if quota is None:
                    raise FeedbackConflictError("feedback quota could not be checked")
                if int(quota["daily_reports"]) >= daily_report_limit:
                    raise FeedbackQuotaExceededError(
                        "feedback daily report quota was exceeded",
                        scope="principal_daily",
                    )
                if (
                    int(quota["pending_bytes"]) + report.archive_bytes
                    > pending_byte_limit
                ):
                    raise FeedbackQuotaExceededError(
                        "feedback pending byte quota was exceeded",
                        scope="principal_pending",
                    )
                app_quota = await connection.fetchrow(
                    """
                    SELECT
                        count(*) FILTER (
                            WHERE created_at >= $2::timestamptz - INTERVAL '24 hours'
                        ) AS daily_reports,
                        COALESCE(sum(archive_bytes) FILTER (
                            WHERE status IN ('reserved', 'rejected', 'deleting')
                              AND upload_expires_at > $2::timestamptz
                        ), 0) AS pending_bytes
                    FROM feedback_reports
                    WHERE client_app_id = $1
                    """,
                    report.client_app_id,
                    report.created_at,
                )
                if app_quota is None:
                    raise FeedbackConflictError(
                        "feedback application quota could not be checked"
                    )
                if int(app_quota["daily_reports"]) >= app_daily_report_limit:
                    raise FeedbackQuotaExceededError(
                        "feedback application daily quota was exceeded",
                        scope="app_daily",
                    )
                if (
                    int(app_quota["pending_bytes"]) + report.archive_bytes
                    > app_pending_byte_limit
                ):
                    raise FeedbackQuotaExceededError(
                        "feedback application pending byte quota was exceeded",
                        scope="app_pending",
                    )

                inserted = await connection.fetchrow(
                    """
                    INSERT INTO feedback_reports (
                        report_id, client_app_id, subject_hash,
                        principal_hash_version, principal_hash, idempotency_hash,
                        request_hash, platform, app_version, archive_bytes,
                        archive_sha256, includes_user_note, includes_screenshot,
                        receipt, object_key, status, object_generation, created_at,
                        upload_expires_at, completed_at, retained_until, deleted_at,
                        cleanup_after, cleanup_phase, cleanup_claimed_at
                    )
                    VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
                        $12, $13, $14, $15, $16, $17, $18, $19, $20, $21,
                        $22, $23, $24, $25
                    )
                    RETURNING *
                    """,
                    report.report_id,
                    report.client_app_id,
                    report.subject_hash,
                    report.principal_hash_version,
                    report.principal_hash,
                    report.idempotency_hash,
                    report.request_hash,
                    report.platform,
                    report.app_version,
                    report.archive_bytes,
                    report.archive_sha256,
                    report.includes_user_note,
                    report.includes_screenshot,
                    report.receipt,
                    report.object_key,
                    report.status,
                    report.object_generation,
                    report.created_at,
                    report.upload_expires_at,
                    report.completed_at,
                    report.retained_until,
                    report.deleted_at,
                    report.cleanup_after,
                    report.cleanup_phase,
                    report.cleanup_claimed_at,
                )
                if inserted is None:
                    raise FeedbackConflictError("feedback reservation conflicted")
                return self._row(inserted), True

    async def activate_upload_capability(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        activated_at: datetime,
        upload_expires_at: datetime,
        cleanup_after: datetime,
        pending_byte_limit: int = 256 * 1024 * 1024,
        app_pending_byte_limit: int = 1024 * 1024 * 1024,
    ) -> FeedbackReport:
        pool = self.primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                initial = await connection.fetchrow(
                    """
                    SELECT *
                    FROM feedback_reports
                    WHERE report_id = $1 AND client_app_id = $2
                    """,
                    report_id,
                    client_app_id,
                )
                if initial is None:
                    raise FeedbackNotFoundError("feedback report was not found")
                initial_report = self._row(initial)
                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended('noop-feedback-app:' || $1, 0)
                    )
                    """,
                    initial_report.client_app_id,
                )
                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended(
                            'noop-feedback:' || $1 || ':' || $2 || ':' || $3,
                            0
                        )
                    )
                    """,
                    initial_report.client_app_id,
                    str(initial_report.principal_hash_version),
                    initial_report.principal_hash,
                )
                current = await connection.fetchrow(
                    """
                    SELECT *
                    FROM feedback_reports
                    WHERE report_id = $1 AND client_app_id = $2
                    FOR UPDATE
                    """,
                    report_id,
                    client_app_id,
                )
                if current is None:
                    raise FeedbackNotFoundError("feedback report was not found")
                report = self._row(current)
                _require_authorizable_principal(report)
                if report.status != "reserved":
                    return report
                if (
                    report.cleanup_claimed_at is not None
                    or report.cleanup_phase != _CLEANUP_DELETE_PENDING
                ):
                    raise FeedbackConflictError(
                        "feedback upload cleanup has already started"
                    )
                if (
                    upload_expires_at > report.retained_until
                    or cleanup_after > report.retained_until
                ):
                    raise FeedbackConflictError(
                        "feedback upload deadline exceeds report retention"
                    )
                pending_bytes = await connection.fetchval(
                    """
                    SELECT COALESCE(sum(archive_bytes), 0)
                    FROM feedback_reports
                    WHERE client_app_id = $1
                      AND COALESCE(principal_hash_version, 0) = $2
                      AND COALESCE(principal_hash, subject_hash) = $3
                      AND report_id <> $4
                      AND status IN ('reserved', 'rejected', 'deleting')
                      AND upload_expires_at > $5
                    """,
                    report.client_app_id,
                    report.principal_hash_version,
                    report.principal_hash,
                    report.report_id,
                    activated_at,
                )
                if int(pending_bytes or 0) + report.archive_bytes > pending_byte_limit:
                    raise FeedbackQuotaExceededError(
                        "feedback pending byte quota was exceeded",
                        scope="principal_pending",
                    )
                app_pending_bytes = await connection.fetchval(
                    """
                    SELECT COALESCE(sum(archive_bytes), 0)
                    FROM feedback_reports
                    WHERE client_app_id = $1
                      AND report_id <> $2
                      AND status IN ('reserved', 'rejected', 'deleting')
                      AND upload_expires_at > $3
                    """,
                    report.client_app_id,
                    report.report_id,
                    activated_at,
                )
                if (
                    int(app_pending_bytes or 0) + report.archive_bytes
                    > app_pending_byte_limit
                ):
                    raise FeedbackQuotaExceededError(
                        "feedback application pending byte quota was exceeded",
                        scope="app_pending",
                    )
                updated = await connection.fetchrow(
                    """
                    UPDATE feedback_reports
                    SET upload_expires_at = LEAST(
                            retained_until,
                            GREATEST(upload_expires_at, $3)
                        ),
                        cleanup_after = LEAST(
                            retained_until,
                            GREATEST(cleanup_after, $4)
                        )
                    WHERE report_id = $1
                      AND client_app_id = $2
                      AND status = 'reserved'
                      AND cleanup_phase = 'delete_pending'
                      AND cleanup_claimed_at IS NULL
                    RETURNING *
                    """,
                    report_id,
                    client_app_id,
                    upload_expires_at,
                    cleanup_after,
                )
                if updated is None:
                    current = await connection.fetchrow(
                        """
                        SELECT *
                        FROM feedback_reports
                        WHERE report_id = $1 AND client_app_id = $2
                        """,
                        report_id,
                        client_app_id,
                    )
                    if current is None:
                        raise FeedbackNotFoundError("feedback report was not found")
                    current_report = self._row(current)
                    if current_report.status != "reserved":
                        return current_report
                    raise FeedbackConflictError(
                        "feedback upload cleanup has already started"
                    )
                return self._row(updated)

    async def get(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
    ) -> FeedbackReport:
        pool = self.primary._require_pool()
        row = await pool.fetchrow(
            """
            SELECT *
            FROM feedback_reports
            WHERE report_id = $1 AND client_app_id = $2
            """,
            report_id,
            client_app_id,
        )
        if row is None:
            raise FeedbackNotFoundError("feedback report was not found")
        return self._row(row)

    async def get_by_idempotency(
        self,
        *,
        client_app_id: str,
        principal_hash_version: int,
        principal_hash: str,
        idempotency_hash: str,
        now: datetime | None = None,
    ) -> FeedbackReport:
        pool = self.primary._require_pool()
        reference = now or datetime.now(UTC)
        row = await pool.fetchrow(
            """
            SELECT *
            FROM feedback_reports
            WHERE client_app_id = $1
              AND COALESCE(principal_hash_version, 0) = $2
              AND COALESCE(principal_hash, subject_hash) = $3
              AND idempotency_hash = $4
              AND retained_until > $5
            """,
            client_app_id,
            principal_hash_version,
            principal_hash,
            idempotency_hash,
            reference,
        )
        if row is None:
            tombstone_expires_at = await pool.fetchval(
                """
                SELECT expires_at
                FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                client_app_id,
                principal_hash_version,
                principal_hash,
                idempotency_hash,
            )
            if tombstone_expires_at is not None and tombstone_expires_at > reference:
                raise FeedbackGoneError("feedback reservation expired")
            await pool.execute(
                """
                DELETE FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                  AND expires_at <= $5
                """,
                client_app_id,
                principal_hash_version,
                principal_hash,
                idempotency_hash,
                reference,
            )
            raise FeedbackNotFoundError("feedback report was not found")
        report = self._row(row)
        _require_authorizable_principal(report)
        return report

    async def mark_sent(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        object_generation: int,
        completed_at: datetime,
    ) -> FeedbackReport:
        pool = self.primary._require_pool()
        row = await pool.fetchrow(
            """
            UPDATE feedback_reports
            SET status = 'sent',
                object_generation = $3,
                completed_at = $4,
                cleanup_after = NULL,
                cleanup_phase = NULL,
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND client_app_id = $2
              AND status = 'reserved'
              AND cleanup_phase = 'delete_pending'
              AND cleanup_claimed_at IS NULL
              AND cleanup_after > $4
            RETURNING *
            """,
            report_id,
            client_app_id,
            object_generation,
            completed_at,
        )
        if row is not None:
            return self._row(row)
        current = await self.get(
            report_id=report_id,
            client_app_id=client_app_id,
        )
        if current.status == "sent":
            return current
        raise FeedbackConflictError("feedback report cannot be completed")

    async def mark_rejected(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        rejected_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport:
        return await self._update_returning(
            """
            UPDATE feedback_reports
            SET status = 'rejected',
                deleted_at = $3,
                cleanup_after = LEAST(
                    retained_until,
                    GREATEST(cleanup_after, $4)
                ),
                cleanup_phase = 'delete_pending',
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND client_app_id = $2
              AND status = 'reserved'
              AND cleanup_phase = 'delete_pending'
              AND cleanup_claimed_at IS NULL
            RETURNING *
            """,
            report_id,
            client_app_id,
            rejected_at,
            cleanup_after,
        )

    async def request_delete(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        requested_at: datetime,
        cleanup_after: datetime,
    ) -> FeedbackReport:
        return await self._update_returning(
            """
            UPDATE feedback_reports
            SET status = 'deleting',
                deleted_at = COALESCE(deleted_at, $3),
                cleanup_after = LEAST(
                    retained_until,
                    GREATEST(COALESCE(cleanup_after, $4), $4)
                ),
                cleanup_phase = 'delete_pending',
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND client_app_id = $2
              AND status <> 'deleted'
              AND cleanup_claimed_at IS NULL
            RETURNING *
            """,
            report_id,
            client_app_id,
            requested_at,
            cleanup_after,
        )

    async def claim_cleanup(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]:
        pool = self.primary._require_pool()
        rows = await pool.fetch(
            """
            WITH candidates AS (
                SELECT report_id
                FROM feedback_reports
                WHERE status IN ('reserved', 'rejected', 'deleting')
                  AND cleanup_after <= $1
                  AND cleanup_phase IN ('delete_pending', 'confirm_absent')
                  AND (
                      cleanup_claimed_at IS NULL
                      OR cleanup_claimed_at <= $1 - INTERVAL '30 minutes'
                  )
                ORDER BY cleanup_after, report_id
                FOR UPDATE SKIP LOCKED
                LIMIT $2
            )
            UPDATE feedback_reports report
            SET cleanup_claimed_at = $1
            FROM candidates
            WHERE report.report_id = candidates.report_id
            RETURNING report.*
            """,
            now,
            limit,
        )
        return [self._row(row) for row in rows]

    async def finish_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        completed_at: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            UPDATE feedback_reports
            SET status = CASE
                    WHEN status IN ('reserved', 'deleting') THEN 'deleted'
                    ELSE status
                END,
                deleted_at = COALESCE(deleted_at, $3),
                cleanup_after = NULL,
                cleanup_phase = NULL,
                cleanup_claimed_at = NULL,
                object_absence_confirmed_at = $3
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
              AND cleanup_phase = 'confirm_absent'
              AND status IN ('reserved', 'rejected', 'deleting')
            RETURNING TRUE
            """,
            report_id,
            claim_token,
            completed_at,
        )
        return bool(result)

    async def schedule_cleanup_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            UPDATE feedback_reports
            SET cleanup_after = $3,
                cleanup_phase = 'confirm_absent',
                cleanup_claimed_at = NULL,
                object_absence_confirmed_at = NULL
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
              AND status IN ('reserved', 'rejected', 'deleting')
            RETURNING TRUE
            """,
            report_id,
            claim_token,
            next_check_at,
        )
        return bool(result)

    async def schedule_expired_confirmation(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        next_check_at: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            UPDATE feedback_reports
            SET status = 'deleting',
                deleted_at = COALESCE(deleted_at, $2),
                cleanup_after = $3,
                cleanup_phase = 'confirm_absent',
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
              AND cleanup_after IS NULL
              AND cleanup_phase IS NULL
              AND object_absence_confirmed_at IS NULL
              AND retained_until <= $2
            RETURNING TRUE
            """,
            report_id,
            claim_token,
            next_check_at,
        )
        return bool(result)

    async def release_cleanup(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            UPDATE feedback_reports
            SET cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
              AND status IN ('reserved', 'rejected', 'deleting')
            RETURNING TRUE
            """,
            report_id,
            claim_token,
        )
        return bool(result)

    async def claim_expired(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> list[FeedbackReport]:
        pool = self.primary._require_pool()
        rows = await pool.fetch(
            """
            WITH candidates AS (
                SELECT report_id
                FROM feedback_reports
                WHERE retained_until <= $1
                  AND cleanup_after IS NULL
                  AND cleanup_phase IS NULL
                  AND (
                      cleanup_claimed_at IS NULL
                      OR cleanup_claimed_at <= $1 - INTERVAL '30 minutes'
                  )
                ORDER BY retained_until, report_id
                FOR UPDATE SKIP LOCKED
                LIMIT $2
            )
            UPDATE feedback_reports report
            SET cleanup_claimed_at = $1
            FROM candidates
            WHERE report.report_id = candidates.report_id
            RETURNING report.*
            """,
            now,
            limit,
        )
        return [self._row(row) for row in rows]

    async def finish_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
        deleted_at: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                identity = await connection.fetchrow(
                    """
                    SELECT
                        client_app_id,
                        COALESCE(principal_hash_version, 0)
                            AS principal_hash_version,
                        COALESCE(principal_hash, subject_hash) AS principal_hash
                    FROM feedback_reports
                    WHERE report_id = $1
                      AND cleanup_claimed_at = $2
                    """,
                    report_id,
                    claim_token,
                )
                if identity is None:
                    return False
                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended('noop-feedback-app:' || $1, 0)
                    )
                    """,
                    identity["client_app_id"],
                )
                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended(
                            'noop-feedback:' || $1 || ':' || $2 || ':' || $3,
                            0
                        )
                    )
                    """,
                    identity["client_app_id"],
                    str(identity["principal_hash_version"]),
                    str(identity["principal_hash"]).strip(),
                )
                result = await connection.fetchval(
                    """
                    WITH deleted_report AS (
                        DELETE FROM feedback_reports
                        WHERE report_id = $1
                          AND cleanup_claimed_at = $2
                          AND object_absence_confirmed_at IS NOT NULL
                          AND retained_until <= $2
                        RETURNING
                            client_app_id,
                            principal_hash_version,
                            principal_hash,
                            idempotency_hash,
                            created_at
                    ),
                    retired_key AS (
                        INSERT INTO feedback_idempotency_tombstones (
                            client_app_id,
                            principal_hash_version,
                            principal_hash,
                            idempotency_hash,
                            reserved_at,
                            expires_at
                        )
                        SELECT
                            client_app_id,
                            principal_hash_version,
                            principal_hash,
                            idempotency_hash,
                            created_at,
                            created_at + INTERVAL '1080 hours'
                        FROM deleted_report
                        WHERE created_at + INTERVAL '1080 hours' > $3::timestamptz
                        ON CONFLICT (
                            client_app_id,
                            principal_hash_version,
                            principal_hash,
                            idempotency_hash
                        ) DO NOTHING
                        RETURNING TRUE
                    )
                    SELECT EXISTS (SELECT 1 FROM deleted_report)
                    """,
                    report_id,
                    claim_token,
                    deleted_at,
                )
        return bool(result)

    async def release_expired(
        self,
        *,
        report_id: UUID,
        claim_token: datetime,
    ) -> bool:
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            UPDATE feedback_reports
            SET cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
            RETURNING TRUE
            """,
            report_id,
            claim_token,
        )
        return bool(result)

    async def purge_expired_tombstones(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> FeedbackTombstoneRetentionResult:
        pool = self.primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                purged = await connection.fetchval(
                    """
                    WITH expired AS (
                        SELECT
                            client_app_id,
                            principal_hash_version,
                            principal_hash,
                            idempotency_hash
                        FROM feedback_idempotency_tombstones
                        WHERE expires_at <= $1
                        ORDER BY
                            expires_at,
                            client_app_id,
                            principal_hash,
                            idempotency_hash
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    ),
                    removed AS (
                        DELETE FROM feedback_idempotency_tombstones tombstone
                        USING expired
                        WHERE tombstone.client_app_id = expired.client_app_id
                          AND tombstone.principal_hash_version =
                              expired.principal_hash_version
                          AND tombstone.principal_hash = expired.principal_hash
                          AND tombstone.idempotency_hash =
                              expired.idempotency_hash
                        RETURNING 1
                    )
                    SELECT count(*) FROM removed
                    """,
                    now,
                    limit,
                )
                backlog = await connection.fetchrow(
                    """
                    WITH remaining AS (
                        SELECT expires_at
                        FROM feedback_idempotency_tombstones
                        WHERE expires_at <= $1
                        ORDER BY expires_at
                        LIMIT $2
                    )
                    SELECT
                        count(*) AS remaining_expired_count,
                        COALESCE(
                            FLOOR(
                                EXTRACT(
                                    EPOCH FROM (
                                        $1::timestamptz - MIN(expires_at)
                                    )
                                )
                            )::bigint,
                            0
                        ) AS oldest_expired_age_seconds
                    FROM remaining
                    """,
                    now,
                    _FEEDBACK_TOMBSTONE_BACKLOG_QUERY_LIMIT,
                )
        return FeedbackTombstoneRetentionResult(
            purged_count=int(purged or 0),
            remaining_expired_count=int(backlog["remaining_expired_count"] or 0),
            oldest_expired_age_seconds=int(backlog["oldest_expired_age_seconds"] or 0),
        )

    async def _update_returning(self, query: str, *arguments: object) -> FeedbackReport:
        pool = self.primary._require_pool()
        row = await pool.fetchrow(query, *arguments)
        if row is None:
            report_id = arguments[0]
            client_app_id = arguments[1]
            try:
                current = await self.get(
                    report_id=report_id,  # type: ignore[arg-type]
                    client_app_id=client_app_id,  # type: ignore[arg-type]
                )
            except FeedbackNotFoundError:
                raise
            raise FeedbackConflictError(
                f"feedback report cannot transition from {current.status}"
            )
        return self._row(row)

    @staticmethod
    def _row(row: Any) -> FeedbackReport:
        return FeedbackReport(
            report_id=row["report_id"],
            client_app_id=str(row["client_app_id"]),
            subject_hash=str(row["subject_hash"]).strip(),
            principal_hash_version=(
                int(row["principal_hash_version"])
                if row["principal_hash_version"] is not None
                else 0
            ),
            principal_hash=str(
                row["principal_hash"]
                if row["principal_hash"] is not None
                else row["subject_hash"]
            ).strip(),
            idempotency_hash=str(row["idempotency_hash"]).strip(),
            request_hash=str(row["request_hash"]).strip(),
            platform=str(row["platform"]),
            app_version=str(row["app_version"]),
            archive_bytes=int(row["archive_bytes"]),
            archive_sha256=str(row["archive_sha256"]).strip(),
            includes_user_note=bool(row["includes_user_note"]),
            includes_screenshot=bool(row["includes_screenshot"]),
            receipt=str(row["receipt"]),
            object_key=str(row["object_key"]),
            status=str(row["status"]),
            object_generation=(
                int(row["object_generation"])
                if row["object_generation"] is not None
                else None
            ),
            created_at=row["created_at"],
            upload_expires_at=row["upload_expires_at"],
            completed_at=row["completed_at"],
            retained_until=row["retained_until"],
            deleted_at=row["deleted_at"],
            cleanup_after=row["cleanup_after"],
            cleanup_phase=row["cleanup_phase"],
            cleanup_claimed_at=row["cleanup_claimed_at"],
            object_absence_confirmed_at=row["object_absence_confirmed_at"],
        )
