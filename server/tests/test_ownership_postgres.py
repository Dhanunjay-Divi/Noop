from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType
from urllib.parse import quote, urlsplit, urlunsplit
from uuid import UUID, uuid4

import asyncpg
import pytest

from app.managed_identity import ManagedIdentityClaims
from app.ownership_deletion import OwnershipBandRetirementEligibility
from app.ownership_deletion_lifecycle import (
    OwnershipManagedTargetTransition,
    PostgresOwnershipDeletionProgressRepository,
)
from app.ownership_models import (
    OWNERSHIP_ACCOUNT_DELETION_CONFIRMATION_SHA256,
    OwnershipAccountDeletionRequest,
    OwnershipAccountRegistration,
    OwnershipInstallationAuthorization,
    OwnershipPlanSelection,
    OwnershipPossessionSubmission,
    OwnershipTermsAcceptance,
)
from app.ownership_possession import OwnershipPossessionEvidence
from app.ownership_repository import (
    OwnershipChallengeError,
    OwnershipConfigurationError,
    OwnershipConflictError,
    OwnershipForbiddenError,
    OwnershipNotFoundError,
    PostgresOwnershipRepository,
)
from app.repository import PostgresRepository

DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL")
APPLE_APP_ID = "1:123456789:ios:abcdef12"
TERMS_SHA256 = "a" * 64
BAND_IDENTITY_HASH = "b" * 64
ROOT = Path(__file__).resolve().parents[2]
OWNERSHIP_PROVISIONER = (
    ROOT / "infra" / "gcp" / "scripts" / "configure-ownership-database.py"
)


def _load_ownership_provisioner() -> ModuleType:
    module_name = "noop_test_configure_ownership_database"
    spec = importlib.util.spec_from_file_location(module_name, OWNERSHIP_PROVISIONER)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
async def ownership_repository():
    if not DATABASE_URL:
        pytest.skip("NOOP_TEST_POSTGRESQL_DATABASE_URL is required for ownership tests")
    primary = PostgresRepository(
        DATABASE_URL,
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine="postgresql",
    )
    await primary.startup()
    assert primary._pool is not None
    await primary._pool.execute(
        """
        TRUNCATE TABLE
            ownership_events,
            ownership_account_deletion_target_progress,
            ownership_account_deletion_targets,
            ownership_account_deletion_requests,
            ownership_releases,
            ownership_entitlements,
            ownership_plan_selection_requests,
            ownership_plan_selections,
            ownership_installation_authorizations,
            ownership_band_claims,
            ownership_claim_requests,
            ownership_possession_challenges,
            ownership_bands,
            ownership_installations,
            ownership_terms_acceptances,
            ownership_terms_documents,
            ownership_external_identities,
            ownership_accounts
        RESTART IDENTITY CASCADE
        """
    )
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v1',
            'en',
            $1,
            'https://terms.noop.example/ownership-v1/en',
            clock_timestamp() - interval '1 minute'
        )
        """,
        TERMS_SHA256,
    )
    repository = PostgresOwnershipRepository(primary)
    try:
        yield repository, primary
    finally:
        await primary.shutdown()


async def _wait_for_lock_waiters(pool, *, minimum: int) -> None:
    for _ in range(500):
        waiting = await pool.fetchval("SELECT count(*) FROM pg_locks WHERE NOT granted")
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} lock waiters")


def _claims(
    subject: str,
    *,
    auth_time: datetime | None = None,
) -> ManagedIdentityClaims:
    now = datetime.now(UTC)
    return ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject=subject,
        provider_tenant="",
        issued_at=now,
        auth_time=auth_time or now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
        email_verified=True,
        phone_verified=False,
        sign_in_provider="password",
    )


def _registration(
    *,
    installation_id: str,
    token_character: str,
    device_key_fingerprint: str | None = None,
    plan_selection: str = "noop",
) -> OwnershipAccountRegistration:
    return OwnershipAccountRegistration(
        request_id=uuid4(),
        installation_id=installation_id,
        installation_token="noopo_" + token_character * 43,
        platform="ios",
        policy_version="ownership-v1",
        policy_sha256=TERMS_SHA256,
        locale="en",
        plan_selection=plan_selection,
        device_key_fingerprint=device_key_fingerprint,
    )


def _account_deletion_request(
    *,
    request_id=None,
    policy_sha256: str = TERMS_SHA256,
) -> OwnershipAccountDeletionRequest:
    return OwnershipAccountDeletionRequest(
        request_id=request_id or uuid4(),
        confirmation_sha256=(OWNERSHIP_ACCOUNT_DELETION_CONFIRMATION_SHA256),
        export_acknowledged=True,
        retention_acknowledged=True,
        policy_version="ownership-v1",
        policy_sha256=policy_sha256,
        locale="en",
    )


async def _register(
    repository: PostgresOwnershipRepository,
    *,
    subject: str,
    installation_id: str,
    token_character: str,
):
    claims = _claims(subject)
    registration = _registration(
        installation_id=installation_id,
        token_character=token_character,
    )
    await repository.register_account(
        claims=claims,
        registration=registration,
    )
    principal = await repository.principal_for_identity(claims)
    await repository.ensure_installation(
        principal=principal,
        installation_id=installation_id,
        installation_token_hash=hashlib.sha256(
            registration.installation_token.get_secret_value().encode("ascii")
        ).hexdigest(),
        expected_platform="ios",
        identity_auth_time=claims.auth_time,
    )
    return claims, registration, principal


async def _provision_band(
    primary: PostgresRepository,
    *,
    identity_hash: str = BAND_IDENTITY_HASH,
) -> None:
    assert primary._pool is not None
    await primary._pool.execute(
        """
        INSERT INTO ownership_bands (
            band_id,
            provisioned_identity_hash,
            hardware_revision,
            protocol_version,
            firmware_version
        ) VALUES (
            $1,
            $2,
            'virtual-hw-v1',
            'test-v1',
            'test-1.0.0'
        )
        """,
        uuid4(),
        identity_hash,
    )


async def _challenge_and_submission(
    repository: PostgresOwnershipRepository,
    *,
    request_id=None,
):
    challenge = await repository.create_challenge(
        request_id=request_id or uuid4(),
        platform="ios",
        app_id=APPLE_APP_ID,
        ttl_seconds=180,
    )
    submission = OwnershipPossessionSubmission(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
    )
    evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=BAND_IDENTITY_HASH,
        protocol_version="test-v1",
        firmware_version="test-1.0.1",
        confirmed_at=datetime.now(UTC),
    )
    return challenge, submission, evidence


@pytest.mark.asyncio
async def test_concurrent_cross_account_registration_rejects_installation_collision(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    shared_installation_id = "ios-shared-registration"
    first_registration = _registration(
        installation_id=shared_installation_id,
        token_character="A",
    )
    second_registration = _registration(
        installation_id=shared_installation_id,
        token_character="B",
    )

    results = await asyncio.gather(
        repository.register_account(
            claims=_claims("registration-collision-first"),
            registration=first_registration,
        ),
        repository.register_account(
            claims=_claims("registration-collision-second"),
            registration=second_registration,
        ),
        return_exceptions=True,
    )

    assert sum(isinstance(result, dict) for result in results) == 1
    assert sum(isinstance(result, OwnershipForbiddenError) for result in results) == 1
    assert not any(isinstance(result, asyncpg.PostgresError) for result in results)
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE installation_id = $1
            """,
            shared_installation_id,
        )
        == 1
    )
    assert await primary._pool.fetchval("SELECT count(*) FROM ownership_accounts") == 1


@pytest.mark.asyncio
async def test_registration_rejects_retired_unified_principal_without_orphaning(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    claims = _claims(f"retired-unified-owner-{uuid4()}")
    now = datetime.now(UTC)
    assert primary._pool is not None
    await primary._pool.execute(
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
        ) VALUES ($1, $2, $3, $4, 'retired', $5, $5, $5)
        """,
        uuid4(),
        claims.issuer,
        claims.provider_tenant,
        claims.subject_hash,
        now,
    )

    with pytest.raises(
        OwnershipForbiddenError,
        match="ownership account is unavailable",
    ):
        await repository.register_account(
            claims=claims,
            registration=_registration(
                installation_id="ios-retired-unified-owner",
                token_character="U",
            ),
        )

    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_external_identities
            WHERE issuer = $1
              AND provider_tenant = $2
              AND subject_hash = $3
            """,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
        )
        == 0
    )
    assert await primary._pool.fetchval("SELECT count(*) FROM ownership_accounts") == 0


@pytest.mark.asyncio
async def test_registration_preserves_initial_noop_plus_preference(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    registration = _registration(
        installation_id="ios-initial-plan",
        token_character="P",
        plan_selection="noop_plus",
    )

    result = await repository.register_account(
        claims=_claims("initial-plan-owner"),
        registration=registration,
    )

    assert result["plan_selection"] == "noop_plus"
    assert result["noop_plus_entitled"] is False
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_plan_selection_requests
            WHERE request_id = $1 AND selection = 'noop_plus'
            """,
            registration.request_id,
        )
        == 1
    )
    assert (
        await primary._pool.fetchval("SELECT count(*) FROM ownership_entitlements") == 0
    )


@pytest.mark.asyncio
async def test_registration_retry_rejects_changed_plan_without_mutating_state(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    claims = _claims("registration-plan-retry-owner")
    registration = _registration(
        installation_id="ios-registration-plan-retry",
        token_character="R",
    )

    first = await repository.register_account(
        claims=claims,
        registration=registration,
    )
    changed = registration.model_copy(
        update={"plan_selection": "noop_plus"},
    )

    with pytest.raises(OwnershipConflictError):
        await repository.register_account(
            claims=claims,
            registration=changed,
        )

    principal = await repository.principal_for_identity(claims)
    overview = await repository.overview(
        principal=principal,
        current_installation_id=registration.installation_id,
    )
    assert first["plan_selection"] == "noop"
    assert overview["plan_selection"] == "noop"
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_plan_selection_requests
            WHERE account_id = $1
            """,
            principal.account_id,
        )
        == 1
    )


