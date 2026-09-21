from __future__ import annotations

import asyncio
import hashlib
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

import pytest

try:
    import asyncpg
except ModuleNotFoundError:
    asyncpg = None

from app.managed_identity import ManagedIdentityClaims, unified_identity_lock_key
from app.ownership_models import OwnershipAccountRegistration
from app.ownership_repository import (
    OwnershipForbiddenError,
    PostgresOwnershipRepository,
)
from app.repository import PostgresRepository
from app.unified_identity_authority import (
    PostgresUnifiedIdentityAuthorityRepository,
)

SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = SERVER_ROOT / "migrations"
MIGRATION_047 = MIGRATIONS / "047_unified_account_principals.sql"
REPAIR_MIGRATION = MIGRATIONS / "059_repair_unified_managed_principals.sql"
DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL") or os.getenv(
    "NOOP_TEST_DATABASE_URL"
)
MIGRATION_047_SHA256 = (
    "3159e5f01eff093e7048bae091f19e2128ae6f436e7fa14e33a4e8d56703d324"
)
ISSUER = "https://securetoken.google.com/noop-migration-test"


def test_unified_principal_repair_is_forward_only_and_terminally_scoped() -> None:
    assert hashlib.sha256(MIGRATION_047.read_bytes()).hexdigest() == (
        MIGRATION_047_SHA256
    )
    sql = REPAIR_MIGRATION.read_text(encoding="utf-8")

    assert "DROP TRIGGER" not in sql
    assert "LOCK TABLE unified_account_principals" not in sql
    assert "LOCK TABLE unified_managed_account_links" not in sql
    assert "LOCK TABLE unified_ownership_account_links" not in sql
    assert "LOCK TABLE ownership_accounts" not in sql
    assert "LOCK TABLE ownership_external_identities" not in sql
    assert sql.index("DELETE FROM unified_managed_account_links") < sql.index(
        "FOR UPDATE OF principal"
    )
    assert "managed_link.linked_at = migration_047.applied_at" in sql
    assert MIGRATION_047_SHA256 in sql
    assert "identity.status = 'revoked'" in sql
    assert "identity.revoked_at IS NOT NULL" in sql
    assert "account.status = 'erased'" in sql
    assert "account.erased_at IS NOT NULL" in sql
    assert "account.status = 'suspended'" not in sql
    assert "account.status = 'erasure_pending'" not in sql
    assert "SET status = 'retired'" in sql
    assert "FROM unified_ownership_account_links AS ownership_link" in sql
    assert "INSERT INTO unified_ownership_account_links" in sql
    assert "DELETE FROM managed_authority_transitions" in sql
    assert "DELETE FROM managed_authority_states" in sql
    assert sql.index("DELETE FROM managed_authority_transitions") < sql.index(
        "DELETE FROM managed_authority_states"
    )
    assert sql.index("DELETE FROM managed_authority_states") < sql.index(
        "DELETE FROM unified_managed_account_links"
    )
    assert "active ownership identity was not preserved" in sql
    assert "terminal managed identities remain linked" in sql
    assert "terminal managed authority state remains" in sql
    assert "orphaned unified principals remain active" in sql
    assert "array_agg" not in sql
    assert "noop_ownership_lock_unified_principal" in sql
    assert "SECURITY DEFINER" in sql
    assert "SET search_path FROM CURRENT" not in sql
    assert "SET search_path = pg_catalog, pg_temp" in sql
    assert "WITH locked_principal AS MATERIALIZED" in sql
    assert "FROM %1$I.unified_account_principals AS principal" in sql
    assert "INSERT INTO %1$I.unified_ownership_account_links" in sql
    assert "FUNCTION %1$I.noop_unified_account_link_guard()" in sql
    assert "requested_subject_hash::character(64)" in sql
    assert "principal.subject_hash::text" not in sql
    assert (
        "'noop_ownership_lock_unified_principal(text, text, text) FROM PUBLIC'" in sql
    )
    assert "account.status IN ('active', 'deletion_pending')" in sql
    assert "pending_ownership_repair" in sql
    assert "noop_migration_059_retired_ownership_repairs" in sql
    assert "managed_account_cloud_erasure_tombstones" in sql
    assert "tombstone.managed_identity_link_rows > 0" in sql
    assert "tombstone.erased_at = principal.retired_at" in sql
    assert "ownership_identity.created_at <= principal.retired_at" in sql
    assert "ownership_identity.verified_at <= principal.retired_at" in sql
    assert "ownership_account.created_at <= principal.retired_at" in sql
    assert "job.status = 'completed'" in sql
    assert "managed_account.status = 'erased'" in sql
    assert "erasure-retired ownership principals were not restored" in sql
    assert (
        sql.count("CREATE OR REPLACE FUNCTION %1$I.noop_unified_principal_guard()") == 2
    )


def test_unified_principal_repair_is_pinned_in_both_manifests() -> None:
    digest = hashlib.sha256(REPAIR_MIGRATION.read_bytes()).hexdigest()
    expected = f"{digest}  {REPAIR_MIGRATION.name}"

    for name in (
        "migration-manifest.sha256",
        "migration-manifest-postgresql.sha256",
    ):
        manifest = (SERVER_ROOT / "backup" / name).read_text(encoding="utf-8")
        assert expected in manifest.splitlines()


def _repository() -> PostgresRepository:
    assert DATABASE_URL is not None
    return PostgresRepository(
        DATABASE_URL,
        pool_min_size=1,
        pool_max_size=3,
        run_migrations=False,
        database_engine="postgresql",
    )


class _BorrowedConnectionContext:
    def __init__(self, connection: Any) -> None:
        self.connection = connection

    async def __aenter__(self) -> Any:
        return self.connection

    async def __aexit__(self, *_: object) -> None:
        return None


class _BorrowedPool:
    def __init__(self, connection: Any) -> None:
        self.connection = connection

    def acquire(self) -> _BorrowedConnectionContext:
        return _BorrowedConnectionContext(self.connection)

    async def execute(self, query: str, *args: Any) -> Any:
        return await self.connection.execute(query, *args)

    async def fetch(self, query: str, *args: Any) -> Any:
        return await self.connection.fetch(query, *args)

    async def fetchrow(self, query: str, *args: Any) -> Any:
        return await self.connection.fetchrow(query, *args)

    async def fetchval(self, query: str, *args: Any) -> Any:
        return await self.connection.fetchval(query, *args)


class _BorrowedPrimary:
    def __init__(self, connection: Any) -> None:
        self._pool = _BorrowedPool(connection)


def _migration_files_through(
    migrations: list[Path],
    terminal_name: str,
) -> list[Path]:
    return [path for path in migrations if path.name <= terminal_name]


async def _apply_migrations(
    repository: PostgresRepository,
    connection: Any,
    migrations: list[Path],
) -> None:
    repository._migration_files = lambda: migrations  # type: ignore[method-assign]
    await repository._run_migrations(connection)


