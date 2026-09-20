from __future__ import annotations

import asyncio
import hashlib
import os
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
import pytest

from app.managed_identity import ManagedIdentityClaims
from app.repository import PostgresRepository
from app.unified_identity_authority import (
    AuthorityEvidence,
    AuthorityTransitionConflictError,
    AuthorityTransitionRejectedError,
    PostgresUnifiedIdentityAuthorityRepository,
    UnifiedIdentityUnavailableError,
)

DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL")
ISSUER = "https://securetoken.google.com/noop-synthetic-project"
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"


@pytest.fixture
async def authority_repository():
    if not DATABASE_URL:
        pytest.skip("NOOP_TEST_POSTGRESQL_DATABASE_URL is required for authority tests")
    primary = PostgresRepository(
        DATABASE_URL,
        pool_min_size=1,
        pool_max_size=12,
        run_migrations=True,
        database_engine="postgresql",
    )
    await primary.startup()
    events: list[tuple[str, dict[str, object]]] = []

    def event_sink(event: str, **fields: object) -> None:
        events.append((event, fields))

    repository = PostgresUnifiedIdentityAuthorityRepository(
        primary,
        event_sink=event_sink,
    )
    try:
        yield repository, primary, events
    finally:
        await primary.shutdown()


def _claims(subject: str, *, tenant: str = "") -> ManagedIdentityClaims:
    now = datetime.now(UTC)
    return ManagedIdentityClaims(
        issuer=ISSUER,
        subject=subject,
        provider_tenant=tenant,
        issued_at=now,
        auth_time=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
        email_verified=True,
        sign_in_provider="password",
    )


async def _wait_for_lock_waiters(pool, *, minimum: int) -> None:
    for _ in range(500):
        waiting = await pool.fetchval("SELECT count(*) FROM pg_locks WHERE NOT granted")
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} lock waiters")


async def _seed_accounts(
    primary: PostgresRepository,
    claims: ManagedIdentityClaims,
    *,
    managed: bool = True,
    ownership: bool = True,
) -> dict[str, UUID]:
    pool = primary._require_pool()
    result: dict[str, UUID] = {}
    now = datetime.now(UTC)
    async with pool.acquire() as connection:
        async with connection.transaction():
            if managed:
                managed_account_id = uuid4()
                managed_identity_id = uuid4()
                await connection.execute(
                    """
                    INSERT INTO managed_accounts (
                        account_id,
                        storage_namespace,
                        home_region,
                        residency_policy_version,
                        auth_valid_after,
                        created_at,
                        updated_at
                    ) VALUES ($1, $2, 'us-test1', 'synthetic-v1', $3, $3, $3)
                    """,
                    managed_account_id,
                    uuid4(),
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_external_identities (
                        identity_id,
                        account_id,
                        issuer,
                        provider_tenant,
                        subject_hash,
                        verified_at,
                        last_seen_at,
                        created_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $6, $6)
                    """,
                    managed_identity_id,
                    managed_account_id,
                    claims.issuer,
                    claims.provider_tenant,
                    claims.subject_hash,
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_subscriptions (
                        subscription_id,
                        account_id,
                        plan_code,
                        plan_revision,
                        status,
                        billing_provider,
                        period_started_at,
                        created_at,
                        updated_at
                    ) VALUES (
                        $1, $2, 'noop_plus_staging', 1,
                        'active', 'manual', $3, $3, $3
                    )
                    """,
                    uuid4(),
                    managed_account_id,
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_consent_events (
                        consent_event_id,
                        account_id,
                        policy_kind,
                        policy_version,
                        decision,
                        data_classes,
                        installation_id,
                        request_id,
                        occurred_at,
                        recorded_at
                    )
                    SELECT
                        $1,
                        $2,
                        'managed_storage',
                        'synthetic-v1',
                        'granted',
                        array_agg(rule.data_class ORDER BY rule.data_class),
                        NULL,
                        $3,
                        $4,
                        $4
                    FROM managed_plan_data_rules AS rule
                    WHERE rule.plan_code = 'noop_plus_staging'
                      AND rule.plan_revision = 1
                    """,
                    uuid4(),
                    managed_account_id,
                    uuid4(),
                    now,
                )
                result["managed_account_id"] = managed_account_id
                result["managed_identity_id"] = managed_identity_id
            if ownership:
                ownership_account_id = uuid4()
                ownership_identity_id = uuid4()
                await connection.execute(
                    """
                    INSERT INTO ownership_accounts (
                        account_id,
                        auth_valid_after,
                        created_at,
                        updated_at
                    ) VALUES ($1, $2, $2, $2)
                    """,
                    ownership_account_id,
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
                        verified_at,
                        last_seen_at,
                        created_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, true, false, $6, $6, $6
                    )
                    """,
                    ownership_identity_id,
                    ownership_account_id,
                    claims.issuer,
                    claims.provider_tenant,
                    claims.subject_hash,
                    now,
                )
                result["ownership_account_id"] = ownership_account_id
                result["ownership_identity_id"] = ownership_identity_id
    return result


