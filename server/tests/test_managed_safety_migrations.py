from __future__ import annotations

import asyncio
import hashlib
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app import migrate
from app.config import Settings
from app.repository import (
    SCHEMA_MIGRATION_LOCK_NAME,
    MigrationManifestMismatchError,
    PostgresRepository,
)


SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = SERVER_ROOT / "migrations"
MANIFEST = SERVER_ROOT / "backup" / "migration-manifest.sha256"
DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL") or os.getenv(
    "NOOP_TEST_DATABASE_URL"
)
EXPECTED_038_SHA256 = "da26324bf1c99c3f384af4fc24c8ef7ad728afcd5e5fd84b1e9a81fe4c61a943"
EXPECTED_041_SHA256 = "227809febdd3369ef530cab71deb08553a45a1d5e62ea070c86547b8d9ae3f9f"


class _ReadyPool:
    def __init__(self, rows: list[dict[str, str]]) -> None:
        self.rows = rows

    async def fetchval(self, _: str) -> int:
        return 1

    async def fetch(self, _: str) -> list[dict[str, str]]:
        return self.rows


class _StaleMigrationJobRepository:
    def __init__(self) -> None:
        self.started = False
        self.shutdown_called = False
        self.manifest_checked = False

    async def startup(self) -> None:
        self.started = True

    async def require_current_migration_manifest(self) -> None:
        self.manifest_checked = True
        raise MigrationManifestMismatchError(
            "database migration manifest does not match this build"
        )

    async def shutdown(self) -> None:
        self.shutdown_called = True


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


async def _create_pre_038_safety_schema(connection) -> None:
    await connection.execute(
        """
        CREATE TABLE managed_accounts (
            account_id uuid PRIMARY KEY
        );
        CREATE TABLE managed_social_profiles (
            profile_id uuid PRIMARY KEY,
            account_id uuid NOT NULL UNIQUE
                REFERENCES managed_accounts(account_id)
        );
        CREATE TABLE managed_safety_incidents (
            incident_id uuid PRIMARY KEY,
            owner_profile_id uuid NOT NULL
                REFERENCES managed_social_profiles(profile_id),
            trigger text NOT NULL,
            CONSTRAINT managed_safety_incident_trigger
                CHECK (trigger = 'manual_sos')
        );
        CREATE TABLE managed_safety_page_quota_events (
            owner_account_id uuid NOT NULL
                REFERENCES managed_accounts(account_id),
            client_request_id uuid NOT NULL,
            incident_id uuid NOT NULL UNIQUE,
            duration_hours integer NOT NULL,
            share_location boolean NOT NULL,
            created_at timestamptz NOT NULL,
            purge_after timestamptz NOT NULL,
            PRIMARY KEY (owner_account_id, client_request_id)
        );
        """
    )


async def _wait_for_backend_lock(connection, backend_pid: int) -> None:
    for _ in range(200):
        waiting = await connection.fetchval(
            """
            SELECT wait_event_type = 'Lock'
            FROM pg_stat_activity
            WHERE pid = $1
            """,
            backend_pid,
        )
        if waiting:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("database writer did not wait on the migration lock")


def test_managed_safety_migration_038_contract_is_immutable() -> None:
    migration = MIGRATIONS / "038_managed_safety_band_sos.sql"
    payload = migration.read_bytes()
    manifest = _manifest_entries()

    assert hashlib.sha256(payload).hexdigest() == EXPECTED_038_SHA256
    assert manifest[migration.name] == EXPECTED_038_SHA256


def test_managed_safety_migration_041_is_manifested_forward_evolution() -> None:
    migration = MIGRATIONS / "041_managed_safety_writer_compatibility.sql"
    manifest = _manifest_entries()
    sql = migration.read_text(encoding="utf-8")

    assert hashlib.sha256(migration.read_bytes()).hexdigest() == EXPECTED_041_SHA256
    assert manifest[migration.name] == EXPECTED_041_SHA256
    assert "ALTER COLUMN trigger DROP NOT NULL" in sql
    assert "NEW.trigger := incident_trigger" in sql
    assert "incident_trigger IS DISTINCT FROM NEW.trigger" in sql
    assert "FOR SHARE OF incident" in sql
    assert "Incident ownership and trigger provenance never have" in sql


