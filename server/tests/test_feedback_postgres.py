from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.feedback_repository import (
    FeedbackConflictError,
    FeedbackQuotaExceededError,
    FeedbackReport,
    PostgresFeedbackRepository,
)
from app.repository import PostgresRepository


DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "postgresql")


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
    subject_hash: str,
    idempotency_seed: str,
    request_seed: str,
    created_at: datetime | None = None,
    upload_expires_at: datetime | None = None,
    retained_until: datetime | None = None,
) -> FeedbackReport:
    report_id = uuid4()
    receipt = base64.b32encode(report_id.bytes).decode("ascii")[:16]
    created = created_at or now
    return FeedbackReport(
        report_id=report_id,
        client_app_id="1:123456789012:ios:0123456789abcdef",
        subject_hash=subject_hash,
        idempotency_hash=hashlib.sha256(idempotency_seed.encode()).hexdigest(),
        request_hash=hashlib.sha256(request_seed.encode()).hexdigest(),
        platform="ios",
        app_version="9.2.0",
        archive_bytes=100,
        archive_sha256=hashlib.sha256(report_id.bytes).hexdigest(),
        includes_user_note=False,
        includes_screenshot=False,
        receipt=f"NF-{receipt}",
        object_key=f"v1/feedback/{created:%Y/%m/%d}/{report_id}.zip",
        status="reserved",
        object_generation=None,
        created_at=created,
        upload_expires_at=(
            upload_expires_at or created + timedelta(minutes=15)
        ),
        completed_at=None,
        retained_until=retained_until or created + timedelta(days=28),
        deleted_at=None,
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


async def _hold_subject_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_lock(
            hashtextextended('noop-feedback:' || $1 || ':' || $2, 0)
        )
        """,
        report.client_app_id,
        report.subject_hash,
    )


async def _release_subject_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_unlock(
            hashtextextended('noop-feedback:' || $1 || ':' || $2, 0)
        )
        """,
        report.client_app_id,
        report.subject_hash,
    )


async def _delete_subject(primary: PostgresRepository, subject_hash: str) -> None:
    if primary._pool is not None:
        await primary._require_pool().execute(
            "DELETE FROM feedback_reports WHERE subject_hash = $1",
            subject_hash,
        )


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_concurrent_same_key_replays_before_quota() -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        first = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="same-key",
            request_seed="same-payload",
        )
        second = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="same-key",
            request_seed="same-payload",
        )
        pool = primary._require_pool()
        async with pool.acquire() as lock_connection:
            await _hold_subject_lock(lock_connection, first)
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
            await _release_subject_lock(lock_connection, first)
        results = await asyncio.gather(*tasks)

        assert {created for _, created in results} == {False, True}
        assert results[0][0].report_id == results[1][0].report_id
    finally:
        await _delete_subject(primary, subject_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_concurrent_same_key_different_payload_conflicts() -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        first = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="same-key",
            request_seed="payload-a",
        )
        second = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="same-key",
            request_seed="payload-b",
        )
        pool = primary._require_pool()
        async with pool.acquire() as lock_connection:
            await _hold_subject_lock(lock_connection, first)
            tasks = [
                asyncio.create_task(repository.reserve(report=report))
                for report in (first, second)
            ]
            await _wait_for_advisory_waiters(pool, minimum=2)
            await _release_subject_lock(lock_connection, first)
        results = await asyncio.gather(*tasks, return_exceptions=True)

        assert sum(isinstance(result, tuple) for result in results) == 1
        assert (
            sum(isinstance(result, FeedbackConflictError) for result in results)
            == 1
        )
    finally:
        await _delete_subject(primary, subject_hash)
        await primary.shutdown()


@pytest.mark.parametrize("terminal_state", ("deleting", "rejected"))
@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_live_terminal_capability_counts_toward_pending_quota(
    terminal_state: str,
) -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        first = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="first",
            request_seed="first",
            created_at=now - timedelta(days=2),
            upload_expires_at=now + timedelta(minutes=15),
            retained_until=now + timedelta(days=26),
        )
        second = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="second",
            request_seed="second",
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
    finally:
        await _delete_subject(primary, subject_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_activation_persists_expiry_and_cancellation_wins() -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="activation",
            request_seed="activation",
            upload_expires_at=now + timedelta(minutes=5),
        )
        await repository.reserve(report=report)
        capability_expiry = now + timedelta(minutes=30)
        activated = await repository.activate_upload_capability(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            activated_at=now,
            upload_expires_at=capability_expiry,
            pending_byte_limit=150,
        )
        assert activated.upload_expires_at == capability_expiry

        deleting = await repository.request_delete(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            requested_at=now + timedelta(minutes=1),
        )
        assert deleting.cleanup_after == capability_expiry
        raced = await repository.activate_upload_capability(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            activated_at=now + timedelta(minutes=2),
            upload_expires_at=now + timedelta(hours=1),
            pending_byte_limit=150,
        )
        assert raced.status == "deleting"
        assert raced.upload_expires_at == capability_expiry
    finally:
        await _delete_subject(primary, subject_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
async def test_postgres_stale_claim_cannot_finish_or_release_reclaimed_row() -> None:
    primary = _primary()
    subject_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            subject_hash=subject_hash,
            idempotency_seed="claim",
            request_seed="claim",
            created_at=now - timedelta(days=2),
            upload_expires_at=now - timedelta(minutes=30),
            retained_until=now + timedelta(days=26),
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
        assert current.cleanup_claimed_at == new_claim.cleanup_claimed_at
        assert await repository.finish_cleanup(
            report_id=report.report_id,
            claim_token=new_claim.cleanup_claimed_at,
            completed_at=now,
        )
    finally:
        await _delete_subject(primary, subject_hash)
        await primary.shutdown()