@pytest.mark.asyncio
async def test_ownership_claim_is_atomic_across_two_accounts(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, first = await _register(
        repository,
        subject="first-subject",
        installation_id="ios-first",
        token_character="A",
    )
    _, _, second = await _register(
        repository,
        subject="second-subject",
        installation_id="ios-second",
        token_character="B",
    )
    _, first_submission, first_evidence = await _challenge_and_submission(repository)
    _, second_submission, second_evidence = await _challenge_and_submission(repository)

    first_result, second_result = await asyncio.gather(
        repository.claim_band(
            principal=first,
            installation_id="ios-first",
            submission=first_submission,
            evidence=first_evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        ),
        repository.claim_band(
            principal=second,
            installation_id="ios-second",
            submission=second_submission,
            evidence=second_evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        ),
    )

    assert sorted([first_result.outcome, second_result.outcome]) == [
        "claimed",
        "conflict",
    ]
    assert primary._pool is not None
    owner_count = await primary._pool.fetchval(
        """
        SELECT count(*)
        FROM ownership_bands
        WHERE status = 'claimed' AND current_account_id IS NOT NULL
        """
    )
    active_claim_count = await primary._pool.fetchval(
        "SELECT count(*) FROM ownership_band_claims WHERE status = 'active'"
    )
    conflict_band_count = await primary._pool.fetchval(
        """
        SELECT count(*)
        FROM ownership_claim_requests
        WHERE outcome = 'conflict' AND band_id IS NOT NULL
        """
    )
    conflict_event_band_count = await primary._pool.fetchval(
        """
        SELECT count(*)
        FROM ownership_events
        WHERE event_kind = 'claim_conflict' AND band_id IS NOT NULL
        """
    )
    assert owner_count == 1
    assert active_claim_count == 1
    assert conflict_band_count == 0
    assert conflict_event_band_count == 0


@pytest.mark.asyncio
async def test_account_cannot_claim_a_second_active_band(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    second_identity_hash = "c" * 64
    await _provision_band(primary)
    await _provision_band(primary, identity_hash=second_identity_hash)
    _, _, principal = await _register(
        repository,
        subject="single-band-owner",
        installation_id="ios-single-band-owner",
        token_character="A",
    )
    _, first_submission, first_evidence = await _challenge_and_submission(repository)
    first = await repository.claim_band(
        principal=principal,
        installation_id="ios-single-band-owner",
        submission=first_submission,
        evidence=first_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    _, second_submission, second_evidence = await _challenge_and_submission(repository)
    second_evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=second_identity_hash,
        protocol_version=second_evidence.protocol_version,
        firmware_version=second_evidence.firmware_version,
        confirmed_at=second_evidence.confirmed_at,
    )
    second = await repository.claim_band(
        principal=principal,
        installation_id="ios-single-band-owner",
        submission=second_submission,
        evidence=second_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    assert first.outcome == "claimed"
    assert second.outcome == "conflict"
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
        SELECT count(*)
        FROM ownership_bands
        WHERE current_account_id = $1
          AND status IN ('claimed', 'return_pending')
        """,
            principal.account_id,
        )
        == 1
    )
    assert (
        await primary._pool.fetchval(
            """
        SELECT count(*)
        FROM ownership_claim_requests
        WHERE account_id = $1
          AND request_id = $2
          AND outcome = 'conflict'
          AND band_id IS NULL
        """,
            principal.account_id,
            second_submission.request_id,
        )
        == 1
    )
    with pytest.raises(asyncpg.UniqueViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_bands
            SET status = 'claimed',
                current_account_id = $1,
                claimed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE provisioned_identity_hash = $2
            """,
            principal.account_id,
            second_identity_hash,
        )


@pytest.mark.asyncio
async def test_ownership_claim_is_idempotent_and_challenge_cannot_replay(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="owner-subject",
        installation_id="ios-owner",
        token_character="A",
    )
    _, submission, evidence = await _challenge_and_submission(repository)

    first = await repository.claim_band(
        principal=principal,
        installation_id="ios-owner",
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    preverified_replay = await repository.claim_replay(
        principal=principal,
        installation_id="ios-owner",
        submission=submission,
    )
    replay = await repository.claim_band(
        principal=principal,
        installation_id="ios-owner",
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    assert first.outcome == "claimed"
    assert preverified_replay == first
    assert replay == first
    conflicting_replay = OwnershipPossessionSubmission(
        request_id=submission.request_id,
        challenge_id=submission.challenge_id,
        challenge="D" * 43,
        possession_response="virtual-signed-response",
    )
    with pytest.raises(OwnershipConflictError):
        await repository.claim_replay(
            principal=principal,
            installation_id="ios-owner",
            submission=conflicting_replay,
        )
    altered_response = OwnershipPossessionSubmission(
        request_id=submission.request_id,
        challenge_id=submission.challenge_id,
        challenge=submission.challenge,
        possession_response="different-signed-response",
    )
    with pytest.raises(OwnershipConflictError):
        await repository.claim_replay(
            principal=principal,
            installation_id="ios-owner",
            submission=altered_response,
        )
    with pytest.raises(OwnershipConflictError):
        await repository.claim_band(
            principal=principal,
            installation_id="ios-owner",
            submission=altered_response,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )
    replay_with_new_request = submission.model_copy(update={"request_id": uuid4()})
    with pytest.raises(OwnershipChallengeError):
        await repository.claim_band(
            principal=principal,
            installation_id="ios-owner",
            submission=replay_with_new_request,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )


@pytest.mark.asyncio
async def test_challenge_preflight_binds_value_platform_and_app_before_verification(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    challenge = await repository.create_challenge(
        request_id=uuid4(),
        platform="ios",
        app_id=APPLE_APP_ID,
        ttl_seconds=180,
    )

    for challenge_value, platform, app_id in [
        ("D" * 43, "ios", APPLE_APP_ID),
        (challenge.challenge, "android", APPLE_APP_ID),
        (challenge.challenge, "ios", "1:123456789:ios:different"),
    ]:
        with pytest.raises(OwnershipChallengeError):
            await repository.require_active_challenge(
                challenge_id=challenge.challenge_id,
                challenge=challenge_value,
                app_id=app_id,
                platform=platform,
            )

    window = await repository.require_active_challenge(
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    assert window.created_at < window.expires_at
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT status
            FROM ownership_possession_challenges
            WHERE challenge_id = $1
            """,
            challenge.challenge_id,
        )
        == "issued"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("confirmation_position", ["before_issued", "at_expiry"])
async def test_claim_rejects_proof_outside_the_exact_challenge_window(
    ownership_repository,
    confirmation_position: str,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject=f"challenge-window-{confirmation_position}",
        installation_id=f"ios-challenge-window-{confirmation_position}",
        token_character="W",
    )
    challenge, submission, evidence = await _challenge_and_submission(repository)
    assert primary._pool is not None
    window = await primary._pool.fetchrow(
        """
        SELECT created_at, expires_at
        FROM ownership_possession_challenges
        WHERE challenge_id = $1
        """,
        challenge.challenge_id,
    )
    assert window is not None
    confirmed_at = (
        window["created_at"] - timedelta(microseconds=1)
        if confirmation_position == "before_issued"
        else window["expires_at"]
    )
    invalid_evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=evidence.provisioned_identity_hash,
        protocol_version=evidence.protocol_version,
        firmware_version=evidence.firmware_version,
        confirmed_at=confirmed_at,
    )

    with pytest.raises(OwnershipChallengeError):
        await repository.claim_band(
            principal=principal,
            installation_id=f"ios-challenge-window-{confirmation_position}",
            submission=submission,
            evidence=invalid_evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )

    challenge_state = await primary._pool.fetchrow(
        """
        SELECT status, consumed_at
        FROM ownership_possession_challenges
        WHERE challenge_id = $1
        """,
        challenge.challenge_id,
    )
    assert challenge_state is not None
    assert challenge_state["status"] == "rejected"
    assert challenge_state["consumed_at"] is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_claim_requests
            WHERE challenge_id = $1
            """,
            challenge.challenge_id,
        )
        == 0
    )


@pytest.mark.asyncio
async def test_claim_requires_the_latest_exact_terms_acceptance(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="terms-changed-before-claim",
        installation_id="ios-terms-changed",
        token_character="T",
    )
    challenge, submission, evidence = await _challenge_and_submission(repository)
    assert primary._pool is not None
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'en',
            $1,
            'https://terms.noop.example/ownership-v2/en',
            clock_timestamp()
        )
        """,
        "c" * 64,
    )

    with pytest.raises(OwnershipConfigurationError):
        await repository.ensure_current_terms(principal=principal)
    with pytest.raises(OwnershipConfigurationError):
        await repository.claim_band(
            principal=principal,
            installation_id="ios-terms-changed",
            submission=submission,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )

    challenge_state = await primary._pool.fetchrow(
        """
        SELECT status, consumed_at
        FROM ownership_possession_challenges
        WHERE challenge_id = $1
        """,
        challenge.challenge_id,
    )
    assert challenge_state is not None
    assert challenge_state["status"] == "issued"
    assert challenge_state["consumed_at"] is None


@pytest.mark.asyncio
async def test_replacement_reaccepts_changed_terms_without_consuming_proof(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="replacement-terms-owner",
        installation_id="ios-replacement-terms-original",
        token_character="T",
    )
    _, claim_submission, claim_evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-replacement-terms-original",
        submission=claim_submission,
        evidence=claim_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    assert primary._pool is not None
    current_sha256 = "c" * 64
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'en',
            $1,
            'https://terms.noop.example/ownership-v2/en',
            clock_timestamp()
        )
        """,
        current_sha256,
    )
    historical = await repository.terms_manifest_version(
        policy_version="ownership-v1",
        locale="en",
    )
    assert historical["document_sha256"] == TERMS_SHA256
    assert (await repository.bootstrap_status(claims=claims))[
        "terms_acceptance_required"
    ] is True

    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-replacement-terms-new",
        new_installation_token="noopo_" + "R" * 43,
        new_platform="ios",
    )
    with pytest.raises(OwnershipConfigurationError):
        await repository.authorize_installation(
            principal=principal,
            submission=authorization,
            evidence=replacement_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=claims.auth_time,
        )
    assert (
        await primary._pool.fetchval(
            """
            SELECT status
            FROM ownership_possession_challenges
            WHERE challenge_id = $1
            """,
            challenge.challenge_id,
        )
        == "issued"
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE installation_id = $1
            """,
            authorization.new_installation_id,
        )
        == 0
    )

    acceptance = OwnershipTermsAcceptance(
        request_id=uuid4(),
        policy_version="ownership-v2",
        policy_sha256=current_sha256,
        locale="en",
    )
    first = await repository.accept_terms(
        principal=principal,
        acceptance=acceptance,
    )
    replay = await repository.accept_terms(
        principal=principal,
        acceptance=acceptance,
    )
    assert first["resumed"] is False
    assert replay["resumed"] is True
    assert (await repository.bootstrap_status(claims=claims))[
        "terms_acceptance_required"
    ] is False

    result = await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=claims.auth_time,
    )
    assert result["installation_state"] == "active"


@pytest.mark.asyncio
async def test_concurrent_identical_claim_requests_converge_idempotently(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="concurrent-owner-subject",
        installation_id="ios-concurrent-owner",
        token_character="A",
    )
    _, submission, evidence = await _challenge_and_submission(repository)

    first, second = await asyncio.gather(
        repository.claim_band(
            principal=principal,
            installation_id="ios-concurrent-owner",
            submission=submission,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        ),
        repository.claim_band(
            principal=principal,
            installation_id="ios-concurrent-owner",
            submission=submission,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        ),
    )

    assert first == second
    assert first.outcome == "claimed"
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
        SELECT count(*)
        FROM ownership_claim_requests
        WHERE account_id = $1 AND request_id = $2
        """,
            principal.account_id,
            submission.request_id,
        )
        == 1
    )


@pytest.mark.asyncio
async def test_owned_band_requires_fresh_possession_for_replacement_installation(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="replacement-owner",
        installation_id="ios-original",
        token_character="A",
    )
    _, claim_submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-original",
        submission=claim_submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    with pytest.raises(OwnershipForbiddenError):
        await repository.register_account(
            claims=claims,
            registration=_registration(
                installation_id="ios-without-proof",
                token_character="B",
            ),
        )

    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-replacement",
        new_installation_token="noopo_" + "C" * 43,
        new_platform="ios",
    )
    authorized = await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=claims.auth_time,
    )

    assert authorized == {
        "installation_state": "active",
        "installation_id": "ios-replacement",
    }
    replacement_token_hash = hashlib.sha256(
        authorization.new_installation_token.get_secret_value().encode("ascii")
    ).hexdigest()
    await repository.ensure_installation(
        principal=principal,
        installation_id="ios-replacement",
        installation_token_hash=replacement_token_hash,
        expected_platform="ios",
        identity_auth_time=claims.auth_time,
    )
    with pytest.raises(OwnershipForbiddenError):
        await repository.ensure_installation(
            principal=principal,
            installation_id="ios-replacement",
            installation_token_hash=replacement_token_hash,
            expected_platform="ios",
            identity_auth_time=claims.auth_time - timedelta(seconds=1),
        )
    with pytest.raises(OwnershipForbiddenError):
        await repository.ensure_installation(
            principal=principal,
            installation_id="ios-replacement",
            installation_token_hash=replacement_token_hash,
            expected_platform="android",
            identity_auth_time=claims.auth_time,
        )
    installations = await repository.list_installations(
        principal=principal,
        current_installation_id="ios-replacement",
    )
    assert {row["installation_id"] for row in installations} == {
        "ios-original",
        "ios-replacement",
    }


