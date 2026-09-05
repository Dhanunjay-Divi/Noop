from __future__ import annotations

import asyncio
import os
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
import pytest
from pydantic import ValidationError

import app.managed_repository as managed_repository_module
from app.managed_models import (
    ManagedSocialInviteCreate,
    ManagedSocialPokeAcknowledgement,
    ManagedSocialPokeCreate,
    ManagedSocialProfileCreate,
    ManagedSocialProfilePatch,
    ManagedSocialRequestCreate,
    ManagedSocialSummaryMutation,
    ManagedSocialVisibilityPatch,
)
from app.managed_repository import (
    ManagedConflictError,
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedPrincipal,
    PostgresManagedRepository,
)
from app.repository import PostgresRepository

DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "postgresql")
REPLAY_SECRET = "test-managed-social-replay-secret-at-least-32-bytes"


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


def _capability() -> str:
    return "noopinvite_" + secrets.token_urlsafe(32)


def test_managed_social_models_reject_unknown_or_null_privacy_data() -> None:
    with pytest.raises(ValidationError):
        ManagedSocialProfilePatch(display_name=None)
    with pytest.raises(ValidationError):
        ManagedSocialVisibilityPatch(charge=None)
    with pytest.raises(ValidationError):
        ManagedSocialSummaryMutation(
            request_id=uuid4(),
            summary={"spo2": 98.0},
        )
    with pytest.raises(ValidationError):
        ManagedSocialSummaryMutation(
            request_id=uuid4(),
            summary={"hrv": 1_001.0},
        )
    with pytest.raises(ValidationError):
        ManagedSocialInviteCreate(
            request_id=uuid4(),
            capability="not-a-capability",
        )
    assert ManagedSocialProfilePatch(time_zone="+05:30").time_zone == "+05:30"
    assert PostgresManagedRepository._inside_quiet_hours(
        now=datetime(2026, 9, 5, 18, 0, tzinfo=UTC),
        time_zone="UTC+05:30",
        start_minute=22 * 60,
        end_minute=7 * 60,
    )
    with pytest.raises(ValueError):
        PostgresManagedRepository._social_time_zone("+15:00")


