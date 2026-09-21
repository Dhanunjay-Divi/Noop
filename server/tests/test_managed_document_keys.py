from __future__ import annotations

import base64
import hashlib
import inspect
import json
import os
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

import pytest

try:
    import asyncpg
except ModuleNotFoundError:
    asyncpg = None  # type: ignore[assignment]

from app.managed_document_keys import (
    ManagedDocumentKeyConflictError,
    ManagedDocumentKeyDisabledError,
    ManagedDocumentKeyNotFoundError,
    ManagedWrappedKeyMutation,
    PostgresManagedDocumentKeyRepository,
    parse_managed_document_envelope,
)
from app.managed_models import ManagedDocumentMutation
from app.managed_repository import (
    ManagedNotFoundError,
    ManagedPrincipal,
    PostgresManagedRepository,
)
from app.repository import PostgresRepository

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "server/migrations/050_managed_document_keys.sql"
AUTHORITY_MIGRATION = ROOT / "server/migrations/055_managed_document_key_authority.sql"
FENCE_MIGRATION = ROOT / "server/migrations/056_managed_identity_and_key_fences.sql"
ENVELOPE_SIZE_MIGRATION = (
    ROOT / "server/migrations/054_managed_document_key_envelope_size.sql"
)
FIXTURE = ROOT / "Fixtures/managed-document-sync/v1/golden-vectors.json"
DATABASE_URL = (
    os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL") if asyncpg is not None else None
)


def _principal() -> ManagedPrincipal:
    return ManagedPrincipal(
        account_id=uuid4(),
        identity_id=uuid4(),
        subject_hash="a" * 64,
        account_status="active",
        auth_valid_after=datetime.now(UTC),
    )


def test_migration_is_additive_account_scoped_and_opaque() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    confirmation_sql = (
        ROOT / "server/migrations/053_managed_master_key_confirmation.sql"
    ).read_text(encoding="utf-8")
    envelope_size_sql = ENVELOPE_SIZE_MIGRATION.read_text(encoding="utf-8")
    authority_sql = AUTHORITY_MIGRATION.read_text(encoding="utf-8")
    fence_sql = FENCE_MIGRATION.read_text(encoding="utf-8")
    assert "CREATE TABLE managed_document_keys" in sql
    assert "PRIMARY KEY (account_id, key_id)" in sql
    assert "FOREIGN KEY (account_id, wrapping_key_id)" in sql
    assert "wrapped_key bytea NOT NULL" in sql
    assert "wrapped_key_sha256 char(64) NOT NULL" in sql
    assert "key_kind IN ('account_master', 'document')" in sql
    assert "status IN ('active', 'retired', 'revoked')" in sql
    assert "CREATE TABLE managed_document_key_versions" in sql
    assert "managed_document_key_version_guard" in sql
    assert "managed_document_key_lifecycle_guard" in sql
    assert "managed_document_key_current_version" in sql
    assert "WITH RECURSIVE successor_chain" in sql
    assert "plaintext" not in sql.lower()
    assert "CREATE TABLE managed_documents" not in sql
    assert "master_key_confirmation_hmac_sha256" in confirmation_sql
    assert "new account master keys require client confirmation" in confirmation_sql
    assert "version.master_key_confirmation_hmac_sha256" in confirmation_sql
    assert "NEW.master_key_confirmation_hmac_sha256" in confirmation_sql
    assert "managed_document_key_document_wrapped_size" in envelope_size_sql
    assert "managed_document_key_version_document_wrapped_size" in (envelope_size_sql)
    assert "octet_length(wrapped_key) = 72" in envelope_size_sql
    assert "managed_document_key_confirmation_guard" in confirmation_sql
    assert "ADD COLUMN document_key_id uuid" in authority_sql
    assert "FOREIGN KEY (account_id, document_key_id)" in authority_sql
    assert "REFERENCES managed_document_keys(account_id, key_id)" in authority_sql
    assert "managed_document_key_authority_guard" in authority_sql
    assert "active account-scoped document key is required" in authority_sql
    assert "client_key_id IS NULL" in authority_sql
    assert "OR document_key_id IS NULL" in authority_sql
    assert "DROP CONSTRAINT managed_document_client_key_fk" not in authority_sql
    assert "managed_document_key_reference_guard" in fence_sql
    assert "still referenced by live documents" in fence_sql


