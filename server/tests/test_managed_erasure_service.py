from __future__ import annotations

import base64
import hashlib
import inspect
import os
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.managed_identity import ManagedIdentityClaims
from app.managed_models import (
    ManagedDocumentMutation,
    ManagedEnrollment,
    ManagedSocialProfileCreate,
)
from app.managed_repository import (
    ManagedConflictError,
    ManagedForbiddenError,
    PostgresManagedRepository,
)
from app.ownership_deletion_lifecycle import (
    ManagedErasureRetryableError,
    ManagedErasureTerminalError,
)
from app.repository import PostgresRepository


DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "timescaledb")
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"


def _managed(primary) -> PostgresManagedRepository:
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
            "user_documents",
        ],
    )


class _Primary:
    def __init__(self, pool) -> None:
        self.pool = pool

    def _require_pool(self):
        return self.pool


class _BrokenAcquire:
    async def __aenter__(self):
        raise ConnectionError("sensitive transport detail")

    async def __aexit__(self, exc_type, exc, traceback):
        return False


class _RetryablePool:
    def acquire(self):
        return _BrokenAcquire()

    async def fetchrow(self, *args):
        raise ConnectionError("sensitive transport detail")


class _TerminalPool:
    async def fetchrow(self, *args):
        raise ValueError("sensitive implementation detail")


def test_service_contract_does_not_construct_a_customer_principal() -> None:
    source = inspect.getsource(PostgresManagedRepository.schedule_all_managed_data)

    assert "ManagedPrincipal(" not in source
    assert "request_erasure(" not in source
    assert "'all_managed_data'" in source
    assert "identity_deletion_ticket" in source
    assert "NULL" in source


@pytest.mark.asyncio
async def test_service_rejects_invalid_identity_before_database_access() -> None:
    repository = _managed(_Primary(pool=None))

    with pytest.raises(
        ManagedErasureTerminalError,
        match="^managed erasure scheduling request is invalid$",
    ):
        await repository.schedule_all_managed_data(
            request_key=uuid4(),
            issuer="issuer with spaces",
            provider_tenant="tenant",
            subject_hash="not-a-digest",
        )


@pytest.mark.asyncio
async def test_service_maps_failures_to_fixed_lifecycle_errors() -> None:
    retryable = _managed(_Primary(_RetryablePool()))
    with pytest.raises(
        ManagedErasureRetryableError,
        match="^managed erasure scheduling is temporarily unavailable$",
    ):
        await retryable.schedule_all_managed_data(
            request_key=uuid4(),
            issuer="https://identity.synthetic.invalid",
            provider_tenant="tenant",
            subject_hash="a" * 64,
        )
    with pytest.raises(
        ManagedErasureRetryableError,
        match="^managed erasure status is temporarily unavailable$",
    ):
        await retryable.managed_erasure_status(job_id=uuid4())

    terminal = _managed(_Primary(_TerminalPool()))
    with pytest.raises(
        ManagedErasureTerminalError,
        match="^managed erasure status failed$",
    ):
        await terminal.managed_erasure_status(job_id=uuid4())