async def _seed_authority_state(
    primary: PostgresRepository,
    *,
    principal_id: UUID,
    managed_account_id: UUID,
    data_class: str,
) -> None:
    await primary._require_pool().execute(
        """
        INSERT INTO managed_authority_states (
            principal_id,
            managed_account_id,
            data_class
        ) VALUES ($1, $2, $3)
        """,
        principal_id,
        managed_account_id,
        data_class,
    )


@pytest.mark.asyncio
async def test_authority_get_is_read_only_and_unknown_classes_do_not_mutate(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"authority-scope-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    pool = primary._require_pool()
    before = await pool.fetchrow(
        """
        SELECT
            (
                SELECT count(*)
                FROM managed_authority_states
                WHERE managed_account_id = $1
            ) AS state_rows,
            (
                SELECT count(*)
                FROM managed_authority_transitions
                WHERE managed_account_id = $1
            ) AS transition_rows,
            (
                SELECT count(*)
                FROM managed_consent_events
                WHERE account_id = $1
            ) AS consent_rows
        """,
        principal.managed_account_id,
    )

    baseline = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class="essential_timeseries",
    )
    assert baseline.state == "local_only"
    assert baseline.transition_version == 0
    assert (
        await pool.fetchval(
            """
            SELECT count(*)
            FROM managed_authority_states
            WHERE managed_account_id = $1
            """,
            principal.managed_account_id,
        )
        == before["state_rows"]
    )

    unknown = "synthetic_unknown_class"
    with pytest.raises(AuthorityTransitionRejectedError):
        await repository.authority_state(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=unknown,
        )
    with pytest.raises(AuthorityTransitionRejectedError):
        await repository.request_rollback(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=unknown,
            request_id=uuid4(),
            opt_out=True,
        )
    with pytest.raises(AuthorityTransitionRejectedError):
        await repository.record_reconsent(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=unknown,
            request_id=uuid4(),
            policy_kind="managed_storage",
            policy_version="synthetic-v1",
            policy_sha256=POLICY_SHA256,
            installation_id="unused-test-installation",
        )

    after = await pool.fetchrow(
        """
        SELECT
            (
                SELECT count(*)
                FROM managed_authority_states
                WHERE managed_account_id = $1
            ) AS state_rows,
            (
                SELECT count(*)
                FROM managed_authority_transitions
                WHERE managed_account_id = $1
            ) AS transition_rows,
            (
                SELECT count(*)
                FROM managed_consent_events
                WHERE account_id = $1
            ) AS consent_rows
        """,
        principal.managed_account_id,
    )
    assert dict(after) == dict(before)


async def _seed_installation(
    primary: PostgresRepository,
    *,
    account_id: UUID,
    installation_id: str,
) -> None:
    now = datetime.now(UTC)
    token_hash = hashlib.sha256(
        f"authority:{installation_id}".encode("ascii")
    ).hexdigest()
    async with primary._require_pool().acquire() as connection:
        async with connection.transaction():
            await connection.execute(
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
                token_hash,
                now,
            )
            await connection.execute(
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
                account_id,
                installation_id,
                now,
            )