def test_server_parses_shared_document_envelope_without_decrypting() -> None:
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))["document"]
    envelope = base64.b64decode(fixture["envelope_base64"], validate=True)
    parsed = parse_managed_document_envelope(envelope)
    assert parsed.version == 1
    assert parsed.nonce.hex() == fixture["nonce_hex"]
    assert parsed.ciphertext_bytes == len(
        base64.b64decode(fixture["plaintext_base64"], validate=True)
    )
    assert hashlib.sha256(envelope).hexdigest() == fixture["envelope_sha256"]

    tampered_header = bytearray(envelope)
    tampered_header[8] = 2
    with pytest.raises(ValueError):
        parse_managed_document_envelope(bytes(tampered_header))


def test_wrapped_key_contract_rejects_digest_and_parent_mismatch() -> None:
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))["key_wrap"]
    wrapped = base64.b64decode(fixture["wrapped_key_base64"], validate=True)
    mutation = ManagedWrappedKeyMutation(
        key_id=UUID(fixture["document_key_id"]),
        key_kind="document",
        wrapping_key_id=UUID(fixture["wrapping_key_id"]),
        wrapping_revision=fixture["wrapping_revision"],
        algorithm="A256GCM",
        wrapped_key=wrapped,
        wrapped_key_sha256=fixture["wrapped_key_sha256"],
    )
    assert mutation.key_id != mutation.wrapping_key_id

    with pytest.raises(ValueError):
        ManagedWrappedKeyMutation(
            key_id=mutation.key_id,
            key_kind="document",
            wrapping_key_id=mutation.wrapping_key_id,
            wrapping_revision=mutation.wrapping_revision,
            algorithm="A256GCM",
            wrapped_key=wrapped,
            wrapped_key_sha256="0" * 64,
        )
    with pytest.raises(ValueError):
        ManagedWrappedKeyMutation(
            key_id=mutation.key_id,
            key_kind="account_master",
            wrapping_key_id=mutation.wrapping_key_id,
            wrapping_revision=1,
            algorithm="A256GCM",
            wrapped_key=wrapped,
            wrapped_key_sha256=fixture["wrapped_key_sha256"],
            recovery_method="recovery_key",
        )
    with pytest.raises(ValueError):
        ManagedWrappedKeyMutation(
            key_id=mutation.key_id,
            key_kind="document",
            wrapping_key_id=mutation.wrapping_key_id,
            wrapping_revision=mutation.wrapping_revision,
            algorithm="A256GCM",
            wrapped_key=b"x" * 40,
            wrapped_key_sha256=hashlib.sha256(b"x" * 40).hexdigest(),
        )


@pytest.mark.asyncio
async def test_repository_is_default_off_before_database_access() -> None:
    class NoDatabase:
        def _require_pool(self):
            raise AssertionError("disabled repository must not access the database")

    repository = PostgresManagedDocumentKeyRepository(NoDatabase())
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))["key_wrap"]
    wrapped = base64.b64decode(fixture["wrapped_key_base64"], validate=True)
    mutation = ManagedWrappedKeyMutation(
        key_id=UUID(fixture["document_key_id"]),
        key_kind="document",
        wrapping_key_id=UUID(fixture["wrapping_key_id"]),
        wrapping_revision=fixture["wrapping_revision"],
        algorithm="A256GCM",
        wrapped_key=wrapped,
        wrapped_key_sha256=fixture["wrapped_key_sha256"],
    )
    with pytest.raises(ManagedDocumentKeyDisabledError):
        await repository.put(principal=_principal(), mutation=mutation)


def test_rotation_revocation_and_reads_are_account_scoped_in_source() -> None:
    source = inspect.getsource(PostgresManagedDocumentKeyRepository)
    assert source.count("WHERE account_id = $1") >= 4
    assert "AND wrapping_revision = $9" in source
    assert "status = 'revoked'" in source
    assert "account master key has active document keys" in source
    assert "successor key must be active and same-kind" in source
    assert "managed_document_key_versions" in source
    assert "_lock_active_account" in source
    assert "noop-managed-erasure-account:" in source
    assert "SELECT status, auth_valid_after" in source
    assert "AND status <> 'revoked'" in source


def _primary() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine="postgresql",
    )