@pytest.mark.asyncio
async def test_replacement_rejects_proof_from_before_its_challenge(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="replacement-window-owner",
        installation_id="ios-replacement-window-original",
        token_character="A",
    )
    _, claim_submission, claim_evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-replacement-window-original",
        submission=claim_submission,
        evidence=claim_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    assert primary._pool is not None
    created_at = await primary._pool.fetchval(
        """
        SELECT created_at
        FROM ownership_possession_challenges
        WHERE challenge_id = $1
        """,
        challenge.challenge_id,
    )
    invalid_evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=replacement_evidence.provisioned_identity_hash,
        protocol_version=replacement_evidence.protocol_version,
        firmware_version=replacement_evidence.firmware_version,
        confirmed_at=created_at - timedelta(microseconds=1),
    )
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-replacement-window-new",
        new_installation_token="noopo_" + "D" * 43,
        new_platform="ios",
    )

    with pytest.raises(OwnershipChallengeError):
        await repository.authorize_installation(
            principal=principal,
            submission=authorization,
            evidence=invalid_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=claims.auth_time,
        )

    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE installation_id = $1
            """,
            authorization.new_installation_id,
        )
        == 0
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT status
            FROM ownership_possession_challenges
            WHERE challenge_id = $1
            """,
            challenge.challenge_id,
        )
        == "rejected"
    )


@pytest.mark.asyncio
async def test_concurrent_cross_account_authorization_rejects_installation_collision(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    second_identity_hash = "c" * 64
    await _provision_band(primary)
    await _provision_band(primary, identity_hash=second_identity_hash)
    first_claims, _, first_principal = await _register(
        repository,
        subject="authorization-collision-first",
        installation_id="ios-authorization-first",
        token_character="A",
    )
    second_claims, _, second_principal = await _register(
        repository,
        subject="authorization-collision-second",
        installation_id="ios-authorization-second",
        token_character="B",
    )

    _, first_claim, first_evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=first_principal,
        installation_id="ios-authorization-first",
        submission=first_claim,
        evidence=first_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    _, second_claim, second_evidence = await _challenge_and_submission(repository)
    second_evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=second_identity_hash,
        protocol_version=second_evidence.protocol_version,
        firmware_version=second_evidence.firmware_version,
        confirmed_at=second_evidence.confirmed_at,
    )
    await repository.claim_band(
        principal=second_principal,
        installation_id="ios-authorization-second",
        submission=second_claim,
        evidence=second_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    shared_installation_id = "ios-shared-authorization"
    first_challenge, _, first_authorization_evidence = await _challenge_and_submission(
        repository
    )
    (
        second_challenge,
        _,
        second_authorization_evidence,
    ) = await _challenge_and_submission(repository)
    second_authorization_evidence = OwnershipPossessionEvidence(
        provisioned_identity_hash=second_identity_hash,
        protocol_version=second_authorization_evidence.protocol_version,
        firmware_version=second_authorization_evidence.firmware_version,
        confirmed_at=second_authorization_evidence.confirmed_at,
    )
    first_authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=first_challenge.challenge_id,
        challenge=first_challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id=shared_installation_id,
        new_installation_token="noopo_" + "D" * 43,
        new_platform="ios",
    )
    second_authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=second_challenge.challenge_id,
        challenge=second_challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id=shared_installation_id,
        new_installation_token="noopo_" + "E" * 43,
        new_platform="ios",
    )

    results = await asyncio.gather(
        repository.authorize_installation(
            principal=first_principal,
            submission=first_authorization,
            evidence=first_authorization_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=first_claims.auth_time,
        ),
        repository.authorize_installation(
            principal=second_principal,
            submission=second_authorization,
            evidence=second_authorization_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=second_claims.auth_time,
        ),
        return_exceptions=True,
    )

    assert sum(isinstance(result, dict) for result in results) == 1
    assert sum(isinstance(result, OwnershipForbiddenError) for result in results) == 1
    assert not any(isinstance(result, asyncpg.PostgresError) for result in results)
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE installation_id = $1
            """,
            shared_installation_id,
        )
        == 1
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installation_authorizations
            WHERE installation_id = $1
            """,
            shared_installation_id,
        )
        == 1
    )