async def _advance_to_cloud_authority(
    repository: PostgresUnifiedIdentityAuthorityRepository,
    *,
    principal_id: UUID,
    managed_account_id: UUID,
    data_class: str,
    authorize_pruning: bool,
) -> tuple[AuthorityEvidence, AuthorityEvidence]:
    now = datetime.now(UTC)
    upload = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="a" * 64,
        recorded_at=now - timedelta(seconds=2),
    )
    restore = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="b" * 64,
        recorded_at=now - timedelta(seconds=1),
    )
    await repository.transition_authority(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="uploading",
        reason="migration_started",
    )
    await repository.transition_authority(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="shadow",
        reason="upload_acknowledged",
        upload_acknowledgement=upload,
    )
    await repository.transition_authority(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="parity_approved",
        reason="parity_approved",
    )
    await repository.transition_authority(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="restore_proven",
        reason="restore_proven",
        restore_proof=restore,
    )
    await repository.transition_authority(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="cloud_authoritative",
        reason="cloud_authority_enabled",
        authorize_pruning=authorize_pruning,
    )
    return upload, restore


@pytest.mark.asyncio
async def test_concurrent_reconciliation_creates_one_unified_root_and_links(
    authority_repository,
) -> None:
    repository, primary, events = authority_repository
    claims = _claims(f"concurrent-root-{uuid4()}", tenant="synthetic-tenant")
    seeded = await _seed_accounts(primary, claims)

    principals = await asyncio.gather(
        *(repository.reconcile_identity(claims) for _ in range(16))
    )

    assert len({principal.principal_id for principal in principals}) == 1
    principal = principals[0]
    assert principal.managed_account_id == seeded["managed_account_id"]
    assert principal.ownership_account_id == seeded["ownership_account_id"]
    pool = primary._require_pool()
    assert (
        await pool.fetchval(
            """
            SELECT count(*)
            FROM unified_account_principals
            WHERE issuer = $1
              AND provider_tenant = $2
              AND subject_hash = $3
            """,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
        )
        == 1
    )
    assert (
        await pool.fetchval(
            """
            SELECT count(*)
            FROM unified_managed_account_links
            WHERE principal_id = $1
            """,
            principal.principal_id,
        )
        == 1
    )
    assert (
        await pool.fetchval(
            """
            SELECT count(*)
            FROM unified_ownership_account_links
            WHERE principal_id = $1
            """,
            principal.principal_id,
        )
        == 1
    )

    rendered_events = repr(events)
    for forbidden in (
        claims.issuer,
        claims.provider_tenant,
        claims.subject_hash,
        str(principal.principal_id),
        str(seeded["managed_account_id"]),
        str(seeded["ownership_account_id"]),
    ):
        assert forbidden not in rendered_events


@pytest.mark.asyncio
async def test_managed_reconciliation_cannot_relink_after_erasure_starts(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"managed-erasure-link-race-{uuid4()}")
    seeded = await _seed_accounts(
        primary,
        claims,
        managed=True,
        ownership=False,
    )
    pool = primary._require_pool()
    async with pool.acquire() as blocker:
        async with blocker.transaction():
            await blocker.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                f"noop-managed-erasure-account:{seeded['managed_account_id']}",
            )
            reconcile_task = asyncio.create_task(repository.reconcile_identity(claims))
            await _wait_for_lock_waiters(pool, minimum=1)
            now = datetime.now(UTC)
            await blocker.execute(
                """
                UPDATE managed_accounts
                SET status = 'erasure_pending',
                    auth_valid_after = $2,
                    erasure_requested_at = $2,
                    updated_at = $2
                WHERE account_id = $1
                """,
                seeded["managed_account_id"],
                now,
            )

    with pytest.raises(
        UnifiedIdentityUnavailableError,
        match="managed account identity is unavailable",
    ):
        await asyncio.wait_for(reconcile_task, timeout=5)
    assert (
        await pool.fetchval(
            """
            SELECT count(*)
            FROM unified_managed_account_links
            WHERE managed_account_id = $1
            """,
            seeded["managed_account_id"],
        )
        == 0
    )