async def _seed_principal(
    primary: PostgresRepository,
    *,
    provider_tenant: str | None = None,
) -> ManagedPrincipal:
    account_id = uuid4()
    identity_id = uuid4()
    now = datetime.now(UTC)
    subject_hash = hashlib.sha256(str(identity_id).encode("ascii")).hexdigest()
    await primary._require_pool().execute(
        """
        INSERT INTO managed_accounts (
            account_id, storage_namespace, status, home_region,
            residency_policy_version, auth_valid_after, created_at, updated_at
        ) VALUES (
            $1, $2, 'active', 'test-region', 'synthetic-v1',
            $3, $3, $3
        )
        """,
        account_id,
        uuid4(),
        now,
    )
    if provider_tenant is not None:
        await primary._require_pool().execute(
            """
            INSERT INTO managed_external_identities (
                identity_id,
                account_id,
                issuer,
                provider_tenant,
                subject_hash,
                status,
                claims_version,
                verified_at,
                last_seen_at
            ) VALUES (
                $1, $2, 'https://securetoken.google.com/noop-test-project',
                $3, $4, 'active', 1, $5, $5
            )
            """,
            identity_id,
            account_id,
            provider_tenant,
            subject_hash,
            now,
        )
    return ManagedPrincipal(
        account_id=account_id,
        identity_id=identity_id,
        subject_hash=subject_hash,
        account_status="active",
        auth_valid_after=now,
    )


async def _seed_installation(
    primary: PostgresRepository,
    *,
    principal: ManagedPrincipal,
) -> str:
    installation_id = uuid4().hex
    now = datetime.now(UTC)
    await primary._require_pool().execute(
        """
        INSERT INTO installation_credentials (
            installation_id,
            enrollment_id,
            token_hash,
            created_at,
            updated_at
        ) VALUES ($1, $2, $3, $4, $4)
        """,
        installation_id,
        uuid4(),
        hashlib.sha256(f"credential:{installation_id}".encode()).hexdigest(),
        now,
    )
    await primary._require_pool().execute(
        """
        INSERT INTO managed_account_installations (
            account_id,
            installation_id,
            platform,
            status,
            token_valid_after,
            registered_at,
            last_seen_at
        ) VALUES ($1, $2, 'ios', 'active', $3, $3, $3)
        """,
        principal.account_id,
        installation_id,
        now,
    )
    return installation_id


def _mutation(
    *,
    key_id: UUID,
    key_kind: str,
    wrapped: bytes,
    wrapping_revision: int = 1,
    wrapping_key_id: UUID | None = None,
) -> ManagedWrappedKeyMutation:
    return ManagedWrappedKeyMutation(
        key_id=key_id,
        key_kind=key_kind,  # type: ignore[arg-type]
        wrapping_key_id=wrapping_key_id,
        wrapping_revision=wrapping_revision,
        algorithm="A256GCM",
        wrapped_key=wrapped,
        wrapped_key_sha256=hashlib.sha256(wrapped).hexdigest(),
        master_key_confirmation_hmac_sha256=(
            "f" * 64 if key_kind == "account_master" else None
        ),
        recovery_method="recovery_key" if key_kind == "account_master" else None,
    )


