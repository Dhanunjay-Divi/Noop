from __future__ import annotations

import asyncio
import hashlib
import os
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.managed_models import (
    ManagedSocialProfileCreate,
)
from app.managed_push import (
    ManagedPushResult,
    ManagedPushTokenCodec,
)
from app.managed_repository import (
    ManagedConflictError,
    ManagedNotFoundError,
    ManagedPrincipal,
    PostgresManagedRepository,
)
from app.managed_safety_models import (
    ManagedPushRegistration,
    ManagedSafetyIncidentCreate,
    ManagedSafetyLocationUpdate,
    ManagedSafetyRequestCreate,
)
from app.managed_safety_repository import (
    ManagedSafetyPushService,
    PostgresManagedSafetyRepository,
)
from app.repository import PostgresRepository

DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL")
DATABASE_ENGINE = "postgresql"
REPLAY_SECRET = "test-managed-safety-replay-secret-at-least-32-bytes"
PUSH_SECRET = "test-managed-safety-push-secret-at-least-32-bytes"


def _managed(primary: PostgresRepository) -> PostgresManagedRepository:
    return PostgresManagedRepository(
        primary,
        home_region="asia-south1",
        residency_policy_version="synthetic-v1",
        default_plan_code="noop_plus_staging",
        default_plan_revision=1,
        consent_policy_kind="managed_storage",
        entitlement_mode="open_beta",
        replay_secret=REPLAY_SECRET,
    )


async def _principal(
    primary: PostgresRepository,
    *,
    label: str,
) -> ManagedPrincipal:
    account_id = uuid4()
    identity_id = uuid4()
    now = datetime.now(UTC)
    await primary._require_pool().execute(
        """
        INSERT INTO managed_accounts (
            account_id,
            storage_namespace,
            status,
            home_region,
            residency_policy_version,
            auth_valid_after,
            created_at,
            updated_at
        ) VALUES ($1, $2, 'active', 'asia-south1', 'synthetic-v1', $3, $3, $3)
        """,
        account_id,
        uuid4(),
        now - timedelta(minutes=5),
    )
    return ManagedPrincipal(
        account_id=account_id,
        identity_id=identity_id,
        subject_hash=(label.encode("utf-8").hex() + ("0" * 64))[:64],
        account_status="active",
        auth_valid_after=now - timedelta(minutes=5),
    )


async def _profile(
    repository: PostgresManagedRepository,
    principal: ManagedPrincipal,
    *,
    display_name: str,
) -> dict:
    return await repository.create_social_profile(
        principal=principal,
        request=ManagedSocialProfileCreate(
            request_id=uuid4(),
            display_name=display_name,
        ),
    )


