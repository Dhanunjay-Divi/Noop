from __future__ import annotations

import asyncio
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from typing import Any, Protocol
from uuid import UUID

from app.repository import PostgresRepository


_CLAIM_LEASE = timedelta(minutes=15)
_PENDING_CAPABILITY_STATUSES = frozenset({"reserved", "rejected", "deleting"})


class FeedbackRepositoryError(Exception):
    """Base class for feedback metadata failures."""


class FeedbackNotFoundError(FeedbackRepositoryError):
    """The report does not exist for this attested application."""


class FeedbackConflictError(FeedbackRepositoryError):
    """An idempotency key or state transition conflicts with existing data."""


class FeedbackQuotaExceededError(FeedbackRepositoryError):
    """The authenticated account exceeded a bounded feedback submission quota."""


@dataclass(frozen=True, slots=True)
class FeedbackReport:
    report_id: UUID
    client_app_id: str
    subject_hash: str
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
    cleanup_claimed_at: datetime | None = None


class FeedbackRepository(Protocol):
    async def reserve(
        self,
        *,
        report: FeedbackReport,
        daily_report_limit: int = 100,
        pending_byte_limit: int = 256 * 1024 * 1024,
    ) -> tuple[FeedbackReport, bool]: ...

    async def activate_upload_capability(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        activated_at: datetime,
        upload_expires_at: datetime,
        pending_byte_limit: int = 256 * 1024 * 1024,
    ) -> FeedbackReport: ...

    async def get(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
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
    ) -> FeedbackReport: ...

    async def request_delete(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        requested_at: datetime,
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


class MemoryFeedbackRepository:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._reports: dict[UUID, FeedbackReport] = {}
        self._idempotency: dict[tuple[str, str, str], UUID] = {}

    async def reserve(
        self,
        *,
        report: FeedbackReport,
        daily_report_limit: int = 100,
        pending_byte_limit: int = 256 * 1024 * 1024,
    ) -> tuple[FeedbackReport, bool]:
        async with self._lock:
            key = (
                report.client_app_id,
                report.subject_hash,
                report.idempotency_hash,
            )
            existing_id = self._idempotency.get(key)
            if existing_id is not None:
                existing = self._reports[existing_id]
                if existing.request_hash != report.request_hash:
                    raise FeedbackConflictError(
                        "feedback idempotency key was reused"
                    )
                return existing, False
            quota_start = report.created_at - timedelta(days=1)
            subject_reports = [
                existing
                for existing in self._reports.values()
                if existing.client_app_id == report.client_app_id
                and existing.subject_hash == report.subject_hash
            ]
            daily_reports = [
                existing
                for existing in subject_reports
                if existing.created_at >= quota_start
            ]
            if len(daily_reports) >= daily_report_limit:
                raise FeedbackQuotaExceededError(
                    "feedback daily report quota was exceeded"
                )
            pending_bytes = sum(
                existing.archive_bytes
                for existing in subject_reports
                if existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > report.created_at
            )
            if pending_bytes + report.archive_bytes > pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback pending byte quota was exceeded"
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
        pending_byte_limit: int = 256 * 1024 * 1024,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            if report.status != "reserved":
                return report
            pending_bytes = sum(
                existing.archive_bytes
                for existing in self._reports.values()
                if existing.report_id != report.report_id
                and existing.client_app_id == report.client_app_id
                and existing.subject_hash == report.subject_hash
                and existing.status in _PENDING_CAPABILITY_STATUSES
                and existing.upload_expires_at > activated_at
            )
            if pending_bytes + report.archive_bytes > pending_byte_limit:
                raise FeedbackQuotaExceededError(
                    "feedback pending byte quota was exceeded"
                )
            report = replace(
                report,
                upload_expires_at=max(report.upload_expires_at, upload_expires_at),
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
            if report.status != "reserved":
                raise FeedbackConflictError("feedback report cannot be completed")
            report = replace(
                report,
                status="sent",
                object_generation=object_generation,
                completed_at=completed_at,
            )
            self._reports[report_id] = report
            return report

    async def mark_rejected(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        rejected_at: datetime,
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            if report.status != "reserved":
                raise FeedbackConflictError("feedback report cannot be rejected")
            report = replace(
                report,
                status="rejected",
                deleted_at=rejected_at,
                cleanup_after=max(rejected_at, report.upload_expires_at),
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
    ) -> FeedbackReport:
        async with self._lock:
            report = self._get(report_id, client_app_id)
            report = replace(
                report,
                status="deleting",
                deleted_at=report.deleted_at or requested_at,
                cleanup_after=max(requested_at, report.upload_expires_at),
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
                    report.status in {"rejected", "deleting"}
                    and report.cleanup_after is not None
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
                or report.status not in {"rejected", "deleting"}
            ):
                return False
            self._reports[report_id] = replace(
                report,
                status="deleted" if report.status == "deleting" else report.status,
                deleted_at=report.deleted_at or completed_at,
                cleanup_after=None,
                cleanup_claimed_at=None,
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
                or report.status not in {"rejected", "deleting"}
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
                    and (
                        report.cleanup_claimed_at is None
                        or report.cleanup_claimed_at <= now - _CLAIM_LEASE
                    )
                    and (
                        report.cleanup_after is None
                        or report.cleanup_after <= now
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
        del deleted_at
        async with self._lock:
            report = self._reports.get(report_id)
            if report is None or report.cleanup_claimed_at != claim_token:
                return False
            self._reports.pop(report_id)
            self._idempotency.pop(
                (
                    report.client_app_id,
                    report.subject_hash,
                    report.idempotency_hash,
                ),
                None,
            )
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
    ) -> tuple[FeedbackReport, bool]:
        pool = self.primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                async def existing_report() -> Any:
                    return await connection.fetchrow(
                        """
                        SELECT *
                        FROM feedback_reports
                        WHERE client_app_id = $1
                          AND subject_hash = $2
                          AND idempotency_hash = $3
                        """,
                        report.client_app_id,
                        report.subject_hash,
                        report.idempotency_hash,
                    )

                existing = await existing_report()
                if existing is not None:
                    value = self._row(existing)
                    if value.request_hash != report.request_hash:
                        raise FeedbackConflictError(
                            "feedback idempotency key was reused"
                        )
                    return value, False

                await connection.execute(
                    """
                    SELECT pg_advisory_xact_lock(
                        hashtextextended(
                            'noop-feedback:' || $1 || ':' || $2,
                            0
                        )
                    )
                    """,
                    report.client_app_id,
                    report.subject_hash,
                )
                existing = await existing_report()
                if existing is not None:
                    value = self._row(existing)
                    if value.request_hash != report.request_hash:
                        raise FeedbackConflictError(
                            "feedback idempotency key was reused"
                        )
                    return value, False
                quota = await connection.fetchrow(
                    """
                    SELECT
                        count(*) FILTER (
                            WHERE created_at >= $3::timestamptz - INTERVAL '24 hours'
                        ) AS daily_reports,
                        COALESCE(sum(archive_bytes) FILTER (
                            WHERE status IN ('reserved', 'rejected', 'deleting')
                              AND upload_expires_at > $3::timestamptz
                        ), 0) AS pending_bytes
                    FROM feedback_reports
                    WHERE client_app_id = $1
                      AND subject_hash = $2
                    """,
                    report.client_app_id,
                    report.subject_hash,
                    report.created_at,
                )
                if quota is None:
                    raise FeedbackConflictError("feedback quota could not be checked")
                if int(quota["daily_reports"]) >= daily_report_limit:
                    raise FeedbackQuotaExceededError(
                        "feedback daily report quota was exceeded"
                    )
                if (
                    int(quota["pending_bytes"]) + report.archive_bytes
                    > pending_byte_limit
                ):
                    raise FeedbackQuotaExceededError(
                        "feedback pending byte quota was exceeded"
                    )

                inserted = await connection.fetchrow(
                    """
                    INSERT INTO feedback_reports (
                        report_id, client_app_id, subject_hash, idempotency_hash,
                        request_hash, platform, app_version, archive_bytes,
                        archive_sha256, includes_user_note, includes_screenshot,
                        receipt, object_key, status, object_generation, created_at,
                        upload_expires_at, completed_at, retained_until, deleted_at,
                        cleanup_after, cleanup_claimed_at
                    )
                    VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
                        $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22
                    )
                    RETURNING *
                    """,
                    report.report_id,
                    report.client_app_id,
                    report.subject_hash,
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
        pending_byte_limit: int = 256 * 1024 * 1024,
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
                        hashtextextended(
                            'noop-feedback:' || $1 || ':' || $2,
                            0
                        )
                    )
                    """,
                    initial_report.client_app_id,
                    initial_report.subject_hash,
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
                if report.status != "reserved":
                    return report
                pending_bytes = await connection.fetchval(
                    """
                    SELECT COALESCE(sum(archive_bytes), 0)
                    FROM feedback_reports
                    WHERE client_app_id = $1
                      AND subject_hash = $2
                      AND report_id <> $3
                      AND status IN ('reserved', 'rejected', 'deleting')
                      AND upload_expires_at > $4
                    """,
                    report.client_app_id,
                    report.subject_hash,
                    report.report_id,
                    activated_at,
                )
                if int(pending_bytes or 0) + report.archive_bytes > pending_byte_limit:
                    raise FeedbackQuotaExceededError(
                        "feedback pending byte quota was exceeded"
                    )
                updated = await connection.fetchrow(
                    """
                    UPDATE feedback_reports
                    SET upload_expires_at = GREATEST(upload_expires_at, $3)
                    WHERE report_id = $1
                      AND client_app_id = $2
                      AND status = 'reserved'
                    RETURNING *
                    """,
                    report_id,
                    client_app_id,
                    upload_expires_at,
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
                        raise FeedbackNotFoundError(
                            "feedback report was not found"
                        )
                    return self._row(current)
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
                completed_at = $4
            WHERE report_id = $1
              AND client_app_id = $2
              AND status = 'reserved'
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
    ) -> FeedbackReport:
        return await self._update_returning(
            """
            UPDATE feedback_reports
            SET status = 'rejected',
                deleted_at = $3,
                cleanup_after = GREATEST($3, upload_expires_at),
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND client_app_id = $2
              AND status = 'reserved'
            RETURNING *
            """,
            report_id,
            client_app_id,
            rejected_at,
        )

    async def request_delete(
        self,
        *,
        report_id: UUID,
        client_app_id: str,
        requested_at: datetime,
    ) -> FeedbackReport:
        return await self._update_returning(
            """
            UPDATE feedback_reports
            SET status = 'deleting',
                deleted_at = COALESCE(deleted_at, $3),
                cleanup_after = GREATEST($3, upload_expires_at),
                cleanup_claimed_at = NULL
            WHERE report_id = $1 AND client_app_id = $2
            RETURNING *
            """,
            report_id,
            client_app_id,
            requested_at,
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
                WHERE status IN ('rejected', 'deleting')
                  AND cleanup_after <= $1
                  AND (
                      cleanup_claimed_at IS NULL
                      OR cleanup_claimed_at <= $1 - INTERVAL '15 minutes'
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
                    WHEN status = 'deleting' THEN 'deleted'
                    ELSE status
                END,
                deleted_at = COALESCE(deleted_at, $3),
                cleanup_after = NULL,
                cleanup_claimed_at = NULL
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
              AND status IN ('rejected', 'deleting')
            RETURNING TRUE
            """,
            report_id,
            claim_token,
            completed_at,
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
              AND status IN ('rejected', 'deleting')
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
                  AND (
                      cleanup_claimed_at IS NULL
                      OR cleanup_claimed_at <= $1 - INTERVAL '15 minutes'
                  )
                  AND (
                      cleanup_after IS NULL
                      OR cleanup_after <= $1
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
        del deleted_at
        pool = self.primary._require_pool()
        result = await pool.fetchval(
            """
            DELETE FROM feedback_reports
            WHERE report_id = $1
              AND cleanup_claimed_at = $2
            RETURNING TRUE
            """,
            report_id,
            claim_token,
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
            cleanup_claimed_at=row["cleanup_claimed_at"],
        )