@pytest.mark.asyncio
async def test_initial_claim_revokes_other_preclaim_installations(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims = _claims("preclaim-installation-owner")
    first = _registration(
        installation_id="ios-preclaim-first",
        token_character="A",
    )
    second = _registration(
        installation_id="ios-preclaim-second",
        token_character="B",
    )
    await repository.register_account(claims=claims, registration=first)
    await repository.register_account(claims=claims, registration=second)
    principal = await repository.principal_for_identity(claims)
    _, submission, evidence = await _challenge_and_submission(repository)

    result = await repository.claim_band(
        principal=principal,
        installation_id=second.installation_id,
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    assert result.outcome == "claimed"
    installations = await repository.list_installations(
        principal=principal,
        current_installation_id=second.installation_id,
    )
    states = {row["installation_id"]: row["status"] for row in installations}
    assert states == {
        second.installation_id: "active",
    }
    with pytest.raises(OwnershipForbiddenError):
        await repository.ensure_installation(
            principal=principal,
            installation_id=first.installation_id,
            installation_token_hash=hashlib.sha256(
                first.installation_token.get_secret_value().encode("ascii")
            ).hexdigest(),
            expected_platform="ios",
            identity_auth_time=claims.auth_time,
        )
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_events
            WHERE account_id = $1
              AND installation_id = $2
              AND event_kind = 'installation_revoked'
              AND outcome = 'completed'
            """,
            principal.account_id,
            first.installation_id,
        )
        == 1
    )


@pytest.mark.asyncio
async def test_revoked_installation_history_cannot_overflow_the_active_list(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    claims, _, principal = await _register(
        repository,
        subject="bounded-installation-list-owner",
        installation_id="ios-current-installation",
        token_character="A",
    )
    assert primary._pool is not None
    for index in range(12):
        await primary._pool.execute(
            """
            INSERT INTO ownership_installations (
                installation_id,
                account_id,
                platform,
                token_hash,
                status,
                auth_valid_after,
                registered_at,
                last_seen_at,
                revoked_at
            ) VALUES (
                $1,
                $2,
                'ios',
                $3,
                'revoked',
                $4,
                clock_timestamp(),
                clock_timestamp(),
                clock_timestamp()
            )
            """,
            f"ios-revoked-history-{index}",
            principal.account_id,
            hashlib.sha256(f"revoked-{index}".encode("ascii")).hexdigest(),
            claims.auth_time,
        )

    installations = await repository.list_installations(
        principal=principal,
        current_installation_id="ios-current-installation",
    )

    assert installations == [
        {
            "installation_id": "ios-current-installation",
            "platform": "ios",
            "status": "active",
            "current": True,
            "registered_at": installations[0]["registered_at"],
            "last_seen_at": installations[0]["last_seen_at"],
        }
    ]


@pytest.mark.asyncio
async def test_concurrent_replacement_authorizations_respect_installation_limit(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="installation-limit-owner",
        installation_id="ios-limit-original",
        token_character="A",
    )
    _, claim_submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-limit-original",
        submission=claim_submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    assert primary._pool is not None
    for index in range(8):
        await primary._pool.execute(
            """
            INSERT INTO ownership_installations (
                installation_id,
                account_id,
                platform,
                token_hash,
                auth_valid_after,
                registered_at,
                last_seen_at
            ) VALUES (
                $1,
                $2,
                'ios',
                $3,
                $4,
                clock_timestamp(),
                clock_timestamp()
            )
            """,
            f"ios-limit-existing-{index}",
            principal.account_id,
            hashlib.sha256(f"existing-{index}".encode("ascii")).hexdigest(),
            claims.auth_time,
        )

    async def authorization(index: int):
        challenge, _, replacement_evidence = await _challenge_and_submission(repository)
        submission = OwnershipInstallationAuthorization(
            request_id=uuid4(),
            challenge_id=challenge.challenge_id,
            challenge=challenge.challenge,
            possession_response="virtual-signed-response",
            new_installation_id=f"ios-limit-racer-{index}",
            new_installation_token="noopo_" + str(index) * 43,
            new_platform="ios",
        )
        return await repository.authorize_installation(
            principal=principal,
            submission=submission,
            evidence=replacement_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=claims.auth_time,
        )

    results = await asyncio.gather(
        authorization(1),
        authorization(2),
        return_exceptions=True,
    )

    assert sum(isinstance(result, dict) for result in results) == 1
    assert sum(isinstance(result, OwnershipForbiddenError) for result in results) == 1
    assert (
        await primary._pool.fetchval(
            """
        SELECT count(*)
        FROM ownership_installations
        WHERE account_id = $1 AND status = 'active'
        """,
            principal.account_id,
        )
        == 10
    )


@pytest.mark.asyncio
async def test_bootstrap_status_reveals_only_replacement_requirement(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    unregistered = await repository.bootstrap_status(
        claims=_claims("not-registered"),
    )
    assert unregistered == {
        "account_state": "unregistered",
        "band_state": "unclaimed",
        "replacement_authorization_required": False,
        "terms_acceptance_required": False,
    }

    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="bootstrap-owner",
        installation_id="ios-bootstrap",
        token_character="A",
    )
    before_claim = await repository.bootstrap_status(claims=claims)
    assert before_claim == {
        "account_state": "active",
        "band_state": "unclaimed",
        "replacement_authorization_required": False,
        "terms_acceptance_required": False,
    }

    _, submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-bootstrap",
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    after_claim = await repository.bootstrap_status(claims=claims)
    assert after_claim == {
        "account_state": "active",
        "band_state": "claimed",
        "replacement_authorization_required": True,
        "terms_acceptance_required": False,
    }


@pytest.mark.asyncio
async def test_registration_cannot_drop_or_replace_bound_device_key(
    ownership_repository,
) -> None:
    repository, _ = ownership_repository
    claims = _claims("device-key-owner")
    fingerprint = "c" * 64
    registration = _registration(
        installation_id="ios-device-key",
        token_character="A",
        device_key_fingerprint=fingerprint,
    )
    await repository.register_account(
        claims=claims,
        registration=registration,
    )

    for replacement in (None, "d" * 64):
        with pytest.raises(OwnershipForbiddenError):
            await repository.register_account(
                claims=claims,
                registration=registration.model_copy(
                    update={
                        "request_id": uuid4(),
                        "device_key_fingerprint": replacement,
                    }
                ),
            )

    resumed = await repository.register_account(
        claims=claims,
        registration=registration.model_copy(update={"request_id": uuid4()}),
    )
    assert resumed["current_installation_id"] == "ios-device-key"


@pytest.mark.asyncio
async def test_registration_rejects_identity_older_than_installation_cutoff(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    claims = _claims("stale-registration-installation-owner")
    registration = _registration(
        installation_id="ios-stale-registration-auth",
        token_character="A",
    )
    await repository.register_account(
        claims=claims,
        registration=registration,
    )
    assert primary._pool is not None
    await primary._pool.execute(
        """
        UPDATE ownership_installations
        SET auth_valid_after = $2
        WHERE installation_id = $1
        """,
        registration.installation_id,
        claims.auth_time + timedelta(seconds=1),
    )

    with pytest.raises(OwnershipForbiddenError):
        await repository.register_account(
            claims=claims,
            registration=registration.model_copy(update={"request_id": uuid4()}),
        )


@pytest.mark.asyncio
async def test_replacement_authorization_replay_binds_token_and_device_key(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="replacement-device-key-owner",
        installation_id="ios-original",
        token_character="A",
    )
    _, claim_submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-original",
        submission=claim_submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-device-key-replacement",
        new_installation_token="noopo_" + "C" * 43,
        new_platform="ios",
        device_key_fingerprint="e" * 64,
    )
    first = await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=_claims("replacement-device-key-owner").auth_time,
    )
    preverified_replay = await repository.installation_authorization_replay(
        principal=principal,
        submission=authorization,
        app_id=APPLE_APP_ID,
        identity_auth_time=_claims("replacement-device-key-owner").auth_time,
    )
    replay = await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=_claims("replacement-device-key-owner").auth_time,
    )

    assert preverified_replay == first
    assert replay == first
    altered_response = OwnershipInstallationAuthorization(
        request_id=authorization.request_id,
        challenge_id=authorization.challenge_id,
        challenge=authorization.challenge,
        possession_response="different-signed-response",
        new_installation_id=authorization.new_installation_id,
        new_installation_token=authorization.new_installation_token,
        new_platform=authorization.new_platform,
        device_key_fingerprint=authorization.device_key_fingerprint,
    )
    with pytest.raises(OwnershipConflictError):
        await repository.installation_authorization_replay(
            principal=principal,
            submission=altered_response,
            app_id=APPLE_APP_ID,
            identity_auth_time=_claims("replacement-device-key-owner").auth_time,
        )
    with pytest.raises(OwnershipConflictError):
        await repository.authorize_installation(
            principal=principal,
            submission=altered_response,
            evidence=replacement_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=_claims("replacement-device-key-owner").auth_time,
        )
    for replacement in (None, "f" * 64):
        with pytest.raises(OwnershipConflictError):
            await repository.authorize_installation(
                principal=principal,
                submission=authorization.model_copy(
                    update={"device_key_fingerprint": replacement}
                ),
                evidence=replacement_evidence,
                app_id=APPLE_APP_ID,
                identity_auth_time=_claims("replacement-device-key-owner").auth_time,
            )


@pytest.mark.asyncio
async def test_replacement_replay_and_reuse_require_current_identity_auth(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, _, principal = await _register(
        repository,
        subject="replacement-auth-cutoff-owner",
        installation_id="ios-auth-cutoff-original",
        token_character="A",
    )
    _, claim_submission, claim_evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-auth-cutoff-original",
        submission=claim_submission,
        evidence=claim_evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    authorization_auth_time = claims.auth_time + timedelta(seconds=1)
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-auth-cutoff-replacement",
        new_installation_token="noopo_" + "C" * 43,
        new_platform="ios",
    )
    await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=authorization_auth_time,
    )
    assert primary._pool is not None
    cutoff = authorization_auth_time + timedelta(seconds=1)
    await primary._pool.execute(
        """
        UPDATE ownership_installations
        SET auth_valid_after = $2
        WHERE installation_id = $1
        """,
        authorization.new_installation_id,
        cutoff,
    )

    with pytest.raises(OwnershipForbiddenError):
        await repository.installation_authorization_replay(
            principal=principal,
            submission=authorization,
            app_id=APPLE_APP_ID,
            identity_auth_time=authorization_auth_time,
        )
    with pytest.raises(OwnershipForbiddenError):
        await repository.authorize_installation(
            principal=principal,
            submission=authorization,
            evidence=replacement_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=authorization_auth_time,
        )

    reuse_challenge, _, reuse_evidence = await _challenge_and_submission(repository)
    reuse = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=reuse_challenge.challenge_id,
        challenge=reuse_challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id=authorization.new_installation_id,
        new_installation_token=authorization.new_installation_token,
        new_platform="ios",
    )
    with pytest.raises(OwnershipForbiddenError):
        await repository.authorize_installation(
            principal=principal,
            submission=reuse,
            evidence=reuse_evidence,
            app_id=APPLE_APP_ID,
            identity_auth_time=authorization_auth_time,
        )


@pytest.mark.asyncio
async def test_replacement_authorization_replay_cannot_add_a_device_key(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="replacement-unbound-device-key-owner",
        installation_id="ios-original-unbound",
        token_character="A",
    )
    _, claim_submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id="ios-original-unbound",
        submission=claim_submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )

    challenge, _, replacement_evidence = await _challenge_and_submission(repository)
    authorization = OwnershipInstallationAuthorization(
        request_id=uuid4(),
        challenge_id=challenge.challenge_id,
        challenge=challenge.challenge,
        possession_response="virtual-signed-response",
        new_installation_id="ios-unbound-device-key-replacement",
        new_installation_token="noopo_" + "C" * 43,
        new_platform="ios",
    )
    await repository.authorize_installation(
        principal=principal,
        submission=authorization,
        evidence=replacement_evidence,
        app_id=APPLE_APP_ID,
        identity_auth_time=_claims("replacement-unbound-device-key-owner").auth_time,
    )

    with pytest.raises(OwnershipConflictError):
        await repository.installation_authorization_replay(
            principal=principal,
            submission=authorization.model_copy(
                update={"device_key_fingerprint": "e" * 64}
            ),
            app_id=APPLE_APP_ID,
            identity_auth_time=_claims(
                "replacement-unbound-device-key-owner"
            ).auth_time,
        )


@pytest.mark.asyncio
async def test_plan_selection_cannot_grant_noop_plus_entitlement(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    _, _, principal = await _register(
        repository,
        subject="plan-owner",
        installation_id="ios-plan",
        token_character="A",
    )
    selection = OwnershipPlanSelection(
        request_id=uuid4(),
        selection="noop_plus",
    )

    first = await repository.select_plan(
        principal=principal,
        installation_id="ios-plan",
        selection=selection,
    )
    replay = await repository.select_plan(
        principal=principal,
        installation_id="ios-plan",
        selection=selection,
    )

    assert first == replay
    assert first["plan_selection"] == "noop_plus"
    assert first["noop_plus_entitled"] is False
    assert primary._pool is not None
    entitlement_count = await primary._pool.fetchval(
        "SELECT count(*) FROM ownership_entitlements"
    )
    assert entitlement_count == 0


@pytest.mark.asyncio
async def test_plan_request_ids_are_tenant_scoped(
    ownership_repository,
) -> None:
    repository, _ = ownership_repository
    _, _, first = await _register(
        repository,
        subject="plan-request-first",
        installation_id="ios-plan-request-first",
        token_character="P",
    )
    _, _, second = await _register(
        repository,
        subject="plan-request-second",
        installation_id="ios-plan-request-second",
        token_character="Q",
    )
    shared_request_id = uuid4()

    first_result, second_result = await asyncio.gather(
        repository.select_plan(
            principal=first,
            installation_id="ios-plan-request-first",
            selection=OwnershipPlanSelection(
                request_id=shared_request_id,
                selection="noop_plus",
            ),
        ),
        repository.select_plan(
            principal=second,
            installation_id="ios-plan-request-second",
            selection=OwnershipPlanSelection(
                request_id=shared_request_id,
                selection="noop",
            ),
        ),
    )

    assert first_result["plan_selection"] == "noop_plus"
    assert second_result["plan_selection"] == "noop"


@pytest.mark.asyncio
async def test_revoked_installation_cannot_claim_or_change_plan(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    _, _, principal = await _register(
        repository,
        subject="revoked-installation-owner",
        installation_id="ios-revoked-installation",
        token_character="A",
    )
    assert primary._pool is not None
    await primary._pool.execute(
        """
        UPDATE ownership_installations
        SET status = 'revoked',
            revoked_at = clock_timestamp()
        WHERE account_id = $1 AND installation_id = $2
        """,
        principal.account_id,
        "ios-revoked-installation",
    )
    _, submission, evidence = await _challenge_and_submission(repository)

    with pytest.raises(OwnershipForbiddenError):
        await repository.claim_band(
            principal=principal,
            installation_id="ios-revoked-installation",
            submission=submission,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )
    with pytest.raises(OwnershipForbiddenError):
        await repository.select_plan(
            principal=principal,
            installation_id="ios-revoked-installation",
            selection=OwnershipPlanSelection(
                request_id=uuid4(),
                selection="noop_plus",
            ),
        )


@pytest.mark.asyncio
async def test_account_deletion_revokes_sessions_schedules_work_and_cancels(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    subject = "account-deletion-owner"
    claims, registration, principal = await _register(
        repository,
        subject=subject,
        installation_id="ios-account-deletion-primary",
        token_character="D",
    )
    await repository.register_account(
        claims=claims,
        registration=_registration(
            installation_id="ios-account-deletion-secondary",
            token_character="E",
        ),
    )
    request = _account_deletion_request()
    token_hash = hashlib.sha256(
        registration.installation_token.get_secret_value().encode("ascii")
    ).hexdigest()

    created = await repository.request_account_deletion(
        claims=claims,
        installation_id=registration.installation_id,
        installation_token_hash=token_hash,
        expected_platform="ios",
        request=request,
        cooling_off=timedelta(hours=24),
    )
    replay = await repository.request_account_deletion(
        claims=claims,
        installation_id=registration.installation_id,
        installation_token_hash=token_hash,
        expected_platform="ios",
        request=request,
        cooling_off=timedelta(hours=24),
    )

    assert created["state"] == "cooling_off"
    assert created["revoked_session_count"] == 2
    assert created["cloud_data_deletion"]["state"] == "scheduled"
    assert created["identity_deletion"] == {
        "state": "blocked",
        "blocker": "provider_credentials_unavailable",
    }
    assert created["band_retirement"]["eligibility"] == "not_required"
    assert created["destructive_completion_claimed"] is False
    assert replay["duplicate"] is True
    assert replay["deletion_request_id"] == created["deletion_request_id"]
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE account_id = $1 AND status = 'active'
            """,
            principal.account_id,
        )
        == 0
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_events
            WHERE account_id = $1
              AND event_kind = 'account_deletion_requested'
            """,
            principal.account_id,
        )
        == 1
    )

    with pytest.raises(OwnershipConflictError):
        await repository.request_account_deletion(
            claims=claims,
            installation_id=registration.installation_id,
            installation_token_hash=token_hash,
            expected_platform="ios",
            request=_account_deletion_request(
                request_id=request.request_id,
                policy_sha256="f" * 64,
            ),
            cooling_off=timedelta(hours=24),
        )

    fresh_claims = _claims(
        subject,
        auth_time=datetime.now(UTC) + timedelta(seconds=1),
    )
    deletion_principal = await repository.principal_for_account_deletion(fresh_claims)
    canceled = await repository.cancel_account_deletion(
        principal=deletion_principal,
        deletion_request_id=UUID(created["deletion_request_id"]),
        installation_id=registration.installation_id,
        installation_token_hash=token_hash,
        expected_platform="ios",
        identity_auth_time=fresh_claims.auth_time,
    )
    canceled_replay = await repository.cancel_account_deletion(
        principal=deletion_principal,
        deletion_request_id=UUID(created["deletion_request_id"]),
        installation_id=registration.installation_id,
        installation_token_hash=token_hash,
        expected_platform="ios",
        identity_auth_time=fresh_claims.auth_time,
    )

    assert canceled["state"] == "canceled"
    assert canceled["account_state"] == "active"
    assert canceled["cancellation_allowed"] is False
    assert canceled["identity_deletion"] == {
        "state": "canceled",
        "blocker": None,
    }
    assert canceled["band_retirement"]["work_state"] == "not_required"
    assert canceled["band_retirement"]["blocker"] is None
    assert canceled["control_plane_deletion"] == {
        "state": "canceled",
        "blocker": None,
    }
    assert canceled_replay["duplicate"] is True
    assert (
        await primary._pool.fetchval(
            "SELECT status FROM ownership_accounts WHERE account_id = $1",
            principal.account_id,
        )
        == "active"
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT count(*)
            FROM ownership_installations
            WHERE account_id = $1 AND status = 'active'
            """,
            principal.account_id,
        )
        == 1
    )
    assert (
        await primary._pool.fetchval(
            """
            SELECT status
            FROM ownership_installations
            WHERE installation_id = $1
            """,
            "ios-account-deletion-secondary",
        )
        == "revoked"
    )