async def _assert_pre_059_trigger_contract(connection: Any) -> None:
    rows = await connection.fetch(
        """
        SELECT relation.relname AS relation_name, trigger.tgname AS trigger_name
        FROM pg_catalog.pg_trigger AS trigger
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = trigger.tgrelid
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = current_schema()
          AND relation.relname = ANY($1::text[])
          AND NOT trigger.tgisinternal
        """,
        [
            "unified_account_principals",
            "unified_managed_account_links",
            "unified_ownership_account_links",
        ],
    )
    actual: dict[str, set[str]] = {}
    for row in rows:
        actual.setdefault(row["relation_name"], set()).add(row["trigger_name"])

    assert actual == {
        "unified_account_principals": {
            "unified_account_principal_guard",
        },
        "unified_managed_account_links": {
            "unified_managed_account_link_guard",
            "unified_managed_account_link_delete_guard",
        },
        "unified_ownership_account_links": {
            "unified_ownership_account_link_guard",
        },
    }

    guard_rows = await connection.fetch(
        """
        SELECT routine.proname, pg_get_functiondef(routine.oid) AS definition
        FROM pg_catalog.pg_proc AS routine
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname = current_schema()
          AND routine.proname = ANY($1::text[])
        """,
        [
            "noop_managed_authority_transition_delete_guard",
            "noop_managed_authority_state_delete_guard",
            "noop_unified_account_link_guard",
            "noop_unified_managed_link_delete_guard",
        ],
    )
    assert {row["proname"] for row in guard_rows} == {
        "noop_managed_authority_transition_delete_guard",
        "noop_managed_authority_state_delete_guard",
        "noop_unified_account_link_guard",
        "noop_unified_managed_link_delete_guard",
    }
    for row in guard_rows:
        assert "noop.unified_principal_repair" not in row["definition"]


async def _seed_pre_unification_identities(
    connection: Any,
    *,
    erased_subject_hash: str = "b" * 64,
) -> dict[str, UUID]:
    created_at = datetime.now(UTC) - timedelta(minutes=10)
    terminal_at = created_at + timedelta(minutes=5)
    active_at = created_at + timedelta(minutes=1)
    records = {
        "revoked_account_id": uuid4(),
        "revoked_identity_id": uuid4(),
        "revoked_ownership_account_id": uuid4(),
        "revoked_ownership_identity_id": uuid4(),
        "erased_account_id": uuid4(),
        "erased_identity_id": uuid4(),
        "active_account_id": uuid4(),
        "active_identity_id": uuid4(),
        "pending_account_id": uuid4(),
        "pending_identity_id": uuid4(),
        "late_terminal_account_id": uuid4(),
        "late_terminal_identity_id": uuid4(),
    }
    hashes = {
        "revoked": "a" * 64,
        "erased": erased_subject_hash,
        "active": "c" * 64,
        "pending": "d" * 64,
        "late_terminal": "e" * 64,
    }

    await connection.executemany(
        """
        INSERT INTO managed_accounts (
            account_id,
            storage_namespace,
            status,
            home_region,
            residency_policy_version,
            auth_valid_after,
            created_at,
            updated_at,
            erasure_requested_at,
            erased_at
        ) VALUES ($1, $2, $3, 'us-test1', 'synthetic-v1', $4, $4, $5, $6, $7)
        """,
        [
            (
                records["revoked_account_id"],
                uuid4(),
                "active",
                created_at,
                active_at,
                None,
                None,
            ),
            (
                records["erased_account_id"],
                uuid4(),
                "erased",
                created_at,
                terminal_at,
                active_at,
                terminal_at,
            ),
            (
                records["active_account_id"],
                uuid4(),
                "active",
                created_at,
                active_at,
                None,
                None,
            ),
            (
                records["pending_account_id"],
                uuid4(),
                "erasure_pending",
                created_at,
                terminal_at,
                terminal_at,
                None,
            ),
            (
                records["late_terminal_account_id"],
                uuid4(),
                "active",
                created_at,
                active_at,
                None,
                None,
            ),
        ],
    )
    await connection.executemany(
        """
        INSERT INTO managed_external_identities (
            identity_id,
            account_id,
            issuer,
            provider_tenant,
            subject_hash,
            status,
            verified_at,
            last_seen_at,
            revoked_at,
            created_at
        ) VALUES ($1, $2, $3, '', $4, $5, $6, $7, $8, $6)
        """,
        [
            (
                records["revoked_identity_id"],
                records["revoked_account_id"],
                ISSUER,
                hashes["revoked"],
                "revoked",
                created_at,
                terminal_at,
                terminal_at,
            ),
            (
                records["erased_identity_id"],
                records["erased_account_id"],
                ISSUER,
                hashes["erased"],
                "active",
                created_at,
                terminal_at,
                None,
            ),
            (
                records["active_identity_id"],
                records["active_account_id"],
                ISSUER,
                hashes["active"],
                "active",
                created_at,
                terminal_at,
                None,
            ),
            (
                records["pending_identity_id"],
                records["pending_account_id"],
                ISSUER,
                hashes["pending"],
                "active",
                created_at,
                terminal_at,
                None,
            ),
            (
                records["late_terminal_identity_id"],
                records["late_terminal_account_id"],
                ISSUER,
                hashes["late_terminal"],
                "active",
                created_at,
                terminal_at,
                None,
            ),
        ],
    )
    await connection.execute(
        """
        INSERT INTO ownership_accounts (
            account_id,
            status,
            auth_valid_after,
            created_at,
            updated_at
        ) VALUES ($1, 'active', $2, $2, $3)
        """,
        records["revoked_ownership_account_id"],
        created_at,
        active_at,
    )
    await connection.execute(
        """
        INSERT INTO ownership_external_identities (
            identity_id,
            account_id,
            issuer,
            provider_tenant,
            subject_hash,
            email_verified,
            phone_verified,
            status,
            verified_at,
            last_seen_at,
            created_at
        ) VALUES ($1, $2, $3, '', $4, true, false, 'active', $5, $6, $5)
        """,
        records["revoked_ownership_identity_id"],
        records["revoked_ownership_account_id"],
        ISSUER,
        hashes["revoked"],
        created_at,
        terminal_at,
    )
    return records


async def _seed_post_unification_ownership_identity(
    connection: Any,
    *,
    subject_hash: str,
    account_status: str = "active",
) -> tuple[UUID, UUID]:
    account_id = uuid4()
    identity_id = uuid4()
    now = datetime.now(UTC)
    await connection.execute(
        """
        INSERT INTO ownership_accounts (
            account_id,
            status,
            auth_valid_after,
            created_at,
            updated_at,
            deletion_requested_at
        ) VALUES (
            $1,
            $2::text,
            $3::timestamptz,
            $3::timestamptz,
            $3::timestamptz,
            CASE
                WHEN $2::text = 'deletion_pending'
                THEN $3::timestamptz
                ELSE NULL
            END
        )
        """,
        account_id,
        account_status,
        now,
    )
    await connection.execute(
        """
        INSERT INTO ownership_external_identities (
            identity_id,
            account_id,
            issuer,
            provider_tenant,
            subject_hash,
            email_verified,
            phone_verified,
            status,
            verified_at,
            last_seen_at,
            created_at
        ) VALUES ($1, $2, $3, '', $4, true, false, 'active', $5, $5, $5)
        """,
        identity_id,
        account_id,
        ISSUER,
        subject_hash,
        now,
    )
    return account_id, identity_id


async def _seed_authority_state(
    connection: Any,
    *,
    managed_account_id: UUID,
) -> None:
    principal_id = await connection.fetchval(
        """
        SELECT principal_id
        FROM unified_managed_account_links
        WHERE managed_account_id = $1
        """,
        managed_account_id,
    )
    assert principal_id is not None
    transition_id = uuid4()
    now = datetime.now(UTC)
    await connection.execute(
        """
        INSERT INTO managed_authority_states (
            principal_id,
            managed_account_id,
            data_class,
            state,
            transition_version,
            last_transition_id,
            created_at,
            updated_at
        ) VALUES (
            $1,
            $2,
            'essential_timeseries',
            'uploading',
            1,
            $3,
            $4,
            $4
        )
        """,
        principal_id,
        managed_account_id,
        transition_id,
        now,
    )
    await connection.execute(
        """
        INSERT INTO managed_authority_transitions (
            transition_id,
            principal_id,
            managed_account_id,
            data_class,
            request_id,
            request_sha256,
            transition_version,
            from_state,
            to_state,
            reason,
            occurred_at
        ) VALUES (
            $1,
            $2,
            $3,
            'essential_timeseries',
            $4,
            $5,
            1,
            'local_only',
            'uploading',
            'migration_started',
            $6
        )
        """,
        transition_id,
        principal_id,
        managed_account_id,
        uuid4(),
        "f" * 64,
        now,
    )


