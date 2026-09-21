from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app.managed_document_keys import (
    ManagedDocumentKeyAccountUnavailableError,
    ManagedWrappedKeyMutation,
    PostgresManagedDocumentKeyRepository,
)
from app.managed_formula_executor import (
    ClientFormulaObservation,
    FormulaDayContext,
    FormulaProvenance,
    ManagedFormulaExecutor,
)
from app.managed_formula_registry import CANONICAL_FORMULA_REGISTRY
from app.managed_formula_repository import PostgresManagedFormulaRepository
from app.managed_formula_repository import (
    FormulaShadowAccountUnavailableError,
)
from app.managed_identity import ManagedIdentityClaims
from app.managed_models import (
    ManagedAccountEnrollment,
    ManagedEnrollment,
    ManagedSocialProfileCreate,
)
from app.managed_repository import PostgresManagedRepository
from app.managed_repository import ManagedNotFoundError
from app.repository import PostgresRepository
from app.unified_identity_authority import (
    PostgresUnifiedIdentityAuthorityRepository,
)

SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = SERVER_ROOT / "migrations"
DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL")
DATABASE_ENGINE = "postgresql"
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"
IMMUTABLE_MIGRATION_SHA256 = {
    "048_managed_authority_state.sql": (
        "8c5b568691d9af3143e9e1965686a182d48918b26539dc8bbbf32f555005c666"
    ),
    "049_managed_formula_shadow.sql": (
        "e11c5c2836ee2b88abc5c63f91dab0447448509e362895fba21fa724d6b31922"
    ),
}


def test_account_erasure_support_is_additive_to_immutable_migrations() -> None:
    for name, expected_sha256 in IMMUTABLE_MIGRATION_SHA256.items():
        assert hashlib.sha256((MIGRATIONS / name).read_bytes()).hexdigest() == (
            expected_sha256
        )

    reconsent_sql = (MIGRATIONS / "051_managed_authority_reconsent.sql").read_text(
        encoding="utf-8"
    )
    erasure_sql = (MIGRATIONS / "052_managed_account_cloud_erasure.sql").read_text(
        encoding="utf-8"
    )
    derived_erasure_sql = (
        MIGRATIONS / "057_managed_formula_shadow_derived_erasure.sql"
    ).read_text(encoding="utf-8")
    assert "ADD COLUMN last_reconsented_at" in reconsent_sql
    assert "managed_formula_shadow_immutable" in reconsent_sql
    assert "managed_account_cloud_erasure_tombstones" in erasure_sql
    assert "noop_erase_managed_account_cloud_state" in erasure_sql
    assert "noop_managed_account_erasure_context" in erasure_sql
    assert "job.status = 'verifying'" in erasure_sql
    assert "account.status = 'erasure_pending'" in erasure_sql
    assert "DELETE FROM managed_document_key_versions" in erasure_sql
    assert "DELETE FROM managed_document_keys" in erasure_sql
    assert "managed_erasure_job_account_job_unique" in erasure_sql
    assert "FOREIGN KEY (account_id, erasure_job_id)" in erasure_sql
    assert "status = 'retired'" in erasure_sql
    assert "noop_managed_formula_shadow_erasure_context" in derived_erasure_sql
    assert "job.scope = 'derived_data'" in derived_erasure_sql
    assert "account.status = 'active'" in derived_erasure_sql
    assert "job.scope IN ('all_managed_data', 'account')" in derived_erasure_sql
    assert "noop_managed_formula_shadow_delete_guard" in derived_erasure_sql


def _primary() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=6,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )


def _managed(primary: PostgresRepository) -> PostgresManagedRepository:
    return PostgresManagedRepository(
        primary,
        home_region="asia-south1",
        residency_policy_version="synthetic-v1",
        default_plan_code="noop_plus_staging",
        default_plan_revision=1,
        consent_policy_kind="managed_storage",
        entitlement_mode="open_beta",
        replay_secret="test-managed-replay-secret-at-least-32-bytes",
    )