def test_service_maps_only_bounded_job_statuses() -> None:
    mapper = PostgresManagedRepository._managed_erasure_service_status

    assert mapper("queued") == "pending"
    assert mapper("cooling_off") == "pending"
    assert mapper("running") == "running"
    assert mapper("verifying") == "running"
    assert mapper("completed") == "completed"
    assert mapper("failed") == "terminal_failure"
    assert mapper("canceled") == "terminal_failure"
    with pytest.raises(
        ManagedErasureTerminalError,
        match="^managed erasure job state is invalid$",
    ):
        mapper("unknown")


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_service_schedules_replays_and_attaches_without_identity_deletion() -> (
    None
):
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"ownership-erasure-{uuid4()}", now)
        installation_id = str(uuid4())
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id),
        )
        principal = await repository.principal_for_identity(claims)
        profile = await repository.create_social_profile(
            principal=principal,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Synthetic",
            ),
        )
        pool = primary._require_pool()
        await pool.execute(
            """
            UPDATE managed_accounts
            SET status = 'suspended',
                suspended_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE account_id = $1
            """,
            principal.account_id,
        )

        request_key = uuid4()
        scheduled = await repository.schedule_all_managed_data(
            request_key=request_key,
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash=claims.subject_hash,
        )

        assert scheduled.outcome == "job"
        assert scheduled.job_status == "pending"
        assert scheduled.job_id is not None
        row = await pool.fetchrow(
            """
            SELECT job.request_id,
                   job.scope,
                   job.status,
                   job.requested_by_identity_id,
                   job.identity_deletion_ticket,
                   account.status AS account_status,
                   (
                       SELECT identity.status
                       FROM managed_external_identities identity
                       WHERE identity.account_id = job.account_id
                       ORDER BY identity.created_at, identity.identity_id
                       LIMIT 1
                   ) AS identity_status,
                   profile.status AS profile_status,
                   profile.poke_opt_in
            FROM managed_erasure_jobs job
            JOIN managed_accounts account USING (account_id)
            JOIN managed_social_profiles profile
              ON profile.account_id = job.account_id
            WHERE job.erasure_job_id = $1
            """,
            scheduled.job_id,
        )
        assert row["request_id"] == request_key
        assert row["scope"] == "all_managed_data"
        assert row["status"] == "queued"
        assert row["requested_by_identity_id"] is None
        assert row["identity_deletion_ticket"] is None
        assert row["account_status"] == "erasure_pending"
        assert row["identity_status"] == "active"
        assert row["profile_status"] == "disabled"
        assert row["poke_opt_in"] is False
        assert UUID(profile["profile_id"])

        replay = await repository.schedule_all_managed_data(
            request_key=request_key,
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash=claims.subject_hash,
        )
        assert replay == scheduled
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_erasure_jobs
                WHERE account_id = $1
                """,
                principal.account_id,
            )
            == 1
        )
        assert (
            await repository.managed_erasure_status(job_id=scheduled.job_id)
            == "pending"
        )

        attach_claims = _claims(f"ownership-attach-{uuid4()}", now)
        attach_installation = str(uuid4())
        await repository.enroll(
            claims=attach_claims,
            enrollment=_enrollment(attach_installation),
        )
        attach_principal = await repository.principal_for_identity(attach_claims)
        attach_request_key = uuid4()
        existing = await repository.request_erasure(
            principal=attach_principal,
            request_id=attach_request_key,
            scope="account",
            confirmation_sha256="b" * 64,
            identity_deletion_ticket=b"t" * 64,
            cooling_off=timedelta(days=1),
        )
        attached = await repository.schedule_all_managed_data(
            request_key=uuid4(),
            issuer=attach_claims.issuer,
            provider_tenant=attach_claims.provider_tenant,
            subject_hash=attach_claims.subject_hash,
        )
        assert attached.outcome == "job"
        assert attached.job_id == UUID(existing["erasure_job_id"])
        assert attached.job_status == "pending"
        assert (
            await pool.fetchval(
                """
                SELECT requested_by_identity_id
                FROM managed_erasure_jobs
                WHERE erasure_job_id = $1
                """,
                attached.job_id,
            )
            is None
        )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_erasure_jobs
                WHERE account_id = $1
                """,
                attach_principal.account_id,
            )
            == 1
        )
        with pytest.raises(
            ManagedConflictError,
            match="^managed erasure can no longer be canceled$",
        ):
            await repository.cancel_erasure(
                principal=attach_principal,
                erasure_job_id=UUID(existing["erasure_job_id"]),
            )
        pending_replay = await repository.schedule_all_managed_data(
            request_key=attach_request_key,
            issuer=attach_claims.issuer,
            provider_tenant=attach_claims.provider_tenant,
            subject_hash=attach_claims.subject_hash,
        )
        assert pending_replay.job_status == "pending"
        assert (
            await pool.fetchval(
                """
                SELECT status
                FROM managed_accounts
                WHERE account_id = $1
                """,
                attach_principal.account_id,
            )
            == "erasure_pending"
        )

        absent = await repository.schedule_all_managed_data(
            request_key=uuid4(),
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash="f" * 64,
        )
        assert absent.outcome == "absent"

        await pool.execute(
            """
            UPDATE managed_erasure_jobs
            SET status = 'completed',
                started_at = not_before,
                completed_at = not_before
            WHERE erasure_job_id = $1
            """,
            scheduled.job_id,
        )
        assert (
            await repository.managed_erasure_status(job_id=scheduled.job_id)
            == "completed"
        )
        completed_replay = await repository.schedule_all_managed_data(
            request_key=request_key,
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash=claims.subject_hash,
        )
        assert completed_replay.outcome == "already_completed"
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_service_treats_erased_account_as_completed() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"ownership-erased-{uuid4()}", now)
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(str(uuid4())),
        )
        principal = await repository.principal_for_identity(claims)
        pool = primary._require_pool()
        await pool.execute(
            """
            UPDATE managed_accounts
            SET status = 'erased',
                erasure_requested_at = clock_timestamp(),
                erased_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE account_id = $1
            """,
            principal.account_id,
        )

        result = await repository.schedule_all_managed_data(
            request_key=uuid4(),
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash=claims.subject_hash,
        )

        assert result.outcome == "already_completed"
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_erasure_jobs
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
async def test_service_erasure_completion_keeps_account_fenced() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"ownership-finalize-{uuid4()}", now)
        installation_id = str(uuid4())
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id),
        )
        principal = await repository.principal_for_identity(claims)
        scheduled = await repository.schedule_all_managed_data(
            request_key=uuid4(),
            issuer=claims.issuer,
            provider_tenant=claims.provider_tenant,
            subject_hash=claims.subject_hash,
        )
        assert scheduled.job_id is not None

        lifecycle_now = await repository.coordination_now()
        assert (
            await repository.claim_erasure_deletions(
                now=lifecycle_now,
                batch_size=10,
            )
            == []
        )
        completed = await repository.finalize_erasure_jobs(
            now=lifecycle_now,
            batch_size=10,
        )
        assert [row["erasure_job_id"] for row in completed] == [scheduled.job_id]

        pool = primary._require_pool()
        fenced = await pool.fetchrow(
            """
            SELECT account.status,
                   account.auth_valid_after,
                   job.requested_by_identity_id
            FROM managed_accounts account
            JOIN managed_erasure_jobs job USING (account_id)
            WHERE account.account_id = $1
              AND job.erasure_job_id = $2
            """,
            principal.account_id,
            scheduled.job_id,
        )
        assert fenced["status"] == "erasure_pending"
        assert fenced["auth_valid_after"] >= lifecycle_now
        assert fenced["requested_by_identity_id"] is None

        refreshed = await repository.principal_for_identity(
            _claims(
                claims.subject,
                fenced["auth_valid_after"] + timedelta(minutes=2),
            )
        )
        assert refreshed.account_status == "erasure_pending"
        with pytest.raises(
            ManagedForbiddenError,
            match="^managed account is not active$",
        ):
            await repository.put_document(
                principal=refreshed,
                installation_id=installation_id,
                mutation=ManagedDocumentMutation(
                    request_id=uuid4(),
                    document_kind="day_ownership",
                    document_id=uuid4(),
                    base_revision=0,
                    content_mode="server_readable",
                    payload_json={
                        "schema_version": 1,
                        "table": "dayOwnership",
                        "key": {"day": "2026-09-21"},
                        "record": {
                            "day": "2026-09-21",
                            "deviceId": "synthetic-device",
                            "locked": 0,
                        },
                    },
                    updated_at=fenced["auth_valid_after"] + timedelta(minutes=2),
                ),
            )
    finally:
        await primary.shutdown()