async def _revoke_late_terminal_identity(
    connection: Any,
    records: dict[str, UUID],
) -> None:
    migration_applied_at = await connection.fetchval(
        """
        SELECT applied_at
        FROM noop_schema_migrations
        WHERE version = '047_unified_account_principals.sql'
        """
    )
    assert migration_applied_at is not None
    revoked_at = await connection.fetchval(
        """
        SELECT GREATEST(clock_timestamp(), $1::timestamptz + interval '1 second')
        """,
        migration_applied_at,
    )
    await connection.execute(
        """
        UPDATE managed_external_identities
        SET status = 'revoked',
            revoked_at = $3,
            last_seen_at = GREATEST(last_seen_at, $3)
        WHERE account_id = $1
          AND identity_id = $2
        """,
        records["late_terminal_account_id"],
        records["late_terminal_identity_id"],
        revoked_at,
    )


async def _wait_for_lock_waiter(
    observer: Any,
    *,
    backend_pid: int,
    task: asyncio.Task[Any],
) -> None:
    for _ in range(500):
        if task.done():
            await task
            raise AssertionError("concurrent task did not wait for migration")
        waiting = await observer.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_locks
                WHERE pid = $1
                  AND NOT granted
            )
            """,
            backend_pid,
        )
        if waiting is True:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("concurrent task never reached a lock wait")


async def _registration_terms(connection: Any) -> tuple[str, str]:
    current = await connection.fetchrow(
        """
        SELECT policy_version, document_sha256
        FROM ownership_terms_documents
        WHERE locale = 'en'
          AND effective_at <= clock_timestamp()
          AND (
              retired_at IS NULL
              OR retired_at > clock_timestamp()
          )
        ORDER BY effective_at DESC, policy_version DESC
        LIMIT 1
        """
    )
    if current is not None:
        return str(current["policy_version"]), str(current["document_sha256"])

    policy_version = f"ownership-race-{uuid4().hex[:12]}"
    document_sha256 = "f" * 64
    await connection.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            $1,
            'en',
            $2,
            'https://terms.noop.example/ownership-race/en',
            clock_timestamp() - interval '1 minute'
        )
        """,
        policy_version,
        document_sha256,
    )
    return policy_version, document_sha256


def _registration_claims(label: str) -> ManagedIdentityClaims:
    now = datetime.now(UTC)
    return ManagedIdentityClaims(
        issuer=ISSUER,
        subject=f"{label}-{uuid4()}",
        provider_tenant="",
        issued_at=now,
        auth_time=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
        email_verified=True,
        sign_in_provider="password",
    )


def _registration_request(
    *,
    label: str,
    policy_version: str,
    policy_sha256: str,
) -> OwnershipAccountRegistration:
    return OwnershipAccountRegistration(
        request_id=uuid4(),
        installation_id=f"ios-{label}-{uuid4().hex[:12]}",
        installation_token="noopo_" + "R" * 43,
        platform="ios",
        policy_version=policy_version,
        policy_sha256=policy_sha256,
        locale="en",
    )


async def _seed_unified_principal(
    connection: Any,
    claims: ManagedIdentityClaims,
) -> UUID:
    principal_id = uuid4()
    await connection.execute(
        """
        INSERT INTO unified_account_principals (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash
        ) VALUES ($1, $2, $3, $4)
        """,
        principal_id,
        claims.issuer,
        claims.provider_tenant,
        claims.subject_hash,
    )
    return principal_id


async def _retire_principal_if_orphaned(
    connection: Any,
    *,
    principal_id: UUID,
) -> str:
    async with connection.transaction():
        await connection.fetchval(
            """
            SELECT principal_id
            FROM unified_account_principals
            WHERE principal_id = $1
            FOR UPDATE
            """,
            principal_id,
        )
        return await connection.execute(
            """
            UPDATE unified_account_principals AS principal
            SET status = 'retired',
                version = principal.version + 1,
                updated_at = clock_timestamp(),
                retired_at = clock_timestamp()
            WHERE principal.principal_id = $1
              AND principal.status = 'active'
              AND NOT EXISTS (
                  SELECT 1
                  FROM unified_managed_account_links AS managed_link
                  WHERE managed_link.principal_id = principal.principal_id
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM unified_ownership_account_links AS ownership_link
                  WHERE ownership_link.principal_id = principal.principal_id
              )
            """,
            principal_id,
        )


