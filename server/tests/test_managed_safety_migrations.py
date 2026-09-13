from __future__ import annotations

import hashlib
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app.repository import PostgresRepository


SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = SERVER_ROOT / "migrations"
MANIFEST = SERVER_ROOT / "backup" / "migration-manifest.sha256"
DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL") or os.getenv(
    "NOOP_TEST_DATABASE_URL"
)
EXPECTED_038_SHA256 = "da26324bf1c99c3f384af4fc24c8ef7ad728afcd5e5fd84b1e9a81fe4c61a943"


def _repository() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=False,
        database_engine="postgresql",
    )


def _manifest_entries() -> dict[str, str]:
    return {
        version: digest
        for digest, version in (
            line.split()
            for line in MANIFEST.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    }


async def _seed_band_sos_incident(
    connection,
) -> tuple[UUID, UUID, UUID, datetime]:
    account_id = uuid4()
    profile_id = uuid4()
    incident_id = uuid4()
    now = datetime.now(UTC).replace(microsecond=0)
    await connection.execute(
        """
        INSERT INTO managed_accounts (
            account_id, storage_namespace, status, home_region,
            residency_policy_version, auth_valid_after, created_at, updated_at
        ) VALUES (
            $1, $2, 'active', 'asia-south1', 'synthetic-v1',
            $3, $3, $3
        )
        """,
        account_id,
        uuid4(),
        now - timedelta(minutes=5),
    )
    await connection.execute(
        """
        INSERT INTO managed_social_profiles (
            profile_id, account_id, creation_request_id, display_name
        ) VALUES ($1, $2, $3, 'Migration test')
        """,
        profile_id,
        account_id,
        uuid4(),
    )
    await connection.execute(
        """
        INSERT INTO managed_safety_incidents (
            incident_id, owner_profile_id, client_request_id, trigger, status,
            duration_hours, share_location, created_at, expires_at, ended_at,
            purge_after
        ) VALUES (
            $1, $2, $3, 'band_sos', 'canceled',
            8, false, $4::timestamptz,
            $4::timestamptz + interval '8 hours', $4::timestamptz,
            $4::timestamptz + interval '38 days'
        )
        """,
        incident_id,
        profile_id,
        uuid4(),
        now,
    )
    return account_id, profile_id, incident_id, now


async def _insert_with_legacy_writer(
    connection,
    *,
    account_id: UUID,
    incident_id: UUID,
    now: datetime,
) -> str:
    await connection.execute(
        """
        INSERT INTO managed_safety_page_quota_events (
            owner_account_id, client_request_id, incident_id,
            duration_hours, share_location, created_at, purge_after
        ) VALUES (
            $1, $2, $3, 8, false, $4::timestamptz,
            $4::timestamptz + interval '38 days'
        )
        """,
        account_id,
        uuid4(),
        incident_id,
        now,
    )
    return await connection.fetchval(
        """
        SELECT trigger
        FROM managed_safety_page_quota_events
        WHERE incident_id = $1
        """,
        incident_id,
    )


def test_managed_safety_migration_038_contract_is_immutable() -> None:
    migration = MIGRATIONS / "038_managed_safety_band_sos.sql"
    payload = migration.read_bytes()
    manifest = _manifest_entries()

    assert hashlib.sha256(payload).hexdigest() == EXPECTED_038_SHA256
    assert manifest[migration.name] == EXPECTED_038_SHA256


def test_managed_safety_migration_041_is_manifested_forward_evolution() -> None:
    migration = MIGRATIONS / "041_managed_safety_writer_compatibility.sql"
    checksum = hashlib.sha256(migration.read_bytes()).hexdigest()
    manifest = _manifest_entries()
    sql = migration.read_text(encoding="utf-8")

    assert manifest[migration.name] == checksum
    assert "ALTER COLUMN trigger DROP NOT NULL" in sql
    assert "NEW.trigger := incident_trigger" in sql
    assert "incident_trigger IS DISTINCT FROM NEW.trigger" in sql


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_fresh_migration_chain_supports_pre_038_safety_writer() -> None:
    repository = _repository()
    schema = f"managed_safety_fresh_{uuid4().hex}"

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with pool.acquire() as connection:
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                await repository._run_migrations(connection)
                account_id, _, incident_id, now = await _seed_band_sos_incident(
                    connection
                )

                assert (
                    await _insert_with_legacy_writer(
                        connection,
                        account_id=account_id,
                        incident_id=incident_id,
                        now=now,
                    )
                    == "band_sos"
                )
                applied = {
                    row["version"]: row["checksum"].strip()
                    for row in await connection.fetch(
                        """
                        SELECT version, checksum
                        FROM noop_schema_migrations
                        WHERE version IN (
                            '038_managed_safety_band_sos.sql',
                            '041_managed_safety_writer_compatibility.sql'
                        )
                        """
                    )
                }
                assert applied["038_managed_safety_band_sos.sql"] == (
                    EXPECTED_038_SHA256
                )
                assert "041_managed_safety_writer_compatibility.sql" in applied
            finally:
                await connection.execute("RESET search_path")
                await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_applied_original_038_upgrades_to_writer_compatibility() -> None:
    repository = _repository()
    schema = f"managed_safety_upgrade_{uuid4().hex}"

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with pool.acquire() as connection:
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                await connection.execute(
                    """
                    CREATE TABLE noop_schema_migrations (
                        version text PRIMARY KEY,
                        checksum char(64) NOT NULL,
                        applied_at timestamptz NOT NULL DEFAULT now()
                    )
                    """
                )
                for path in repository._migration_files():
                    if path.name > "038_managed_safety_band_sos.sql":
                        break
                    payload = path.read_bytes()
                    checksum = hashlib.sha256(payload).hexdigest()
                    if path.name == "038_managed_safety_band_sos.sql":
                        checksum = EXPECTED_038_SHA256
                    async with connection.transaction():
                        await connection.execute(payload.decode("utf-8"))
                        await connection.execute(
                            """
                            INSERT INTO noop_schema_migrations (version, checksum)
                            VALUES ($1, $2)
                            """,
                            path.name,
                            checksum,
                        )

                account_id, _, incident_id, now = await _seed_band_sos_incident(
                    connection
                )
                with pytest.raises(Exception) as legacy_failure:
                    await _insert_with_legacy_writer(
                        connection,
                        account_id=account_id,
                        incident_id=incident_id,
                        now=now,
                    )
                assert getattr(legacy_failure.value, "sqlstate", None) == "23502"

                await repository._run_migrations(connection)

                assert (
                    await _insert_with_legacy_writer(
                        connection,
                        account_id=account_id,
                        incident_id=incident_id,
                        now=now,
                    )
                    == "band_sos"
                )
                applied = {
                    row["version"]: row["checksum"].strip()
                    for row in await connection.fetch(
                        """
                        SELECT version, checksum
                        FROM noop_schema_migrations
                        WHERE version IN (
                            '038_managed_safety_band_sos.sql',
                            '041_managed_safety_writer_compatibility.sql'
                        )
                        """
                    )
                }
                assert applied["038_managed_safety_band_sos.sql"] == (
                    EXPECTED_038_SHA256
                )
                assert "041_managed_safety_writer_compatibility.sql" in applied
            finally:
                await connection.execute("RESET search_path")
                await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    finally:
        await repository.shutdown()
