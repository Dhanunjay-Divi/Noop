from __future__ import annotations

import hashlib
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest

from app.feedback_principal import feedback_principal_matches
from app.managed_identity import ManagedIdentityClaims

try:
    import asyncpg
except ModuleNotFoundError:
    asyncpg = None


SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = SERVER_ROOT / "migrations"
MANIFEST = SERVER_ROOT / "backup" / "migration-manifest.sha256"
DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
EXPECTED_039_SHA256 = "a0f190dd4efe5f6b3eabbff658bf9ee6c5240c268d7bac0f5e228b7767273cf6"


def _identity(
    *,
    tenant: str,
    issuer: str = "https://securetoken.google.com/noop-test-project",
) -> ManagedIdentityClaims:
    now = datetime.now(UTC)
    return ManagedIdentityClaims(
        issuer=issuer,
        subject="legacy-user",
        provider_tenant=tenant,
        issued_at=now,
        auth_time=now,
        expires_at=now + timedelta(hours=1),
        sign_in_provider="anonymous",
    )


def test_feedback_migration_039_contract_is_immutable() -> None:
    migration = MIGRATIONS / "039_feedback_reports.sql"
    payload = migration.read_bytes()
    sql = payload.decode("utf-8")

    assert hashlib.sha256(payload).hexdigest() == EXPECTED_039_SHA256
    assert "subject_hash char(64) NOT NULL" in sql
    assert "principal_hash_version" not in sql
    assert "cleanup_phase" not in sql


