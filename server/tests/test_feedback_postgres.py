from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.feedback_repository import (
    FeedbackConflictError,
    FeedbackReport,
    PostgresFeedbackRepository,
)
from app.repository import PostgresRepository


DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "postgresql")
FINALIZATION_GRACE = timedelta(minutes=5)


def _primary() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )


def _report(
    *,
    now: datetime,
    principal_hash: str,
    idempotency_seed: str,
    request_seed: str,
    subject_hash: str | None = None,
    status: str = "reserved",
    created_at: datetime | None = None,
    upload_expires_at: datetime | None = None,
    cleanup_after: datetime | None = None,
) -> FeedbackReport:
    report_id = uuid4()
    receipt = base64.b32encode(report_id.bytes).decode("ascii")[:16]
    created = created_at or now
    upload_expiry = upload_expires_at or created + timedelta(minutes=15)
    return FeedbackReport(
        report_id=report_id,
        client_app_id="1:123456789012:ios:0123456789abcdef",
        subject_hash=subject_hash or principal_hash,
        principal_hash_version=1,
        principal_hash=principal_hash,
        idempotency_hash=hashlib.sha256(
            f"{principal_hash}\0{idempotency_seed}".encode()
        ).hexdigest(),
        request_hash=hashlib.sha256(request_seed.encode()).hexdigest(),
        platform="ios",
        app_version="9.2.0",
        archive_bytes=100,
        archive_sha256=hashlib.sha256(report_id.bytes).hexdigest(),
        includes_user_note=False,
        includes_screenshot=False,
        receipt=f"NF-{receipt}",
        object_key=f"v1/feedback/{created:%Y/%m/%d}/{report_id}.zip",
        status=status,
        object_generation=42 if status == "sent" else None,
        created_at=created,
        upload_expires_at=upload_expiry,
        completed_at=created if status == "sent" else None,
        retained_until=created + timedelta(days=28),
        deleted_at=None,
        cleanup_after=(
            None
            if status == "sent"
            else cleanup_after or upload_expiry + FINALIZATION_GRACE
        ),
        cleanup_phase=None if status == "sent" else "delete_pending",
    )


async def _wait_for_advisory_waiters(pool, *, minimum: int) -> None:
    for _ in range(200):
        waiting = await pool.fetchval(
            """
            SELECT count(*)
            FROM pg_locks
            WHERE locktype = 'advisory' AND NOT granted
            """
        )
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} advisory-lock waiters")