def test_managed_social_noop_id_is_canonical_and_exact() -> None:
    request = ManagedSocialRequestCreate(
        request_id=uuid4(),
        noop_id="noop-abcd-efgh-jklm-npqr",
    )
    assert request.noop_id == "NOOP-ABCD-EFGH-JKLM-NPQR"
    with pytest.raises(ValidationError):
        ManagedSocialRequestCreate(
            request_id=uuid4(),
            noop_id="NOOP-AAAA-AAAA-AAAA-AAAI",
        )


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_managed_social_received_request_limit_is_concurrency_safe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        managed_repository_module,
        "SOCIAL_MAX_RECEIVED_REQUESTS_PER_DAY",
        1,
    )
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=6,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        recipient = await _principal(primary, label=f"recipient-{uuid4()}")
        first_sender = await _principal(primary, label=f"sender-one-{uuid4()}")
        second_sender = await _principal(primary, label=f"sender-two-{uuid4()}")
        recipient_profile = await repository.create_social_profile(
            principal=recipient,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Recipient",
            ),
        )
        for principal, name in (
            (first_sender, "First sender"),
            (second_sender, "Second sender"),
        ):
            await repository.create_social_profile(
                principal=principal,
                request=ManagedSocialProfileCreate(
                    request_id=uuid4(),
                    display_name=name,
                ),
            )

        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            async with blocker.transaction():
                await blocker.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    (
                        "noop-managed-social:request-rate:"
                        f"{recipient_profile['profile_id']}"
                    ),
                )
                tasks = [
                    asyncio.create_task(
                        repository.create_social_request(
                            principal=sender,
                            request=ManagedSocialRequestCreate(
                                request_id=uuid4(),
                                noop_id=recipient_profile["noop_id"],
                            ),
                        )
                    )
                    for sender in (first_sender, second_sender)
                ]
                await asyncio.sleep(0.05)
                assert all(not task.done() for task in tasks)

        results = await asyncio.wait_for(
            asyncio.gather(*tasks, return_exceptions=True),
            timeout=5,
        )
        assert sum(isinstance(result, dict) for result in results) == 1
        assert sum(isinstance(result, ManagedConflictError) for result in results) == 1
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_managed_social_accept_and_block_cannot_leave_friendship() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=6,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        sender = await _principal(primary, label=f"sender-{uuid4()}")
        recipient = await _principal(primary, label=f"recipient-{uuid4()}")
        sender_profile = await repository.create_social_profile(
            principal=sender,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Sender",
            ),
        )
        recipient_profile = await repository.create_social_profile(
            principal=recipient,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Recipient",
            ),
        )
        friend_request = await repository.create_social_request(
            principal=sender,
            request=ManagedSocialRequestCreate(
                request_id=uuid4(),
                noop_id=recipient_profile["noop_id"],
            ),
        )
        sender_profile_id = UUID(sender_profile["profile_id"])
        recipient_profile_id = UUID(recipient_profile["profile_id"])
        relationship_key = repository._social_relationship_lock_key(
            sender_profile_id,
            recipient_profile_id,
        )

        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            async with blocker.transaction():
                await blocker.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    relationship_key,
                )
                accept_task = asyncio.create_task(
                    repository.decide_social_request(
                        principal=recipient,
                        request_id=UUID(friend_request["request_id"]),
                        decision="accept",
                    )
                )
                block_task = asyncio.create_task(
                    repository.block_social_profile(
                        principal=recipient,
                        blocked_profile_id=sender_profile_id,
                    )
                )
                await asyncio.sleep(0.05)
                assert not accept_task.done()
                assert not block_task.done()

        accept_result, block_result = await asyncio.wait_for(
            asyncio.gather(
                accept_task,
                block_task,
                return_exceptions=True,
            ),
            timeout=5,
        )
        assert block_result is None
        assert isinstance(accept_result, (dict, ManagedConflictError))

        relationship = await pool.fetchrow(
            """
            SELECT
                EXISTS (
                    SELECT 1
                    FROM managed_social_blocks
                    WHERE blocker_profile_id = $1
                      AND blocked_profile_id = $2
                ) AS blocked,
                EXISTS (
                    SELECT 1
                    FROM managed_social_friendships
                    WHERE profile_low_id = LEAST($1::uuid, $2::uuid)
                      AND profile_high_id = GREATEST($1::uuid, $2::uuid)
                ) AS friends,
                (
                    SELECT count(*)
                    FROM managed_social_visibility
                    WHERE (
                        owner_profile_id = $1 AND reader_profile_id = $2
                    ) OR (
                        owner_profile_id = $2 AND reader_profile_id = $1
                    )
                ) AS visibility_count
            """,
            recipient_profile_id,
            sender_profile_id,
        )
        assert relationship["blocked"] is True
        assert relationship["friends"] is False
        assert relationship["visibility_count"] == 0
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_managed_social_consent_isolation_poke_and_lifecycle() -> None:
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
        first = await _principal(primary, label=f"first-{uuid4()}")
        second = await _principal(primary, label=f"second-{uuid4()}")
        outsider = await _principal(primary, label=f"outsider-{uuid4()}")

        first_profile = await repository.create_social_profile(
            principal=first,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="First",
            ),
        )
        repeated_profile = await repository.create_social_profile(
            principal=first,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Ignored on replay",
            ),
        )
        second_profile = await repository.create_social_profile(
            principal=second,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Second",
            ),
        )
        outsider_profile = await repository.create_social_profile(
            principal=outsider,
            request=ManagedSocialProfileCreate(
                request_id=uuid4(),
                display_name="Outside",
            ),
        )
        assert repeated_profile["duplicate"] is True
        assert repeated_profile["noop_id"] == first_profile["noop_id"]

        found = await repository.lookup_social_profile(
            principal=second,
            noop_id=first_profile["noop_id"],
        )
        assert found["profile_id"] == first_profile["profile_id"]
        old_alias = first_profile["noop_id"]
        rotated = await repository.rotate_social_alias(principal=first)
        assert rotated["noop_id"] != old_alias
        with pytest.raises(ManagedNotFoundError):
            await repository.lookup_social_profile(
                principal=second,
                noop_id=old_alias,
            )
        with pytest.raises(asyncpg.CheckViolationError):
            await primary._require_pool().execute(
                """
                UPDATE managed_social_aliases
                SET purge_after = NULL
                WHERE alias_value = $1 AND status = 'revoked'
                """,
                old_alias,
            )

        cooldown_request = await repository.create_social_request(
            principal=outsider,
            request=ManagedSocialRequestCreate(
                request_id=uuid4(),
                noop_id=second_profile["noop_id"],
            ),
        )
        await repository.decide_social_request(
            principal=second,
            request_id=UUID(cooldown_request["request_id"]),
            decision="decline",
        )
        with pytest.raises(ManagedConflictError):
            await repository.create_social_request(
                principal=outsider,
                request=ManagedSocialRequestCreate(
                    request_id=uuid4(),
                    noop_id=second_profile["noop_id"],
                ),
            )
        reverse_request = await repository.create_social_request(
            principal=second,
            request=ManagedSocialRequestCreate(
                request_id=uuid4(),
                noop_id=outsider_profile["noop_id"],
            ),
        )
        await repository.decide_social_request(
            principal=outsider,
            request_id=UUID(reverse_request["request_id"]),
            decision="decline",
        )

        invite_request_id = uuid4()
        capability = _capability()
        invite = await repository.create_social_invite(
            principal=first,
            request=ManagedSocialInviteCreate(
                request_id=invite_request_id,
                capability=capability,
                expires_in_hours=72,
            ),
        )
        invite_replay = await repository.create_social_invite(
            principal=first,
            request=ManagedSocialInviteCreate(
                request_id=invite_request_id,
                capability=capability,
                expires_in_hours=72,
            ),
        )
        assert invite_replay["duplicate"] is True
        request = await repository.redeem_social_invite(
            principal=second,
            request_id=uuid4(),
            capability=invite["capability"],
        )
        assert request["status"] == "pending"
        assert request["direction"] == "outgoing"

        accepted = await repository.decide_social_request(
            principal=first,
            request_id=UUID(request["request_id"]),
            decision="accept",
        )
        assert accepted["status"] == "accepted"
        assert (
            await repository.decide_social_request(
                principal=first,
                request_id=UUID(request["request_id"]),
                decision="accept",
            )
        )["duplicate"] is True

        empty_friends = await repository.list_social_friends(principal=first)
        assert empty_friends[0]["latest"] is None
        assert not any(empty_friends[0]["shared_with_me"].values())

        await repository.update_social_visibility(
            principal=second,
            friend_profile_id=UUID(first_profile["profile_id"]),
            patch=ManagedSocialVisibilityPatch(
                charge=True,
                sleep_duration=True,
            ),
        )
        summary_request_id = uuid4()
        summary = await repository.put_social_summary(
            principal=second,
            day=datetime.now(UTC).date(),
            mutation=ManagedSocialSummaryMutation(
                request_id=summary_request_id,
                summary={
                    "charge": 73.25,
                    "sleep_duration": 447.0,
                },
            ),
        )
        summary_replay = await repository.put_social_summary(
            principal=second,
            day=datetime.now(UTC).date(),
            mutation=ManagedSocialSummaryMutation(
                request_id=summary_request_id,
                summary={
                    "charge": 73.25,
                    "sleep_duration": 447.0,
                },
            ),
        )
        assert summary["duplicate"] is False
        assert summary_replay["duplicate"] is True
        with pytest.raises(ManagedConflictError):
            await repository.put_social_summary(
                principal=second,
                day=datetime.now(UTC).date(),
                mutation=ManagedSocialSummaryMutation(
                    request_id=summary_request_id,
                    summary={"charge": 1.0},
                ),
            )
        friends = await repository.list_social_friends(principal=first)
        assert friends[0]["latest"]["summary"] == {
            "charge": 73.25,
            "sleep_duration": 447.0,
        }
        feed = await repository.social_feed(
            principal=first,
            start=datetime.now(UTC).date(),
            end=datetime.now(UTC).date(),
        )
        assert feed[0]["summary"] == {
            "charge": 73.25,
            "sleep_duration": 447.0,
        }
        assert (
            await repository.social_feed(
                principal=outsider,
                start=datetime.now(UTC).date(),
                end=datetime.now(UTC).date(),
            )
            == []
        )
        with pytest.raises(ManagedForbiddenError):
            await repository.put_social_summary(
                principal=second,
                day=datetime.now(UTC).date(),
                mutation=ManagedSocialSummaryMutation(
                    request_id=uuid4(),
                    summary={"hrv": 58.0},
                ),
            )
        await repository.update_social_visibility(
            principal=second,
            friend_profile_id=UUID(first_profile["profile_id"]),
            patch=ManagedSocialVisibilityPatch(
                charge=False,
                sleep_duration=False,
            ),
        )
        cleared = await primary._require_pool().fetchrow(
            """
            SELECT charge, sleep_duration
            FROM managed_social_daily_summaries
            WHERE profile_id = $1 AND day = $2
            """,
            UUID(second_profile["profile_id"]),
            datetime.now(UTC).date(),
        )
        assert cleared["charge"] is None
        assert cleared["sleep_duration"] is None

        await repository.update_social_profile(
            principal=first,
            patch=ManagedSocialProfilePatch(
                poke_opt_in=True,
                quiet_start_minute=0,
                quiet_end_minute=0,
                time_zone="UTC",
            ),
        )
        await repository.update_social_visibility(
            principal=first,
            friend_profile_id=UUID(second_profile["profile_id"]),
            patch=ManagedSocialVisibilityPatch(poke_allowed=True),
        )
        poke_request_id = uuid4()
        poke = await repository.create_social_poke(
            principal=second,
            request=ManagedSocialPokeCreate(
                request_id=poke_request_id,
                recipient_profile_id=UUID(first_profile["profile_id"]),
            ),
        )
        replayed_poke = await repository.create_social_poke(
            principal=second,
            request=ManagedSocialPokeCreate(
                request_id=poke_request_id,
                recipient_profile_id=UUID(first_profile["profile_id"]),
            ),
        )
        assert poke["status"] == "queued"
        assert replayed_poke["duplicate"] is True
        with pytest.raises(ManagedConflictError):
            await repository.create_social_poke(
                principal=second,
                request=ManagedSocialPokeCreate(
                    request_id=uuid4(),
                    recipient_profile_id=UUID(first_profile["profile_id"]),
                ),
            )

        claimed = await repository.claim_social_pokes(
            principal=first,
            installation_id="ios-test-installation",
            limit=3,
        )
        assert len(claimed) == 1
        acknowledgement = ManagedSocialPokeAcknowledgement(
            claim_id=UUID(claimed[0]["claim_id"]),
            notification_outcome="scheduled",
            haptic_outcome="requested",
        )
        with pytest.raises(ManagedConflictError):
            await repository.acknowledge_social_poke(
                principal=first,
                installation_id="other-installation",
                poke_id=UUID(claimed[0]["poke_id"]),
                acknowledgement=acknowledgement,
            )
        acknowledged = await repository.acknowledge_social_poke(
            principal=first,
            installation_id="ios-test-installation",
            poke_id=UUID(claimed[0]["poke_id"]),
            acknowledgement=acknowledgement,
        )
        assert acknowledged["status"] == "acknowledged"

        pool = primary._require_pool()
        await pool.execute(
            """
            UPDATE managed_social_pokes
            SET created_at = created_at - interval '20 minutes',
                expires_at = expires_at - interval '20 minutes'
            WHERE poke_id = $1
            """,
            UUID(poke["poke_id"]),
        )
        revocable_poke = await repository.create_social_poke(
            principal=second,
            request=ManagedSocialPokeCreate(
                request_id=uuid4(),
                recipient_profile_id=UUID(first_profile["profile_id"]),
            ),
        )
        await repository.update_social_profile(
            principal=first,
            patch=ManagedSocialProfilePatch(poke_opt_in=False),
        )
        assert (
            await repository.claim_social_pokes(
                principal=first,
                installation_id="ios-test-installation",
                limit=3,
            )
            == []
        )
        assert (
            await pool.fetchval(
                """
                SELECT status
                FROM managed_social_pokes
                WHERE poke_id = $1
                """,
                UUID(revocable_poke["poke_id"]),
            )
            == "expired"
        )

        await repository.block_social_profile(
            principal=first,
            blocked_profile_id=UUID(second_profile["profile_id"]),
        )
        blocks = await repository.list_social_blocks(principal=first)
        assert blocks == [
            {
                "profile_id": second_profile["profile_id"],
                "display_name": "Second",
                "blocked_at": blocks[0]["blocked_at"],
            }
        ]
        assert await repository.list_social_friends(principal=first) == []
        with pytest.raises(ManagedNotFoundError):
            await repository.lookup_social_profile(
                principal=second,
                noop_id=rotated["noop_id"],
            )
        await repository.unblock_social_profile(
            principal=first,
            blocked_profile_id=UUID(second_profile["profile_id"]),
        )
        assert await repository.list_social_blocks(principal=first) == []
        assert (
            await repository.lookup_social_profile(
                principal=second,
                noop_id=rotated["noop_id"],
            )
        )["profile_id"] == first_profile["profile_id"]
        await repository.block_social_profile(
            principal=first,
            blocked_profile_id=UUID(second_profile["profile_id"]),
        )
        with pytest.raises(ManagedForbiddenError):
            await repository.create_social_poke(
                principal=second,
                request=ManagedSocialPokeCreate(
                    request_id=uuid4(),
                    recipient_profile_id=UUID(first_profile["profile_id"]),
                ),
            )

        expiring_request_id = uuid4()
        expiring_invite = await repository.create_social_invite(
            principal=first,
            request=ManagedSocialInviteCreate(
                request_id=expiring_request_id,
                capability=_capability(),
                expires_in_hours=1,
            ),
        )
        now = await repository.coordination_now()
        await pool.execute(
            """
            UPDATE managed_social_invites
            SET created_at = $2::timestamptz - interval '2 hours',
                expires_at = $2::timestamptz - interval '1 hour'
            WHERE invite_id = $1
            """,
            UUID(expiring_invite["invite_id"]),
            now,
        )
        expired_replay = await repository.create_social_invite(
            principal=first,
            request=ManagedSocialInviteCreate(
                request_id=expiring_request_id,
                capability=expiring_invite["capability"],
                expires_in_hours=1,
            ),
        )
        assert expired_replay["status"] == "expired"
        lifecycle_invite = await repository.create_social_invite(
            principal=first,
            request=ManagedSocialInviteCreate(
                request_id=uuid4(),
                capability=_capability(),
                expires_in_hours=1,
            ),
        )
        await pool.execute(
            """
            UPDATE managed_social_invites
            SET created_at = $2::timestamptz - interval '2 hours',
                expires_at = $2::timestamptz - interval '1 hour'
            WHERE invite_id = $1
            """,
            UUID(lifecycle_invite["invite_id"]),
            now,
        )
        await pool.execute(
            """
            UPDATE managed_social_daily_summaries
            SET day = (($2 AT TIME ZONE 'UTC')::date - 100)
            WHERE profile_id = $1
            """,
            UUID(second_profile["profile_id"]),
            now,
        )
        counts = await repository.purge_expired_control_rows(
            now=now,
            batch_size=100,
        )
        assert counts["social_invites_expired"] == 1
        assert counts["social_summaries"] == 1
        assert "social_pokes" in counts

        await repository.delete_social_profile(principal=first)
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_social_pokes
                WHERE sender_profile_id = $1 OR recipient_profile_id = $1
                """,
                UUID(first_profile["profile_id"]),
            )
            == 0
        )
        with pytest.raises(ManagedNotFoundError):
            await repository.delete_social_profile(principal=first)
    finally:
        await primary.shutdown()