def test_feedback_migration_040_is_manifested_schema_evolution() -> None:
    migration = MIGRATIONS / "040_feedback_principal_cleanup.sql"
    checksum = hashlib.sha256(migration.read_bytes()).hexdigest()
    manifest = {
        version: digest
        for digest, version in (
            line.split()
            for line in MANIFEST.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    }
    sql = migration.read_text(encoding="utf-8")

    assert manifest["039_feedback_reports.sql"] == EXPECTED_039_SHA256
    assert manifest["040_feedback_principal_cleanup.sql"] == checksum
    assert "RENAME COLUMN subject_hash" not in sql
    assert "DROP COLUMN subject_hash" not in sql
    assert "ADD COLUMN principal_hash_version smallint" in sql
    assert "ADD COLUMN principal_hash char(64)" in sql
    assert "ADD COLUMN cleanup_phase text" in sql
    assert "ADD COLUMN object_absence_confirmed_at timestamptz" in sql
    assert "noop_feedback_report_compatibility" in sql
    assert "principal_hash = subject_hash" in sql
    assert "DROP INDEX IF EXISTS feedback_reports_subject_quota_idx" not in sql


def test_feedback_migration_v0_identity_is_ambiguous_and_fails_closed() -> None:
    legacy_hash = _identity(tenant="tenant-a").subject_hash

    assert not feedback_principal_matches(
        stored_version=0,
        stored_hash=legacy_hash,
        claims=_identity(tenant="tenant-a"),
    )
    assert not feedback_principal_matches(
        stored_version=0,
        stored_hash=legacy_hash,
        claims=_identity(tenant="tenant-b"),
    )
    assert not feedback_principal_matches(
        stored_version=0,
        stored_hash=legacy_hash,
        claims=_identity(
            tenant="tenant-a",
            issuer="https://securetoken.google.com/other-project",
        ),
    )


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason="PostgreSQL upgrade tests require asyncpg and NOOP_TEST_DATABASE_URL",
)
async def test_feedback_migration_039_to_040_preserves_legacy_row() -> None:
    assert asyncpg is not None
    connection = await asyncpg.connect(DATABASE_URL)
    schema = f"feedback_upgrade_{uuid4().hex}"
    try:
        async with connection.transaction():
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET LOCAL search_path TO "{schema}"')
            await connection.execute(
                (MIGRATIONS / "039_feedback_reports.sql").read_text(encoding="utf-8")
            )
            report_id = uuid4()
            legacy_hash = "a" * 64
            await connection.execute(
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
                    $1, '1:123456:ios:abcdef12', $2, $3, $4, 'ios', '9.2.0',
                    100, $5, false, false, 'NF-ABCDEFGHIJKLMNOP',
                    $6, 'reserved', NULL, now() - INTERVAL '1 day',
                    now() + INTERVAL '1 hour', NULL, now() + INTERVAL '28 days',
                    NULL, NULL, NULL
                )
                """,
                report_id,
                legacy_hash,
                "b" * 64,
                "c" * 64,
                "d" * 64,
                f"v1/feedback/2026/09/12/{report_id}.zip",
            )
            await connection.execute(
                (MIGRATIONS / "040_feedback_principal_cleanup.sql").read_text(
                    encoding="utf-8"
                )
            )
            row = await connection.fetchrow(
                "SELECT * FROM feedback_reports WHERE report_id = $1",
                report_id,
            )

            assert row is not None
            assert str(row["subject_hash"]).strip() == legacy_hash
            assert row["principal_hash_version"] == 0
            assert str(row["principal_hash"]).strip() == legacy_hash
            assert row["cleanup_phase"] == "delete_pending"
            assert row["cleanup_after"] <= row["retained_until"]
            assert row["upload_expires_at"] <= row["retained_until"]
            assert row["object_absence_confirmed_at"] is None
            assert not feedback_principal_matches(
                stored_version=row["principal_hash_version"],
                stored_hash=str(row["principal_hash"]).strip(),
                claims=_identity(tenant="tenant-a"),
            )
            assert not feedback_principal_matches(
                stored_version=row["principal_hash_version"],
                stored_hash=str(row["principal_hash"]).strip(),
                claims=_identity(tenant="tenant-b"),
            )

            old_writer_report_id = uuid4()
            old_writer_hash = "e" * 64
            await connection.execute(
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
                    $1, '1:123456:ios:abcdef12', $2, $3, $4, 'ios', '9.2.0',
                    101, $5, false, false, 'NF-BCDEFGHIJKLMNOPQ',
                    $6, 'reserved', NULL, now(),
                    now() + INTERVAL '15 minutes', NULL,
                    now() + INTERVAL '28 days', NULL, NULL, NULL
                )
                """,
                old_writer_report_id,
                old_writer_hash,
                "f" * 64,
                "1" * 64,
                "2" * 64,
                f"v1/feedback/2026/09/12/{old_writer_report_id}.zip",
            )
            old_writer_row = await connection.fetchrow(
                "SELECT * FROM feedback_reports WHERE report_id = $1",
                old_writer_report_id,
            )
            assert old_writer_row is not None
            assert old_writer_row["principal_hash_version"] == 0
            assert str(old_writer_row["principal_hash"]).strip() == old_writer_hash
            assert old_writer_row["cleanup_phase"] == "delete_pending"
            assert (
                old_writer_row["cleanup_after"] >= old_writer_row["upload_expires_at"]
            )

            await connection.execute(
                """
                UPDATE feedback_reports
                SET upload_expires_at = now() + INTERVAL '30 minutes'
                WHERE report_id = $1
                """,
                old_writer_report_id,
            )
            activated = await connection.fetchrow(
                "SELECT * FROM feedback_reports WHERE report_id = $1",
                old_writer_report_id,
            )
            assert activated is not None
            assert activated["cleanup_after"] >= activated["upload_expires_at"]

            new_writer_report_id = uuid4()
            new_subject_hash = "3" * 64
            new_principal_hash = "4" * 64
            await connection.execute(
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
                    $1, '1:123456:ios:abcdef12', $2, 1, $3, $4, $5, 'ios',
                    '9.2.0', 102, $6, false, false,
                    'NF-CDEFGHIJKLMNOPQR', $7, 'reserved', NULL, now(),
                    now() + INTERVAL '15 minutes', NULL,
                    now() + INTERVAL '28 days', NULL,
                    now() + INTERVAL '20 minutes', 'delete_pending', NULL
                )
                """,
                new_writer_report_id,
                new_subject_hash,
                new_principal_hash,
                "5" * 64,
                "6" * 64,
                "7" * 64,
                f"v1/feedback/2026/09/12/{new_writer_report_id}.zip",
            )
            rollback_read = await connection.fetchrow(
                """
                SELECT subject_hash, status
                FROM feedback_reports
                WHERE report_id = $1
                """,
                new_writer_report_id,
            )
            assert rollback_read is not None
            assert str(rollback_read["subject_hash"]).strip() == new_subject_hash
            assert rollback_read["status"] == "reserved"

            await connection.execute(
                """
                UPDATE feedback_reports
                SET status = 'sent',
                    object_generation = 42,
                    completed_at = now()
                WHERE report_id = $1
                """,
                new_writer_report_id,
            )
            rollback_updated = await connection.fetchrow(
                "SELECT * FROM feedback_reports WHERE report_id = $1",
                new_writer_report_id,
            )
            assert rollback_updated is not None
            assert rollback_updated["status"] == "sent"
            assert rollback_updated["cleanup_after"] is None
            assert rollback_updated["cleanup_phase"] is None
    finally:
        await connection.close()