async def _hold_principal_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_lock(
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


async def _release_principal_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_unlock(
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


async def _delete_principals(
    primary: PostgresRepository,
    *principal_hashes: str,
) -> None:
    if primary._pool is not None:
        await primary._require_pool().execute(
            "DELETE FROM feedback_reports WHERE principal_hash = ANY($1::char(64)[])",
            list(principal_hashes),
        )


async def _insert_report(
    primary: PostgresRepository,
    report: FeedbackReport,
) -> None:
    await primary._require_pool().execute(
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
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25
        )
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


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_concurrent_same_key_replays_before_quota() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        first = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="same-key",
            request_seed="same-payload",
        )
        second = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="same-key",
            request_seed="same-payload",
        )
        pool = primary._require_pool()
        async with pool.acquire() as lock_connection:
            await _hold_principal_lock(lock_connection, first)
            tasks = [
                asyncio.create_task(
                    repository.reserve(
                        report=report,
                        daily_report_limit=1,
                        pending_byte_limit=150,
                    )
                )
                for report in (first, second)
            ]
            await _wait_for_advisory_waiters(pool, minimum=2)
            await _release_principal_lock(lock_connection, first)
        results = await asyncio.gather(*tasks)

        assert {created for _, created in results} == {False, True}
        assert results[0][0].report_id == results[1][0].report_id
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_same_subject_different_tenant_principals_are_isolated() -> None:
    primary = _primary()
    first_hash = hashlib.sha256(b"issuer-a\0tenant-a\0same-subject").hexdigest()
    second_hash = hashlib.sha256(b"issuer-a\0tenant-b\0same-subject").hexdigest()
    subject_hash = hashlib.sha256(b"same-subject").hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        first, first_created = await repository.reserve(
            report=_report(
                now=now,
                principal_hash=first_hash,
                subject_hash=subject_hash,
                idempotency_seed="shared-key",
                request_seed="same-payload",
            ),
            daily_report_limit=1,
        )
        second, second_created = await repository.reserve(
            report=_report(
                now=now,
                principal_hash=second_hash,
                subject_hash=subject_hash,
                idempotency_seed="shared-key",
                request_seed="same-payload",
            ),
            daily_report_limit=1,
        )

        assert first_created and second_created
        assert first.report_id != second.report_id
    finally:
        await _delete_principals(primary, first_hash, second_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_v0_row_is_not_replayed_or_counted_for_v1_principal() -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(b"legacy-shared-subject").hexdigest()
    principal_hash = hashlib.sha256(
        b"issuer-a\0tenant-b\0legacy-shared-subject"
    ).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        legacy = replace(
            _report(
                now=now,
                principal_hash=subject_hash,
                subject_hash=subject_hash,
                idempotency_seed="legacy-placeholder",
                request_seed="same-payload",
            ),
            principal_hash_version=0,
            idempotency_hash=hashlib.sha256(
                (
                    f"1:123456789012:ios:0123456789abcdef\0{subject_hash}\0shared-key"
                ).encode()
            ).hexdigest(),
        )
        with pytest.raises(FeedbackConflictError):
            await repository.reserve(report=legacy)
        await _insert_report(primary, legacy)

        current = _report(
            now=now,
            principal_hash=principal_hash,
            subject_hash=subject_hash,
            idempotency_seed="shared-key",
            request_seed="same-payload",
        )
        reserved, created = await repository.reserve(
            report=current,
            daily_report_limit=1,
            pending_byte_limit=current.archive_bytes,
        )
        activated = await repository.activate_upload_capability(
            report_id=reserved.report_id,
            client_app_id=reserved.client_app_id,
            activated_at=now,
            upload_expires_at=now + timedelta(minutes=30),
            cleanup_after=now + timedelta(minutes=35),
            pending_byte_limit=current.archive_bytes,
        )

        assert created
        assert reserved.report_id == current.report_id
        assert reserved.report_id != legacy.report_id
        assert reserved.principal_hash_version == 1
        assert activated.report_id == current.report_id
    finally:
        await _delete_principals(primary, subject_hash, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_activation_updates_expiry_and_cleanup_atomically() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="activation",
            request_seed="activation",
            upload_expires_at=now + timedelta(minutes=5),
        )
        await repository.reserve(report=report)
        capability_expiry = now + timedelta(minutes=30)
        cleanup_after = capability_expiry + FINALIZATION_GRACE
        activated = await repository.activate_upload_capability(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            activated_at=now,
            upload_expires_at=capability_expiry,
            cleanup_after=cleanup_after,
            pending_byte_limit=150,
        )

        assert activated.upload_expires_at == capability_expiry
        assert activated.cleanup_after == cleanup_after
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_mark_sent_cannot_race_cleanup_claim() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="completion-race",
            request_seed="completion-race",
            created_at=now - timedelta(days=1),
            upload_expires_at=now - timedelta(minutes=10),
            cleanup_after=now,
        )
        await repository.reserve(report=report)
        assert len(await repository.claim_cleanup(now=now, limit=1)) == 1

        with pytest.raises(FeedbackConflictError):
            await repository.mark_sent(
                report_id=report.report_id,
                client_app_id=report.client_app_id,
                object_generation=42,
                completed_at=now,
            )
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_cleanup_requires_confirm_absent_phase() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="cleanup",
            request_seed="cleanup",
            created_at=now - timedelta(days=1),
            upload_expires_at=now - timedelta(minutes=10),
            cleanup_after=now,
        )
        await repository.reserve(report=report)
        first_claim = (await repository.claim_cleanup(now=now, limit=1))[0]
        assert first_claim.cleanup_claimed_at is not None
        assert not await repository.finish_cleanup(
            report_id=report.report_id,
            claim_token=first_claim.cleanup_claimed_at,
            completed_at=now,
        )
        next_check = now + timedelta(minutes=1)
        assert await repository.schedule_cleanup_confirmation(
            report_id=report.report_id,
            claim_token=first_claim.cleanup_claimed_at,
            next_check_at=next_check,
        )
        second_claim = (await repository.claim_cleanup(now=next_check, limit=1))[0]
        assert second_claim.cleanup_claimed_at is not None
        assert await repository.finish_cleanup(
            report_id=report.report_id,
            claim_token=second_claim.cleanup_claimed_at,
            completed_at=next_check,
        )
        current = await repository.get(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
        )
        assert current.status == "deleted"
        assert current.cleanup_phase is None
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_retention_confirmation_cannot_be_claimed_early() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="retention-confirmation",
            request_seed="retention-confirmation",
            status="sent",
            created_at=now - timedelta(days=29),
        )
        await repository.reserve(report=report)
        retention_claim = (await repository.claim_expired(now=now, limit=1))[0]
        assert retention_claim.cleanup_claimed_at is not None
        next_check_at = now + timedelta(minutes=1)
        assert await repository.schedule_expired_confirmation(
            report_id=report.report_id,
            claim_token=retention_claim.cleanup_claimed_at,
            next_check_at=next_check_at,
        )

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
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_cleanup_claim_lease_exceeds_twenty_minutes() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="lease",
            request_seed="lease",
            created_at=now - timedelta(days=1),
            upload_expires_at=now - timedelta(hours=1),
            cleanup_after=now - timedelta(hours=1),
        )
        await repository.reserve(report=report)
        old = (
            await repository.claim_cleanup(now=now - timedelta(minutes=25), limit=1)
        )[0]
        assert await repository.claim_cleanup(now=now, limit=1) == []
        reclaimed = (
            await repository.claim_cleanup(now=now + timedelta(minutes=6), limit=1)
        )[0]
        assert old.cleanup_claimed_at != reclaimed.cleanup_claimed_at
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()