async def _assert_repaired(
    connection: Any,
    records: dict[str, UUID],
    *,
    erased_ownership_account_id: UUID | None = None,
    erased_subject_hash: str = "b" * 64,
) -> None:
    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM unified_managed_account_links AS managed_link
            JOIN managed_external_identities AS identity
              ON identity.account_id = managed_link.managed_account_id
             AND identity.identity_id = managed_link.managed_identity_id
            JOIN managed_accounts AS account
              ON account.account_id = identity.account_id
            JOIN noop_schema_migrations AS migration_047
              ON migration_047.version =
                 '047_unified_account_principals.sql'
            WHERE managed_link.linked_at = migration_047.applied_at
              AND (
                  (
                      identity.status = 'revoked'
                      AND identity.revoked_at <= migration_047.applied_at
                  )
                  OR (
                      account.status = 'erased'
                      AND account.erased_at <= migration_047.applied_at
                  )
              )
            """
        )
        == 0
    )

    revoked = await connection.fetchrow(
        """
        SELECT
            principal.status,
            principal.retired_at,
            managed_link.managed_account_id,
            ownership_link.ownership_account_id
        FROM unified_account_principals AS principal
        LEFT JOIN unified_managed_account_links AS managed_link
          ON managed_link.principal_id = principal.principal_id
        LEFT JOIN unified_ownership_account_links AS ownership_link
          ON ownership_link.principal_id = principal.principal_id
        WHERE principal.issuer = $1
          AND principal.provider_tenant = ''
          AND principal.subject_hash = $2
        """,
        ISSUER,
        "a" * 64,
    )
    assert revoked is not None
    assert revoked["status"] == "active"
    assert revoked["retired_at"] is None
    assert revoked["managed_account_id"] is None
    assert revoked["ownership_account_id"] == records["revoked_ownership_account_id"]

    erased = await connection.fetchrow(
        """
        SELECT
            principal.status,
            principal.retired_at,
            managed_link.managed_account_id,
            ownership_link.ownership_account_id
        FROM unified_account_principals AS principal
        LEFT JOIN unified_managed_account_links AS managed_link
          ON managed_link.principal_id = principal.principal_id
        LEFT JOIN unified_ownership_account_links AS ownership_link
          ON ownership_link.principal_id = principal.principal_id
        WHERE principal.issuer = $1
          AND principal.provider_tenant = ''
          AND principal.subject_hash = $2
        """,
        ISSUER,
        erased_subject_hash,
    )
    assert erased is not None
    assert erased["managed_account_id"] is None
    if erased_ownership_account_id is None:
        assert erased["status"] == "retired"
        assert erased["retired_at"] is not None
        assert erased["ownership_account_id"] is None
    else:
        assert erased["status"] == "active"
        assert erased["retired_at"] is None
        assert erased["ownership_account_id"] == erased_ownership_account_id

    function = await connection.fetchrow(
        """
        SELECT routine.prosecdef,
               routine.provolatile::text AS provolatile,
               routine.proconfig,
               oidvectortypes(routine.proargtypes) AS arguments,
               format_type(routine.prorettype, NULL) AS result_type,
               language.lanname AS language_name,
               btrim(
                   regexp_replace(
                       routine.prosrc,
                       '[[:space:]]+',
                       ' ',
                       'g'
                   )
               ) AS normalized_body,
               NOT EXISTS (
                   SELECT 1
                   FROM aclexplode(
                       COALESCE(
                           routine.proacl,
                           acldefault('f', routine.proowner)
                       )
                   ) AS permission
                   WHERE permission.grantee = 0
                     AND permission.privilege_type = 'EXECUTE'
               ) AS public_execute_revoked
        FROM pg_proc AS routine
        JOIN pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        JOIN pg_language AS language
          ON language.oid = routine.prolang
        WHERE namespace.nspname = current_schema()
          AND routine.oid = to_regprocedure(
              'noop_ownership_lock_unified_principal(text,text,text)'
          )
        """
    )
    assert function is not None
    assert function["prosecdef"] is True
    assert function["provolatile"] == "v"
    assert function["proconfig"] == ["search_path=pg_catalog, pg_temp"]
    assert function["arguments"] == "text, text, text"
    assert function["result_type"] == "text"
    assert function["language_name"] == "sql"
    schema = await connection.fetchval("SELECT current_schema()")
    assert function["normalized_body"] == " ".join(
        f"""
        WITH locked_principal AS MATERIALIZED (
            SELECT
                principal.principal_id,
                principal.issuer,
                principal.provider_tenant,
                principal.subject_hash,
                principal.status
            FROM {schema}.unified_account_principals AS principal
            WHERE principal.issuer = requested_issuer
              AND principal.provider_tenant = requested_provider_tenant
              AND principal.subject_hash =
                  requested_subject_hash::character(64)
            FOR UPDATE
        ),
        linked_ownership AS (
            INSERT INTO {schema}.unified_ownership_account_links (
                principal_id,
                ownership_account_id,
                ownership_identity_id,
                issuer,
                provider_tenant,
                subject_hash
            )
            SELECT
                principal.principal_id,
                identity.account_id,
                identity.identity_id,
                principal.issuer,
                principal.provider_tenant,
                principal.subject_hash
            FROM locked_principal AS principal
            JOIN {schema}.ownership_external_identities AS identity
              ON identity.issuer = principal.issuer
             AND identity.provider_tenant = principal.provider_tenant
             AND identity.subject_hash = principal.subject_hash
            JOIN {schema}.ownership_accounts AS account
              ON account.account_id = identity.account_id
            WHERE principal.status = 'active'
              AND identity.status = 'active'
              AND account.status = 'active'
            ON CONFLICT DO NOTHING
            RETURNING principal_id
        )
        SELECT status
        FROM locked_principal
        """.split()
    )
    assert function["public_execute_revoked"] is True
    assert (
        await connection.fetchval(
            """
            SELECT noop_ownership_lock_unified_principal($1, $2, $3)
            """,
            ISSUER,
            "",
            erased_subject_hash,
        )
        == erased["status"]
    )
    await connection.execute("SET enable_seqscan TO off")
    try:
        plan_rows = await connection.fetch(
            f"""
            EXPLAIN (COSTS OFF)
            SELECT status
            FROM "{schema}".unified_account_principals
            WHERE issuer = $1
              AND provider_tenant = $2
              AND subject_hash = $3::character(64)
            FOR UPDATE
            """,
            ISSUER,
            "",
            erased_subject_hash,
        )
    finally:
        await connection.execute("RESET enable_seqscan")
    plan = " ".join(str(row[0]) for row in plan_rows)
    assert "Index Cond:" in plan
    assert "issuer" in plan
    assert "provider_tenant" in plan
    assert "subject_hash" in plan
    await connection.execute(
        """
        CREATE TEMP TABLE unified_account_principals (
            issuer text NOT NULL,
            provider_tenant text NOT NULL,
            subject_hash char(64) NOT NULL,
            status text NOT NULL
        )
        """
    )
    await connection.execute(
        """
        INSERT INTO pg_temp.unified_account_principals (
            issuer,
            provider_tenant,
            subject_hash,
            status
        ) VALUES ($1, '', $2, 'forged')
        """,
        ISSUER,
        erased_subject_hash,
    )
    assert (
        await connection.fetchval(
            """
            SELECT noop_ownership_lock_unified_principal($1, $2, $3)
            """,
            ISSUER,
            "",
            erased_subject_hash,
        )
        == erased["status"]
    )
    await connection.execute("DROP TABLE pg_temp.unified_account_principals")

    for subject_hash, account_key in (
        ("c" * 64, "active_account_id"),
        ("d" * 64, "pending_account_id"),
        ("e" * 64, "late_terminal_account_id"),
    ):
        preserved = await connection.fetchrow(
            """
            SELECT principal.status, managed_link.managed_account_id
            FROM unified_account_principals AS principal
            JOIN unified_managed_account_links AS managed_link
              ON managed_link.principal_id = principal.principal_id
            WHERE principal.issuer = $1
              AND principal.provider_tenant = ''
              AND principal.subject_hash = $2
            """,
            ISSUER,
            subject_hash,
        )
        assert preserved is not None
        assert preserved["status"] == "active"
        assert preserved["managed_account_id"] == records[account_key]

    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_authority_states
            WHERE managed_account_id = $1
            """,
            records["erased_account_id"],
        )
        == 0
    )
    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1
            """,
            records["erased_account_id"],
        )
        == 0
    )
    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_authority_states
            WHERE managed_account_id = $1
            """,
            records["active_account_id"],
        )
        == 1
    )
    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1
            """,
            records["active_account_id"],
        )
        == 1
    )
    with pytest.raises(asyncpg.CheckViolationError):
        await connection.execute(
            """
            DELETE FROM managed_authority_transitions
            WHERE managed_account_id = $1
            """,
            records["active_account_id"],
        )
    with pytest.raises(asyncpg.CheckViolationError):
        await connection.execute(
            """
            DELETE FROM managed_authority_states
            WHERE managed_account_id = $1
            """,
            records["active_account_id"],
        )
    with pytest.raises(asyncpg.CheckViolationError):
        await connection.execute(
            """
            DELETE FROM unified_managed_account_links
            WHERE managed_account_id = $1
            """,
            records["active_account_id"],
        )
    await _assert_pre_059_trigger_contract(connection)

    assert (
        await connection.fetchval(
            """
            SELECT count(*)
            FROM noop_schema_migrations
            WHERE version = $1
            """,
            REPAIR_MIGRATION.name,
        )
        == 1
    )


async def _run_upgrade_scenario(*, add_post_ownership: bool) -> None:
    assert asyncpg is not None
    repository = _repository()
    schema = f"unified_principal_repair_{uuid4().hex}"
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with pool.acquire() as connection:
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                all_migrations = repository._migration_files()
                await _apply_migrations(
                    repository,
                    connection,
                    _migration_files_through(
                        all_migrations,
                        "046_managed_safety_repeated_paging.sql",
                    ),
                )
                records = await _seed_pre_unification_identities(connection)
                await _apply_migrations(
                    repository,
                    connection,
                    _migration_files_through(
                        all_migrations,
                        "048_managed_authority_state.sql",
                    ),
                )
                await _seed_authority_state(
                    connection,
                    managed_account_id=records["erased_account_id"],
                )
                await _seed_authority_state(
                    connection,
                    managed_account_id=records["active_account_id"],
                )
                await _apply_migrations(
                    repository,
                    connection,
                    _migration_files_through(
                        all_migrations,
                        "058_managed_social_communication_permissions.sql",
                    ),
                )
                await _assert_pre_059_trigger_contract(connection)
                assert (
                    await connection.fetchval(
                        """
                        SELECT count(*)
                        FROM unified_managed_account_links AS managed_link
                        JOIN managed_external_identities AS identity
                          ON identity.account_id =
                             managed_link.managed_account_id
                         AND identity.identity_id =
                             managed_link.managed_identity_id
                        JOIN managed_accounts AS account
                          ON account.account_id = identity.account_id
                        JOIN noop_schema_migrations AS migration_047
                          ON migration_047.version =
                             '047_unified_account_principals.sql'
                        WHERE managed_link.linked_at =
                              migration_047.applied_at
                          AND (
                              identity.revoked_at <=
                                  migration_047.applied_at
                              OR account.erased_at <=
                                  migration_047.applied_at
                          )
                        """
                    )
                    == 2
                )
                await _revoke_late_terminal_identity(connection, records)
                erased_ownership_account_id: UUID | None = None
                if add_post_ownership:
                    (
                        erased_ownership_account_id,
                        _,
                    ) = await _seed_post_unification_ownership_identity(
                        connection,
                        subject_hash="b" * 64,
                        account_status="deletion_pending",
                    )
                await _apply_migrations(
                    repository,
                    connection,
                    all_migrations,
                )

                await _assert_repaired(
                    connection,
                    records,
                    erased_ownership_account_id=erased_ownership_account_id,
                )
            finally:
                await connection.execute("RESET search_path")
                await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL registration race tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_registration_and_principal_retirement_have_two_serial_outcomes() -> None:
    assert asyncpg is not None
    assert DATABASE_URL is not None
    repository = PostgresRepository(
        DATABASE_URL,
        pool_min_size=1,
        pool_max_size=3,
        run_migrations=True,
        database_engine="postgresql",
    )
    registration_task: asyncio.Task[Any] | None = None
    retirement_task: asyncio.Task[Any] | None = None
    retirement_transaction: Any = None
    advisory_lock_key = 59061
    advisory_locked = False
    trigger_name = f"noop_test_registration_block_{uuid4().hex}"
    function_name = f"noop_test_registration_block_fn_{uuid4().hex}"
    trigger_created = False
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as registration_connection,
            pool.acquire() as retirement_connection,
            pool.acquire() as observer_connection,
        ):
            policy_version, policy_sha256 = await _registration_terms(
                observer_connection
            )

            registration_wins_claims = _registration_claims("registration-wins")
            registration_wins_request = _registration_request(
                label="registration-wins",
                policy_version=policy_version,
                policy_sha256=policy_sha256,
            )
            registration_wins_principal = await _seed_unified_principal(
                observer_connection,
                registration_wins_claims,
            )
            await observer_connection.execute(
                f"""
                CREATE FUNCTION {function_name}()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $function$
                BEGIN
                    PERFORM pg_advisory_xact_lock({advisory_lock_key});
                    RETURN NEW;
                END
                $function$;

                CREATE TRIGGER {trigger_name}
                BEFORE INSERT ON ownership_accounts
                FOR EACH ROW
                EXECUTE FUNCTION {function_name}();
                """
            )
            trigger_created = True
            await observer_connection.execute(
                "SELECT pg_advisory_lock($1)",
                advisory_lock_key,
            )
            advisory_locked = True

            registration_repository = PostgresOwnershipRepository(
                _BorrowedPrimary(registration_connection)  # type: ignore[arg-type]
            )
            registration_task = asyncio.create_task(
                registration_repository.register_account(
                    claims=registration_wins_claims,
                    registration=registration_wins_request,
                )
            )
            await _wait_for_lock_waiter(
                observer_connection,
                backend_pid=registration_connection.get_server_pid(),
                task=registration_task,
            )
            retirement_task = asyncio.create_task(
                _retire_principal_if_orphaned(
                    retirement_connection,
                    principal_id=registration_wins_principal,
                )
            )
            await _wait_for_lock_waiter(
                observer_connection,
                backend_pid=retirement_connection.get_server_pid(),
                task=retirement_task,
            )
            assert await observer_connection.fetchval(
                "SELECT pg_advisory_unlock($1)",
                advisory_lock_key,
            )
            advisory_locked = False
            await asyncio.wait_for(registration_task, timeout=10)
            assert await asyncio.wait_for(retirement_task, timeout=10) == "UPDATE 0"
            registration_task = None
            retirement_task = None
            assert (
                await observer_connection.fetchval(
                    """
                    SELECT principal.status
                    FROM unified_account_principals AS principal
                    JOIN unified_ownership_account_links AS ownership_link
                      ON ownership_link.principal_id = principal.principal_id
                    WHERE principal.principal_id = $1
                    """,
                    registration_wins_principal,
                )
                == "active"
            )

            await observer_connection.execute(
                f"DROP TRIGGER {trigger_name} ON ownership_accounts"
            )
            await observer_connection.execute(f"DROP FUNCTION {function_name}()")
            trigger_created = False

            retirement_wins_claims = _registration_claims("retirement-wins")
            retirement_wins_request = _registration_request(
                label="retirement-wins",
                policy_version=policy_version,
                policy_sha256=policy_sha256,
            )
            retirement_wins_principal = await _seed_unified_principal(
                observer_connection,
                retirement_wins_claims,
            )
            retirement_transaction = retirement_connection.transaction()
            await retirement_transaction.start()
            await retirement_connection.fetchval(
                """
                SELECT principal_id
                FROM unified_account_principals
                WHERE principal_id = $1
                FOR UPDATE
                """,
                retirement_wins_principal,
            )
            assert (
                await retirement_connection.execute(
                    """
                    UPDATE unified_account_principals
                    SET status = 'retired',
                        version = version + 1,
                        updated_at = clock_timestamp(),
                        retired_at = clock_timestamp()
                    WHERE principal_id = $1
                    """,
                    retirement_wins_principal,
                )
                == "UPDATE 1"
            )
            registration_task = asyncio.create_task(
                registration_repository.register_account(
                    claims=retirement_wins_claims,
                    registration=retirement_wins_request,
                )
            )
            await _wait_for_lock_waiter(
                observer_connection,
                backend_pid=registration_connection.get_server_pid(),
                task=registration_task,
            )
            await retirement_transaction.commit()
            retirement_transaction = None
            with pytest.raises(OwnershipForbiddenError):
                await asyncio.wait_for(registration_task, timeout=10)
            registration_task = None
            assert (
                await observer_connection.fetchval(
                    """
                    SELECT count(*)
                    FROM ownership_external_identities
                    WHERE issuer = $1
                      AND provider_tenant = $2
                      AND subject_hash = $3
                    """,
                    retirement_wins_claims.issuer,
                    retirement_wins_claims.provider_tenant,
                    retirement_wins_claims.subject_hash,
                )
                == 0
            )
    finally:
        if registration_task is not None and not registration_task.done():
            registration_task.cancel()
            await asyncio.gather(registration_task, return_exceptions=True)
        if retirement_task is not None and not retirement_task.done():
            retirement_task.cancel()
            await asyncio.gather(retirement_task, return_exceptions=True)
        if retirement_transaction is not None:
            await retirement_transaction.rollback()
        if repository._pool is not None:
            if advisory_locked:
                await repository._pool.execute(
                    "SELECT pg_advisory_unlock($1)",
                    advisory_lock_key,
                )
            if trigger_created:
                await repository._pool.execute(
                    f"DROP TRIGGER IF EXISTS {trigger_name} ON ownership_accounts"
                )
                await repository._pool.execute(
                    f"DROP FUNCTION IF EXISTS {function_name}()"
                )
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL registration race tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_registration_and_reconciliation_share_no_principal_lock() -> None:
    assert asyncpg is not None
    repository = PostgresRepository(
        DATABASE_URL,
        pool_min_size=1,
        pool_max_size=3,
        run_migrations=True,
        database_engine="postgresql",
    )
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as registration_connection,
            pool.acquire() as reconcile_connection,
            pool.acquire() as observer_connection,
        ):
            policy_version, policy_sha256 = await _registration_terms(
                observer_connection
            )
            for label, registration_first in (
                ("registration-first-no-principal", True),
                ("reconcile-first-no-principal", False),
            ):
                claims = _registration_claims(label)
                request = _registration_request(
                    label=label,
                    policy_version=policy_version,
                    policy_sha256=policy_sha256,
                )
                lock_key = unified_identity_lock_key(claims)
                assert claims.issuer not in lock_key
                if claims.provider_tenant:
                    assert claims.provider_tenant not in lock_key
                await observer_connection.execute(
                    "SELECT pg_advisory_lock(hashtextextended($1, 0))",
                    lock_key,
                )
                ownership = PostgresOwnershipRepository(
                    _BorrowedPrimary(registration_connection)  # type: ignore[arg-type]
                )
                authority = PostgresUnifiedIdentityAuthorityRepository(
                    _BorrowedPrimary(reconcile_connection)  # type: ignore[arg-type]
                )
                first_task = asyncio.create_task(
                    ownership.register_account(claims=claims, registration=request)
                    if registration_first
                    else authority.reconcile_identity(claims)
                )
                await _wait_for_lock_waiter(
                    observer_connection,
                    backend_pid=(
                        registration_connection.get_server_pid()
                        if registration_first
                        else reconcile_connection.get_server_pid()
                    ),
                    task=first_task,
                )
                assert await observer_connection.fetchval(
                    "SELECT pg_advisory_unlock(hashtextextended($1, 0))",
                    lock_key,
                )
                await asyncio.wait_for(first_task, timeout=10)
                if registration_first:
                    await authority.reconcile_identity(claims)
                else:
                    await ownership.register_account(
                        claims=claims,
                        registration=request,
                    )
                row = await observer_connection.fetchrow(
                    """
                    SELECT principal.status,
                           ownership_link.ownership_account_id,
                           ownership_link.ownership_identity_id
                    FROM unified_account_principals AS principal
                    JOIN unified_ownership_account_links AS ownership_link
                      ON ownership_link.principal_id = principal.principal_id
                    JOIN ownership_external_identities AS identity
                      ON identity.account_id =
                         ownership_link.ownership_account_id
                     AND identity.identity_id =
                         ownership_link.ownership_identity_id
                    WHERE principal.issuer = $1
                      AND principal.provider_tenant = $2
                      AND principal.subject_hash = $3
                      AND identity.issuer = principal.issuer
                      AND identity.provider_tenant =
                          principal.provider_tenant
                      AND identity.subject_hash = principal.subject_hash
                    """,
                    claims.issuer,
                    claims.provider_tenant,
                    claims.subject_hash,
                )
                assert row is not None
                assert row["status"] == "active"
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_fresh_upgrade_chain_repairs_terminal_managed_principals() -> None:
    await _run_upgrade_scenario(add_post_ownership=False)


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_already_migrated_database_repairs_terminal_principals() -> None:
    await _run_upgrade_scenario(add_post_ownership=True)


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_completed_pre_059_erasure_restores_preexisting_ownership_root() -> None:
    assert asyncpg is not None
    repository = _repository()
    schema = f"unified_pre059_erasure_{uuid4().hex}"
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with pool.acquire() as connection:
            await connection.execute(f'CREATE SCHEMA "{schema}"')
            await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                all_migrations = repository._migration_files()
                await _apply_migrations(
                    repository,
                    connection,
                    _migration_files_through(
                        all_migrations,
                        "046_managed_safety_repeated_paging.sql",
                    ),
                )
                records = await _seed_pre_unification_identities(connection)
                await _apply_migrations(
                    repository,
                    connection,
                    _migration_files_through(
                        all_migrations,
                        "058_managed_social_communication_permissions.sql",
                    ),
                )
                principal_id = await connection.fetchval(
                    """
                    SELECT principal_id
                    FROM unified_account_principals
                    WHERE issuer = $1
                      AND provider_tenant = ''
                      AND subject_hash = $2
                    """,
                    ISSUER,
                    "c" * 64,
                )
                (
                    ownership_account_id,
                    ownership_identity_id,
                ) = await _seed_post_unification_ownership_identity(
                    connection,
                    subject_hash="c" * 64,
                )
                erasure_time = await connection.fetchval(
                    "SELECT clock_timestamp() + interval '1 second'"
                )
                erasure_job_id = uuid4()
                await connection.execute(
                    """
                    UPDATE managed_accounts
                    SET status = 'erasure_pending',
                        erasure_requested_at = $2,
                        updated_at = $2
                    WHERE account_id = $1
                    """,
                    records["active_account_id"],
                    erasure_time,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_erasure_jobs (
                        erasure_job_id,
                        account_id,
                        request_id,
                        scope,
                        status,
                        tenant_replay_hash,
                        confirmation_sha256,
                        requested_at,
                        not_before,
                        started_at,
                        verification_expires_at
                    ) VALUES (
                        $1, $2, $3, 'account', 'verifying', $4, $5,
                        $6::timestamptz,
                        $6::timestamptz,
                        $6::timestamptz,
                        $6::timestamptz + interval '1 hour'
                    )
                    """,
                    erasure_job_id,
                    records["active_account_id"],
                    uuid4(),
                    "3" * 64,
                    "4" * 64,
                    erasure_time,
                )
                erased = await connection.fetchrow(
                    """
                    SELECT *
                    FROM noop_erase_managed_account_cloud_state($1, $2, $3)
                    """,
                    records["active_account_id"],
                    erasure_job_id,
                    erasure_time,
                )
                assert erased is not None
                assert int(erased["managed_identity_link_rows"]) == 1
                completion_time = await connection.fetchval(
                    "SELECT $1::timestamptz + interval '1 second'",
                    erasure_time,
                )
                await connection.execute(
                    """
                    UPDATE managed_accounts
                    SET status = 'erased',
                        erased_at = $2,
                        auth_valid_after = $2,
                        updated_at = $2
                    WHERE account_id = $1
                    """,
                    records["active_account_id"],
                    completion_time,
                )
                await connection.execute(
                    """
                    UPDATE managed_erasure_jobs
                    SET status = 'completed',
                        completed_at = $3
                    WHERE account_id = $1
                      AND erasure_job_id = $2
                    """,
                    records["active_account_id"],
                    erasure_job_id,
                    completion_time,
                )
                await connection.execute(
                    """
                    DELETE FROM managed_external_identities
                    WHERE account_id = $1
                    """,
                    records["active_account_id"],
                )
                retired = await connection.fetchrow(
                    """
                    SELECT status, retired_at
                    FROM unified_account_principals
                    WHERE principal_id = $1
                    """,
                    principal_id,
                )
                assert retired is not None
                assert retired["status"] == "retired"
                assert retired["retired_at"] == erasure_time

                late_principal_id = uuid4()
                late_account_id = uuid4()
                late_identity_id = uuid4()
                late_subject_hash = "9" * 64
                await connection.execute(
                    """
                    INSERT INTO unified_account_principals (
                        principal_id,
                        issuer,
                        provider_tenant,
                        subject_hash,
                        status,
                        created_at,
                        updated_at,
                        retired_at
                    ) VALUES (
                        $1, $2, '', $3, 'retired', $4, $4, $4
                    )
                    """,
                    late_principal_id,
                    ISSUER,
                    late_subject_hash,
                    erasure_time,
                )
                await connection.execute(
                    """
                    INSERT INTO ownership_accounts (
                        account_id,
                        auth_valid_after,
                        created_at,
                        updated_at
                    ) VALUES ($1, $2, $2, $2)
                    """,
                    late_account_id,
                    completion_time,
                )
                await connection.execute(
                    """
                    INSERT INTO ownership_external_identities (
                        identity_id,
                        account_id,
                        issuer,
                        provider_tenant,
                        subject_hash,
                        email_verified,
                        phone_verified,
                        verified_at,
                        last_seen_at,
                        created_at
                    ) VALUES (
                        $1, $2, $3, '', $4, true, false, $5, $5, $5
                    )
                    """,
                    late_identity_id,
                    late_account_id,
                    ISSUER,
                    late_subject_hash,
                    completion_time,
                )

                await _apply_migrations(repository, connection, all_migrations)

                repaired = await connection.fetchrow(
                    """
                    SELECT principal.status,
                           principal.retired_at,
                           ownership_link.ownership_account_id,
                           ownership_link.ownership_identity_id
                    FROM unified_account_principals AS principal
                    JOIN unified_ownership_account_links AS ownership_link
                      ON ownership_link.principal_id = principal.principal_id
                    WHERE principal.principal_id = $1
                    """,
                    principal_id,
                )
                assert repaired is not None
                assert repaired["status"] == "active"
                assert repaired["retired_at"] == erasure_time
                assert repaired["ownership_account_id"] == ownership_account_id
                assert repaired["ownership_identity_id"] == ownership_identity_id
                assert (
                    await connection.fetchval(
                        """
                        SELECT status
                        FROM unified_account_principals
                        WHERE principal_id = $1
                        """,
                        late_principal_id,
                    )
                    == "retired"
                )
                assert (
                    await connection.fetchval(
                        """
                        SELECT count(*)
                        FROM unified_ownership_account_links
                        WHERE principal_id = $1
                        """,
                        late_principal_id,
                    )
                    == 0
                )
                assert (
                    await connection.fetchval(
                        """
                        SELECT count(*)
                        FROM managed_account_cloud_erasure_tombstones
                        WHERE account_id = $1
                          AND erasure_job_id = $2
                        """,
                        records["active_account_id"],
                        erasure_job_id,
                    )
                    == 1
                )
                await _assert_pre_059_trigger_contract(connection)
            finally:
                await connection.execute("RESET search_path")
                await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_repair_preserves_concurrent_identity_reconciliation_without_deadlock() -> (
    None
):
    assert asyncpg is not None
    repository = _repository()
    schema = f"unified_principal_lock_{uuid4().hex}"
    migration_task: asyncio.Task[Any] | None = None
    reconcile_task: asyncio.Task[Any] | None = None
    advisory_lock_key = 59059
    advisory_locked = False
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as migration_connection,
            pool.acquire() as reconcile_connection,
            pool.acquire() as blocker_connection,
        ):
            await migration_connection.execute(f'CREATE SCHEMA "{schema}"')
            for connection in (
                migration_connection,
                reconcile_connection,
                blocker_connection,
            ):
                await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                all_migrations = repository._migration_files()
                await _apply_migrations(
                    repository,
                    migration_connection,
                    _migration_files_through(
                        all_migrations,
                        "046_managed_safety_repeated_paging.sql",
                    ),
                )
                now = datetime.now(UTC)
                claims = ManagedIdentityClaims(
                    issuer=ISSUER,
                    subject=f"repair-concurrency-{uuid4()}",
                    provider_tenant="",
                    issued_at=now,
                    auth_time=now - timedelta(seconds=5),
                    expires_at=now + timedelta(hours=1),
                    email_verified=True,
                    sign_in_provider="password",
                )
                records = await _seed_pre_unification_identities(
                    migration_connection,
                    erased_subject_hash=claims.subject_hash,
                )
                await _apply_migrations(
                    repository,
                    migration_connection,
                    _migration_files_through(
                        all_migrations,
                        "048_managed_authority_state.sql",
                    ),
                )
                await _seed_authority_state(
                    migration_connection,
                    managed_account_id=records["erased_account_id"],
                )
                await _seed_authority_state(
                    migration_connection,
                    managed_account_id=records["active_account_id"],
                )
                await _apply_migrations(
                    repository,
                    migration_connection,
                    _migration_files_through(
                        all_migrations,
                        "058_managed_social_communication_permissions.sql",
                    ),
                )
                await _assert_pre_059_trigger_contract(migration_connection)

                principal_id = await migration_connection.fetchval(
                    """
                    SELECT principal_id
                    FROM unified_account_principals
                    WHERE issuer = $1
                      AND provider_tenant = ''
                      AND subject_hash = $2
                    """,
                    ISSUER,
                    claims.subject_hash,
                )
                (
                    ownership_account_id,
                    ownership_identity_id,
                ) = await _seed_post_unification_ownership_identity(
                    migration_connection,
                    subject_hash=claims.subject_hash,
                )
                await migration_connection.execute(
                    """
                    CREATE FUNCTION noop_test_block_059_delete()
                    RETURNS trigger
                    LANGUAGE plpgsql
                    AS $function$
                    BEGIN
                        PERFORM pg_advisory_xact_lock(TG_ARGV[0]::bigint);
                        RETURN OLD;
                    END
                    $function$;

                    CREATE TRIGGER aaa_noop_test_block_059_delete
                    BEFORE DELETE ON unified_managed_account_links
                    FOR EACH ROW
                    EXECUTE FUNCTION noop_test_block_059_delete('59059');
                    """
                )
                await blocker_connection.execute(
                    "SELECT pg_advisory_lock($1)",
                    advisory_lock_key,
                )
                advisory_locked = True
                migration_task = asyncio.create_task(
                    _apply_migrations(
                        repository,
                        migration_connection,
                        all_migrations,
                    )
                )
                await _wait_for_lock_waiter(
                    blocker_connection,
                    backend_pid=migration_connection.get_server_pid(),
                    task=migration_task,
                )
                authority = PostgresUnifiedIdentityAuthorityRepository(
                    _BorrowedPrimary(reconcile_connection)  # type: ignore[arg-type]
                )
                reconcile_task = asyncio.create_task(
                    authority.reconcile_identity(claims)
                )
                reconciled = await asyncio.wait_for(reconcile_task, timeout=10)
                assert reconciled.principal_id == principal_id
                assert reconciled.ownership_account_id == ownership_account_id
                assert reconciled.ownership_identity_id == ownership_identity_id
                assert await blocker_connection.fetchval(
                    "SELECT pg_advisory_unlock($1)",
                    advisory_lock_key,
                )
                advisory_locked = False
                await asyncio.wait_for(migration_task, timeout=10)
                await migration_connection.execute(
                    """
                    DROP TRIGGER aaa_noop_test_block_059_delete
                        ON unified_managed_account_links;
                    DROP FUNCTION noop_test_block_059_delete();
                    """
                )

                assert (
                    await migration_connection.fetchval(
                        """
                        SELECT status
                        FROM unified_account_principals
                        WHERE principal_id = $1
                        """,
                        principal_id,
                    )
                    == "active"
                )
                assert (
                    await migration_connection.fetchval(
                        """
                        SELECT count(*)
                        FROM unified_ownership_account_links
                        WHERE principal_id = $1
                        """,
                        principal_id,
                    )
                    == 1
                )
                await _assert_repaired(
                    migration_connection,
                    records,
                    erased_ownership_account_id=ownership_account_id,
                    erased_subject_hash=claims.subject_hash,
                )
            finally:
                if migration_task is not None and not migration_task.done():
                    migration_task.cancel()
                    await asyncio.gather(migration_task, return_exceptions=True)
                if reconcile_task is not None and not reconcile_task.done():
                    reconcile_task.cancel()
                    await asyncio.gather(reconcile_task, return_exceptions=True)
                if advisory_locked:
                    await blocker_connection.execute(
                        "SELECT pg_advisory_unlock($1)",
                        advisory_lock_key,
                    )
                for connection in (
                    blocker_connection,
                    reconcile_connection,
                    migration_connection,
                ):
                    await connection.execute("RESET search_path")
                await migration_connection.execute(
                    f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'
                )
    finally:
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_repair_and_managed_erasure_share_link_then_principal_lock_order() -> (
    None
):
    assert asyncpg is not None
    repository = _repository()
    schema = f"unified_principal_erasure_{uuid4().hex}"
    migration_task: asyncio.Task[Any] | None = None
    erasure_task: asyncio.Task[Any] | None = None
    advisory_lock_key = 59060
    advisory_locked = False
    await repository.startup()
    pool = repository._require_pool()
    try:
        async with (
            pool.acquire() as migration_connection,
            pool.acquire() as erasure_connection,
            pool.acquire() as blocker_connection,
        ):
            await migration_connection.execute(f'CREATE SCHEMA "{schema}"')
            for connection in (
                migration_connection,
                erasure_connection,
                blocker_connection,
            ):
                await connection.execute(f'SET search_path TO "{schema}", public')
            try:
                all_migrations = repository._migration_files()
                await _apply_migrations(
                    repository,
                    migration_connection,
                    _migration_files_through(
                        all_migrations,
                        "046_managed_safety_repeated_paging.sql",
                    ),
                )
                records = await _seed_pre_unification_identities(migration_connection)
                await _apply_migrations(
                    repository,
                    migration_connection,
                    _migration_files_through(
                        all_migrations,
                        "058_managed_social_communication_permissions.sql",
                    ),
                )
                principal_id = await migration_connection.fetchval(
                    """
                    SELECT principal_id
                    FROM unified_account_principals
                    WHERE issuer = $1
                      AND provider_tenant = ''
                      AND subject_hash = $2
                    """,
                    ISSUER,
                    "a" * 64,
                )
                now = datetime.now(UTC)
                erasure_job_id = uuid4()
                await migration_connection.execute(
                    """
                    UPDATE managed_accounts
                    SET status = 'erasure_pending',
                        erasure_requested_at = $2,
                        updated_at = $2
                    WHERE account_id = $1
                    """,
                    records["revoked_account_id"],
                    now,
                )
                await migration_connection.execute(
                    """
                    INSERT INTO managed_erasure_jobs (
                        erasure_job_id,
                        account_id,
                        request_id,
                        scope,
                        status,
                        tenant_replay_hash,
                        confirmation_sha256,
                        requested_at,
                        not_before,
                        started_at,
                        verification_expires_at
                    ) VALUES (
                        $1,
                        $2,
                        $3,
                        'account',
                        'verifying',
                        $4,
                        $5,
                        $6::timestamptz,
                        $6::timestamptz,
                        $6::timestamptz,
                        $6::timestamptz + interval '1 hour'
                    )
                    """,
                    erasure_job_id,
                    records["revoked_account_id"],
                    uuid4(),
                    "1" * 64,
                    "2" * 64,
                    now,
                )
                await migration_connection.execute(
                    """
                    CREATE FUNCTION noop_test_block_erasure_link()
                    RETURNS trigger
                    LANGUAGE plpgsql
                    AS $function$
                    BEGIN
                        IF current_setting(
                            'noop.managed_erasure_account_id',
                            true
                        ) = OLD.managed_account_id::text
                           AND current_setting(
                               'noop.unified_principal_repair',
                               true
                           ) IS DISTINCT FROM '059' THEN
                            PERFORM pg_advisory_xact_lock(TG_ARGV[0]::bigint);
                        END IF;
                        RETURN OLD;
                    END
                    $function$;

                    CREATE TRIGGER aaa_noop_test_block_erasure_link
                    AFTER DELETE ON unified_managed_account_links
                    FOR EACH ROW
                    EXECUTE FUNCTION noop_test_block_erasure_link('59060');
                    """
                )
                await blocker_connection.execute(
                    "SELECT pg_advisory_lock($1)",
                    advisory_lock_key,
                )
                advisory_locked = True
                erasure_task = asyncio.create_task(
                    erasure_connection.fetchrow(
                        """
                        SELECT *
                        FROM noop_erase_managed_account_cloud_state($1, $2, $3)
                        """,
                        records["revoked_account_id"],
                        erasure_job_id,
                        now,
                    )
                )
                await _wait_for_lock_waiter(
                    blocker_connection,
                    backend_pid=erasure_connection.get_server_pid(),
                    task=erasure_task,
                )
                migration_task = asyncio.create_task(
                    _apply_migrations(
                        repository,
                        migration_connection,
                        all_migrations,
                    )
                )
                await _wait_for_lock_waiter(
                    blocker_connection,
                    backend_pid=migration_connection.get_server_pid(),
                    task=migration_task,
                )
                assert await blocker_connection.fetchval(
                    "SELECT pg_advisory_unlock($1)",
                    advisory_lock_key,
                )
                advisory_locked = False
                erased = await asyncio.wait_for(erasure_task, timeout=10)
                await asyncio.wait_for(migration_task, timeout=10)
                assert erased is not None
                assert int(erased["managed_identity_link_rows"]) == 1
                await migration_connection.execute(
                    """
                    DROP TRIGGER aaa_noop_test_block_erasure_link
                        ON unified_managed_account_links;
                    DROP FUNCTION noop_test_block_erasure_link();
                    """
                )
                principal = await migration_connection.fetchrow(
                    """
                    SELECT principal.status,
                           managed_link.principal_id AS managed_link_id,
                           ownership_link.principal_id AS ownership_link_id
                    FROM unified_account_principals AS principal
                    LEFT JOIN unified_managed_account_links AS managed_link
                      ON managed_link.principal_id = principal.principal_id
                    LEFT JOIN unified_ownership_account_links AS ownership_link
                      ON ownership_link.principal_id = principal.principal_id
                    WHERE principal.principal_id = $1
                    """,
                    principal_id,
                )
                assert principal is not None
                assert principal["status"] == "active"
                assert principal["managed_link_id"] is None
                assert principal["ownership_link_id"] == principal_id
            finally:
                if migration_task is not None and not migration_task.done():
                    migration_task.cancel()
                    await asyncio.gather(migration_task, return_exceptions=True)
                if erasure_task is not None and not erasure_task.done():
                    erasure_task.cancel()
                    await asyncio.gather(erasure_task, return_exceptions=True)
                if advisory_locked:
                    await blocker_connection.execute(
                        "SELECT pg_advisory_unlock($1)",
                        advisory_lock_key,
                    )
                for connection in (
                    blocker_connection,
                    erasure_connection,
                    migration_connection,
                ):
                    await connection.execute("RESET search_path")
                await migration_connection.execute(
                    f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'
                )
    finally:
        await repository.shutdown()