def test_safety_writer_compatibility_bundle_precedes_interleaved_migrations() -> None:
    selected = [
        MIGRATIONS / name
        for name in (
            "037_managed_document_contract_v2_activate.sql",
            "038_managed_safety_band_sos.sql",
            "039_feedback_reports.sql",
            "040_feedback_principal_cleanup.sql",
            "041_managed_safety_writer_compatibility.sql",
        )
    ]

    batches = PostgresRepository._migration_batches(selected, set())
    assert [[path.name for path in batch] for batch in batches] == [
        ["037_managed_document_contract_v2_activate.sql"],
        [
            "038_managed_safety_band_sos.sql",
            "041_managed_safety_writer_compatibility.sql",
        ],
        ["039_feedback_reports.sql"],
        ["040_feedback_principal_cleanup.sql"],
    ]

    upgrade_batches = PostgresRepository._migration_batches(
        selected,
        {
            "037_managed_document_contract_v2_activate.sql",
            "038_managed_safety_band_sos.sql",
        },
    )
    assert [[path.name for path in batch] for batch in upgrade_batches] == [
        ["041_managed_safety_writer_compatibility.sql"],
        ["039_feedback_reports.sql"],
        ["040_feedback_principal_cleanup.sql"],
    ]


@pytest.mark.asyncio
async def test_migration_job_requires_exact_manifest_after_application(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(
        api_token=None,
        database_url="postgresql://synthetic.invalid/noop",
    )
    repository = _StaleMigrationJobRepository()
    monkeypatch.setattr(
        migrate.Settings,
        "from_env",
        classmethod(lambda cls: settings),
    )
    monkeypatch.setattr(
        migrate,
        "PostgresRepository",
        lambda *args, **kwargs: repository,
    )

    with pytest.raises(MigrationManifestMismatchError):
        await migrate.run()

    assert repository.started is True
    assert repository.manifest_checked is True
    assert repository.shutdown_called is True


@pytest.mark.asyncio
async def test_readiness_rejects_an_exact_prior_image_after_forward_migration(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    migration = tmp_path / "001_init.sql"
    migration.write_text("SELECT 1;\n", encoding="utf-8")
    checksum = hashlib.sha256(migration.read_bytes()).hexdigest()
    repository = _repository()
    monkeypatch.setattr(repository, "_migration_files", lambda: [migration])

    repository._pool = _ReadyPool(
        [
            {"version": migration.name, "checksum": checksum},
            {
                "version": "002_forward.sql",
                "checksum": hashlib.sha256(b"SELECT 2;\n").hexdigest(),
            },
        ]
    )
    assert await repository.ready() is False
    with pytest.raises(MigrationManifestMismatchError):
        await repository.require_current_migration_manifest()

    repository._pool = _ReadyPool([{"version": migration.name, "checksum": checksum}])
    assert await repository.ready() is True
    await repository.require_current_migration_manifest()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_migration_runner_rejects_unknown_forward_version_before_ddl() -> None:
    repository = _repository()
    schema = f"managed_safety_forward_{uuid4().hex}"

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
                await connection.execute(
                    """
                    INSERT INTO noop_schema_migrations (version, checksum)
                    VALUES ('999_forward.sql', $1)
                    """,
                    hashlib.sha256(b"SELECT 999;\n").hexdigest(),
                )

                with pytest.raises(MigrationManifestMismatchError):
                    await repository._run_migrations(connection)

                assert (
                    await connection.fetchval(
                        "SELECT count(*) FROM noop_schema_migrations"
                    )
                    == 1
                )
                assert await connection.fetchval(
                    "SELECT to_regclass($1) IS NULL",
                    f"{schema}.devices",
                )
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
async def test_concurrent_fresh_bootstrap_serializes_before_ledger_create() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=3,
        run_migrations=True,
        database_engine="postgresql",
    )
    schema = f"managed_safety_bootstrap_{uuid4().hex}"
    first_task = None
    second_task = None
    lock_held = False

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as lock_connection,
            pool.acquire() as first_connection,
            pool.acquire() as second_connection,
        ):
            for connection in (
                lock_connection,
                first_connection,
                second_connection,
            ):
                await connection.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
                await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                assert await lock_connection.fetchval(
                    "SELECT to_regclass($1) IS NULL",
                    f"{schema}.noop_schema_migrations",
                )
                await lock_connection.execute(
                    "SELECT pg_advisory_lock(hashtext('noop_schema_migrations'))"
                )
                lock_held = True

                first_task = asyncio.create_task(
                    repository._run_migrations(first_connection)
                )
                second_task = asyncio.create_task(
                    repository._run_migrations(second_connection)
                )
                await _wait_for_backend_lock(
                    lock_connection,
                    first_connection.get_server_pid(),
                )
                await _wait_for_backend_lock(
                    lock_connection,
                    second_connection.get_server_pid(),
                )

                assert await lock_connection.fetchval(
                    "SELECT to_regclass($1) IS NULL",
                    f"{schema}.noop_schema_migrations",
                )

                await lock_connection.execute(
                    "SELECT pg_advisory_unlock(hashtext('noop_schema_migrations'))"
                )
                lock_held = False
                await asyncio.wait_for(
                    asyncio.gather(first_task, second_task),
                    timeout=60,
                )

                assert await lock_connection.fetchval(
                    "SELECT count(*) FROM noop_schema_migrations"
                ) == len(repository._migration_files())
            finally:
                if lock_held:
                    await lock_connection.execute(
                        "SELECT pg_advisory_unlock(hashtext('noop_schema_migrations'))"
                    )
                pending = [
                    task
                    for task in (first_task, second_task)
                    if task is not None and not task.done()
                ]
                for task in pending:
                    task.cancel()
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)
                for connection in (
                    first_connection,
                    second_connection,
                    lock_connection,
                ):
                    await connection.execute("RESET search_path")
                await lock_connection.execute(
                    f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'
                )
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_maintenance_guard_blocks_the_schema_migration_lock() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine="postgresql",
    )
    migration_lock_task = None

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as migration_connection,
            pool.acquire() as observer_connection,
        ):
            try:
                async with repository.maintenance_guard():
                    migration_lock_task = asyncio.create_task(
                        migration_connection.execute(
                            "SELECT pg_advisory_lock(hashtext($1))",
                            SCHEMA_MIGRATION_LOCK_NAME,
                        )
                    )
                    await _wait_for_backend_lock(
                        observer_connection,
                        migration_connection.get_server_pid(),
                    )
                    assert migration_lock_task.done() is False

                await asyncio.wait_for(migration_lock_task, timeout=5)
            finally:
                if migration_lock_task is not None and not migration_lock_task.done():
                    migration_lock_task.cancel()
                    await asyncio.gather(
                        migration_lock_task,
                        return_exceptions=True,
                    )
                await migration_connection.execute(
                    "SELECT pg_advisory_unlock(hashtext($1))",
                    SCHEMA_MIGRATION_LOCK_NAME,
                )
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_maintenance_guard_preserves_a_size_one_operation_pool() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=1,
        run_migrations=True,
        database_engine="postgresql",
    )

    await repository.startup()
    try:
        async with repository.maintenance_guard():
            assert (
                await asyncio.wait_for(
                    repository._require_pool().fetchval("SELECT 1"),
                    timeout=5,
                )
                == 1
            )
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_migration_checksum_uses_exact_crlf_file_bytes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = _repository()
    schema = f"managed_safety_crlf_{uuid4().hex}"
    migration = tmp_path / "001_crlf.sql"
    payload = b"SELECT 1;\r\n"
    migration.write_bytes(payload)
    raw_checksum = hashlib.sha256(payload).hexdigest()
    normalized_checksum = hashlib.sha256(
        migration.read_text(encoding="utf-8").encode("utf-8")
    ).hexdigest()
    assert raw_checksum != normalized_checksum

    monkeypatch.setattr(repository, "_migration_files", lambda: [migration])
    monkeypatch.setattr(
        repository,
        "_migration_batches",
        lambda migrations, applied: (
            [] if migration.name in applied else [(migration,)]
        ),
    )

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with pool.acquire() as connection:
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                await repository._run_migrations(connection)
                row = await connection.fetchrow(
                    """
                    SELECT version, checksum
                    FROM noop_schema_migrations
                    WHERE version = $1
                    """,
                    migration.name,
                )
                assert row["checksum"].strip() == raw_checksum

                await repository._run_migrations(connection)
                assert (
                    await connection.fetchval(
                        "SELECT count(*) FROM noop_schema_migrations"
                    )
                    == 1
                )

                repository._pool = _ReadyPool(
                    [
                        {
                            "version": row["version"],
                            "checksum": row["checksum"],
                        }
                    ]
                )
                assert await repository.ready() is True
                await repository.require_current_migration_manifest()
            finally:
                repository._pool = pool
                await connection.execute("RESET search_path")
                await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    finally:
        repository._pool = pool
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_038_and_041_commit_atomically_for_legacy_writer() -> None:
    repository = _repository()
    schema = f"managed_safety_atomic_{uuid4().hex}"
    account_id = uuid4()
    profile_id = uuid4()
    incident_id = uuid4()
    now = datetime.now(UTC).replace(microsecond=0)
    migration_transaction = None
    writer_task = None

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as migration_connection,
            pool.acquire() as writer_connection,
        ):
            await migration_connection.execute(f'CREATE SCHEMA "{schema}"')
            await migration_connection.execute(f'SET search_path TO "{schema}", public')
            await writer_connection.execute(f'SET search_path TO "{schema}", public')
            try:
                await _create_pre_038_safety_schema(migration_connection)
                await migration_connection.execute(
                    "INSERT INTO managed_accounts (account_id) VALUES ($1)",
                    account_id,
                )
                await migration_connection.execute(
                    """
                    INSERT INTO managed_social_profiles (profile_id, account_id)
                    VALUES ($1, $2)
                    """,
                    profile_id,
                    account_id,
                )
                await migration_connection.execute(
                    """
                    INSERT INTO managed_safety_incidents (
                        incident_id, owner_profile_id, trigger
                    ) VALUES ($1, $2, 'manual_sos')
                    """,
                    incident_id,
                    profile_id,
                )

                migration_transaction = migration_connection.transaction()
                await migration_transaction.start()
                await migration_connection.execute(
                    (MIGRATIONS / "038_managed_safety_band_sos.sql").read_text(
                        encoding="utf-8"
                    )
                )
                writer_task = asyncio.create_task(
                    _insert_with_legacy_writer(
                        writer_connection,
                        account_id=account_id,
                        incident_id=incident_id,
                        now=now,
                    )
                )
                await _wait_for_backend_lock(
                    migration_connection,
                    writer_connection.get_server_pid(),
                )
                assert writer_task.done() is False

                await migration_connection.execute(
                    (
                        MIGRATIONS / "041_managed_safety_writer_compatibility.sql"
                    ).read_text(encoding="utf-8")
                )
                await migration_transaction.commit()
                migration_transaction = None

                assert await asyncio.wait_for(writer_task, timeout=2) == "manual_sos"
                writer_task = None
            finally:
                if writer_task is not None:
                    writer_task.cancel()
                    await asyncio.gather(writer_task, return_exceptions=True)
                if migration_transaction is not None:
                    await migration_transaction.rollback()
                await writer_connection.execute("RESET search_path")
                await migration_connection.execute("RESET search_path")
                await migration_connection.execute(
                    f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'
                )
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="a PostgreSQL test URL is required for managed Safety migration tests",
)
@pytest.mark.asyncio
async def test_quota_insert_serializes_incident_provenance_mutation() -> None:
    repository = _repository()
    schema = f"managed_safety_provenance_{uuid4().hex}"
    account_a = uuid4()
    account_b = uuid4()
    profile_a = uuid4()
    profile_b = uuid4()
    incident_id = uuid4()
    now = datetime.now(UTC).replace(microsecond=0)
    quota_transaction = None
    update_task = None

    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as quota_connection,
            pool.acquire() as update_connection,
        ):
            await quota_connection.execute(f'CREATE SCHEMA "{schema}"')
            await quota_connection.execute(f'SET search_path TO "{schema}", public')
            await update_connection.execute(f'SET search_path TO "{schema}", public')
            try:
                await _create_pre_038_safety_schema(quota_connection)
                async with quota_connection.transaction():
                    await quota_connection.execute(
                        (MIGRATIONS / "038_managed_safety_band_sos.sql").read_text(
                            encoding="utf-8"
                        )
                    )
                    await quota_connection.execute(
                        (
                            MIGRATIONS / "041_managed_safety_writer_compatibility.sql"
                        ).read_text(encoding="utf-8")
                    )
                await quota_connection.executemany(
                    "INSERT INTO managed_accounts (account_id) VALUES ($1)",
                    [(account_a,), (account_b,)],
                )
                await quota_connection.executemany(
                    """
                    INSERT INTO managed_social_profiles (profile_id, account_id)
                    VALUES ($1, $2)
                    """,
                    [(profile_a, account_a), (profile_b, account_b)],
                )
                await quota_connection.execute(
                    """
                    INSERT INTO managed_safety_incidents (
                        incident_id, owner_profile_id, trigger
                    ) VALUES ($1, $2, 'band_sos')
                    """,
                    incident_id,
                    profile_a,
                )

                quota_transaction = quota_connection.transaction()
                await quota_transaction.start()
                assert (
                    await _insert_with_legacy_writer(
                        quota_connection,
                        account_id=account_a,
                        incident_id=incident_id,
                        now=now,
                    )
                    == "band_sos"
                )
                update_task = asyncio.create_task(
                    update_connection.execute(
                        """
                        UPDATE managed_safety_incidents
                        SET owner_profile_id = $2, trigger = 'manual_sos'
                        WHERE incident_id = $1
                        """,
                        incident_id,
                        profile_b,
                    )
                )
                await _wait_for_backend_lock(
                    quota_connection,
                    update_connection.get_server_pid(),
                )
                assert update_task.done() is False

                await quota_transaction.commit()
                quota_transaction = None
                with pytest.raises(Exception) as immutable:
                    await asyncio.wait_for(update_task, timeout=2)
                update_task = None
                assert getattr(immutable.value, "sqlstate", None) == "23514"
                assert "managed Safety incident quota provenance is immutable" in str(
                    immutable.value
                )
                row = await quota_connection.fetchrow(
                    """
                    SELECT incident.owner_profile_id,
                           incident.trigger AS incident_trigger,
                           quota.owner_account_id,
                           quota.trigger AS quota_trigger
                    FROM managed_safety_incidents incident
                    JOIN managed_safety_page_quota_events quota
                      USING (incident_id)
                    WHERE incident.incident_id = $1
                    """,
                    incident_id,
                )
                assert row["owner_profile_id"] == profile_a
                assert row["incident_trigger"] == "band_sos"
                assert row["owner_account_id"] == account_a
                assert row["quota_trigger"] == "band_sos"
            finally:
                if update_task is not None:
                    update_task.cancel()
                    await asyncio.gather(update_task, return_exceptions=True)
                if quota_transaction is not None:
                    await quota_transaction.rollback()
                await update_connection.execute("RESET search_path")
                await quota_connection.execute("RESET search_path")
                await quota_connection.execute(
                    f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'
                )
    finally:
        await repository.shutdown()


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
                    row["version"]: row
                    for row in await connection.fetch(
                        """
                        SELECT version, checksum, applied_at,
                               xmin::text AS transaction_id
                        FROM noop_schema_migrations
                        WHERE version IN (
                            '038_managed_safety_band_sos.sql',
                            '039_feedback_reports.sql',
                            '040_feedback_principal_cleanup.sql',
                            '041_managed_safety_writer_compatibility.sql'
                        )
                        """
                    )
                }
                assert applied["038_managed_safety_band_sos.sql"][
                    "checksum"
                ].strip() == (EXPECTED_038_SHA256)
                assert "041_managed_safety_writer_compatibility.sql" in applied
                assert (
                    applied["038_managed_safety_band_sos.sql"]["transaction_id"]
                    == applied["041_managed_safety_writer_compatibility.sql"][
                        "transaction_id"
                    ]
                )
                assert (
                    applied["041_managed_safety_writer_compatibility.sql"]["applied_at"]
                    <= applied["039_feedback_reports.sql"]["applied_at"]
                )
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