@pytest.mark.asyncio
async def test_account_deletion_progress_is_seeded_reported_and_terminal(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    claims, registration, principal = await _register(
        repository,
        subject="account-deletion-progress-owner",
        installation_id="ios-account-deletion-progress",
        token_character="P",
    )
    created = await repository.request_account_deletion(
        claims=claims,
        installation_id=registration.installation_id,
        installation_token_hash=hashlib.sha256(
            registration.installation_token.get_secret_value().encode("ascii")
        ).hexdigest(),
        expected_platform="ios",
        request=_account_deletion_request(),
        cooling_off=timedelta(hours=24),
    )

    assert primary._pool is not None
    rows = await primary._pool.fetch(
        """
        SELECT target_kind, current_state, blocker, attempt_count
        FROM ownership_account_deletion_target_progress
        WHERE deletion_request_id = $1
        ORDER BY target_kind
        """,
        UUID(created["deletion_request_id"]),
    )
    assert [
        (
            str(row["target_kind"]),
            str(row["current_state"]),
            row["blocker"],
            int(row["attempt_count"]),
        )
        for row in rows
    ] == [
        ("band_retirement", "not_required", None, 0),
        (
            "identity_provider",
            "blocked",
            "provider_credentials_unavailable",
            0,
        ),
        ("managed_cloud_data", "scheduled", None, 0),
        (
            "ownership_control_plane",
            "blocked",
            "identity_provider_pending",
            0,
        ),
    ]

    lease_owner = uuid4()
    await primary._pool.execute(
        """
        UPDATE ownership_account_deletion_target_progress
        SET current_state = 'processing',
            attempt_count = 1,
            lease_owner = $2,
            lease_expires_at = clock_timestamp() + interval '10 minutes',
            updated_at = clock_timestamp()
        WHERE deletion_request_id = $1
          AND target_kind = 'managed_cloud_data'
        """,
        UUID(created["deletion_request_id"]),
        lease_owner,
    )
    processing = await repository.get_account_deletion(
        principal=principal,
        deletion_request_id=UUID(created["deletion_request_id"]),
    )
    assert processing["cloud_data_deletion"]["state"] == "processing"

    await primary._pool.execute(
        """
        UPDATE ownership_account_deletion_target_progress
        SET current_state = 'not_required',
            lease_owner = NULL,
            lease_expires_at = NULL,
            updated_at = clock_timestamp(),
            completed_at = clock_timestamp()
        WHERE deletion_request_id = $1
          AND target_kind = 'managed_cloud_data'
        """,
        UUID(created["deletion_request_id"]),
    )
    completed = await repository.get_account_deletion(
        principal=principal,
        deletion_request_id=UUID(created["deletion_request_id"]),
    )
    assert completed["cloud_data_deletion"]["state"] == "not_required"

    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_account_deletion_target_progress
            SET current_state = 'scheduled',
                completed_at = NULL,
                updated_at = clock_timestamp()
            WHERE deletion_request_id = $1
              AND target_kind = 'managed_cloud_data'
            """,
            UUID(created["deletion_request_id"]),
        )


@pytest.mark.asyncio
async def test_account_deletion_worker_claims_due_rows_with_cas_and_leases(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    _, _, principal = await _register(
        repository,
        subject="account-deletion-worker-owner",
        installation_id="ios-account-deletion-worker",
        token_character="W",
    )
    assert primary._pool is not None
    identity_id = await primary._pool.fetchval(
        """
        SELECT identity_id
        FROM ownership_external_identities
        WHERE account_id = $1
        """,
        principal.account_id,
    )
    deletion_request_id = uuid4()
    requested_at = datetime.now(UTC) - timedelta(hours=2)
    cancel_before = requested_at + timedelta(hours=1)
    await primary._pool.execute(
        """
        INSERT INTO ownership_account_deletion_requests (
            deletion_request_id,
            account_id,
            request_id,
            request_digest,
            requester_identity_hash,
            requester_installation_hash,
            policy_version,
            locale,
            document_sha256,
            export_acknowledged_at,
            retention_acknowledged_at,
            sessions_revoked_at,
            sessions_revoked_count,
            requested_at,
            cancel_before
        ) VALUES (
            $1, $2, $3, $4, $5, $6, 'ownership-v1', 'en', $7,
            $8, $8, $8, 1, $8, $9
        )
        """,
        deletion_request_id,
        principal.account_id,
        uuid4(),
        "d" * 64,
        hashlib.sha256(str(identity_id).encode("utf-8")).hexdigest(),
        "c" * 64,
        TERMS_SHA256,
        requested_at,
        cancel_before,
    )
    await primary._pool.execute(
        """
        INSERT INTO ownership_account_deletion_targets (
            deletion_request_id,
            target_kind,
            initial_state,
            scheduled_at,
            not_before
        ) VALUES ($1, 'managed_cloud_data', 'scheduled', $2, $3)
        """,
        deletion_request_id,
        requested_at,
        cancel_before,
    )

    progress = PostgresOwnershipDeletionProgressRepository(primary)
    first_owner = uuid4()
    first = await progress.claim_due_managed_targets(
        now=datetime.now(UTC),
        lease_owner=first_owner,
        lease_seconds=300,
        limit=10,
    )
    assert len(first) == 1
    assert first[0].deletion_request_id == deletion_request_id
    assert first[0].progress_version == 1
    assert first[0].attempt_count == 1

    assert (
        await progress.persist_managed_target_state(
            target=first[0],
            lease_owner=uuid4(),
            transition=OwnershipManagedTargetTransition(
                state="not_required",
            ),
            now=datetime.now(UTC),
        )
        is False
    )
    await primary._pool.execute(
        """
        UPDATE ownership_account_deletion_target_progress
        SET lease_expires_at = clock_timestamp() - interval '1 second'
        WHERE deletion_request_id = $1
          AND target_kind = 'managed_cloud_data'
        """,
        deletion_request_id,
    )
    second_owner = uuid4()
    reclaimed = await progress.claim_due_managed_targets(
        now=datetime.now(UTC),
        lease_owner=second_owner,
        lease_seconds=300,
        limit=10,
    )
    assert len(reclaimed) == 1
    assert reclaimed[0].progress_version == 2
    assert reclaimed[0].attempt_count == 2
    assert (
        await progress.persist_managed_target_state(
            target=reclaimed[0],
            lease_owner=second_owner,
            transition=OwnershipManagedTargetTransition(
                state="not_required",
            ),
            now=datetime.now(UTC),
        )
        is True
    )
    terminal = await primary._pool.fetchrow(
        """
        SELECT current_state,
               progress_version,
               attempt_count,
               lease_owner,
               completed_at
        FROM ownership_account_deletion_target_progress
        WHERE deletion_request_id = $1
          AND target_kind = 'managed_cloud_data'
        """,
        deletion_request_id,
    )
    assert terminal["current_state"] == "not_required"
    assert terminal["progress_version"] == 3
    assert terminal["attempt_count"] == 2
    assert terminal["lease_owner"] is None
    assert terminal["completed_at"] is not None
    assert (
        await progress.persist_managed_target_state(
            target=reclaimed[0],
            lease_owner=second_owner,
            transition=OwnershipManagedTargetTransition(
                state="not_required",
            ),
            now=datetime.now(UTC),
        )
        is False
    )


@pytest.mark.asyncio
async def test_pre_deadline_cancellation_fences_post_deadline_managed_claim(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    subject = "account-deletion-cancellation-race-owner"
    _, registration, principal = await _register(
        repository,
        subject=subject,
        installation_id="ios-account-deletion-cancellation-race",
        token_character="R",
    )
    token_hash = hashlib.sha256(
        registration.installation_token.get_secret_value().encode("ascii")
    ).hexdigest()
    deletion_request_id = uuid4()
    requested_at = datetime.now(UTC)
    cancel_before = requested_at + timedelta(seconds=4)
    assert primary._pool is not None
    async with primary._pool.acquire() as connection:
        async with connection.transaction():
            identity_id = await connection.fetchval(
                """
                SELECT identity_id
                FROM ownership_external_identities
                WHERE account_id = $1
                """,
                principal.account_id,
            )
            await connection.execute(
                """
                INSERT INTO ownership_account_deletion_requests (
                    deletion_request_id,
                    account_id,
                    request_id,
                    request_digest,
                    requester_identity_hash,
                    requester_installation_hash,
                    policy_version,
                    locale,
                    document_sha256,
                    export_acknowledged_at,
                    retention_acknowledged_at,
                    sessions_revoked_at,
                    sessions_revoked_count,
                    requested_at,
                    cancel_before
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, 'ownership-v1', 'en', $7,
                    $8, $8, $8, 1, $8, $9
                )
                """,
                deletion_request_id,
                principal.account_id,
                uuid4(),
                "d" * 64,
                hashlib.sha256(str(identity_id).encode("utf-8")).hexdigest(),
                hashlib.sha256(
                    registration.installation_id.encode("utf-8")
                ).hexdigest(),
                TERMS_SHA256,
                requested_at,
                cancel_before,
            )
            await connection.executemany(
                """
                INSERT INTO ownership_account_deletion_targets (
                    deletion_request_id,
                    target_kind,
                    initial_state,
                    blocker,
                    scheduled_at,
                    not_before
                ) VALUES ($1, $2, $3, $4, $5, $6)
                """,
                [
                    (
                        deletion_request_id,
                        "managed_cloud_data",
                        "scheduled",
                        None,
                        requested_at,
                        cancel_before,
                    ),
                    (
                        deletion_request_id,
                        "identity_provider",
                        "blocked",
                        "provider_credentials_unavailable",
                        requested_at,
                        cancel_before,
                    ),
                    (
                        deletion_request_id,
                        "band_retirement",
                        "not_required",
                        None,
                        requested_at,
                        cancel_before,
                    ),
                    (
                        deletion_request_id,
                        "ownership_control_plane",
                        "blocked",
                        "identity_provider_pending",
                        requested_at,
                        cancel_before,
                    ),
                ],
            )
            await connection.execute(
                """
                UPDATE ownership_installations
                SET status = 'revoked',
                    revoked_at = $3,
                    last_seen_at = GREATEST(last_seen_at, $3)
                WHERE account_id = $1 AND installation_id = $2
                """,
                principal.account_id,
                registration.installation_id,
                requested_at,
            )
            await connection.execute(
                """
                UPDATE ownership_accounts
                SET status = 'deletion_pending',
                    auth_valid_after = $2,
                    deletion_requested_at = $2,
                    updated_at = $2
                WHERE account_id = $1
                """,
                principal.account_id,
                requested_at,
            )
    fresh_claims = _claims(
        subject,
        auth_time=datetime.now(UTC) + timedelta(seconds=1),
    )
    deletion_principal = await repository.principal_for_account_deletion(fresh_claims)
    progress = PostgresOwnershipDeletionProgressRepository(primary)

    async with primary._pool.acquire() as blocker:
        async with blocker.transaction():
            await blocker.fetchval(
                """
                SELECT 1
                FROM ownership_account_deletion_target_progress
                WHERE deletion_request_id = $1
                  AND target_kind = 'managed_cloud_data'
                FOR UPDATE
                """,
                deletion_request_id,
            )
            cancel_task = asyncio.create_task(
                repository.cancel_account_deletion(
                    principal=deletion_principal,
                    deletion_request_id=deletion_request_id,
                    installation_id=registration.installation_id,
                    installation_token_hash=token_hash,
                    expected_platform="ios",
                    identity_auth_time=fresh_claims.auth_time,
                )
            )
            await _wait_for_lock_waiters(primary._pool, minimum=1)
            assert datetime.now(UTC) < cancel_before
            await asyncio.sleep(
                max(
                    0.0,
                    (cancel_before - datetime.now(UTC)).total_seconds() + 0.1,
                )
            )

            claimed = await asyncio.wait_for(
                progress.claim_due_managed_targets(
                    now=datetime.now(UTC),
                    lease_owner=uuid4(),
                    lease_seconds=300,
                    limit=10,
                ),
                timeout=2,
            )
            assert claimed == []

        canceled = await asyncio.wait_for(cancel_task, timeout=2)

    assert canceled["state"] == "canceled"
    state = await primary._pool.fetchrow(
        """
        SELECT request.canceled_at,
               progress.current_state,
               progress.attempt_count,
               progress.managed_erasure_job_id
        FROM ownership_account_deletion_requests request
        JOIN ownership_account_deletion_target_progress progress
          USING (deletion_request_id)
        WHERE request.deletion_request_id = $1
          AND progress.target_kind = 'managed_cloud_data'
        """,
        deletion_request_id,
    )
    assert state["canceled_at"] is not None
    assert state["current_state"] == "scheduled"
    assert state["attempt_count"] == 0
    assert state["managed_erasure_job_id"] is None


@pytest.mark.asyncio
async def test_account_deletion_band_retirement_is_fail_closed_and_tenant_scoped(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    await _provision_band(primary)
    claims, registration, principal = await _register(
        repository,
        subject="account-deletion-band-owner",
        installation_id="ios-account-deletion-band",
        token_character="F",
    )
    _, submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id=registration.installation_id,
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    request = _account_deletion_request()
    created = await repository.request_account_deletion(
        claims=claims,
        installation_id=registration.installation_id,
        installation_token_hash=hashlib.sha256(
            registration.installation_token.get_secret_value().encode("ascii")
        ).hexdigest(),
        expected_platform="ios",
        request=request,
        cooling_off=timedelta(hours=24),
    )

    assert created["band_retirement"] == {
        "required": True,
        "eligibility": "blocked_policy",
        "work_state": "blocked",
        "blocker": "policy_unapproved",
        "policy_version": None,
        "hardware_capability_version": None,
    }
    assert primary._pool is not None
    band = await primary._pool.fetchrow(
        """
        SELECT status, current_account_id, released_at
        FROM ownership_bands
        WHERE provisioned_identity_hash = $1
        """,
        BAND_IDENTITY_HASH,
    )
    assert band["status"] == "claimed"
    assert band["current_account_id"] == principal.account_id
    assert band["released_at"] is None
    assert await primary._pool.fetchval("SELECT count(*) FROM ownership_releases") == 0

    _, _, other_principal = await _register(
        repository,
        subject="account-deletion-other-owner",
        installation_id="ios-account-deletion-other",
        token_character="G",
    )
    with pytest.raises(OwnershipNotFoundError):
        await repository.get_account_deletion(
            principal=other_principal,
            deletion_request_id=UUID(created["deletion_request_id"]),
        )


@pytest.mark.asyncio
async def test_retirement_eligibility_never_claims_hardware_completion(
    ownership_repository,
) -> None:
    _, primary = ownership_repository

    class EligibleRetirementEvaluator:
        def evaluate(self, **_: object) -> OwnershipBandRetirementEligibility:
            return OwnershipBandRetirementEligibility(
                state="eligible_pending_operator",
                policy_version="india-deletion-v1",
                hardware_capability_version="band-wipe-v1",
            )

    repository = PostgresOwnershipRepository(
        primary,
        retirement_evaluator=EligibleRetirementEvaluator(),
    )
    await _provision_band(primary)
    claims, registration, principal = await _register(
        repository,
        subject="eligible-retirement-owner",
        installation_id="ios-eligible-retirement",
        token_character="H",
    )
    _, submission, evidence = await _challenge_and_submission(repository)
    await repository.claim_band(
        principal=principal,
        installation_id=registration.installation_id,
        submission=submission,
        evidence=evidence,
        app_id=APPLE_APP_ID,
        platform="ios",
    )
    created = await repository.request_account_deletion(
        claims=claims,
        installation_id=registration.installation_id,
        installation_token_hash=hashlib.sha256(
            registration.installation_token.get_secret_value().encode("ascii")
        ).hexdigest(),
        expected_platform="ios",
        request=_account_deletion_request(),
        cooling_off=timedelta(hours=24),
    )

    assert created["band_retirement"]["eligibility"] == ("eligible_pending_operator")
    assert created["band_retirement"]["work_state"] == "blocked"
    assert created["band_retirement"]["blocker"] == "operator_approval_required"
    assert created["destructive_completion_claimed"] is False
    assert primary._pool is not None
    assert (
        await primary._pool.fetchval(
            """
            SELECT status
            FROM ownership_bands
            WHERE current_account_id = $1
            """,
            principal.account_id,
        )
        == "claimed"
    )
    assert await primary._pool.fetchval("SELECT count(*) FROM ownership_releases") == 0


@pytest.mark.asyncio
async def test_ownership_terms_metadata_is_immutable_and_retirement_is_one_way(
    ownership_repository,
) -> None:
    _, primary = ownership_repository
    assert primary._pool is not None

    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_terms_documents
            SET document_sha256 = $1
            WHERE policy_version = 'ownership-v1' AND locale = 'en'
            """,
            "c" * 64,
        )
    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            DELETE FROM ownership_terms_documents
            WHERE policy_version = 'ownership-v1' AND locale = 'en'
            """
        )

    await primary._pool.execute(
        """
        UPDATE ownership_terms_documents
        SET retired_at = clock_timestamp()
        WHERE policy_version = 'ownership-v1' AND locale = 'en'
        """
    )
    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_terms_documents
            SET retired_at = NULL
            WHERE policy_version = 'ownership-v1' AND locale = 'en'
            """
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "document_uri",
    [
        "https://user@terms.noop.example/ownership-v2/en",
        "https://user:secret@terms.noop.example/ownership-v2/en",
        "https://terms.noop.example:8443/ownership-v2/en",
        "https://terms.noop.example/ownership-v2/en?next=other",
        "https://terms.noop.example/ownership-v2/en#current",
    ],
)
async def test_ownership_terms_metadata_rejects_dynamic_or_credentialed_urls(
    ownership_repository,
    document_uri: str,
) -> None:
    _, primary = ownership_repository
    assert primary._pool is not None

    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            INSERT INTO ownership_terms_documents (
                policy_version,
                locale,
                document_sha256,
                document_uri,
                effective_at
            ) VALUES (
                'ownership-v2',
                'en',
                $1,
                $2,
                clock_timestamp()
            )
            """,
            "c" * 64,
            document_uri,
        )


@pytest.mark.asyncio
async def test_current_terms_use_english_version_with_localized_fallback(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    assert primary._pool is not None
    french_v1_sha = "d" * 64
    english_v2_sha = "e" * 64
    french_v2_sha = "f" * 64
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v1',
            'fr',
            $1,
            'https://terms.noop.example/ownership-v1/fr',
            clock_timestamp() - interval '30 seconds'
        )
        """,
        french_v1_sha,
    )
    localized_v1 = await repository.terms_manifest(locale="fr")
    assert localized_v1["policy_version"] == "ownership-v1"
    assert localized_v1["locale"] == "fr"
    assert localized_v1["document_sha256"] == french_v1_sha

    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'en',
            $1,
            'https://terms.noop.example/ownership-v2/en',
            clock_timestamp()
        )
        """,
        english_v2_sha,
    )
    fallback = await repository.terms_manifest(locale="fr")
    assert fallback["policy_version"] == "ownership-v2"
    assert fallback["locale"] == "en"
    assert fallback["document_sha256"] == english_v2_sha

    historical = await repository.terms_manifest_version(
        policy_version="ownership-v1",
        locale="fr",
    )
    assert historical["locale"] == "fr"
    assert historical["document_sha256"] == french_v1_sha

    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'fr',
            $1,
            'https://terms.noop.example/ownership-v2/fr',
            clock_timestamp()
        )
        """,
        french_v2_sha,
    )
    localized_v2 = await repository.terms_manifest(locale="fr")
    assert localized_v2["policy_version"] == "ownership-v2"
    assert localized_v2["locale"] == "fr"
    assert localized_v2["document_sha256"] == french_v2_sha