@pytest.mark.asyncio
async def test_link_guard_rejects_inactive_managed_identity_and_account(
    authority_repository,
) -> None:
    _, primary, _ = authority_repository
    claims = _claims(f"inactive-managed-link-{uuid4()}")
    seeded = await _seed_accounts(
        primary,
        claims,
        managed=True,
        ownership=False,
    )
    pool = primary._require_pool()
    principal_id = uuid4()
    now = datetime.now(UTC)
    await pool.execute(
        """
        INSERT INTO unified_account_principals (
            principal_id,
            issuer,
            provider_tenant,
            subject_hash,
            created_at,
            updated_at
        ) VALUES ($1, $2, $3, $4, $5, $5)
        """,
        principal_id,
        claims.issuer,
        claims.provider_tenant,
        claims.subject_hash,
        now,
    )
    await pool.execute(
        """
        UPDATE managed_accounts
        SET status = 'erasure_pending',
            auth_valid_after = $2,
            erasure_requested_at = $2,
            updated_at = $2
        WHERE account_id = $1
        """,
        seeded["managed_account_id"],
        now,
    )
    with pytest.raises(
        asyncpg.CheckViolationError,
        match="unavailable or mismatched",
    ):
        await pool.execute(
            """
            INSERT INTO unified_managed_account_links (
                principal_id,
                managed_account_id,
                managed_identity_id,
                issuer,
                provider_tenant,
                subject_hash
            ) VALUES ($1, $2, $3, $4, $5, $6)
            """,
            principal_id,
            seeded["managed_account_id"],
            seeded["managed_identity_id"],
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
        )