async def _installation(
    primary: PostgresRepository,
    principal: ManagedPrincipal,
    *,
    installation_id: str,
    platform: str,
) -> None:
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
        ) VALUES ($1, $2, $3, 'active', $4, $4, $4)
        """,
        principal.account_id,
        installation_id,
        platform,
        now,
    )


async def _accept_contact(
    managed: PostgresManagedRepository,
    safety: PostgresManagedSafetyRepository,
    *,
    owner: ManagedPrincipal,
    contact: ManagedPrincipal,
    contact_name: str,
) -> tuple[dict, dict]:
    profile = await _profile(
        managed,
        contact,
        display_name=contact_name,
    )
    request = await safety.create_request(
        principal=owner,
        request=ManagedSafetyRequestCreate(
            request_id=uuid4(),
            noop_id=profile["noop_id"],
        ),
    )
    accepted = await safety.decide_request(
        principal=contact,
        request_id=UUID(request["request_id"]),
        decision="accept",
    )
    return profile, accepted


class _RecordingPushProvider:
    def __init__(self) -> None:
        self.tokens: list[str] = []

    @property
    def available(self) -> bool:
        return True

    async def send_safety_incident(
        self,
        *,
        token: str,
        target_kind: str,
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        assert expires_at > datetime.now(UTC)
        assert isinstance(incident_id, UUID)
        self.tokens.append(f"{target_kind}:{token}")
        return ManagedPushResult(
            outcome="sent",
            provider_reference_hash=hashlib.sha256(
                f"provider:{incident_id}:{token}".encode()
            ).hexdigest(),
        )


class _RetryThenSendPushProvider:
    def __init__(self) -> None:
        self.calls = 0

    @property
    def available(self) -> bool:
        return True

    async def send_safety_incident(
        self,
        *,
        token: str,
        target_kind: str,
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        assert target_kind == "fid"
        assert token.startswith("fcm-token:")
        assert expires_at > datetime.now(UTC)
        self.calls += 1
        if self.calls == 1:
            return ManagedPushResult(outcome="transient_failure")
        return ManagedPushResult(
            outcome="sent",
            provider_reference_hash=hashlib.sha256(
                f"retry-provider:{incident_id}".encode()
            ).hexdigest(),
        )


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_concurrent_contact_acceptance_preserves_owner_limit() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=10,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        owner = await _principal(primary, label=f"owner-limit-{uuid4()}")
        owner_profile = await _profile(
            managed,
            owner,
            display_name="Owner limit",
        )
        for index in range(4):
            contact = await _principal(
                primary,
                label=f"existing-contact-{index}-{uuid4()}",
            )
            await _accept_contact(
                managed,
                safety,
                owner=owner,
                contact=contact,
                contact_name=f"Existing {index}",
            )

        candidates: list[tuple[ManagedPrincipal, UUID]] = []
        for index in range(2):
            contact = await _principal(
                primary,
                label=f"candidate-contact-{index}-{uuid4()}",
            )
            profile = await _profile(
                managed,
                contact,
                display_name=f"Candidate {index}",
            )
            request = await safety.create_request(
                principal=owner,
                request=ManagedSafetyRequestCreate(
                    request_id=uuid4(),
                    noop_id=profile["noop_id"],
                ),
            )
            candidates.append((contact, UUID(request["request_id"])))

        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            async with blocker.transaction():
                await blocker.execute(
                    """
                    SELECT profile_id
                    FROM managed_social_profiles
                    WHERE profile_id = $1
                    FOR UPDATE
                    """,
                    UUID(owner_profile["profile_id"]),
                )
                tasks = [
                    asyncio.create_task(
                        safety.decide_request(
                            principal=contact,
                            request_id=request_id,
                            decision="accept",
                        )
                    )
                    for contact, request_id in candidates
                ]
                await asyncio.sleep(0.05)
                assert all(not task.done() for task in tasks)
        results = await asyncio.wait_for(
            asyncio.gather(*tasks, return_exceptions=True),
            timeout=10,
        )
        assert sum(isinstance(result, dict) for result in results) == 1
        assert sum(isinstance(result, ManagedConflictError) for result in results) == 1
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_safety_contacts
                WHERE owner_profile_id = $1
                """,
                UUID(owner_profile["profile_id"]),
            )
            == 5
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_managed_safety_is_tenant_scoped_latest_only_and_idempotent() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        owner = await _principal(primary, label=f"owner-{uuid4()}")
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        outsider = await _principal(primary, label=f"outsider-{uuid4()}")
        owner_profile = await _profile(managed, owner, display_name="Owner")
        await _profile(managed, outsider, display_name="Outsider")
        first_profile, _ = await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=first,
            contact_name="First",
        )
        second_profile, _ = await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=second,
            contact_name="Second",
        )
        contacts = await safety.list_contacts(principal=owner)
        assert {row["profile_id"] for row in contacts} == {
            first_profile["profile_id"],
            second_profile["profile_id"],
        }

        request_id = uuid4()
        incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=request_id,
                duration_hours=8,
                share_location=True,
            ),
        )
        replay = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=request_id,
                duration_hours=8,
                share_location=True,
            ),
        )
        assert replay["incident_id"] == incident["incident_id"]
        assert replay["duplicate"] is True
        with pytest.raises(ManagedConflictError):
            await safety.create_incident(
                principal=owner,
                request=ManagedSafetyIncidentCreate(
                    request_id=uuid4(),
                    duration_hours=12,
                    share_location=True,
                ),
            )
        with pytest.raises(ManagedNotFoundError):
            await safety.get_incident(
                principal=outsider,
                incident_id=UUID(incident["incident_id"]),
            )

        captured = datetime.now(UTC)
        location = await safety.update_location(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            update=ManagedSafetyLocationUpdate(
                sequence=1,
                latitude=17.385,
                longitude=78.4867,
                horizontal_accuracy_m=12.5,
                captured_at=captured,
            ),
        )
        assert location["duplicate"] is False
        assert (
            await safety.update_location(
                principal=owner,
                incident_id=UUID(incident["incident_id"]),
                update=ManagedSafetyLocationUpdate(
                    sequence=1,
                    latitude=17.385,
                    longitude=78.4867,
                    horizontal_accuracy_m=12.5,
                    captured_at=captured,
                ),
            )
        )["duplicate"] is True
        newer = await safety.update_location(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            update=ManagedSafetyLocationUpdate(
                sequence=2,
                latitude=17.386,
                longitude=78.487,
                horizontal_accuracy_m=9.0,
                captured_at=captured + timedelta(seconds=10),
            ),
        )
        assert newer["sequence"] == 2
        cross_installation = await safety.update_location(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            update=ManagedSafetyLocationUpdate(
                sequence=1,
                latitude=17.387,
                longitude=78.488,
                horizontal_accuracy_m=7.0,
                captured_at=captured + timedelta(seconds=20),
            ),
        )
        assert cross_installation["sequence"] == 3
        bounded_jump = await safety.update_location(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            update=ManagedSafetyLocationUpdate(
                sequence=99,
                latitude=17.388,
                longitude=78.489,
                horizontal_accuracy_m=6.5,
                captured_at=captured + timedelta(seconds=30),
            ),
        )
        assert bounded_jump["sequence"] == 4
        assert (
            await safety.update_location(
                principal=owner,
                incident_id=UUID(incident["incident_id"]),
                update=ManagedSafetyLocationUpdate(
                    sequence=1,
                    latitude=17.388,
                    longitude=78.489,
                    horizontal_accuracy_m=6.5,
                    captured_at=captured + timedelta(seconds=30),
                ),
            )
        )["duplicate"] is True
        with pytest.raises(ManagedConflictError):
            await safety.update_location(
                principal=owner,
                incident_id=UUID(incident["incident_id"]),
                update=ManagedSafetyLocationUpdate(
                    sequence=99,
                    latitude=17.389,
                    longitude=78.49,
                    horizontal_accuracy_m=6.0,
                    captured_at=captured + timedelta(seconds=15),
                ),
            )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_locations
                WHERE incident_id = $1
                """,
                UUID(incident["incident_id"]),
            )
            == 1
        )

        contact_view = await safety.respond(
            principal=first,
            incident_id=UUID(incident["incident_id"]),
            decision="responding",
        )
        assert contact_view["role"] == "contact"
        assert contact_view["status"] == "acknowledged"
        assert len(contact_view["participants"]) == 1
        owner_view = await safety.get_incident(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
        )
        assert owner_view["status"] == "acknowledged"
        assert len(owner_view["participants"]) == 2
        withdrawn = await safety.respond(
            principal=first,
            incident_id=UUID(incident["incident_id"]),
            decision="cannot_respond",
        )
        assert withdrawn["status"] == "open"
        status_after_withdrawal = await primary._require_pool().fetchrow(
            """
            SELECT status, acknowledged_at
            FROM managed_safety_incidents
            WHERE incident_id = $1
            """,
            UUID(incident["incident_id"]),
        )
        assert status_after_withdrawal["status"] == "open"
        assert status_after_withdrawal["acknowledged_at"] is None
        resumed = await safety.respond(
            principal=first,
            incident_id=UUID(incident["incident_id"]),
            decision="responding",
        )
        assert resumed["status"] == "acknowledged"

        ended = await safety.end_incident(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            outcome="resolved",
        )
        assert ended["status"] == "resolved"
        assert ended["location"] is None
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_locations
                WHERE incident_id = $1
                """,
                UUID(incident["incident_id"]),
            )
            == 0
        )
        assert owner_profile["profile_id"] == ended["owner_profile_id"]
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_remove_contact_deletes_both_directional_roles() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        first_profile = await _profile(managed, first, display_name="First")
        second_profile = await _profile(managed, second, display_name="Second")

        stale_reciprocal_request = await safety.create_request(
            principal=second,
            request=ManagedSafetyRequestCreate(
                request_id=uuid4(),
                noop_id=first_profile["noop_id"],
            ),
        )
        first_request = await safety.create_request(
            principal=first,
            request=ManagedSafetyRequestCreate(
                request_id=uuid4(),
                noop_id=second_profile["noop_id"],
            ),
        )
        await safety.decide_request(
            principal=second,
            request_id=UUID(first_request["request_id"]),
            decision="accept",
        )

        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_contacts
                WHERE (
                    owner_profile_id = $1
                    AND contact_profile_id = $2
                ) OR (
                    owner_profile_id = $2
                    AND contact_profile_id = $1
                )
                """,
                UUID(first_profile["profile_id"]),
                UUID(second_profile["profile_id"]),
            )
            == 1
        )
        await safety.remove_contact(
            principal=first,
            other_profile_id=UUID(second_profile["profile_id"]),
        )
        assert await safety.list_contacts(principal=first) == []
        assert await safety.list_contacts(principal=second) == []
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_requests
                WHERE request_id = $1
                """,
                UUID(stale_reciprocal_request["request_id"]),
            )
            == "canceled"
        )
        with pytest.raises(ManagedConflictError):
            await safety.decide_request(
                principal=first,
                request_id=UUID(stale_reciprocal_request["request_id"]),
                decision="accept",
            )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_social_profile_deletion_cascades_accepted_safety_contact() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        owner = await _principal(primary, label=f"owner-delete-{uuid4()}")
        contact = await _principal(primary, label=f"contact-delete-{uuid4()}")
        owner_profile = await _profile(managed, owner, display_name="Owner")
        contact_profile, accepted = await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=contact,
            contact_name="Contact",
        )

        await managed.delete_social_profile(principal=owner)

        pool = primary._require_pool()
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_safety_contacts
                WHERE owner_profile_id = $1 OR contact_profile_id = $1
                """,
                UUID(owner_profile["profile_id"]),
            )
            == 0
        )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_safety_requests
                WHERE request_id = $1
                """,
                UUID(accepted["request_id"]),
            )
            == 0
        )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_social_profiles
                WHERE profile_id = $1
                """,
                UUID(contact_profile["profile_id"]),
            )
            == 1
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_managed_safety_push_is_encrypted_and_block_revokes_access() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        codec = ManagedPushTokenCodec(PUSH_SECRET)
        provider = _RecordingPushProvider()
        push = ManagedSafetyPushService(
            repository=safety,
            token_codec=codec,
            provider=provider,
        )
        owner = await _principal(primary, label=f"owner-{uuid4()}")
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        owner_profile = await _profile(managed, owner, display_name="Owner")
        first_profile, _ = await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=first,
            contact_name="First",
        )
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=second,
            contact_name="Second",
        )
        run_id = uuid4().hex
        first_token = f"fcm-token:first_{run_id}"
        second_token = f"fcm-token:second_{run_id}"
        for principal, installation_id, token in (
            (
                first,
                f"ios-safety-first-{run_id}",
                first_token,
            ),
            (
                second,
                f"android-safety-second-{run_id}",
                second_token,
            ),
        ):
            platform = "ios" if installation_id.startswith("ios") else "android"
            await _installation(
                primary,
                principal,
                installation_id=installation_id,
                platform=platform,
            )
            await push.register(
                principal=principal,
                installation_id=installation_id,
                registration=ManagedPushRegistration(
                    platform=platform,
                    environment="development",
                    target_kind="fid" if platform == "ios" else "token",
                    token=token,
                ),
            )
        stored = await primary._require_pool().fetch(
            """
            SELECT token_hash, token_ciphertext
            FROM managed_push_installations
            WHERE account_id = ANY($1::uuid[])
            ORDER BY installation_id
            """,
            [first.account_id, second.account_id],
        )
        assert len(stored) == 2
        assert all("fcm-token:" not in row["token_ciphertext"] for row in stored)

        incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        summary = await push.dispatch(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
        )
        assert summary["contacts_targeted"] == 2
        assert summary["contacts_reached"] == 2
        assert sorted(provider.tokens) == [
            f"fid:{first_token}",
            f"token:{second_token}",
        ]
        acknowledged = await safety.respond(
            principal=first,
            incident_id=UUID(incident["incident_id"]),
            decision="responding",
        )
        assert acknowledged["status"] == "acknowledged"

        await managed.block_social_profile(
            principal=owner,
            blocked_profile_id=UUID(first_profile["profile_id"]),
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_contacts
                WHERE owner_profile_id = $1
                  AND contact_profile_id = $2
                """,
                UUID(owner_profile["profile_id"]),
                UUID(first_profile["profile_id"]),
            )
            == 0
        )
        participant_status = await primary._require_pool().fetchval(
            """
            SELECT status
            FROM managed_safety_participants
            WHERE incident_id = $1 AND contact_profile_id = $2
            """,
            UUID(incident["incident_id"]),
            UUID(first_profile["profile_id"]),
        )
        assert participant_status == "revoked"
        incident_status = await primary._require_pool().fetchrow(
            """
            SELECT status, acknowledged_at
            FROM managed_safety_incidents
            WHERE incident_id = $1
            """,
            UUID(incident["incident_id"]),
        )
        assert incident_status["status"] == "open"
        assert incident_status["acknowledged_at"] is None
        with pytest.raises(ManagedNotFoundError):
            await safety.get_incident(
                principal=first,
                incident_id=UUID(incident["incident_id"]),
            )

        race_token = f"fcm-token:race_{run_id}"
        race_accounts: list[tuple[ManagedPrincipal, str]] = []
        for label in ("first", "second"):
            race_principal = await _principal(
                primary,
                label=f"race-{label}-{uuid4()}",
            )
            race_installation = f"ios-safety-race-{label}-{run_id}"
            await _installation(
                primary,
                race_principal,
                installation_id=race_installation,
                platform="ios",
            )
            race_accounts.append((race_principal, race_installation))
        token_lock_key = f"noop-managed-push-token:{codec.token_hash(race_token)}"
        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            async with blocker.transaction():
                await blocker.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    token_lock_key,
                )
                registration_tasks = [
                    asyncio.create_task(
                        push.register(
                            principal=race_principal,
                            installation_id=race_installation,
                            registration=ManagedPushRegistration(
                                platform="ios",
                                environment="development",
                                target_kind="fid",
                                token=race_token,
                            ),
                        )
                    )
                    for race_principal, race_installation in race_accounts
                ]
                await asyncio.sleep(0.05)
                assert all(not task.done() for task in registration_tasks)
        registration_results = await asyncio.wait_for(
            asyncio.gather(*registration_tasks, return_exceptions=True),
            timeout=10,
        )
        assert sum(isinstance(result, dict) for result in registration_results) == 1
        assert (
            sum(
                isinstance(result, ManagedConflictError)
                for result in registration_results
            )
            == 1
        )
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_push_installations
                WHERE token_hash = $1 AND status = 'active'
                """,
                codec.token_hash(race_token),
            )
            == 1
        )

        replacement = await _principal(
            primary,
            label=f"replacement-{uuid4()}",
        )
        replacement_installation = f"ios-safety-replacement-{run_id}"
        await _installation(
            primary,
            replacement,
            installation_id=replacement_installation,
            platform="ios",
        )
        with pytest.raises(ManagedConflictError):
            await push.register(
                principal=replacement,
                installation_id=replacement_installation,
                registration=ManagedPushRegistration(
                    platform="ios",
                    environment="development",
                    target_kind="fid",
                    token=first_token,
                ),
            )
        await safety.revoke_push_installation(
            principal=first,
            installation_id=f"ios-safety-first-{run_id}",
        )
        retained_delivery_id = await primary._require_pool().fetchval(
            """
            SELECT delivery_id
            FROM managed_safety_push_deliveries
            WHERE account_id = $1 AND installation_id = $2
            """,
            first.account_id,
            f"ios-safety-first-{run_id}",
        )
        assert retained_delivery_id is not None
        revoked = await primary._require_pool().fetchrow(
            """
            SELECT status, token_hash, token_ciphertext
            FROM managed_push_installations
            WHERE account_id = $1 AND installation_id = $2
            """,
            first.account_id,
            f"ios-safety-first-{run_id}",
        )
        assert revoked["status"] == "revoked"
        assert revoked["token_ciphertext"] == f"revoked.{revoked['token_hash']}"
        assert first_token not in revoked["token_ciphertext"]
        transferred = await push.register(
            principal=replacement,
            installation_id=replacement_installation,
            registration=ManagedPushRegistration(
                platform="ios",
                environment="development",
                target_kind="fid",
                token=first_token,
            ),
        )
        assert transferred["status"] == "active"
        assert transferred["target_kind"] == "fid"
        retired = await primary._require_pool().fetchrow(
            """
            SELECT status, token_hash, token_ciphertext
            FROM managed_push_installations
            WHERE account_id = $1 AND installation_id = $2
            """,
            first.account_id,
            f"ios-safety-first-{run_id}",
        )
        assert retired["status"] == "revoked"
        assert retired["token_hash"] != codec.token_hash(first_token)
        assert retired["token_ciphertext"] == f"retired.{retired['token_hash']}"
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_push_deliveries
                WHERE delivery_id = $1
                """,
                retained_delivery_id,
            )
            == 1
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_push_installations
                WHERE token_hash = $1
                """,
                codec.token_hash(first_token),
            )
            == 1
        )

        for index in range(4):
            surplus_installation = f"ios-safety-surplus-{index}-{run_id}"
            await _installation(
                primary,
                replacement,
                installation_id=surplus_installation,
                platform="ios",
            )
            await push.register(
                principal=replacement,
                installation_id=surplus_installation,
                registration=ManagedPushRegistration(
                    platform="ios",
                    environment="development",
                    target_kind="fid",
                    token=f"fcm-token:surplus_{index}_{run_id}",
                ),
            )
        surplus = await primary._require_pool().fetchrow(
            """
            SELECT status, token_hash, token_ciphertext
            FROM managed_push_installations
            WHERE account_id = $1 AND installation_id = $2
            """,
            replacement.account_id,
            replacement_installation,
        )
        assert surplus["status"] == "revoked"
        assert surplus["token_ciphertext"] == f"revoked.{surplus['token_hash']}"
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_safety_accept_locks_profiles_before_request_rows() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        owner = await _principal(primary, label=f"lock-owner-{uuid4()}")
        contact = await _principal(primary, label=f"lock-contact-{uuid4()}")
        owner_profile = await _profile(
            managed,
            owner,
            display_name="Lock owner",
        )
        contact_profile = await _profile(
            managed,
            contact,
            display_name="Lock contact",
        )
        request = await safety.create_request(
            principal=owner,
            request=ManagedSafetyRequestCreate(
                request_id=uuid4(),
                noop_id=contact_profile["noop_id"],
            ),
        )
        request_id = UUID(request["request_id"])
        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            async with blocker.transaction():
                await blocker.fetch(
                    """
                    SELECT profile_id
                    FROM managed_social_profiles
                    WHERE profile_id = ANY($1::uuid[])
                    ORDER BY profile_id
                    FOR UPDATE
                    """,
                    [
                        UUID(owner_profile["profile_id"]),
                        UUID(contact_profile["profile_id"]),
                    ],
                )
                accept_task = asyncio.create_task(
                    safety.decide_request(
                        principal=contact,
                        request_id=request_id,
                        decision="accept",
                    )
                )
                await asyncio.sleep(0.1)
                assert not accept_task.done()
                locked_request = await blocker.fetchrow(
                    """
                    SELECT request_id
                    FROM managed_safety_requests
                    WHERE request_id = $1
                    FOR UPDATE
                    """,
                    request_id,
                    timeout=1,
                )
                assert locked_request["request_id"] == request_id
        accepted = await asyncio.wait_for(accept_task, timeout=5)
        assert accepted["status"] == "accepted"
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_managed_safety_due_push_retries_without_owner_session() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        provider = _RetryThenSendPushProvider()
        push = ManagedSafetyPushService(
            repository=safety,
            token_codec=ManagedPushTokenCodec(PUSH_SECRET),
            provider=provider,
        )
        owner = await _principal(primary, label=f"owner-{uuid4()}")
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        await _profile(managed, owner, display_name="Owner")
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=first,
            contact_name="First",
        )
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=second,
            contact_name="Second",
        )
        run_id = uuid4().hex
        installation_id = f"ios-retry-{run_id}"
        await _installation(
            primary,
            first,
            installation_id=installation_id,
            platform="ios",
        )
        await push.register(
            principal=first,
            installation_id=installation_id,
            registration=ManagedPushRegistration(
                platform="ios",
                environment="development",
                target_kind="fid",
                token=f"fcm-token:retry_{run_id}",
            ),
        )
        incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )

        await push.dispatch(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
        )
        assert provider.calls == 1
        await primary._require_pool().execute(
            """
            UPDATE managed_safety_push_deliveries
            SET last_attempt_at = clock_timestamp() - interval '2 minutes'
            WHERE incident_id = $1
            """,
            UUID(incident["incident_id"]),
        )

        retry = await push.dispatch_due(limit=20)
        assert retry.claimed == 1
        assert retry.provider_accepted == 1
        assert retry.retryable_failures == 0
        assert retry.terminal_failures == 0
        assert retry.receipt_failures == 0
        assert provider.calls == 2
        row = await primary._require_pool().fetchrow(
            """
            SELECT status, attempts
            FROM managed_safety_push_deliveries
            WHERE incident_id = $1
            """,
            UUID(incident["incident_id"]),
        )
        assert row["status"] == "sent"
        assert row["attempts"] == 2
        assert (await push.dispatch_due(limit=20)).claimed == 0

        await safety.end_incident(
            principal=owner,
            incident_id=UUID(incident["incident_id"]),
            outcome="resolved",
        )
        canceled = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        canceled_id = UUID(canceled["incident_id"])
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                """,
                canceled_id,
            )
            == "pending"
        )
        await safety.end_incident(
            principal=owner,
            incident_id=canceled_id,
            outcome="canceled",
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                """,
                canceled_id,
            )
            == "rejected"
        )

        exhausted = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        exhausted_id = UUID(exhausted["incident_id"])
        await primary._require_pool().execute(
            """
            UPDATE managed_safety_push_deliveries
            SET status = 'sending',
                attempts = 3,
                claim_id = $2,
                claim_expires_at = clock_timestamp() - interval '1 second',
                last_attempt_at = clock_timestamp() - interval '2 minutes',
                updated_at = clock_timestamp() - interval '2 minutes'
            WHERE incident_id = $1
            """,
            exhausted_id,
            uuid4(),
        )
        assert (await push.dispatch_due(limit=20)).claimed == 0
        exhausted_row = await primary._require_pool().fetchrow(
            """
            SELECT status, attempts
            FROM managed_safety_push_deliveries
            WHERE incident_id = $1
            """,
            exhausted_id,
        )
        assert exhausted_row["status"] == "rejected"
        assert exhausted_row["attempts"] == 3
        exhausted_summary = await safety.delivery_summary(
            principal=owner,
            incident_id=exhausted_id,
        )
        assert exhausted_summary["installations_retryable"] == 0
        assert exhausted_summary["installations_terminal"] == 1
        assert provider.calls == 2

        await safety.end_incident(
            principal=owner,
            incident_id=exhausted_id,
            outcome="resolved",
        )
        invalid_incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        await primary._require_pool().execute(
            """
            UPDATE managed_push_installations
            SET token_ciphertext = $3
            WHERE account_id = $1 AND installation_id = $2
            """,
            first.account_id,
            installation_id,
            "v1." + ("a" * 40),
        )
        invalid_delivery = await push.dispatch(
            principal=owner,
            incident_id=UUID(invalid_incident["incident_id"]),
        )
        assert invalid_delivery["installations_terminal"] == 1
        invalid = await primary._require_pool().fetchrow(
            """
            SELECT status, token_hash, token_ciphertext
            FROM managed_push_installations
            WHERE account_id = $1 AND installation_id = $2
            """,
            first.account_id,
            installation_id,
        )
        assert invalid["status"] == "invalid"
        assert invalid["token_ciphertext"] == f"invalid.{invalid['token_hash']}"
        assert provider.calls == 2
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_push_registration_joins_active_incident_and_response_stops_retry() -> (
    None
):
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=8,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        provider = _RecordingPushProvider()
        codec = ManagedPushTokenCodec(PUSH_SECRET)
        push = ManagedSafetyPushService(
            repository=safety,
            token_codec=codec,
            provider=provider,
        )
        owner = await _principal(primary, label=f"owner-{uuid4()}")
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        await _profile(managed, owner, display_name="Owner")
        first_profile, _ = await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=first,
            contact_name="First",
        )
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=second,
            contact_name="Second",
        )
        incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        incident_id = UUID(incident["incident_id"])
        run_id = uuid4().hex
        first_installation = f"ios-late-first-{run_id}"
        await _installation(
            primary,
            first,
            installation_id=first_installation,
            platform="ios",
        )
        first_token = f"fcm-token:late_first_{run_id}"
        await push.register(
            principal=first,
            installation_id=first_installation,
            registration=ManagedPushRegistration(
                platform="ios",
                environment="development",
                target_kind="fid",
                token=first_token,
            ),
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                  AND installation_id = $2
                """,
                incident_id,
                first_installation,
            )
            == "pending"
        )
        first_delivery = await push.dispatch_due(limit=20)
        assert first_delivery.claimed == 1
        assert first_delivery.provider_accepted == 1
        assert provider.tokens == [f"fid:{first_token}"]

        second_installation = f"ios-late-second-{run_id}"
        await _installation(
            primary,
            second,
            installation_id=second_installation,
            platform="ios",
        )
        old_second_token = f"fcm-token:late_second_old_{run_id}"
        registration = ManagedPushRegistration(
            platform="ios",
            environment="development",
            target_kind="fid",
            token=old_second_token,
        )
        await push.register(
            principal=second,
            installation_id=second_installation,
            registration=registration,
        )
        old_claim_id = uuid4()
        await primary._require_pool().execute(
            """
            UPDATE managed_safety_push_deliveries
            SET status = 'sending',
                attempts = 1,
                claim_id = $3,
                claim_expires_at = clock_timestamp() + interval '1 minute',
                last_attempt_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE incident_id = $1
              AND installation_id = $2
            """,
            incident_id,
            second_installation,
            old_claim_id,
        )
        duplicate = await push.register(
            principal=second,
            installation_id=second_installation,
            registration=registration,
        )
        assert duplicate["duplicate"] is True
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                  AND installation_id = $2
                """,
                incident_id,
                second_installation,
            )
            == "sending"
        )

        new_second_token = f"fcm-token:late_second_new_{run_id}"
        changed = await push.register(
            principal=second,
            installation_id=second_installation,
            registration=ManagedPushRegistration(
                platform="ios",
                environment="development",
                target_kind="fid",
                token=new_second_token,
            ),
        )
        assert changed["duplicate"] is False
        reset = await primary._require_pool().fetchrow(
            """
            SELECT status, attempts
            FROM managed_safety_push_deliveries
            WHERE incident_id = $1
              AND installation_id = $2
            """,
            incident_id,
            second_installation,
        )
        assert reset["status"] == "pending"
        assert reset["attempts"] == 0
        with pytest.raises(ManagedConflictError):
            await safety.complete_push_delivery(
                delivery_id=await primary._require_pool().fetchval(
                    """
                    SELECT delivery_id
                    FROM managed_safety_push_deliveries
                    WHERE incident_id = $1
                      AND installation_id = $2
                    """,
                    incident_id,
                    second_installation,
                ),
                claim_id=old_claim_id,
                outcome="invalid",
                provider_reference_hash=None,
            )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_push_installations
                WHERE account_id = $1 AND installation_id = $2
                """,
                second.account_id,
                second_installation,
            )
            == "active"
        )

        await safety.respond(
            principal=second,
            incident_id=incident_id,
            decision="cannot_respond",
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                  AND installation_id = $2
                """,
                incident_id,
                second_installation,
            )
            == "rejected"
        )
        assert (await push.dispatch_due(limit=20)).claimed == 0

        responded_installation = f"ios-after-response-{run_id}"
        await _installation(
            primary,
            first,
            installation_id=responded_installation,
            platform="ios",
        )
        await push.register(
            principal=first,
            installation_id=responded_installation,
            registration=ManagedPushRegistration(
                platform="ios",
                environment="development",
                target_kind="fid",
                token=f"fcm-token:after_response_{run_id}",
            ),
        )
        await safety.respond(
            principal=first,
            incident_id=incident_id,
            decision="responding",
        )
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT count(*)
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1
                  AND contact_profile_id = $2
                  AND status IN (
                      'pending',
                      'sending',
                      'transient_failure',
                      'unavailable'
                  )
                """,
                incident_id,
                UUID(first_profile["profile_id"]),
            )
            == 0
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_managed_safety_read_expiry_is_always_transactional() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        principal = await _principal(primary, label=f"transaction-{uuid4()}")
        await _profile(managed, principal, display_name="Transaction")
        original_expire = safety._expire
        transaction_checks: list[bool] = []

        async def checked_expire(connection, now):
            transaction_checks.append(connection.is_in_transaction())
            await original_expire(connection, now)

        safety._expire = checked_expire
        await safety.list_requests(principal=principal)
        await safety.list_incidents(principal=principal)
        with pytest.raises(ManagedNotFoundError):
            await safety.get_incident(
                principal=principal,
                incident_id=uuid4(),
            )

        assert transaction_checks == [True, True, True]
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "NOOP_TEST_POSTGRESQL_DATABASE_URL is required for PostgreSQL-overlay "
        "integration tests"
    ),
)
@pytest.mark.asyncio
async def test_inactive_safety_contacts_cannot_start_or_receive_a_page() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=6,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        managed = _managed(primary)
        safety = PostgresManagedSafetyRepository(primary)
        provider = _RecordingPushProvider()
        push = ManagedSafetyPushService(
            repository=safety,
            token_codec=ManagedPushTokenCodec(PUSH_SECRET),
            provider=provider,
        )
        owner = await _principal(primary, label=f"inactive-owner-{uuid4()}")
        first = await _principal(primary, label=f"inactive-first-{uuid4()}")
        second = await _principal(primary, label=f"inactive-second-{uuid4()}")
        await _profile(managed, owner, display_name="Owner")
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=first,
            contact_name="First",
        )
        await _accept_contact(
            managed,
            safety,
            owner=owner,
            contact=second,
            contact_name="Second",
        )
        await primary._require_pool().execute(
            """
            UPDATE managed_accounts
            SET status = 'suspended', updated_at = clock_timestamp()
            WHERE account_id = $1
            """,
            second.account_id,
        )
        assert len(await safety.list_contacts(principal=owner)) == 1
        with pytest.raises(ManagedConflictError):
            await safety.create_incident(
                principal=owner,
                request=ManagedSafetyIncidentCreate(
                    request_id=uuid4(),
                    duration_hours=8,
                    share_location=False,
                ),
            )

        await primary._require_pool().execute(
            """
            UPDATE managed_accounts
            SET status = 'active', updated_at = clock_timestamp()
            WHERE account_id = $1
            """,
            second.account_id,
        )
        installation_id = f"android-inactive-{uuid4().hex}"
        await _installation(
            primary,
            second,
            installation_id=installation_id,
            platform="android",
        )
        await push.register(
            principal=second,
            installation_id=installation_id,
            registration=ManagedPushRegistration(
                platform="android",
                environment="development",
                target_kind="token",
                token=f"fcm-token:inactive_{uuid4().hex}",
            ),
        )
        incident = await safety.create_incident(
            principal=owner,
            request=ManagedSafetyIncidentCreate(
                request_id=uuid4(),
                duration_hours=8,
                share_location=False,
            ),
        )
        incident_id = UUID(incident["incident_id"])
        await primary._require_pool().execute(
            """
            UPDATE managed_accounts
            SET status = 'erasure_pending',
                erasure_requested_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE account_id = $1
            """,
            second.account_id,
        )

        summary = await push.dispatch(
            principal=owner,
            incident_id=incident_id,
        )

        assert provider.tokens == []
        assert summary["installations_reached"] == 0
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT status
                FROM managed_safety_push_deliveries
                WHERE incident_id = $1 AND installation_id = $2
                """,
                incident_id,
                installation_id,
            )
            == "rejected"
        )
    finally:
        await primary.shutdown()