@pytest.mark.asyncio
async def test_stale_localized_acceptance_cannot_bypass_new_english_terms(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    assert primary._pool is not None
    french_v1_sha = "d" * 64
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v1',
            'fr',
            $1,
            'https://terms.noop.example/ownership-v1/fr',
            clock_timestamp() - interval '30 seconds'
        )
        """,
        french_v1_sha,
    )
    claims = _claims("localized-policy-owner")
    registration = _registration(
        installation_id="ios-localized-policy",
        token_character="L",
    ).model_copy(
        update={
            "locale": "fr",
            "policy_sha256": french_v1_sha,
        }
    )
    await repository.register_account(
        claims=claims,
        registration=registration,
    )
    principal = await repository.principal_for_identity(claims)

    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'en',
            $1,
            'https://terms.noop.example/ownership-v2/en',
            clock_timestamp()
        )
        """,
        "e" * 64,
    )

    with pytest.raises(OwnershipConfigurationError):
        await repository.ensure_current_terms(principal=principal)
    with pytest.raises(OwnershipConfigurationError):
        await repository.register_account(
            claims=_claims("stale-localized-registration"),
            registration=_registration(
                installation_id="ios-stale-localized-registration",
                token_character="S",
            ).model_copy(
                update={
                    "locale": "fr",
                    "policy_sha256": french_v1_sha,
                }
            ),
        )
    with pytest.raises(OwnershipConfigurationError):
        await repository.accept_terms(
            principal=principal,
            acceptance=OwnershipTermsAcceptance(
                request_id=uuid4(),
                policy_version="ownership-v1",
                policy_sha256=french_v1_sha,
                locale="fr",
            ),
        )