@pytest.mark.asyncio
async def test_link_guards_and_composite_fks_reject_mismatched_identity(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    root_claims = _claims(f"unlinked-root-{uuid4()}")
    principal = await repository.reconcile_identity(root_claims)
    first_claims = _claims(f"first-account-{uuid4()}")
    second_claims = _claims(f"second-account-{uuid4()}")
    first = await _seed_accounts(
        primary,
        first_claims,
        managed=True,
        ownership=False,
    )
    second = await _seed_accounts(
        primary,
        second_claims,
        managed=True,
        ownership=False,
    )
    pool = primary._require_pool()

    with pytest.raises(
        asyncpg.CheckViolationError,
        match="unavailable or mismatched",
    ):
        await pool.execute(
            """
            INSERT INTO unified_managed_account_links (
                principal_id,
                managed_account_id,
                managed_identity_id,
                issuer,
                provider_tenant,
                subject_hash
            ) VALUES ($1, $2, $3, $4, $5, $6)
            """,
            principal.principal_id,
            first["managed_account_id"],
            second["managed_identity_id"],
            root_claims.issuer,
            root_claims.provider_tenant,
            root_claims.subject_hash,
        )

    constraint_definition = await pool.fetchval(
        """
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conname = 'unified_managed_account_link_identity_fk'
        """
    )
    assert constraint_definition is not None
    assert (
        "FOREIGN KEY (managed_account_id, managed_identity_id)" in constraint_definition
    )
    assert (
        "REFERENCES managed_external_identities(account_id, identity_id)"
        in constraint_definition
    )

    with pytest.raises(
        asyncpg.CheckViolationError,
        match="unavailable or mismatched",
    ):
        await pool.execute(
            """
            INSERT INTO unified_managed_account_links (
                principal_id,
                managed_account_id,
                managed_identity_id,
                issuer,
                provider_tenant,
                subject_hash
            ) VALUES ($1, $2, $3, $4, $5, $6)
            """,
            principal.principal_id,
            first["managed_account_id"],
            first["managed_identity_id"],
            root_claims.issuer,
            root_claims.provider_tenant,
            root_claims.subject_hash,
        )


@pytest.mark.asyncio
async def test_authority_requires_ordered_ack_restore_and_explicit_pruning(
    authority_repository,
) -> None:
    repository, primary, events = authority_repository
    claims = _claims(f"authority-sequence-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "raw_motion"

    initial = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    assert initial.state == "local_only"
    assert initial.transition_version == 0
    assert initial.pruning_authorized is False
    with pytest.raises(AuthorityTransitionRejectedError):
        await repository.transition_authority(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=data_class,
            request_id=uuid4(),
            target_state="cloud_authoritative",
            reason="cloud_authority_enabled",
            authorize_pruning=True,
        )

    upload, restore = await _advance_to_cloud_authority(
        repository,
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        authorize_pruning=True,
    )
    state = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    assert state.state == "cloud_authoritative"
    assert state.transition_version == 5
    assert state.upload_acknowledgement_id == upload.evidence_id
    assert state.restore_proof_id == restore.evidence_id
    assert state.pruning_authorized is True
    assert await repository.pruning_authorized(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    assert (
        await primary._require_pool().fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1 AND data_class = $2
            """,
            principal.managed_account_id,
            data_class,
        )
        == 5
    )
    rendered_events = repr(events)
    assert data_class not in rendered_events
    assert str(upload.evidence_id) not in rendered_events
    assert str(restore.evidence_id) not in rendered_events


@pytest.mark.asyncio
async def test_concurrent_transition_replay_is_idempotent_and_conflict_safe(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"authority-idempotency-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "essential_timeseries"
    await repository.transition_authority(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="uploading",
        reason="migration_started",
    )
    request_id = uuid4()
    upload = AuthorityEvidence(
        evidence_id=uuid4(),
        receipt_sha256="c" * 64,
        recorded_at=datetime.now(UTC) - timedelta(seconds=1),
    )

    results = await asyncio.gather(
        *(
            repository.transition_authority(
                principal_id=principal.principal_id,
                managed_account_id=principal.managed_account_id,
                data_class=data_class,
                request_id=request_id,
                target_state="shadow",
                reason="upload_acknowledged",
                upload_acknowledgement=upload,
            )
            for _ in range(12)
        )
    )
    assert len({result.transition_id for result in results}) == 1
    assert sum(result.duplicate for result in results) == 11
    assert (
        await primary._require_pool().fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1
              AND data_class = $2
              AND request_id = $3
            """,
            principal.managed_account_id,
            data_class,
            request_id,
        )
        == 1
    )
    with pytest.raises(AuthorityTransitionConflictError):
        await repository.transition_authority(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=data_class,
            request_id=request_id,
            target_state="parity_approved",
            reason="parity_approved",
        )


@pytest.mark.asyncio
async def test_database_guard_rejects_direct_state_skip(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"database-guard-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "derived_summaries"
    await _seed_authority_state(
        primary,
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    now = datetime.now(UTC)
    transition_id = uuid4()
    pool = primary._require_pool()

    with pytest.raises(asyncpg.CheckViolationError, match="not allowed"):
        async with pool.acquire() as connection:
            async with connection.transaction():
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
                        upload_acknowledgement_id,
                        upload_acknowledgement_sha256,
                        upload_acknowledged_at,
                        restore_proof_id,
                        restore_proof_sha256,
                        restore_proven_at,
                        pruning_authorized_at,
                        occurred_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, 1,
                        'local_only', 'cloud_authoritative',
                        'cloud_authority_enabled',
                        $7, $8, $9, $10, $11, $9, $9, $9
                    )
                    """,
                    transition_id,
                    principal.principal_id,
                    principal.managed_account_id,
                    data_class,
                    uuid4(),
                    "d" * 64,
                    uuid4(),
                    "e" * 64,
                    now,
                    uuid4(),
                    "f" * 64,
                )
                await connection.execute(
                    """
                    UPDATE managed_authority_states
                    SET state = 'cloud_authoritative',
                        transition_version = 1,
                        last_transition_id = $4,
                        upload_acknowledgement_id = $5,
                        upload_acknowledgement_sha256 = $6,
                        upload_acknowledged_at = $7,
                        restore_proof_id = $8,
                        restore_proof_sha256 = $9,
                        restore_proven_at = $7,
                        pruning_authorized_at = $7,
                        updated_at = $7
                    WHERE principal_id = $1
                      AND managed_account_id = $2
                      AND data_class = $3
                    """,
                    principal.principal_id,
                    principal.managed_account_id,
                    data_class,
                    transition_id,
                    uuid4(),
                    "e" * 64,
                    now,
                    uuid4(),
                    "f" * 64,
                )

    state = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    assert state.state == "local_only"
    assert state.transition_version == 0


@pytest.mark.asyncio
async def test_database_guard_rejects_direct_cloud_authority_insert(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"direct-cloud-insert-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    now = datetime.now(UTC)

    with pytest.raises(asyncpg.CheckViolationError, match="ledger baseline"):
        await primary._require_pool().execute(
            """
            INSERT INTO managed_authority_states (
                principal_id,
                managed_account_id,
                data_class,
                state,
                transition_version,
                last_transition_id,
                upload_acknowledgement_id,
                upload_acknowledgement_sha256,
                upload_acknowledged_at,
                restore_proof_id,
                restore_proof_sha256,
                restore_proven_at,
                pruning_authorized_at,
                created_at,
                updated_at
            ) VALUES (
                $1, $2, 'raw_motion', 'cloud_authoritative', 5, $3,
                $4, $5, $6, $7, $8, $6, $6, $6, $6
            )
            """,
            principal.principal_id,
            principal.managed_account_id,
            uuid4(),
            uuid4(),
            "a" * 64,
            now,
            uuid4(),
            "b" * 64,
        )

    assert (
        await primary._require_pool().fetchval(
            """
            SELECT count(*)
            FROM managed_authority_states
            WHERE managed_account_id = $1 AND data_class = 'raw_motion'
            """,
            principal.managed_account_id,
        )
        == 0
    )


@pytest.mark.asyncio
async def test_database_guard_rejects_unapplied_ledger_event(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"unapplied-event-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "raw_motion"
    await _seed_authority_state(
        primary,
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )

    with pytest.raises(asyncpg.CheckViolationError, match="was not applied"):
        async with primary._require_pool().acquire() as connection:
            async with connection.transaction():
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
                        reason
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, 1,
                        'local_only', 'uploading', 'migration_started'
                    )
                    """,
                    uuid4(),
                    principal.principal_id,
                    principal.managed_account_id,
                    data_class,
                    uuid4(),
                    "9" * 64,
                )

    assert (
        await primary._require_pool().fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1 AND data_class = $2
            """,
            principal.managed_account_id,
            data_class,
        )
        == 0
    )


@pytest.mark.asyncio
async def test_opt_out_rollback_revokes_pruning_and_restores_local_authority(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"authority-opt-out-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "raw_ppg"
    await _advance_to_cloud_authority(
        repository,
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        authorize_pruning=True,
    )


@pytest.mark.asyncio
async def test_opt_out_is_ledgered_while_local_and_blocks_repromotion(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"authority-local-opt-out-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "essential_timeseries"
    installation_id = f"ios-authority-{uuid4().hex}"
    await _seed_installation(
        primary,
        account_id=principal.managed_account_id,
        installation_id=installation_id,
    )
    first_request_id = uuid4()

    first = await repository.request_rollback(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=first_request_id,
        opt_out=True,
    )
    replay = await repository.request_rollback(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=first_request_id,
        opt_out=True,
    )
    second = await repository.request_rollback(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        opt_out=True,
    )
    blocked = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )

    assert first.state == "rollback"
    assert first.transition_version == 1
    assert replay.duplicate is True
    assert replay.transition_id == first.transition_id
    assert second.state == "rollback"
    assert second.transition_version == 2
    assert blocked.last_opt_out_at is not None
    assert blocked.last_reconsented_at is None
    with pytest.raises(AuthorityTransitionRejectedError, match="re-consent"):
        await repository.transition_authority(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=data_class,
            request_id=uuid4(),
            target_state="uploading",
            reason="migration_started",
        )

    reconsented = await repository.record_reconsent(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        policy_kind="managed_storage",
        policy_version="synthetic-v1",
        policy_sha256=POLICY_SHA256,
        installation_id=installation_id,
    )
    promoted = await repository.transition_authority(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        target_state="uploading",
        reason="migration_started",
    )
    allowed = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )

    assert reconsented.state == "local_only"
    assert promoted.state == "uploading"
    assert allowed.last_reconsented_at is not None
    assert allowed.last_reconsented_at > allowed.last_opt_out_at
    assert allowed.reconsent_consent_event_id is not None
    assert allowed.reconsent_policy_version == "synthetic-v1"
    assert allowed.reconsent_policy_sha256 == POLICY_SHA256
    consent = await primary._require_pool().fetchrow(
        """
        SELECT consent_event_id,
               policy_kind,
               policy_version,
               decision,
               data_classes,
               installation_id
        FROM managed_consent_events
        WHERE account_id = $1
          AND consent_event_id = $2
        """,
        principal.managed_account_id,
        allowed.reconsent_consent_event_id,
    )
    assert consent is not None
    assert consent["policy_kind"] == "managed_storage"
    assert consent["policy_version"] == "synthetic-v1"
    assert consent["decision"] == "granted"
    assert list(consent["data_classes"]) == [data_class]
    assert consent["installation_id"] == installation_id
    assert (
        await primary._require_pool().fetchval(
            """
            SELECT count(*)
            FROM managed_authority_transitions
            WHERE managed_account_id = $1
              AND data_class = $2
              AND reason = 'opt_out_requested'
            """,
            principal.managed_account_id,
            data_class,
        )
        == 2
    )


@pytest.mark.asyncio
async def test_database_guard_blocks_direct_repromotion_after_opt_out(
    authority_repository,
) -> None:
    repository, primary, _ = authority_repository
    claims = _claims(f"authority-direct-repromotion-{uuid4()}")
    await _seed_accounts(primary, claims, ownership=False)
    principal = await repository.reconcile_identity(claims)
    assert principal.managed_account_id is not None
    data_class = "raw_ppg"
    await repository.request_rollback(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        opt_out=True,
    )
    state = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    transition_id = uuid4()
    now = datetime.now(UTC)

    with pytest.raises(asyncpg.CheckViolationError, match="re-consent"):
        async with primary._require_pool().acquire() as connection:
            async with connection.transaction():
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
                        last_opt_out_at,
                        occurred_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7,
                        'rollback', 'uploading', 'migration_started', $8, $9
                    )
                    """,
                    transition_id,
                    principal.principal_id,
                    principal.managed_account_id,
                    data_class,
                    uuid4(),
                    "d" * 64,
                    state.transition_version + 1,
                    state.last_opt_out_at,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_authority_states
                    SET state = 'uploading',
                        transition_version = $4,
                        last_transition_id = $5,
                        updated_at = $6
                    WHERE principal_id = $1
                      AND managed_account_id = $2
                      AND data_class = $3
                    """,
                    principal.principal_id,
                    principal.managed_account_id,
                    data_class,
                    state.transition_version + 1,
                    transition_id,
                    now,
                )

    rollback = await repository.request_rollback(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
        opt_out=True,
    )
    assert rollback.state == "rollback"
    assert rollback.pruning_authorized is False
    rollback_state = await repository.authority_state(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
    )
    assert rollback_state.upload_acknowledgement_id is None
    assert rollback_state.restore_proof_id is None
    assert rollback_state.pruning_authorized_at is None
    assert rollback_state.last_opt_out_at is not None

    restored = await repository.restore_local_authority(
        principal_id=principal.principal_id,
        managed_account_id=principal.managed_account_id,
        data_class=data_class,
        request_id=uuid4(),
    )
    assert restored.state == "local_only"
    assert (
        await repository.pruning_authorized(
            principal_id=principal.principal_id,
            managed_account_id=principal.managed_account_id,
            data_class=data_class,
        )
        is False
    )