def _claims(label: str, now: datetime) -> ManagedIdentityClaims:
    return ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject=label,
        provider_tenant="noop-staging",
        issued_at=now,
        auth_time=now - timedelta(minutes=1),
        expires_at=now + timedelta(hours=1),
    )


def _installation_token(installation_id: str) -> str:
    encoded = (
        base64.urlsafe_b64encode(
            hashlib.sha256(installation_id.encode("utf-8")).digest()
        )
        .decode("ascii")
        .rstrip("=")
    )
    return f"noopm_{encoded}"


def _enrollment(installation_id: str) -> ManagedEnrollment:
    return ManagedEnrollment(
        installation_id=installation_id,
        platform="ios",
        installation_token=_installation_token(installation_id),
        enrollment_request_id=uuid4(),
        policy_version="synthetic-v1",
        policy_sha256=POLICY_SHA256,
        data_classes=[
            "essential_timeseries",
            "encrypted_backup",
            "raw_motion",
            "user_documents",
        ],
    )


def _account_enrollment(installation_id: str) -> ManagedAccountEnrollment:
    return ManagedAccountEnrollment(
        installation_id=installation_id,
        platform="ios",
        installation_token=_installation_token(installation_id),
        enrollment_request_id=uuid4(),
    )


def _wrapped_key(
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


def _formula_execution(account_id: UUID):
    executor = ManagedFormulaExecutor(CANONICAL_FORMULA_REGISTRY)
    context = FormulaDayContext.create(
        account_id=account_id,
        local_day=date(2026, 9, 19),
        timezone_name="America/Chicago",
    )
    provenance = FormulaProvenance(
        source_kind="synthetic_test",
        source_revision="erasure-v1",
        input_manifest_sha256="d" * 64,
        calibration_revision="baseline-v1",
    )
    inputs = {
        "hrv": 52.0,
        "rhr": 55.0,
        "hrv_baseline": {
            "mean": 50.0,
            "spread": 5.0,
            "usable": True,
        },
    }
    local = executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs=inputs,
        provenance=provenance,
    )
    return executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs=inputs,
        provenance=provenance,
        client_observation=ClientFormulaObservation(
            status="present",
            formula_revision="noop-charge-v2",
            value=local.server_value,
        ),
    )


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_account_only_friends_erasure_requires_no_storage_consent() -> None:
    primary = _primary()
    await primary.startup()
    try:
        managed = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"account-only-erasure-{uuid4()}", now)
        installation_id = str(uuid4())
        installation_token_hash = hashlib.sha256(
            _installation_token(installation_id).encode("ascii")
        ).hexdigest()
        await managed.enroll_account(
            claims=claims,
            enrollment=_account_enrollment(installation_id),
        )
        principal = await managed.principal_for_identity(claims)
        social_profile = await managed.create_social_profile(
            principal=principal,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Synthetic account erasure",
            ),
        )
        pool = primary._require_pool()

        storage_state = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_subscriptions
                    WHERE account_id = $1
                ) AS subscriptions,
                (
                    SELECT count(*)
                    FROM managed_consent_events
                    WHERE account_id = $1
                ) AS consent_events,
                (
                    SELECT count(*)
                    FROM managed_retention_policy_snapshots
                    WHERE account_id = $1
                ) AS retention_snapshots,
                (
                    SELECT count(*)
                    FROM managed_account_installations
                    WHERE account_id = $1
                ) AS installations,
                (
                    SELECT count(*)
                    FROM managed_social_profiles
                    WHERE account_id = $1
                ) AS social_profiles,
                (
                    SELECT count(*)
                    FROM managed_social_aliases
                    WHERE profile_id = $2
                ) AS social_aliases
            """,
            principal.account_id,
            UUID(social_profile["profile_id"]),
        )
        assert dict(storage_state) == {
            "subscriptions": 0,
            "consent_events": 0,
            "retention_snapshots": 0,
            "installations": 1,
            "social_profiles": 1,
            "social_aliases": 1,
        }

        requested = await managed.request_erasure(
            principal=principal,
            request_id=uuid4(),
            scope="account",
            confirmation_sha256="a" * 64,
            identity_deletion_ticket=b"t" * 64,
            cooling_off=timedelta(0),
        )
        erasure_job_id = UUID(requested["erasure_job_id"])
        receipt, receipt_platform = await managed.get_erasure_receipt(
            erasure_job_id=erasure_job_id,
            installation_id=installation_id,
            installation_token_hash=installation_token_hash,
        )
        assert receipt["status"] == "cooling_off"
        assert receipt_platform == "ios"

        lifecycle_now = await managed.coordination_now()
        await managed.claim_erasure_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert (
            await managed.finalize_erasure_jobs(
                now=lifecycle_now,
                batch_size=10,
            )
            == []
        )

        tombstone = await pool.fetchrow(
            """
            SELECT authority_state_rows,
                   authority_transition_rows,
                   formula_shadow_rows,
                   document_key_rows,
                   document_key_version_rows,
                   managed_identity_link_rows
            FROM managed_account_cloud_erasure_tombstones
            WHERE account_id = $1
              AND erasure_job_id = $2
            """,
            principal.account_id,
            erasure_job_id,
        )
        assert tombstone is not None
        assert all(int(value or 0) == 0 for value in tombstone.values())

        finished = await managed.mark_identity_deletion_succeeded(
            account_id=principal.account_id,
            erasure_job_id=erasure_job_id,
            now=lifecycle_now,
        )
        assert finished["status"] == "completed"
        completed_receipt, completed_platform = await managed.get_erasure_receipt(
            erasure_job_id=erasure_job_id,
            installation_id=installation_id,
            installation_token_hash=installation_token_hash,
        )
        assert completed_receipt["status"] == "completed"
        assert completed_platform == "ios"
        erased_state = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_external_identities
                    WHERE account_id = $1
                ) AS identities,
                (
                    SELECT count(*)
                    FROM managed_social_profiles
                    WHERE account_id = $1
                ) AS social_profiles,
                (
                    SELECT count(*)
                    FROM managed_social_aliases
                    WHERE profile_id = $2
                ) AS social_aliases
            """,
            principal.account_id,
            UUID(social_profile["profile_id"]),
        )
        assert dict(erased_state) == {
            "identities": 0,
            "social_profiles": 0,
            "social_aliases": 0,
        }
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_derived_data_erasure_removes_formula_shadow_only() -> None:
    primary = _primary()
    await primary.startup()
    try:
        managed = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"derived-formula-erasure-{uuid4()}", now)
        installation_id = str(uuid4())
        await managed.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id),
        )
        principal = await managed.principal_for_identity(claims)
        formula_repository = PostgresManagedFormulaRepository(primary)
        await formula_repository.publish_shadow(
            principal=principal,
            request_id=uuid4(),
            execution=_formula_execution(principal.account_id),
            now=now,
        )
        requested = await managed.request_erasure(
            principal=principal,
            request_id=uuid4(),
            scope="derived_data",
            confirmation_sha256="d" * 64,
            identity_deletion_ticket=None,
            cooling_off=timedelta(0),
        )
        job_id = UUID(requested["erasure_job_id"])
        lifecycle_now = await managed.coordination_now()
        assert (
            await managed.claim_erasure_deletions(
                now=lifecycle_now,
                batch_size=10,
            )
            == []
        )
        completed = await managed.finalize_erasure_jobs(
            now=lifecycle_now,
            batch_size=10,
        )
        assert [row["erasure_job_id"] for row in completed] == [job_id]

        pool = primary._require_pool()
        state = await pool.fetchrow(
            """
            SELECT account.status AS account_status,
                   job.status AS job_status,
                   (
                       SELECT count(*)
                       FROM managed_formula_shadow_results
                       WHERE account_id = account.account_id
                   ) AS formula_rows
            FROM managed_accounts account
            JOIN managed_erasure_jobs job USING (account_id)
            WHERE account.account_id = $1
              AND job.erasure_job_id = $2
            """,
            principal.account_id,
            job_id,
        )
        assert state["account_status"] == "active"
        assert state["job_status"] == "completed"
        assert int(state["formula_rows"]) == 0
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_account_erasure_removes_reconsent_formula_and_wrapped_keys() -> None:
    primary = _primary()
    await primary.startup()
    try:
        managed = _managed(primary)
        started_at = datetime.now(UTC)
        claims = _claims(f"cloud-erasure-{uuid4()}", started_at)
        installation_id = str(uuid4())
        await managed.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id),
        )
        principal = await managed.principal_for_identity(claims)

        authority = PostgresUnifiedIdentityAuthorityRepository(primary)
        unified = await authority.reconcile_identity(claims)
        assert unified.managed_account_id == principal.account_id
        data_class = "raw_motion"
        await authority.request_rollback(
            principal_id=unified.principal_id,
            managed_account_id=principal.account_id,
            data_class=data_class,
            request_id=uuid4(),
            opt_out=True,
        )
        await authority.restore_local_authority(
            principal_id=unified.principal_id,
            managed_account_id=principal.account_id,
            data_class=data_class,
            request_id=uuid4(),
        )
        reconsented = await authority.record_reconsent(
            principal_id=unified.principal_id,
            managed_account_id=principal.account_id,
            data_class=data_class,
            request_id=uuid4(),
            policy_kind="managed_storage",
            policy_version="synthetic-v1",
            policy_sha256=POLICY_SHA256,
            installation_id=installation_id,
        )
        assert reconsented.state == "local_only"

        formula_repository = PostgresManagedFormulaRepository(primary)
        formula = await formula_repository.publish_shadow(
            principal=principal,
            request_id=uuid4(),
            execution=_formula_execution(principal.account_id),
            now=datetime.now(UTC),
        )
        assert formula.server_value is not None

        key_repository = PostgresManagedDocumentKeyRepository(
            primary,
            enabled=True,
        )
        master_key_id = uuid4()
        document_key_id = uuid4()
        await key_repository.put(
            principal=principal,
            mutation=_wrapped_key(
                key_id=master_key_id,
                key_kind="account_master",
                wrapped=b"a" * 72,
            ),
        )
        await key_repository.put(
            principal=principal,
            mutation=_wrapped_key(
                key_id=document_key_id,
                key_kind="document",
                wrapping_key_id=master_key_id,
                wrapped=b"b" * 72,
            ),
        )
        await key_repository.rotate_wrapping(
            principal=principal,
            mutation=_wrapped_key(
                key_id=document_key_id,
                key_kind="document",
                wrapping_key_id=master_key_id,
                wrapping_revision=2,
                wrapped=b"c" * 72,
            ),
            expected_wrapping_revision=1,
        )

        pool = primary._require_pool()
        before = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_authority_transitions
                    WHERE managed_account_id = $1
                ) AS authority_transitions,
                (
                    SELECT count(*)
                    FROM managed_formula_shadow_results
                    WHERE account_id = $1
                      AND server_value IS NOT NULL
                ) AS formula_values,
                (
                    SELECT count(*)
                    FROM managed_document_keys
                    WHERE account_id = $1
                ) AS current_keys,
                (
                    SELECT count(*)
                    FROM managed_document_key_versions
                    WHERE account_id = $1
                ) AS key_versions
            """,
            principal.account_id,
        )
        assert int(before["authority_transitions"]) == 3
        assert int(before["formula_values"]) == 1
        assert int(before["current_keys"]) == 2
        assert int(before["key_versions"]) == 3

        requested = await managed.request_erasure(
            principal=principal,
            request_id=uuid4(),
            scope="account",
            confirmation_sha256="a" * 64,
            identity_deletion_ticket=b"t" * 64,
            cooling_off=timedelta(0),
        )
        erasure_job_id = UUID(requested["erasure_job_id"])
        installation_token_hash = hashlib.sha256(
            _installation_token(installation_id).encode("ascii")
        ).hexdigest()
        receipt, receipt_platform = await managed.get_erasure_receipt(
            erasure_job_id=erasure_job_id,
            installation_id=installation_id,
            installation_token_hash=installation_token_hash,
        )
        assert receipt["status"] == "cooling_off"
        assert receipt_platform == "ios"
        lifecycle_now = await managed.coordination_now()
        await managed.claim_erasure_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert (
            await managed.finalize_erasure_jobs(
                now=lifecycle_now,
                batch_size=10,
            )
            == []
        )

        tombstone = await pool.fetchrow(
            """
            SELECT *
            FROM managed_account_cloud_erasure_tombstones
            WHERE account_id = $1 AND erasure_job_id = $2
            """,
            principal.account_id,
            erasure_job_id,
        )
        assert tombstone is not None
        assert int(tombstone["authority_state_rows"]) == 1
        assert int(tombstone["authority_transition_rows"]) == 3
        assert int(tombstone["formula_shadow_rows"]) == 1
        assert int(tombstone["document_key_rows"]) == 2
        assert int(tombstone["document_key_version_rows"]) == 3
        assert int(tombstone["managed_identity_link_rows"]) == 1
        assert (
            await pool.fetchval(
                """
                SELECT status
                FROM unified_account_principals
                WHERE principal_id = $1
                """,
                unified.principal_id,
            )
            == "retired"
        )

        erased = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_authority_states
                    WHERE managed_account_id = $1
                ) AS authority_states,
                (
                    SELECT count(*)
                    FROM managed_authority_transitions
                    WHERE managed_account_id = $1
                ) AS authority_transitions,
                (
                    SELECT count(*)
                    FROM managed_formula_shadow_results
                    WHERE account_id = $1
                ) AS formula_rows,
                (
                    SELECT count(server_value) + count(client_value)
                    FROM managed_formula_shadow_results
                    WHERE account_id = $1
                ) AS formula_values,
                (
                    SELECT COALESCE(sum(octet_length(wrapped_key)), 0)
                    FROM managed_document_keys
                    WHERE account_id = $1
                ) AS current_key_bytes,
                (
                    SELECT COALESCE(sum(octet_length(wrapped_key)), 0)
                    FROM managed_document_key_versions
                    WHERE account_id = $1
                ) AS historical_key_bytes,
                (
                    SELECT count(*)
                    FROM managed_consent_events
                    WHERE account_id = $1
                ) AS consent_rows,
                (
                    SELECT count(*)
                    FROM unified_managed_account_links
                    WHERE managed_account_id = $1
                ) AS managed_links
            """,
            principal.account_id,
        )
        assert all(int(value or 0) == 0 for value in erased.values())

        finished = await managed.mark_identity_deletion_succeeded(
            account_id=principal.account_id,
            erasure_job_id=erasure_job_id,
            now=lifecycle_now,
        )
        assert finished["status"] == "completed"
        completed_receipt, completed_platform = await managed.get_erasure_receipt(
            erasure_job_id=erasure_job_id,
            installation_id=installation_id,
            installation_token_hash=installation_token_hash,
        )
        assert completed_receipt["status"] == "completed"
        assert completed_platform == "ios"
        await pool.execute(
            """
            UPDATE managed_erasure_jobs
            SET verification_expires_at = requested_at + interval '1 microsecond'
            WHERE erasure_job_id = $1
            """,
            erasure_job_id,
        )
        with pytest.raises(ManagedNotFoundError):
            await managed.get_erasure_receipt(
                erasure_job_id=erasure_job_id,
                installation_id=installation_id,
                installation_token_hash=installation_token_hash,
            )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_external_identities
                WHERE account_id = $1
                """,
                principal.account_id,
            )
            == 0
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_all_managed_data_erasure_removes_payloads_and_preserves_account() -> (
    None
):
    primary = _primary()
    await primary.startup()
    try:
        managed = _managed(primary)
        started_at = datetime.now(UTC)
        identity_label = f"all-data-erasure-{uuid4()}"
        claims = _claims(identity_label, started_at)
        installation_id = str(uuid4())
        await managed.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id),
        )
        principal = await managed.principal_for_identity(claims)

        authority = PostgresUnifiedIdentityAuthorityRepository(primary)
        unified = await authority.reconcile_identity(claims)
        assert unified.managed_account_id == principal.account_id
        await authority.request_rollback(
            principal_id=unified.principal_id,
            managed_account_id=principal.account_id,
            data_class="raw_motion",
            request_id=uuid4(),
            opt_out=True,
        )

        formula_repository = PostgresManagedFormulaRepository(primary)
        await formula_repository.publish_shadow(
            principal=principal,
            request_id=uuid4(),
            execution=_formula_execution(principal.account_id),
            now=datetime.now(UTC),
        )

        key_repository = PostgresManagedDocumentKeyRepository(
            primary,
            enabled=True,
        )
        master_key_id = uuid4()
        await key_repository.put(
            principal=principal,
            mutation=_wrapped_key(
                key_id=master_key_id,
                key_kind="account_master",
                wrapped=b"a" * 72,
            ),
        )

        pool = primary._require_pool()
        before = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM unified_managed_account_links
                    WHERE managed_account_id = $1
                ) AS managed_links,
                (
                    SELECT count(*)
                    FROM managed_consent_events
                    WHERE account_id = $1
                ) AS consent_rows
            """,
            principal.account_id,
        )
        assert int(before["managed_links"]) == 1
        assert int(before["consent_rows"]) > 0

        requested = await managed.request_erasure(
            principal=principal,
            request_id=uuid4(),
            scope="all_managed_data",
            confirmation_sha256="b" * 64,
            identity_deletion_ticket=None,
            cooling_off=timedelta(0),
        )
        first_job_id = UUID(requested["erasure_job_id"])
        lifecycle_now = await managed.coordination_now()
        await managed.claim_erasure_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        completed = await managed.finalize_erasure_jobs(
            now=lifecycle_now,
            batch_size=10,
        )
        assert [row["erasure_job_id"] for row in completed] == [first_job_id]

        after = await pool.fetchrow(
            """
            SELECT
                account.status,
                account.auth_valid_after,
                (
                    SELECT count(*)
                    FROM managed_external_identities
                    WHERE account_id = account.account_id
                      AND status = 'active'
                ) AS active_identities,
                (
                    SELECT count(*)
                    FROM unified_managed_account_links
                    WHERE managed_account_id = account.account_id
                ) AS managed_links,
                (
                    SELECT count(*)
                    FROM managed_consent_events
                    WHERE account_id = account.account_id
                ) AS consent_rows,
                (
                    SELECT count(*)
                    FROM managed_authority_states
                    WHERE managed_account_id = account.account_id
                ) AS authority_states,
                (
                    SELECT count(*)
                    FROM managed_authority_transitions
                    WHERE managed_account_id = account.account_id
                ) AS authority_transitions,
                (
                    SELECT count(*)
                    FROM managed_formula_shadow_results
                    WHERE account_id = account.account_id
                ) AS formula_rows,
                (
                    SELECT COALESCE(sum(octet_length(wrapped_key)), 0)
                    FROM managed_document_keys
                    WHERE account_id = account.account_id
                ) AS current_key_bytes,
                (
                    SELECT COALESCE(sum(octet_length(wrapped_key)), 0)
                    FROM managed_document_key_versions
                    WHERE account_id = account.account_id
                ) AS historical_key_bytes
            FROM managed_accounts AS account
            WHERE account.account_id = $1
            """,
            principal.account_id,
        )
        assert after["status"] == "active"
        assert after["auth_valid_after"] >= lifecycle_now
        assert int(after["active_identities"]) == 1
        assert int(after["managed_links"]) == 1
        assert int(after["consent_rows"]) == int(before["consent_rows"])
        assert int(after["authority_states"]) == 0
        assert int(after["authority_transitions"]) == 0
        assert int(after["formula_rows"]) == 0
        assert int(after["current_key_bytes"]) == 0
        assert int(after["historical_key_bytes"]) == 0

        tombstone = await pool.fetchrow(
            """
            SELECT *
            FROM managed_account_cloud_erasure_tombstones
            WHERE account_id = $1 AND erasure_job_id = $2
            """,
            principal.account_id,
            first_job_id,
        )
        assert tombstone is not None
        assert tombstone["erasure_scope"] == "all_managed_data"
        assert int(tombstone["managed_identity_link_rows"]) == 0

        with pytest.raises(FormulaShadowAccountUnavailableError):
            await formula_repository.publish_shadow(
                principal=principal,
                request_id=uuid4(),
                execution=_formula_execution(principal.account_id),
                now=datetime.now(UTC),
            )
        with pytest.raises(ManagedDocumentKeyAccountUnavailableError):
            await key_repository.put(
                principal=principal,
                mutation=_wrapped_key(
                    key_id=uuid4(),
                    key_kind="account_master",
                    wrapped=b"b" * 72,
                ),
            )

        refreshed_claims = _claims(
            identity_label,
            lifecycle_now + timedelta(minutes=2),
        )
        refreshed_principal = await managed.principal_for_identity(refreshed_claims)
        repeated = await managed.request_erasure(
            principal=refreshed_principal,
            request_id=uuid4(),
            scope="all_managed_data",
            confirmation_sha256="c" * 64,
            identity_deletion_ticket=None,
            cooling_off=timedelta(0),
        )
        second_job_id = UUID(repeated["erasure_job_id"])
        second_now = await managed.coordination_now()
        await managed.claim_erasure_deletions(
            now=second_now,
            batch_size=10,
        )
        second_completed = await managed.finalize_erasure_jobs(
            now=second_now,
            batch_size=10,
        )
        assert [row["erasure_job_id"] for row in second_completed] == [second_job_id]
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_account_cloud_erasure_tombstones
                WHERE account_id = $1
                  AND erasure_scope = 'all_managed_data'
                """,
                principal.account_id,
            )
            == 2
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_erasure_account_fence_serializes_formula_and_key_writes() -> None:
    primary = _primary()
    await primary.startup()
    try:
        managed = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"erasure-fence-{uuid4()}", now)
        await managed.enroll(
            claims=claims,
            enrollment=_enrollment(str(uuid4())),
        )
        principal = await managed.principal_for_identity(claims)
        formula_repository = PostgresManagedFormulaRepository(primary)
        key_repository = PostgresManagedDocumentKeyRepository(
            primary,
            enabled=True,
        )
        pool = primary._require_pool()

        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-erasure-account:{principal.account_id}",
                )
                await connection.execute(
                    """
                    UPDATE managed_accounts
                    SET status = 'erasure_pending',
                        auth_valid_after = $2,
                        erasure_requested_at = $2,
                        updated_at = $2
                    WHERE account_id = $1
                    """,
                    principal.account_id,
                    now + timedelta(seconds=1),
                )
                formula_task = asyncio.create_task(
                    formula_repository.publish_shadow(
                        principal=principal,
                        request_id=uuid4(),
                        execution=_formula_execution(principal.account_id),
                        now=now + timedelta(seconds=2),
                    )
                )
                key_task = asyncio.create_task(
                    key_repository.put(
                        principal=principal,
                        mutation=_wrapped_key(
                            key_id=uuid4(),
                            key_kind="account_master",
                            wrapped=b"k" * 72,
                        ),
                        now=now + timedelta(seconds=2),
                    )
                )
                done, _ = await asyncio.wait(
                    {formula_task, key_task},
                    timeout=0.1,
                )
                assert done == set()

        results = await asyncio.gather(
            formula_task,
            key_task,
            return_exceptions=True,
        )
        assert isinstance(results[0], FormulaShadowAccountUnavailableError)
        assert isinstance(results[1], ManagedDocumentKeyAccountUnavailableError)
        counts = await pool.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_formula_shadow_results
                    WHERE account_id = $1
                ) AS formula_rows,
                (
                    SELECT count(*)
                    FROM managed_document_keys
                    WHERE account_id = $1
                ) AS key_rows,
                (
                    SELECT count(*)
                    FROM managed_document_key_versions
                    WHERE account_id = $1
                ) AS key_version_rows
            """,
            principal.account_id,
        )
        assert all(int(value) == 0 for value in counts.values())
    finally:
        await primary.shutdown()