@pytest.mark.asyncio
async def test_registration_rejects_a_superseded_active_terms_version(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    assert primary._pool is not None
    await primary._pool.execute(
        """
        INSERT INTO ownership_terms_documents (
            policy_version,
            locale,
            document_sha256,
            document_uri,
            effective_at
        ) VALUES (
            'ownership-v2',
            'en',
            $1,
            'https://terms.noop.example/ownership-v2/en',
            clock_timestamp() - interval '1 second'
        )
        """,
        "c" * 64,
    )

    with pytest.raises(OwnershipConfigurationError):
        await repository.register_account(
            claims=_claims("stale-terms-subject"),
            registration=_registration(
                installation_id="ios-stale-terms",
                token_character="S",
            ),
        )


@pytest.mark.asyncio
async def test_terms_acceptance_digest_is_bound_to_immutable_document(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    _, _, principal = await _register(
        repository,
        subject="terms-digest-owner",
        installation_id="ios-terms-digest",
        token_character="T",
    )
    assert primary._pool is not None

    with pytest.raises(asyncpg.ForeignKeyViolationError):
        await primary._pool.execute(
            """
            INSERT INTO ownership_terms_acceptances (
                acceptance_id,
                account_id,
                policy_version,
                locale,
                document_sha256,
                request_id,
                request_digest,
                accepted_at,
                recorded_at
            ) VALUES (
                $1,
                $2,
                'ownership-v1',
                'en',
                $3,
                $4,
                $5,
                clock_timestamp(),
                clock_timestamp()
            )
            """,
            uuid4(),
            principal.account_id,
            "c" * 64,
            uuid4(),
            "d" * 64,
        )


@pytest.mark.asyncio
async def test_ownership_schema_contains_no_health_or_contact_columns(
    ownership_repository,
) -> None:
    _, primary = ownership_repository
    assert primary._pool is not None
    columns = await primary._pool.fetch(
        """
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name LIKE 'ownership_%'
        """
    )
    names = {f"{row['table_name']}.{row['column_name']}".casefold() for row in columns}
    prohibited_fragments = {
        "email_address",
        "phone_number",
        "password",
        "otp",
        "health",
        "biometric",
        "sensor",
        "sample",
        "journal",
        "printed_number",
        "possession_response",
    }
    assert not {
        name
        for name in names
        if any(fragment in name for fragment in prohibited_fragments)
    }


@pytest.mark.asyncio
async def test_ownership_readiness_rejects_the_broad_migration_principal(
    ownership_repository,
) -> None:
    repository, _ = ownership_repository

    assert await repository.configuration_ready() is False


@pytest.mark.asyncio
async def test_deletion_lifecycle_readiness_requires_exact_restricted_principal(
    ownership_repository,
) -> None:
    _, primary = ownership_repository
    assert DATABASE_URL is not None
    assert primary._pool is not None
    role = f"noop_ownership_lifecycle_test_{uuid4().hex}"
    password = uuid4().hex + uuid4().hex
    quoted_role = f'"{role}"'
    database_name = await primary._pool.fetchval("SELECT current_database()")
    quoted_database = '"' + str(database_name).replace('"', '""') + '"'
    await primary._pool.execute(
        f"""
        CREATE ROLE {quoted_role}
        LOGIN PASSWORD '{password}'
        NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
        NOREPLICATION NOBYPASSRLS
        """
    )
    restricted: PostgresRepository | None = None
    public_schema_create_revoked = False
    try:
        await primary._pool.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        public_schema_create_revoked = True
        await primary._pool.execute(
            f"""
            GRANT CONNECT ON DATABASE {quoted_database} TO {quoted_role};
            GRANT USAGE ON SCHEMA public TO {quoted_role};
            GRANT SELECT ON TABLE
                ownership_account_deletion_target_progress,
                ownership_account_deletion_requests,
                ownership_external_identities
            TO {quoted_role};
            GRANT UPDATE (
                current_state,
                blocker,
                progress_version,
                attempt_count,
                lease_owner,
                lease_expires_at,
                retry_after,
                managed_erasure_job_id,
                last_error_kind,
                updated_at,
                completed_at
            ) ON TABLE ownership_account_deletion_target_progress
            TO {quoted_role}
            """
        )
        parsed = urlsplit(DATABASE_URL)
        host = parsed.hostname or "127.0.0.1"
        if ":" in host:
            host = f"[{host}]"
        if parsed.port is not None:
            host = f"{host}:{parsed.port}"
        restricted_url = urlunsplit(
            (
                parsed.scheme,
                f"{quote(role)}:{quote(password)}@{host}",
                parsed.path,
                parsed.query,
                parsed.fragment,
            )
        )
        restricted = PostgresRepository(
            restricted_url,
            pool_min_size=1,
            pool_max_size=1,
            run_migrations=False,
            database_engine="postgresql",
        )
        await restricted.startup()
        scoped = PostgresOwnershipDeletionProgressRepository(restricted)

        assert await scoped.configuration_ready() is True
        assert (
            await scoped.claim_due_managed_targets(
                now=datetime.now(UTC),
                lease_owner=uuid4(),
                lease_seconds=300,
                limit=1,
            )
            == []
        )

        await primary._pool.execute(
            f"GRANT SELECT ON TABLE ownership_bands TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE SELECT ON TABLE ownership_bands FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "GRANT UPDATE (target_kind) ON TABLE "
            f"ownership_account_deletion_target_progress TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE UPDATE (target_kind) ON TABLE "
            f"ownership_account_deletion_target_progress FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "REVOKE UPDATE (retry_after) ON TABLE "
            f"ownership_account_deletion_target_progress FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
    finally:
        if restricted is not None:
            await restricted.shutdown()
        await primary._pool.execute(f"DROP OWNED BY {quoted_role}")
        await primary._pool.execute(f"DROP ROLE {quoted_role}")
        if public_schema_create_revoked:
            await primary._pool.execute("GRANT CREATE ON SCHEMA public TO PUBLIC")


@pytest.mark.asyncio
async def test_ownership_readiness_accepts_only_a_restricted_principal(
    ownership_repository,
) -> None:
    _, primary = ownership_repository
    assert DATABASE_URL is not None
    assert primary._pool is not None
    role = f"noop_ownership_test_{uuid4().hex}"
    inherited_role = f"noop_ownership_parent_{uuid4().hex}"
    owned_schema = f"ownership_owned_{uuid4().hex}"
    test_sequence = f"ownership_sequence_{uuid4().hex}"
    ordinary_function = f"ownership_owned_function_{uuid4().hex}"
    password = uuid4().hex + uuid4().hex
    quoted_role = f'"{role}"'
    quoted_inherited_role = f'"{inherited_role}"'
    quoted_owned_schema = f'"{owned_schema}"'
    quoted_test_sequence = f'"{test_sequence}"'
    quoted_ordinary_function = f'"{ordinary_function}"'
    database_name = await primary._pool.fetchval("SELECT current_database()")
    quoted_database = '"' + str(database_name).replace('"', '""') + '"'
    await primary._pool.execute(
        f"""
        CREATE ROLE {quoted_role}
        LOGIN PASSWORD '{password}'
        NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
        NOREPLICATION NOBYPASSRLS
        """
    )
    restricted: PostgresRepository | None = None
    public_schema_create_revoked = False
    public_database_temporary_granted = bool(
        await primary._pool.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM pg_database database
                CROSS JOIN LATERAL aclexplode(
                    COALESCE(
                        database.datacl,
                        acldefault('d', database.datdba)
                    )
                ) AS permission
                WHERE database.datname = current_database()
                  AND permission.grantee = 0
                  AND permission.privilege_type = 'TEMPORARY'
            )
            """
        )
    )
    try:
        await primary._pool.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        public_schema_create_revoked = True
        await primary._pool.execute(
            f"REVOKE TEMPORARY ON DATABASE {quoted_database} FROM PUBLIC"
        )
        await primary._pool.execute(
            f"GRANT CONNECT ON DATABASE {quoted_database} TO {quoted_role}"
        )
        await primary._pool.execute(f"GRANT USAGE ON SCHEMA public TO {quoted_role}")
        await primary._pool.execute(
            f"""
            GRANT SELECT, INSERT ON TABLE
                ownership_accounts
            TO {quoted_role};
            GRANT SELECT, INSERT ON TABLE
                ownership_external_identities,
                ownership_installations,
                ownership_possession_challenges,
                ownership_plan_selections
            TO {quoted_role};
            GRANT SELECT ON TABLE
                ownership_terms_documents
            TO {quoted_role};
            GRANT SELECT, INSERT ON TABLE
                ownership_terms_acceptances,
                ownership_claim_requests,
                ownership_installation_authorizations,
                ownership_plan_selection_requests,
                ownership_account_deletion_requests,
                ownership_account_deletion_targets
            TO {quoted_role};
            GRANT SELECT ON TABLE
                ownership_account_deletion_target_progress
            TO {quoted_role};
            GRANT SELECT ON TABLE
                ownership_bands
            TO {quoted_role};
            GRANT INSERT ON TABLE
                ownership_band_claims,
                ownership_events
            TO {quoted_role};
            GRANT UPDATE (
                email_verified,
                phone_verified,
                last_seen_at
            ) ON TABLE ownership_external_identities TO {quoted_role};
            GRANT UPDATE (
                device_key_fingerprint,
                status,
                last_seen_at,
                revoked_at
            ) ON TABLE ownership_installations TO {quoted_role};
            GRANT UPDATE (
                status,
                current_account_id,
                claimed_at,
                firmware_version,
                updated_at
            ) ON TABLE ownership_bands TO {quoted_role};
            GRANT UPDATE (
                status,
                consumed_at
            ) ON TABLE ownership_possession_challenges TO {quoted_role};
            GRANT UPDATE (
                selection,
                request_id,
                updated_at
            ) ON TABLE ownership_plan_selections TO {quoted_role};
            GRANT UPDATE (
                status,
                auth_valid_after,
                updated_at,
                deletion_requested_at
            ) ON TABLE ownership_accounts TO {quoted_role};
                GRANT UPDATE (
                    canceled_at
                ) ON TABLE ownership_account_deletion_requests TO {quoted_role};
                GRANT EXECUTE ON FUNCTION
                    noop_ownership_lock_unified_principal(text, text, text)
                TO {quoted_role}
            """
        )
        parsed = urlsplit(DATABASE_URL)
        host = parsed.hostname or "127.0.0.1"
        if ":" in host:
            host = f"[{host}]"
        if parsed.port is not None:
            host = f"{host}:{parsed.port}"
        restricted_url = urlunsplit(
            (
                parsed.scheme,
                f"{quote(role)}:{quote(password)}@{host}",
                parsed.path,
                parsed.query,
                parsed.fragment,
            )
        )
        restricted = PostgresRepository(
            restricted_url,
            pool_min_size=1,
            pool_max_size=1,
            run_migrations=False,
            database_engine="postgresql",
        )
        await restricted.startup()
        scoped = PostgresOwnershipRepository(restricted)
        assert await scoped.configuration_ready() is True
        assert await scoped.runtime_ready() is True
        provisioner = _load_ownership_provisioner()
        async with restricted._require_pool().acquire() as restricted_connection:
            await provisioner.verify_role(restricted_connection)

        await _provision_band(primary)
        claims, _, principal = await _register(
            scoped,
            subject="restricted-runtime-owner",
            installation_id="ios-restricted-runtime",
            token_character="R",
        )
        await scoped.principal_for_identity(claims)
        rejected = await scoped.create_challenge(
            request_id=uuid4(),
            platform="ios",
            app_id=APPLE_APP_ID,
            ttl_seconds=180,
        )
        await scoped.reject_challenge(
            challenge_id=rejected.challenge_id,
            challenge=rejected.challenge,
            app_id=APPLE_APP_ID,
        )
        _, submission, evidence = await _challenge_and_submission(scoped)
        claim = await scoped.claim_band(
            principal=principal,
            installation_id="ios-restricted-runtime",
            submission=submission,
            evidence=evidence,
            app_id=APPLE_APP_ID,
            platform="ios",
        )
        assert claim.outcome == "claimed"
        selected = await scoped.select_plan(
            principal=principal,
            installation_id="ios-restricted-runtime",
            selection=OwnershipPlanSelection(
                request_id=uuid4(),
                selection="noop_plus",
            ),
        )
        assert selected["plan_selection"] == "noop_plus"
        assert selected["noop_plus_entitled"] is False

        await primary._pool.execute(f"ALTER ROLE {quoted_role} INHERIT")
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(f"ALTER ROLE {quoted_role} NOINHERIT")
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(f"CREATE ROLE {quoted_inherited_role} NOLOGIN")
        await primary._pool.execute(f"GRANT {quoted_inherited_role} TO {quoted_role}")
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE {quoted_inherited_role} FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(f"GRANT CREATE ON SCHEMA public TO {quoted_role}")
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE CREATE ON SCHEMA public FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"GRANT CREATE ON DATABASE {quoted_database} TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE CREATE ON DATABASE {quoted_database} FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"GRANT TEMPORARY ON DATABASE {quoted_database} TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE TEMPORARY ON DATABASE {quoted_database} FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"CREATE SCHEMA {quoted_owned_schema} AUTHORIZATION {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(f"DROP SCHEMA {quoted_owned_schema}")
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(f"CREATE SEQUENCE public.{quoted_test_sequence}")
        await primary._pool.execute(
            f"GRANT USAGE ON SEQUENCE public.{quoted_test_sequence} TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE USAGE ON SEQUENCE public.{quoted_test_sequence} FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True
        await primary._pool.execute(f"DROP SEQUENCE public.{quoted_test_sequence}")

        await primary._pool.execute(
            "REVOKE EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "GRANT EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "GRANT EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"TO {quoted_role} WITH GRANT OPTION"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "GRANT EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"TO {quoted_inherited_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"FROM {quoted_inherited_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "GRANT EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            "TO PUBLIC"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE EXECUTE ON FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            "FROM PUBLIC"
        )
        assert await scoped.configuration_ready() is True

        quoted_principal_table_owner = await primary._pool.fetchval(
            """
            SELECT format('%I', pg_get_userbyid(candidate.relowner))
            FROM pg_class candidate
            JOIN pg_namespace namespace
              ON namespace.oid = candidate.relnamespace
            WHERE namespace.nspname = 'public'
              AND candidate.relname = 'unified_account_principals'
              AND candidate.relkind IN ('r', 'p')
            """
        )
        assert quoted_principal_table_owner is not None
        await primary._pool.execute(
            "ALTER FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"OWNER TO {quoted_inherited_role}"
        )
        assert await scoped.configuration_ready() is False
        with pytest.raises(provisioner.ProvisioningError):
            async with restricted._require_pool().acquire() as restricted_connection:
                await provisioner.verify_role(restricted_connection)
        await primary._pool.execute(
            "ALTER FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) "
            f"OWNER TO {quoted_principal_table_owner}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "ALTER FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) STABLE"
        )
        assert await scoped.configuration_ready() is False
        with pytest.raises(provisioner.ProvisioningError):
            async with restricted._require_pool().acquire() as restricted_connection:
                await provisioner.verify_role(restricted_connection)
        await primary._pool.execute(
            "ALTER FUNCTION "
            "noop_ownership_lock_unified_principal(text, text, text) VOLATILE"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"""
            CREATE FUNCTION public.{quoted_ordinary_function}()
            RETURNS integer
            LANGUAGE sql
            AS 'SELECT 1';
            ALTER FUNCTION public.{quoted_ordinary_function}()
                OWNER TO {quoted_role};
            """
        )
        assert await scoped.configuration_ready() is False
        with pytest.raises(provisioner.ProvisioningError):
            await provisioner.assert_role_owns_no_objects(primary._pool, role)
        with pytest.raises(provisioner.ProvisioningError):
            async with restricted._require_pool().acquire() as restricted_connection:
                await provisioner.verify_role(restricted_connection)
        await primary._pool.execute(
            "ALTER FUNCTION public."
            f"{quoted_ordinary_function}() OWNER TO {quoted_principal_table_owner}"
        )
        await primary._pool.execute(
            f"DROP FUNCTION public.{quoted_ordinary_function}()"
        )
        assert await scoped.configuration_ready() is True

        security_definer_function = f"ownership_escalation_{uuid4().hex}"
        quoted_security_definer_function = f'"{security_definer_function}"'
        await primary._pool.execute(
            f"""
            CREATE FUNCTION public.{quoted_security_definer_function}()
            RETURNS integer
            LANGUAGE sql
            SECURITY DEFINER
            AS 'SELECT 1'
            """
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE EXECUTE ON FUNCTION public."
            f"{quoted_security_definer_function}() FROM PUBLIC"
        )
        assert await scoped.configuration_ready() is True
        await primary._pool.execute(
            "GRANT EXECUTE ON FUNCTION public."
            f"{quoted_security_definer_function}() TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            "REVOKE EXECUTE ON FUNCTION public."
            f"{quoted_security_definer_function}() FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True
        await primary._pool.execute(
            f"DROP FUNCTION public.{quoted_security_definer_function}()"
        )

        await primary._pool.execute(
            """
            UPDATE ownership_terms_documents
            SET retired_at = clock_timestamp()
            WHERE policy_version = 'ownership-v1' AND locale = 'en'
            """
        )
        await primary._pool.execute(
            """
            INSERT INTO ownership_terms_documents (
                policy_version,
                locale,
                document_sha256,
                document_uri,
                effective_at
            ) VALUES (
                'ownership-v1',
                'fr',
                $1,
                'https://terms.noop.example/ownership-v1/fr',
                clock_timestamp() - interval '1 minute'
            )
            """,
            "b" * 64,
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            """
            INSERT INTO ownership_terms_documents (
                policy_version,
                locale,
                document_sha256,
                document_uri,
                effective_at
            ) VALUES (
                'ownership-v2',
                'en',
                $1,
                'https://terms.noop.example/ownership-v2/en',
                clock_timestamp() - interval '1 minute'
            )
            """,
            "c" * 64,
        )
        assert await scoped.configuration_ready() is True

        for privilege in (
            "UPDATE",
            "DELETE",
            "TRUNCATE",
            "REFERENCES",
            "TRIGGER",
        ):
            await primary._pool.execute(
                f"GRANT {privilege} ON TABLE ownership_accounts TO {quoted_role}"
            )
            assert await scoped.configuration_ready() is False
            await primary._pool.execute(
                f"REVOKE {privilege} ON TABLE ownership_accounts FROM {quoted_role}"
            )
            if privilege == "UPDATE":
                await primary._pool.execute(
                    """
                    GRANT UPDATE (
                        status,
                        auth_valid_after,
                        updated_at,
                        deletion_requested_at
                    ) ON TABLE ownership_accounts TO """
                    f"{quoted_role}"
                )
            assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"GRANT SELECT ON TABLE ownership_entitlements TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE SELECT ON TABLE ownership_entitlements FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            f"GRANT UPDATE (retired_at) ON TABLE ownership_accounts TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
        await primary._pool.execute(
            f"REVOKE UPDATE (retired_at) ON TABLE ownership_accounts FROM {quoted_role}"
        )
        assert await scoped.configuration_ready() is True

        await primary._pool.execute(
            "REVOKE UPDATE (last_seen_at) ON TABLE "
            f"ownership_installations FROM {quoted_role}"
        )
        assert await scoped.runtime_ready() is False
        await primary._pool.execute(
            "GRANT UPDATE (last_seen_at) ON TABLE "
            f"ownership_installations TO {quoted_role}"
        )
        assert await scoped.runtime_ready() is True

        await primary._pool.execute(
            f"GRANT UPDATE ON TABLE ownership_installations TO {quoted_role}"
        )
        assert await scoped.runtime_ready() is False
        await primary._pool.execute(
            f"REVOKE UPDATE ON TABLE ownership_installations FROM {quoted_role}"
        )
        await primary._pool.execute(
            "GRANT UPDATE (device_key_fingerprint, status, last_seen_at, revoked_at) "
            f"ON TABLE ownership_installations TO {quoted_role}"
        )
        assert await scoped.runtime_ready() is True

        await primary._pool.execute(
            "GRANT UPDATE (token_hash) ON TABLE "
            f"ownership_installations TO {quoted_role}"
        )
        assert await scoped.runtime_ready() is False
        await primary._pool.execute(
            "REVOKE UPDATE (token_hash) ON TABLE "
            f"ownership_installations FROM {quoted_role}"
        )
        assert await scoped.runtime_ready() is True

        nonownership_table = await primary._pool.fetchval(
            """
            SELECT format('%I.%I', namespace.nspname, candidate.relname)
            FROM pg_class candidate
            JOIN pg_namespace namespace
              ON namespace.oid = candidate.relnamespace
            WHERE candidate.relkind IN ('r', 'p')
              AND namespace.nspname = 'public'
              AND candidate.relname NOT LIKE 'ownership\\_%' ESCAPE '\\'
            ORDER BY candidate.relname
            LIMIT 1
            """
        )
        assert nonownership_table is not None
        await primary._pool.execute(
            f"GRANT SELECT ON TABLE {nonownership_table} TO {quoted_role}"
        )
        assert await scoped.configuration_ready() is False
    finally:
        if restricted is not None:
            await restricted.shutdown()
        if "quoted_security_definer_function" in locals():
            await primary._pool.execute(
                f"DROP FUNCTION IF EXISTS public.{quoted_security_definer_function}()"
            )
        await primary._pool.execute(
            f"DROP FUNCTION IF EXISTS public.{quoted_ordinary_function}()"
        )
        await primary._pool.execute(
            f"DROP SEQUENCE IF EXISTS public.{quoted_test_sequence}"
        )
        await primary._pool.execute(
            f"DROP SCHEMA IF EXISTS {quoted_owned_schema} CASCADE"
        )
        await primary._pool.execute(f"DROP OWNED BY {quoted_role}")
        await primary._pool.execute(f"DROP ROLE {quoted_role}")
        await primary._pool.execute(f"DROP ROLE IF EXISTS {quoted_inherited_role}")
        if public_schema_create_revoked:
            await primary._pool.execute("GRANT CREATE ON SCHEMA public TO PUBLIC")
        if public_database_temporary_granted:
            await primary._pool.execute(
                f"GRANT TEMPORARY ON DATABASE {quoted_database} TO PUBLIC"
            )


@pytest.mark.asyncio
async def test_ownership_schema_enforces_tenant_and_append_only_boundaries(
    ownership_repository,
) -> None:
    repository, primary = ownership_repository
    _, _, first = await _register(
        repository,
        subject="tenant-first",
        installation_id="ios-tenant-first",
        token_character="A",
    )
    _, _, second = await _register(
        repository,
        subject="tenant-second",
        installation_id="ios-tenant-second",
        token_character="B",
    )
    challenge = await repository.create_challenge(
        request_id=uuid4(),
        platform="ios",
        app_id=APPLE_APP_ID,
        ttl_seconds=180,
    )
    assert primary._pool is not None

    with pytest.raises(asyncpg.ForeignKeyViolationError):
        await primary._pool.execute(
            """
            INSERT INTO ownership_claim_requests (
                account_id,
                request_id,
                request_digest,
                installation_id,
                challenge_id,
                proof_digest,
                outcome
            ) VALUES ($1, $2, $3, $4, $5, $6, 'conflict')
            """,
            first.account_id,
            uuid4(),
            "c" * 64,
            "ios-tenant-second",
            challenge.challenge_id,
            "d" * 64,
        )

    with pytest.raises(OwnershipNotFoundError):
        await repository.revoke_installation(
            principal=first,
            current_installation_id="ios-tenant-first",
            target_installation_id="ios-tenant-second",
        )
    second_installations = await repository.list_installations(
        principal=second,
        current_installation_id="ios-tenant-second",
    )
    assert {row["installation_id"] for row in second_installations} == {
        "ios-tenant-second"
    }

    await _provision_band(primary)
    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_bands
            SET current_account_id = $1,
                claimed_at = clock_timestamp()
            WHERE provisioned_identity_hash = $2
            """,
            first.account_id,
            BAND_IDENTITY_HASH,
        )

    acceptance_id = await primary._pool.fetchval(
        """
        SELECT acceptance_id
        FROM ownership_terms_acceptances
        WHERE account_id = $1
        LIMIT 1
        """,
        first.account_id,
    )
    event_id = await primary._pool.fetchval(
        """
        SELECT event_id
        FROM ownership_events
        WHERE account_id = $1
        LIMIT 1
        """,
        first.account_id,
    )
    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            UPDATE ownership_terms_acceptances
            SET recorded_at = recorded_at + interval '1 second'
            WHERE acceptance_id = $1
            """,
            acceptance_id,
        )
    with pytest.raises(asyncpg.CheckViolationError):
        await primary._pool.execute(
            """
            DELETE FROM ownership_events
            WHERE event_id = $1
            """,
            event_id,
        )
