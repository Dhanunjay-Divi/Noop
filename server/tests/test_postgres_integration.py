from __future__ import annotations

import hashlib
import json
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app.models import SyncPayload
from app.repository import (
    FriendConflictError,
    FriendNotFoundError,
    PostgresRepository,
)

FIXTURES = Path(__file__).resolve().parent / "data"
DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")


def _load_fixture(name: str) -> SyncPayload:
    return SyncPayload.model_validate_json(
        (FIXTURES / name).read_text(encoding="utf-8")
    )


def _payload_hash(payload: SyncPayload) -> str:
    canonical = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_timescaledb_migrations_idempotency_rr_and_row_provenance() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    raw = _load_fixture("apple_sync_v1.json")
    official = _load_fixture("official_reference_sync_v1.json")

    await repository.startup()
    try:
        await repository.delete_device(raw.source.device_id)
        await repository.delete_device(official.source.device_id)

        accepted = await repository.sync(raw, _payload_hash(raw))
        duplicate = await repository.sync(raw, _payload_hash(raw))
        official_result = await repository.sync(official, _payload_hash(official))

        assert accepted.duplicate is False
        assert duplicate.duplicate is True
        assert official_result.counts.daily_metrics == 4

        rr = await repository.metric_range(
            raw.source.device_id,
            "rr",
            raw.streams.rr[0].recorded_at.replace(hour=0, minute=0, second=0),
            raw.streams.rr[0].recorded_at.replace(
                hour=23, minute=59, second=59, microsecond=999_999
            ),
            100,
        )
        assert [(row["value"], row["metadata"]["seq"]) for row in rr] == [
            (810.0, "0"),
            (825.0, "0"),
            (810.0, "1"),
        ]
        assert all(row["sync_batch_id"] == raw.batch_id for row in rr)
        assert all(
            row["source_metadata"]["logical_source_id"] == "strap-abc-strap"
            for row in rr
        )

        export = await repository.export_device(official.source.device_id, None, None)
        assert export["daily_metrics"][0]["source_metadata"]["namespace"] == (
            "official_reference"
        )
        assert export["sleep_sessions"][0]["sync_batch_id"] == official.batch_id

        pool = repository._require_pool()
        async with pool.acquire() as connection:
            migration_count = await connection.fetchval(
                "SELECT count(*) FROM noop_schema_migrations"
            )
            assert migration_count == 3
            await repository._run_migrations(connection)
            assert (
                await connection.fetchval("SELECT count(*) FROM noop_schema_migrations")
                == migration_count
            )
            assert (
                await connection.fetchval(
                    """
                    SELECT count(*)
                    FROM metric_samples
                    WHERE device_id = $1 AND metric = 'rr'
                    """,
                    raw.source.device_id,
                )
                == 3
            )
    finally:
        await repository.delete_device(raw.source.device_id)
        await repository.delete_device(official.source.device_id)
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_timescaledb_friend_join_and_directional_visibility() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    alice_id = str(uuid4())
    bob_id = str(uuid4())
    alice_install = str(uuid4())
    bob_install = str(uuid4())
    invite_id = str(uuid4())
    request_id = str(uuid4())
    bob_enrollment = str(uuid4())
    invite_hash = hashlib.sha256(b"postgres-friend-invite").hexdigest()
    bob_token_hash = hashlib.sha256(b"bob-member-token").hexdigest()

    await repository.startup()
    try:
        alice = await repository.create_friend_profile(
            alice_id,
            str(uuid4()),
            "Alice",
            alice_install,
            f"ios:{alice_install}:noop-friends",
            hashlib.sha256(b"alice-member-token").hexdigest(),
        )
        assert str(alice["profile_id"]) == alice_id
        await repository.create_friend_invite(
            invite_id,
            alice_id,
            invite_hash,
            datetime.now(UTC) + timedelta(hours=1),
        )

        orphan_install = str(uuid4())
        with pytest.raises(FriendNotFoundError):
            await repository.join_friend_invite(
                hashlib.sha256(b"wrong-code").hexdigest(),
                str(uuid4()),
                str(uuid4()),
                "Orphan",
                orphan_install,
                f"ios:{orphan_install}:noop-friends",
                hashlib.sha256(b"orphan-token").hexdigest(),
                str(uuid4()),
                datetime.now(UTC),
            )

        joined = await repository.join_friend_invite(
            invite_hash,
            bob_id,
            bob_enrollment,
            "Bob",
            bob_install,
            f"ios:{bob_install}:noop-friends",
            bob_token_hash,
            request_id,
            datetime.now(UTC),
        )
        assert str(joined["profile"]["profile_id"]) == bob_id
        assert joined["inviter_display_name"] == "Alice"
        replay = await repository.join_friend_invite(
            invite_hash,
            str(uuid4()),
            bob_enrollment,
            "Bob",
            bob_install,
            f"ios:{bob_install}:noop-friends",
            bob_token_hash,
            str(uuid4()),
            datetime.now(UTC) + timedelta(days=30),
        )
        assert replay["idempotent_replay"] is True
        assert str(replay["profile"]["profile_id"]) == bob_id
        assert str(replay["request"]["request_id"]) == request_id
        with pytest.raises(FriendConflictError):
            await repository.join_friend_invite(
                invite_hash,
                str(uuid4()),
                bob_enrollment,
                "Bob",
                bob_install,
                f"ios:{bob_install}:noop-friends",
                hashlib.sha256(b"different-token").hexdigest(),
                str(uuid4()),
                datetime.now(UTC),
            )

        accepted_at = datetime.now(UTC)
        accepted = await repository.decide_friend_request(
            alice_id,
            request_id,
            "accept",
            accepted_at,
        )
        assert accepted["status"] == "accepted"
        accepted_replay = await repository.join_friend_invite(
            invite_hash,
            str(uuid4()),
            bob_enrollment,
            "Bob",
            bob_install,
            f"ios:{bob_install}:noop-friends",
            bob_token_hash,
            str(uuid4()),
            datetime.now(UTC),
        )
        assert accepted_replay["idempotent_replay"] is True
        assert accepted_replay["request"]["status"] == "accepted"
        visibility = await repository.update_friend_visibility(
            alice_id,
            bob_id,
            {"hrv": True},
        )
        assert visibility["hrv"] is True
        bob_friends = await repository.list_friends(bob_id)
        assert bob_friends[0]["shared_with_me"]["hrv"] is True
        assert bob_friends[0]["sharing"]["hrv"] is False

        today = accepted_at.date()
        prior_day = today - timedelta(days=1)
        social_payload = SyncPayload.model_validate(
            {
                "schema_version": 1,
                "batch_id": str(uuid4()),
                "source": {
                    "device_id": f"ios:{alice_install}:noop-friends",
                    "sent_at": datetime.now(UTC).isoformat(),
                    "platform": "ios",
                    "metadata": {
                        "installation_id": alice_install,
                        "logical_source_id": "noop-friends",
                        "namespace": "noop_computed",
                        "paired_device_id": "strap-test",
                        "privacy": "explicit_opt_in",
                        "score_provenance": "noop_transparent_algorithm",
                        "algorithm_revision": "friends-test-v1",
                    },
                },
                "streams": {},
                "daily_metrics": {
                    prior_day.isoformat(): {
                        "recovery": 10,
                        "effort": 10,
                        "sleep_performance": 10,
                    },
                    today.isoformat(): {
                        "recovery": 72,
                        "effort": 59,
                        "sleep_performance": 81,
                    },
                },
                "sleep_sessions": [],
                "workouts": [],
                "journal": [],
            }
        )
        await repository.sync(
            social_payload,
            _payload_hash(social_payload),
            social_profile_id=alice_id,
        )
        feed = await repository.friend_feed(bob_id, prior_day, today)
        assert [row["day"] for row in feed] == [today]

        replacement_body = social_payload.model_dump(mode="json")
        replacement_body["batch_id"] = str(uuid4())
        replacement_body["daily_metrics"] = {today.isoformat(): {"recovery": 73.0}}
        replacement = SyncPayload.model_validate(replacement_body)
        await repository.sync(
            replacement,
            _payload_hash(replacement),
            social_profile_id=alice_id,
        )
        replaced_feed = await repository.friend_feed(bob_id, today, today)
        assert replaced_feed[0]["summary"] == {"charge": 73.0}

        deleted = await repository.delete_friend_profile_data(
            alice_id,
            f"ios:{alice_install}:noop-friends",
        )
        assert deleted["friend_profiles"] == 1
        assert (
            await repository.daily_metrics(
                f"ios:{alice_install}:noop-friends", today, today
            )
            == []
        )
        assert await repository.list_friends(bob_id) == []
    finally:
        pool = repository._require_pool()
        await pool.execute(
            "DELETE FROM friend_profiles WHERE profile_id = ANY($1::uuid[])",
            [UUID(alice_id), UUID(bob_id)],
        )
        await repository.shutdown()