async def _document_key_pair(
    repository: PostgresManagedDocumentKeyRepository,
    *,
    principal: ManagedPrincipal,
    marker: bytes,
) -> tuple[UUID, UUID]:
    master_key_id = uuid4()
    document_key_id = uuid4()
    await repository.put(
        principal=principal,
        mutation=_mutation(
            key_id=master_key_id,
            key_kind="account_master",
            wrapped=marker * 72,
        ),
    )
    await repository.put(
        principal=principal,
        mutation=_mutation(
            key_id=document_key_id,
            key_kind="document",
            wrapping_key_id=master_key_id,
            wrapped=marker.upper() * 72,
        ),
    )
    return master_key_id, document_key_id


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_document_upload_uses_active_account_scoped_document_keys() -> None:
    primary = _primary()
    await primary.startup()
    try:
        first = await _seed_principal(primary, provider_tenant="tenant-a")
        second = await _seed_principal(primary, provider_tenant="tenant-a")
        cross_tenant = await _seed_principal(
            primary,
            provider_tenant="tenant-b",
        )
        installation_id = await _seed_installation(primary, principal=first)
        keys = PostgresManagedDocumentKeyRepository(primary, enabled=True)
        managed = PostgresManagedRepository(
            primary,
            home_region="test-region",
            residency_policy_version="synthetic-v1",
            default_plan_code="noop_plus_staging",
            default_plan_revision=1,
            consent_policy_kind="managed_storage",
            entitlement_mode="open_beta",
            replay_secret="test-managed-replay-secret-at-least-32-bytes",
        )

        master_key_id, document_key_id = await _document_key_pair(
            keys,
            principal=first,
            marker=b"a",
        )
        _, wrong_account_key_id = await _document_key_pair(
            keys,
            principal=second,
            marker=b"b",
        )
        _, cross_tenant_key_id = await _document_key_pair(
            keys,
            principal=cross_tenant,
            marker=b"c",
        )
        _, revoked_key_id = await _document_key_pair(
            keys,
            principal=first,
            marker=b"d",
        )
        await keys.revoke(principal=first, key_id=revoked_key_id)

        tenant_rows = await primary._require_pool().fetch(
            """
            SELECT identity_id, provider_tenant
            FROM managed_external_identities
            WHERE identity_id = ANY($1::uuid[])
            """,
            [first.identity_id, second.identity_id, cross_tenant.identity_id],
        )
        assert {row["identity_id"]: row["provider_tenant"] for row in tenant_rows} == {
            first.identity_id: "tenant-a",
            second.identity_id: "tenant-a",
            cross_tenant.identity_id: "tenant-b",
        }
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_client_keys
                WHERE account_id = $1 AND client_key_id = $2
                """,
                first.account_id,
                document_key_id,
            )
            == 0
        )
        payload = base64.b64encode(b"synthetic-encrypted-document").decode("ascii")
        document_id = uuid4()
        created = await managed.put_document(
            principal=first,
            installation_id=installation_id,
            mutation=ManagedDocumentMutation(
                request_id=uuid4(),
                document_kind="journal",
                document_id=document_id,
                base_revision=0,
                content_mode="client_encrypted",
                client_key_id=document_key_id,
                payload_ciphertext_base64=payload,
                updated_at=datetime.now(UTC),
            ),
        )
        assert created["client_key_id"] == str(document_key_id)
        stored = await primary._require_pool().fetchrow(
            """
            SELECT client_key_id, document_key_id
            FROM managed_documents
            WHERE account_id = $1
              AND document_kind = 'journal'
              AND document_id = $2
            """,
            first.account_id,
            document_id,
        )
        assert stored["client_key_id"] is None
        assert stored["document_key_id"] == document_key_id
        with pytest.raises(
            ManagedDocumentKeyConflictError,
            match="still referenced by live documents",
        ):
            await keys.revoke(principal=first, key_id=document_key_id)
        with pytest.raises(
            asyncpg.CheckViolationError,
            match="still referenced by live documents",
        ):
            await primary._require_pool().execute(
                """
                UPDATE managed_document_keys
                SET status = 'revoked',
                    revoked_at = clock_timestamp(),
                    updated_at = clock_timestamp()
                WHERE account_id = $1 AND key_id = $2
                """,
                first.account_id,
                document_key_id,
            )

        for rejected_key_id in (
            master_key_id,
            revoked_key_id,
            wrong_account_key_id,
            cross_tenant_key_id,
        ):
            with pytest.raises(
                ManagedNotFoundError,
                match="active managed document key",
            ):
                await managed.put_document(
                    principal=first,
                    installation_id=installation_id,
                    mutation=ManagedDocumentMutation(
                        request_id=uuid4(),
                        document_kind="journal",
                        document_id=uuid4(),
                        base_revision=0,
                        content_mode="client_encrypted",
                        client_key_id=rejected_key_id,
                        payload_ciphertext_base64=payload,
                        updated_at=datetime.now(UTC),
                    ),
                )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_document_key_database_guards_preserve_legacy_rows() -> None:
    primary = _primary()
    await primary.startup()
    try:
        first = await _seed_principal(primary)
        second = await _seed_principal(primary)
        installation_id = await _seed_installation(primary, principal=first)
        keys = PostgresManagedDocumentKeyRepository(primary, enabled=True)
        master_key_id, document_key_id = await _document_key_pair(
            keys,
            principal=first,
            marker=b"e",
        )
        _, wrong_account_key_id = await _document_key_pair(
            keys,
            principal=second,
            marker=b"f",
        )
        _, revoked_key_id = await _document_key_pair(
            keys,
            principal=first,
            marker=b"g",
        )
        await keys.revoke(principal=first, key_id=revoked_key_id)
        pool = primary._require_pool()
        now = datetime.now(UTC)

        async def insert_with_document_key(key_id: UUID) -> None:
            ciphertext = b"x" * 40
            await pool.execute(
                """
                INSERT INTO managed_documents (
                    account_id,
                    document_kind,
                    document_id,
                    document_revision,
                    origin_installation_id,
                    content_mode,
                    document_key_id,
                    content_sha256,
                    payload_ciphertext,
                    updated_at
                ) VALUES (
                    $1, 'journal', $2, 1, $3, 'client_encrypted',
                    $4, $5, $6, $7
                )
                """,
                first.account_id,
                uuid4(),
                installation_id,
                key_id,
                hashlib.sha256(ciphertext).hexdigest(),
                ciphertext,
                now,
            )

        await insert_with_document_key(document_key_id)
        for rejected_key_id in (
            master_key_id,
            revoked_key_id,
            wrong_account_key_id,
        ):
            with pytest.raises(
                asyncpg.CheckViolationError,
                match="active account-scoped document key",
            ):
                await insert_with_document_key(rejected_key_id)

        legacy_key_id = uuid4()
        await pool.execute(
            """
            INSERT INTO managed_client_keys (
                account_id,
                client_key_id,
                installation_id,
                purpose,
                algorithm,
                key_fingerprint,
                recovery_method,
                hardware_backed
            ) VALUES (
                $1, $2, $3, 'recovery', 'X25519-AESGCM',
                $4, 'recovery_key', true
            )
            """,
            first.account_id,
            legacy_key_id,
            installation_id,
            "a" * 64,
        )
        legacy_ciphertext = b"y" * 40
        legacy_document_id = uuid4()
        await pool.execute(
            """
            INSERT INTO managed_documents (
                account_id,
                document_kind,
                document_id,
                document_revision,
                origin_installation_id,
                content_mode,
                client_key_id,
                content_sha256,
                payload_ciphertext,
                updated_at
            ) VALUES (
                $1, 'journal', $2, 1, $3, 'client_encrypted',
                $4, $5, $6, $7
            )
            """,
            first.account_id,
            legacy_document_id,
            installation_id,
            legacy_key_id,
            hashlib.sha256(legacy_ciphertext).hexdigest(),
            legacy_ciphertext,
            now,
        )
        managed = PostgresManagedRepository(
            primary,
            home_region="test-region",
            residency_policy_version="synthetic-v1",
            default_plan_code="noop_plus_staging",
            default_plan_revision=1,
            consent_policy_kind="managed_storage",
            entitlement_mode="open_beta",
            replay_secret="test-managed-replay-secret-at-least-32-bytes",
        )
        legacy_document = await managed.get_document(
            principal=first,
            document_kind="journal",
            document_id=legacy_document_id,
            revision=1,
        )
        assert legacy_document["client_key_id"] == str(legacy_key_id)
        assert (
            base64.b64decode(
                legacy_document["payload_ciphertext_base64"],
                validate=True,
            )
            == legacy_ciphertext
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_rotation_is_strictly_increasing_recoverable_and_idempotent() -> None:
    primary = _primary()
    await primary.startup()
    try:
        principal = await _seed_principal(primary)
        repository = PostgresManagedDocumentKeyRepository(primary, enabled=True)
        first_master_id = uuid4()
        second_master_id = uuid4()
        document_id = uuid4()
        await repository.put(
            principal=principal,
            mutation=_mutation(
                key_id=first_master_id,
                key_kind="account_master",
                wrapped=b"a" * 72,
            ),
        )
        await repository.put(
            principal=principal,
            mutation=_mutation(
                key_id=second_master_id,
                key_kind="account_master",
                wrapped=b"b" * 72,
            ),
        )
        initial = _mutation(
            key_id=document_id,
            key_kind="document",
            wrapping_key_id=first_master_id,
            wrapping_revision=1,
            wrapped=b"c" * 72,
        )
        await repository.put(principal=principal, mutation=initial)
        replacement = _mutation(
            key_id=document_id,
            key_kind="document",
            wrapping_key_id=second_master_id,
            wrapping_revision=2,
            wrapped=b"d" * 72,
        )
        rotated = await repository.rotate_wrapping(
            principal=principal,
            mutation=replacement,
            expected_wrapping_revision=1,
        )
        replay = await repository.rotate_wrapping(
            principal=principal,
            mutation=replacement,
            expected_wrapping_revision=1,
        )
        first_version = await repository.get_version(
            principal=principal,
            key_id=document_id,
            wrapping_revision=1,
        )
        second_version = await repository.get_version(
            principal=principal,
            key_id=document_id,
            wrapping_revision=2,
        )

        assert rotated.wrapping_revision == 2
        assert replay.wrapped_key == rotated.wrapped_key
        assert first_version.wrapped_key == b"c" * 72
        assert first_version.wrapping_key_id == first_master_id
        assert second_version.wrapped_key == b"d" * 72
        assert second_version.wrapping_key_id == second_master_id
        with pytest.raises(ValueError, match="exactly one"):
            await repository.rotate_wrapping(
                principal=principal,
                mutation=_mutation(
                    key_id=document_id,
                    key_kind="document",
                    wrapping_key_id=second_master_id,
                    wrapping_revision=4,
                    wrapped=b"e" * 72,
                ),
                expected_wrapping_revision=2,
            )

        other_principal = await _seed_principal(primary)
        with pytest.raises(ManagedDocumentKeyNotFoundError):
            await repository.get_version(
                principal=other_principal,
                key_id=document_id,
                wrapping_revision=1,
            )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_revocation_validates_dependents_and_successors() -> None:
    primary = _primary()
    await primary.startup()
    try:
        principal = await _seed_principal(primary)
        repository = PostgresManagedDocumentKeyRepository(primary, enabled=True)
        first_master_id = uuid4()
        second_master_id = uuid4()
        third_master_id = uuid4()
        first_document_id = uuid4()
        second_document_id = uuid4()
        for key_id, wrapped in (
            (first_master_id, b"a" * 40),
            (second_master_id, b"b" * 40),
            (third_master_id, b"c" * 40),
        ):
            await repository.put(
                principal=principal,
                mutation=_mutation(
                    key_id=key_id,
                    key_kind="account_master",
                    wrapped=wrapped,
                ),
            )
        for key_id, wrapped in (
            (first_document_id, b"d" * 72),
            (second_document_id, b"e" * 72),
        ):
            await repository.put(
                principal=principal,
                mutation=_mutation(
                    key_id=key_id,
                    key_kind="document",
                    wrapping_key_id=first_master_id,
                    wrapped=wrapped,
                ),
            )

        with pytest.raises(ManagedDocumentKeyConflictError, match="active document"):
            await repository.revoke(
                principal=principal,
                key_id=first_master_id,
                successor_key_id=second_master_id,
            )
        with pytest.raises(ManagedDocumentKeyConflictError, match="same-kind"):
            await repository.revoke(
                principal=principal,
                key_id=first_document_id,
                successor_key_id=second_master_id,
            )

        await repository.revoke(
            principal=principal,
            key_id=first_document_id,
            successor_key_id=second_document_id,
        )
        await repository.revoke(
            principal=principal,
            key_id=second_document_id,
        )
        revoked_master = await repository.revoke(
            principal=principal,
            key_id=first_master_id,
            successor_key_id=second_master_id,
        )
        assert revoked_master.successor_key_id == second_master_id

        await repository.revoke(
            principal=principal,
            key_id=third_master_id,
        )
        with pytest.raises(
            ManagedDocumentKeyConflictError, match="active and same-kind"
        ):
            await repository.revoke(
                principal=principal,
                key_id=second_master_id,
                successor_key_id=third_master_id,
            )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_database_guards_reject_destructive_key_mutations() -> None:
    primary = _primary()
    await primary.startup()
    try:
        principal = await _seed_principal(primary)
        repository = PostgresManagedDocumentKeyRepository(primary, enabled=True)
        master_id = uuid4()
        document_id = uuid4()
        await repository.put(
            principal=principal,
            mutation=_mutation(
                key_id=master_id,
                key_kind="account_master",
                wrapped=b"a" * 72,
            ),
        )
        await repository.put(
            principal=principal,
            mutation=_mutation(
                key_id=document_id,
                key_kind="document",
                wrapping_key_id=master_id,
                wrapped=b"b" * 72,
            ),
        )
        pool = primary._require_pool()
        changed = b"c" * 40
        now = datetime.now(UTC)
        malformed_document_id = uuid4()

        with pytest.raises(
            asyncpg.CheckViolationError,
            match="managed_document_key_document_wrapped_size",
        ):
            await pool.execute(
                """
                INSERT INTO managed_document_keys (
                    account_id,
                    key_id,
                    key_kind,
                    wrapping_key_id,
                    wrapping_revision,
                    algorithm,
                    wrapped_key,
                    wrapped_key_sha256,
                    recovery_method,
                    status,
                    created_at,
                    updated_at
                ) VALUES (
                    $1, $2, 'document', $3, 1, 'A256GCM',
                    $4, $5, NULL, 'active', $6, $6
                )
                """,
                principal.account_id,
                malformed_document_id,
                master_id,
                changed,
                hashlib.sha256(changed).hexdigest(),
                now,
            )
        with pytest.raises(
            asyncpg.CheckViolationError,
            match="managed_document_key_version_document_wrapped_size",
        ):
            await pool.execute(
                """
                INSERT INTO managed_document_key_versions (
                    account_id,
                    key_id,
                    key_kind,
                    wrapping_revision,
                    wrapping_key_id,
                    algorithm,
                    wrapped_key,
                    wrapped_key_sha256,
                    recovery_method,
                    created_at
                ) VALUES (
                    $1, $2, 'document', 2, $3, 'A256GCM',
                    $4, $5, NULL, $6
                )
                """,
                principal.account_id,
                document_id,
                master_id,
                changed,
                hashlib.sha256(changed).hexdigest(),
                now,
            )
        with pytest.raises(
            asyncpg.CheckViolationError,
            match="require client confirmation",
        ):
            await pool.execute(
                """
                INSERT INTO managed_document_keys (
                    account_id,
                    key_id,
                    key_kind,
                    wrapping_revision,
                    algorithm,
                    wrapped_key,
                    wrapped_key_sha256,
                    recovery_method,
                    status,
                    created_at,
                    updated_at
                ) VALUES (
                    $1, $2, 'account_master', 1, 'A256GCM',
                    $3, $4, 'recovery_key', 'active', $5, $5
                )
                """,
                principal.account_id,
                uuid4(),
                b"m" * 40,
                hashlib.sha256(b"m" * 40).hexdigest(),
                now,
            )
        with pytest.raises(
            asyncpg.CheckViolationError,
            match="confirmation is immutable",
        ):
            await pool.execute(
                """
                UPDATE managed_document_keys
                SET master_key_confirmation_hmac_sha256 = $3,
                    updated_at = $4
                WHERE account_id = $1 AND key_id = $2
                """,
                principal.account_id,
                master_id,
                "e" * 64,
                now,
            )

        with pytest.raises(asyncpg.CheckViolationError, match="rotation is invalid"):
            await pool.execute(
                """
                UPDATE managed_document_keys
                SET wrapped_key = $3,
                    wrapped_key_sha256 = $4,
                    updated_at = $5
                WHERE account_id = $1 AND key_id = $2
                """,
                principal.account_id,
                document_id,
                changed,
                hashlib.sha256(changed).hexdigest(),
                datetime.now(UTC),
            )
        with pytest.raises(asyncpg.CheckViolationError, match="history is required"):
            await pool.execute(
                """
                UPDATE managed_document_keys
                SET wrapping_revision = wrapping_revision + 1,
                    wrapped_key = $3,
                    wrapped_key_sha256 = $4,
                    updated_at = $5
                WHERE account_id = $1 AND key_id = $2
                """,
                principal.account_id,
                document_id,
                changed,
                hashlib.sha256(changed).hexdigest(),
                datetime.now(UTC),
            )
        with pytest.raises(asyncpg.CheckViolationError, match="append-only"):
            await pool.execute(
                """
                UPDATE managed_document_key_versions
                SET wrapped_key = $3
                WHERE account_id = $1
                  AND key_id = $2
                  AND wrapping_revision = 1
                """,
                principal.account_id,
                document_id,
                changed,
            )
        with pytest.raises(asyncpg.CheckViolationError, match="active dependent"):
            await pool.execute(
                """
                UPDATE managed_document_keys
                SET status = 'revoked',
                    revoked_at = $3,
                    updated_at = $3
                WHERE account_id = $1 AND key_id = $2
                """,
                principal.account_id,
                master_id,
                datetime.now(UTC),
            )
    finally:
        await primary.shutdown()
