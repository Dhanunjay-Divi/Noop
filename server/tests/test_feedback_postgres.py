from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import asyncpg
import pytest

from app.feedback_repository import (
    FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME,
    FeedbackConflictError,
    FeedbackGoneError,
    FeedbackNotFoundError,
    FeedbackReport,
    FeedbackTombstoneRetentionResult,
    PostgresFeedbackRepository,
)
from app.repository import PostgresRepository


DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL")
DATABASE_ENGINE = "postgresql"
FINALIZATION_GRACE = timedelta(minutes=5)
RESTORE_SMOKE_PATH = (
    Path(__file__).resolve().parents[1] / "backup" / "restore-application-smoke.sql"
)


def _primary() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )


def _restore_smoke_contract_block() -> str:
    smoke = RESTORE_SMOKE_PATH.read_text(encoding="utf-8")
    start = smoke.index("DO $smoke$")
    end = smoke.index("$smoke$;", start) + len("$smoke$;")
    return smoke[start:end]


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


async def _hold_app_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_lock(
            hashtextextended('noop-feedback-app:' || $1, 0)
        )
        """,
        report.client_app_id,
    )


async def _release_app_lock(connection, report: FeedbackReport) -> None:
    await connection.execute(
        """
        SELECT pg_advisory_unlock(
            hashtextextended('noop-feedback-app:' || $1, 0)
        )
        """,
        report.client_app_id,
    )


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


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
@pytest.mark.parametrize("column_name", ("reserved_at", "expires_at"))
async def test_restore_smoke_rejects_nullable_feedback_timestamps(
    column_name: str,
) -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    f"""
                    ALTER TABLE feedback_idempotency_tombstones
                    ALTER COLUMN {column_name} DROP NOT NULL
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match=(
                        "feedback tombstone lifecycle timestamp is missing, "
                        "nullable, or not timestamptz"
                    ),
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
@pytest.mark.parametrize("column_name", ("reserved_at", "expires_at"))
async def test_restore_smoke_rejects_non_timestamptz_feedback_timestamps(
    column_name: str,
) -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    ALTER TABLE feedback_idempotency_tombstones
                    DROP CONSTRAINT feedback_tombstone_time_order
                    """
                )
                await connection.execute(
                    f"""
                    ALTER TABLE feedback_idempotency_tombstones
                    ALTER COLUMN {column_name}
                    TYPE timestamp without time zone
                    USING {column_name} AT TIME ZONE 'UTC'
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match=(
                        "feedback tombstone lifecycle timestamp is missing, "
                        "nullable, or not timestamptz"
                    ),
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_requires_feedback_reports_table() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    "ALTER TABLE feedback_reports RENAME TO feedback_reports_missing"
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match="feedback reports table is missing",
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_feedback_runtime_column_drift() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    ALTER TABLE feedback_reports
                    ALTER COLUMN app_version TYPE varchar(32)
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match=(
                        "feedback reports runtime column contract is missing or invalid"
                    ),
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_weakened_feedback_runtime_constraint() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    ALTER TABLE feedback_reports
                    DROP CONSTRAINT feedback_cleanup_claim_consistent,
                    ADD CONSTRAINT feedback_cleanup_claim_consistent CHECK (TRUE)
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match=(
                        "feedback report runtime constraint is missing, "
                        "unvalidated, or invalid"
                    ),
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_disabled_feedback_retirement_trigger() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    ALTER TABLE feedback_reports
                    DISABLE TRIGGER feedback_report_retire_idempotency
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match="feedback report runtime trigger is missing or disabled",
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_ignores_same_named_index_in_other_schema() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                schema = f"feedback_restore_shadow_{uuid4().hex}"
                await connection.execute(f'CREATE SCHEMA "{schema}"')
                await connection.execute(
                    f"""
                    CREATE TABLE "{schema}".feedback_reports (
                        cleanup_after timestamp with time zone,
                        report_id uuid
                    )
                    """
                )
                await connection.execute(f'SET LOCAL search_path TO "{schema}"')
                await connection.execute(
                    """
                    CREATE INDEX feedback_reports_cleanup_v2_idx
                    ON feedback_reports (cleanup_after, report_id)
                    """
                )
                await connection.execute("SET LOCAL search_path TO public")

                await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_missing_feedback_runtime_index() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute("DROP INDEX feedback_reports_cleanup_v2_idx")
                with pytest.raises(
                    asyncpg.PostgresError,
                    match="feedback report runtime index is missing or invalid",
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_weakened_feedback_constraint() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    ALTER TABLE feedback_idempotency_tombstones
                    DROP CONSTRAINT feedback_tombstone_time_order,
                    ADD CONSTRAINT feedback_tombstone_time_order CHECK (TRUE)
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match=(
                        "feedback tombstone check constraint is missing, "
                        "unvalidated, or invalid"
                    ),
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_restore_smoke_rejects_non_btree_feedback_expiry_index() -> None:
    primary = _primary()
    await primary.startup()
    try:
        async with primary._require_pool().acquire() as connection:
            transaction = connection.transaction()
            await transaction.start()
            try:
                await connection.execute(
                    """
                    DROP INDEX feedback_idempotency_tombstones_expiry_idx;
                    CREATE INDEX feedback_idempotency_tombstones_expiry_idx
                    ON feedback_idempotency_tombstones USING brin (
                        expires_at,
                        client_app_id,
                        principal_hash,
                        idempotency_hash
                    )
                    """
                )
                with pytest.raises(
                    asyncpg.PostgresError,
                    match="feedback tombstone expiry index is missing or invalid",
                ):
                    await connection.execute(_restore_smoke_contract_block())
            finally:
                await transaction.rollback()
    finally:
        await primary.shutdown()


async def _delete_principals(
    primary: PostgresRepository,
    *principal_hashes: str,
) -> None:
    if primary._pool is not None:
        pool = primary._require_pool()
        await pool.execute(
            "DELETE FROM feedback_reports WHERE principal_hash = ANY($1::char(64)[])",
            list(principal_hashes),
        )
        await pool.execute(
            """
            DELETE FROM feedback_idempotency_tombstones
            WHERE principal_hash = ANY($1::char(64)[])
            """,
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
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


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_expiry_atomically_creates_bounded_tombstone() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="retired-key",
            request_seed="retired-payload",
            status="sent",
            created_at=now - timedelta(days=29),
        )
        await repository.reserve(report=report)
        await primary._require_pool().execute(
            """
            UPDATE feedback_reports
            SET object_absence_confirmed_at = $2
            WHERE report_id = $1
            """,
            report.report_id,
            now - timedelta(minutes=1),
        )
        pre_delete_replay = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="retired-key",
            request_seed="retired-payload",
        )
        with pytest.raises(FeedbackNotFoundError):
            await repository.reserve(report=pre_delete_replay)
        with pytest.raises(FeedbackNotFoundError):
            await repository.get_by_idempotency(
                client_app_id=report.client_app_id,
                principal_hash_version=report.principal_hash_version,
                principal_hash=report.principal_hash,
                idempotency_hash=report.idempotency_hash,
                now=now,
            )
        claim = (await repository.claim_expired(now=now, limit=1))[0]
        assert claim.cleanup_claimed_at is not None
        assert await repository.finish_expired(
            report_id=report.report_id,
            claim_token=claim.cleanup_claimed_at,
            deleted_at=now,
        )

        state = await primary._require_pool().fetchrow(
            """
            SELECT
                EXISTS (
                    SELECT 1 FROM feedback_reports WHERE report_id = $1
                ) AS report_exists,
                reserved_at,
                expires_at
            FROM feedback_idempotency_tombstones
            WHERE client_app_id = $2
              AND principal_hash_version = $3
              AND principal_hash = $4
              AND idempotency_hash = $5
            """,
            report.report_id,
            report.client_app_id,
            report.principal_hash_version,
            report.principal_hash,
            report.idempotency_hash,
        )
        assert state is not None
        assert state["report_exists"] is False
        assert state["reserved_at"] == report.created_at
        assert (
            state["expires_at"]
            == report.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
        )

        replay = _report(
            now=now + timedelta(seconds=1),
            principal_hash=principal_hash,
            idempotency_seed="retired-key",
            request_seed="retired-payload",
        )
        with pytest.raises(FeedbackGoneError):
            await repository.reserve(report=replay)
        with pytest.raises(FeedbackGoneError):
            await repository.get_by_idempotency(
                client_app_id=report.client_app_id,
                principal_hash_version=report.principal_hash_version,
                principal_hash=report.principal_hash,
                idempotency_hash=report.idempotency_hash,
                now=now + timedelta(seconds=1),
            )

        expires_at = report.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
        assert await repository.purge_expired_tombstones(
            now=expires_at - timedelta(microseconds=1),
            limit=10,
        ) == FeedbackTombstoneRetentionResult(
            purged_count=0,
            remaining_expired_count=0,
            oldest_expired_age_seconds=0,
        )
        assert await repository.purge_expired_tombstones(
            now=expires_at,
            limit=10,
        ) == FeedbackTombstoneRetentionResult(
            purged_count=1,
            remaining_expired_count=0,
            oldest_expired_age_seconds=0,
        )
        replacement = replace(
            replay,
            created_at=expires_at,
            upload_expires_at=expires_at + timedelta(minutes=15),
            retained_until=expires_at + timedelta(days=28),
            cleanup_after=expires_at + timedelta(minutes=20),
        )
        reserved, created = await repository.reserve(report=replacement)
        assert created is True
        assert reserved.report_id == replacement.report_id
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_legacy_direct_delete_still_retires_idempotency_key() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC).replace(microsecond=0)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="legacy-delete",
            request_seed="legacy-delete",
            status="sent",
            created_at=now - timedelta(days=1),
        )
        await repository.reserve(report=report)

        deleted = await primary._require_pool().fetchval(
            """
            WITH removed AS (
                DELETE FROM feedback_reports
                WHERE report_id = $1
                RETURNING TRUE
            )
            SELECT EXISTS (SELECT 1 FROM removed)
            """,
            report.report_id,
        )
        assert deleted is True
        tombstone = await primary._require_pool().fetchrow(
            """
            SELECT reserved_at, expires_at
            FROM feedback_idempotency_tombstones
            WHERE client_app_id = $1
              AND principal_hash_version = $2
              AND principal_hash = $3
              AND idempotency_hash = $4
            """,
            report.client_app_id,
            report.principal_hash_version,
            report.principal_hash,
            report.idempotency_hash,
        )
        assert tombstone is not None
        assert tombstone["reserved_at"] == report.created_at
        assert (
            tombstone["expires_at"]
            == report.created_at + FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
        )

        replay = _report(
            now=now + timedelta(seconds=1),
            principal_hash=principal_hash,
            idempotency_seed="legacy-delete",
            request_seed="legacy-delete",
        )
        with pytest.raises(FeedbackGoneError):
            await repository.reserve(report=replay)
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_reservation_races_finish_expired_without_duplicate() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC).replace(microsecond=0)
        expired = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="finish-race",
            request_seed="finish-race",
            status="sent",
            created_at=now - timedelta(days=29),
        )
        await repository.reserve(report=expired)
        pool = primary._require_pool()
        await pool.execute(
            """
            UPDATE feedback_reports
            SET object_absence_confirmed_at = $2
            WHERE report_id = $1
            """,
            expired.report_id,
            now - timedelta(minutes=1),
        )
        claim = (await repository.claim_expired(now=now, limit=1))[0]
        assert claim.cleanup_claimed_at is not None
        replay = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="finish-race",
            request_seed="finish-race",
        )

        async with pool.acquire() as lock_connection:
            await _hold_app_lock(lock_connection, expired)
            finish_task = asyncio.create_task(
                repository.finish_expired(
                    report_id=expired.report_id,
                    claim_token=claim.cleanup_claimed_at,
                    deleted_at=now,
                )
            )
            await _wait_for_advisory_waiters(pool, minimum=1)
            reserve_task = asyncio.create_task(repository.reserve(report=replay))
            await _wait_for_advisory_waiters(pool, minimum=2)
            await _release_app_lock(lock_connection, expired)

        assert await finish_task is True
        with pytest.raises(FeedbackGoneError):
            await reserve_task
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM feedback_reports
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                expired.client_app_id,
                expired.principal_hash_version,
                expired.principal_hash,
                expired.idempotency_hash,
            )
            == 0
        )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                expired.client_app_id,
                expired.principal_hash_version,
                expired.principal_hash,
                expired.idempotency_hash,
            )
            == 1
        )
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_tombstone_purge_boundary_is_race_safe() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        boundary = datetime.now(UTC).replace(microsecond=0) + timedelta(seconds=1)
        expired = _report(
            now=boundary,
            principal_hash=principal_hash,
            idempotency_seed="purge-boundary",
            request_seed="old-payload",
            status="sent",
            created_at=(boundary - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME),
        )
        await repository.reserve(report=expired)
        pool = primary._require_pool()
        await pool.execute(
            """
            UPDATE feedback_reports
            SET object_absence_confirmed_at = $2
            WHERE report_id = $1
            """,
            expired.report_id,
            boundary - timedelta(minutes=1),
        )
        claim = (
            await repository.claim_expired(
                now=boundary - timedelta(microseconds=1),
                limit=1,
            )
        )[0]
        assert claim.cleanup_claimed_at is not None
        assert await repository.finish_expired(
            report_id=expired.report_id,
            claim_token=claim.cleanup_claimed_at,
            deleted_at=boundary - timedelta(microseconds=1),
        )
        replacement = _report(
            now=boundary,
            principal_hash=principal_hash,
            idempotency_seed="purge-boundary",
            request_seed="new-payload",
            created_at=boundary,
        )
        start = asyncio.Event()

        async def reserve_at_boundary() -> tuple[FeedbackReport, bool]:
            await start.wait()
            return await repository.reserve(report=replacement)

        async def recover_at_boundary() -> FeedbackReport | None:
            await start.wait()
            try:
                return await repository.get_by_idempotency(
                    client_app_id=expired.client_app_id,
                    principal_hash_version=expired.principal_hash_version,
                    principal_hash=expired.principal_hash,
                    idempotency_hash=expired.idempotency_hash,
                    now=boundary,
                )
            except FeedbackNotFoundError:
                return None

        async def purge_at_boundary() -> FeedbackTombstoneRetentionResult:
            await start.wait()
            return await repository.purge_expired_tombstones(
                now=boundary,
                limit=1,
            )

        reserve_task = asyncio.create_task(reserve_at_boundary())
        recover_task = asyncio.create_task(recover_at_boundary())
        purge_task = asyncio.create_task(purge_at_boundary())
        start.set()
        (reserved, created), recovered, purge = await asyncio.gather(
            reserve_task,
            recover_task,
            purge_task,
        )

        assert created is True
        assert reserved.report_id == replacement.report_id
        assert recovered is None or recovered.report_id == replacement.report_id
        assert purge.purged_count in (0, 1)
        assert purge.remaining_expired_count in (0, 1)
        current = await repository.get_by_idempotency(
            client_app_id=replacement.client_app_id,
            principal_hash_version=replacement.principal_hash_version,
            principal_hash=replacement.principal_hash,
            idempotency_hash=replacement.idempotency_hash,
            now=boundary,
        )
        assert current.report_id == replacement.report_id
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                replacement.client_app_id,
                replacement.principal_hash_version,
                replacement.principal_hash,
                replacement.idempotency_hash,
            )
            == 0
        )
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_tombstone_purge_reports_post_purge_backlog() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    now = datetime.now(UTC).replace(microsecond=0)
    await primary.startup()
    try:
        pool = primary._require_pool()
        for offset, age_seconds in enumerate((180, 120, 60), start=1):
            expires_at = now - timedelta(seconds=age_seconds)
            await pool.execute(
                """
                INSERT INTO feedback_idempotency_tombstones (
                    client_app_id,
                    principal_hash_version,
                    principal_hash,
                    idempotency_hash,
                    reserved_at,
                    expires_at
                )
                VALUES ($1, 1, $2, $3, $4, $5)
                """,
                "1:123456789012:ios:0123456789abcdef",
                principal_hash,
                hashlib.sha256(f"backlog-{offset}".encode()).hexdigest(),
                expires_at - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME,
                expires_at,
            )

        result = await PostgresFeedbackRepository(primary).purge_expired_tombstones(
            now=now, limit=1
        )

        assert result == FeedbackTombstoneRetentionResult(
            purged_count=1,
            remaining_expired_count=2,
            oldest_expired_age_seconds=120,
        )
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_expiry_skips_elapsed_key_lifetime() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        report = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="elapsed-key",
            request_seed="elapsed-payload",
            status="sent",
            created_at=(
                now - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME - timedelta(seconds=1)
            ),
        )
        await repository.reserve(report=report)
        await primary._require_pool().execute(
            """
            UPDATE feedback_reports
            SET object_absence_confirmed_at = $2
            WHERE report_id = $1
            """,
            report.report_id,
            now - timedelta(minutes=1),
        )
        claim = (await repository.claim_expired(now=now, limit=1))[0]
        assert claim.cleanup_claimed_at is not None
        assert await repository.finish_expired(
            report_id=report.report_id,
            claim_token=claim.cleanup_claimed_at,
            deleted_at=now,
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                report.client_app_id,
                report.principal_hash_version,
                report.principal_hash,
                report.idempotency_hash,
            )
            == 0
        )

        replacement = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="elapsed-key",
            request_seed="elapsed-payload",
        )
        reserved, created = await repository.reserve(report=replacement)
        assert created is True
        assert reserved.report_id == replacement.report_id
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "feedback tests"
    ),
)
async def test_postgres_lingering_report_releases_key_at_total_lifetime() -> None:
    primary = _primary()
    principal_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    await primary.startup()
    try:
        repository = PostgresFeedbackRepository(primary)
        now = datetime.now(UTC)
        created_at = now - FEEDBACK_IDEMPOTENCY_KEY_MAXIMUM_LIFETIME
        lingering = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="lingering-key",
            request_seed="old-payload",
            status="sent",
            created_at=created_at,
        )
        await repository.reserve(report=lingering)

        replacement = _report(
            now=now,
            principal_hash=principal_hash,
            idempotency_seed="lingering-key",
            request_seed="new-payload",
        )
        reserved, created = await repository.reserve(report=replacement)

        assert created is True
        assert reserved.report_id == replacement.report_id
        retired_hash = await primary._require_pool().fetchval(
            """
            SELECT idempotency_hash
            FROM feedback_reports
            WHERE report_id = $1
            """,
            lingering.report_id,
        )
        assert str(retired_hash).strip() != lingering.idempotency_hash

        await primary._require_pool().execute(
            """
            UPDATE feedback_reports
            SET object_absence_confirmed_at = $2
            WHERE report_id = $1
            """,
            lingering.report_id,
            now - timedelta(minutes=1),
        )
        claim = next(
            report
            for report in await repository.claim_expired(now=now, limit=10)
            if report.report_id == lingering.report_id
        )
        assert claim.cleanup_claimed_at is not None
        assert await repository.finish_expired(
            report_id=lingering.report_id,
            claim_token=claim.cleanup_claimed_at,
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
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM feedback_idempotency_tombstones
                WHERE client_app_id = $1
                  AND principal_hash_version = $2
                  AND principal_hash = $3
                  AND idempotency_hash = $4
                """,
                replacement.client_app_id,
                replacement.principal_hash_version,
                replacement.principal_hash,
                replacement.idempotency_hash,
            )
            == 0
        )
    finally:
        await _delete_principals(primary, principal_hash)
        await primary.shutdown()
