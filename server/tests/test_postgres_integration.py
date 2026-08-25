from __future__ import annotations

import asyncio
import hashlib
import json
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app.models import SyncPayload
from app.repository import (
    ExportLimitExceededError,
    FriendConflictError,
    FriendForbiddenError,
    FriendNotFoundError,
    PostgresRepository,
    SyncForbiddenError,
    SyncRetiredError,
)
from app.safety_repository import PostgresSafetyRepository
from app.safety_repository import SafetyConflictError
from app.tenancy import (
    InstallationConflictError,
    PostgresInstallationRepository,
)

FIXTURES = Path(__file__).resolve().parent / "data"
MIGRATIONS = Path(__file__).resolve().parents[1] / "migrations"
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


async def _wait_for_advisory_waiters(pool, *, minimum: int) -> None:
    for _ in range(200):
        waiting = await pool.fetchval(
            """
            SELECT count(*)
            FROM pg_locks
            WHERE locktype = 'advisory' AND NOT granted
            """
        )
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} advisory-lock waiters")


async def _wait_for_lock_waiters(pool, *, minimum: int) -> None:
    for _ in range(200):
        waiting = await pool.fetchval(
            """
            SELECT count(*)
            FROM pg_locks
            WHERE NOT granted
            """
        )
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} lock waiters")


def test_safety_migration_removes_legacy_constraints_before_state_conversion() -> None:
    sql = (MIGRATIONS / "006_safety_incidents.sql").read_text(encoding="utf-8")

    dispatch_drop = sql.index("DROP CONSTRAINT IF EXISTS safety_dispatch_status")
    dispatch_conversion = sql.index("UPDATE safety_dispatches\nSET status = 'expired'")
    delivery_drop = sql.index("DROP CONSTRAINT IF EXISTS safety_delivery_status")
    delivery_conversion = sql.index("UPDATE safety_deliveries\nSET status = CASE")

    assert dispatch_drop < dispatch_conversion
    assert delivery_drop < delivery_conversion


def test_safety_control_migration_is_fail_safe_and_admits_terminal_failure() -> None:
    sql = (MIGRATIONS / "008_safety_paging_control.sql").read_text(encoding="utf-8")

    assert "CREATE TABLE IF NOT EXISTS safety_runtime_controls" in sql
    assert "CREATE TABLE IF NOT EXISTS safety_runtime_control_audit" in sql
    assert "VALUES ('paging', TRUE" in sql
    assert "ON CONFLICT (control_name) DO NOTHING" in sql
    assert "CREATE TABLE IF NOT EXISTS safety_worker_heartbeats" in sql
    assert sql.index("DROP CONSTRAINT IF EXISTS safety_dispatch_status") < sql.index(
        "ADD CONSTRAINT safety_dispatch_status"
    )
    assert "'failed'" in sql
    assert "'unknown'" in sql


def test_safety_reliability_migration_is_fail_closed_and_indexed() -> None:
    sql = (MIGRATIONS / "009_safety_reliability.sql").read_text(encoding="utf-8")

    assert "ALTER COLUMN actor SET NOT NULL" in sql
    assert "request_id uuid" in sql
    assert "Awaiting explicit production paging enablement" in sql
    assert "AND revision = 1" in sql
    assert "CREATE TABLE IF NOT EXISTS safety_invitation_jobs" in sql
    assert "CREATE TABLE IF NOT EXISTS safety_invitation_attempts" in sql
    assert "CREATE TABLE IF NOT EXISTS safety_provider_rate_state" in sql
    assert "safety_invitation_jobs_due_idx" in sql
    assert "safety_deliveries_status_updated_idx" in sql
    assert "safety_delivery_attempts_status_finished_idx" in sql
    assert "safety_invitation_attempts_status_finished_idx" in sql


def test_tenancy_and_safety_lifecycle_migrations_are_complete() -> None:
    tenancy = (MIGRATIONS / "010_installation_tenancy.sql").read_text(encoding="utf-8")
    lifecycle = (MIGRATIONS / "011_safety_data_lifecycle.sql").read_text(
        encoding="utf-8"
    )
    cutover = (MIGRATIONS / "012_tenancy_cutover_invariants.sql").read_text(
        encoding="utf-8"
    )
    escalation = (MIGRATIONS / "013_safety_escalation_contract.sql").read_text(
        encoding="utf-8"
    )

    assert "CREATE TABLE IF NOT EXISTS installation_credentials" in tenancy
    assert "CREATE TABLE IF NOT EXISTS installation_devices" in tenancy
    assert "split_part(device_id, ':', 2) = installation_id" in tenancy
    assert "token_version bigint NOT NULL DEFAULT 1" in lifecycle
    assert "CREATE TABLE IF NOT EXISTS safety_dispatch_tombstones" in lifecycle
    assert "ON DELETE CASCADE" in lifecycle
    assert "AFTER INSERT ON devices" in cutover
    assert "BEFORE INSERT ON friend_profiles" in cutover
    assert "BEFORE INSERT ON safety_profiles" in cutover
    assert "validated_fall" in escalation
    assert "safety_dispatches_fall_event_unique" in escalation
    assert "safety_delivery_round_unique" in escalation
    assert "share_duration_hours" in escalation


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_installation_tenancy_rotation_and_isolation() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    installations = PostgresInstallationRepository(repository)
    now = datetime.now(UTC)
    first = str(uuid4())
    second = str(uuid4())
    first_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    second_hash = hashlib.sha256(uuid4().bytes).hexdigest()

    await repository.startup()
    try:
        for installation_id, token_hash in (
            (first, first_hash),
            (second, second_hash),
        ):
            await installations.create_installation(
                installation_id=installation_id,
                enrollment_id=str(uuid4()),
                token_hash=token_hash,
                now=now,
            )
        device_id = f"ios:{first}:strap"
        await installations.claim_device(
            installation_id=first,
            device_id=device_id,
            now=now,
        )
        with pytest.raises(InstallationConflictError):
            await installations.claim_device(
                installation_id=second,
                device_id=device_id,
                now=now,
            )
        replacement_hash = hashlib.sha256(uuid4().bytes).hexdigest()
        rotated = await installations.rotate_token(
            installation_id=first,
            rotation_id=str(uuid4()),
            expected_version=1,
            token_hash=replacement_hash,
            now=now + timedelta(minutes=1),
        )
        assert rotated["token_version"] == 2
        assert await installations.installation_for_token(first_hash) is None
        assert (await installations.installation_for_token(replacement_hash))[
            "installation_id"
        ] == first
        assert await installations.device_ids(first) == [device_id]
        await installations.revoke_installation(
            installation_id=first,
            now=now + timedelta(minutes=2),
        )
        assert await installations.shared_cutover_ready() is True
    finally:
        for installation_id in (first, second):
            try:
                await installations.delete_installation(installation_id)
            except Exception:
                pass
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_cutover_backfills_rows_created_after_tenancy_migration() -> (
    None
):
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=3,
    )
    installations = PostgresInstallationRepository(repository)
    safety = PostgresSafetyRepository(repository)
    installation_id = str(uuid4())
    profile_id = str(uuid4())
    friend_profile_id = str(uuid4())
    daily_device_id = f"ios:{installation_id}:noop-computed"
    payload_body = _load_fixture("apple_sync_v1.json").model_dump(mode="json")
    payload_body["batch_id"] = str(uuid4())
    payload_body["source"]["device_id"] = f"ios:{installation_id}:strap"
    payload_body["source"]["metadata"]["installation_id"] = installation_id
    payload = SyncPayload.model_validate(payload_body)

    await repository.startup()
    try:
        await repository.sync(payload, _payload_hash(payload))
        await repository.create_friend_profile(
            friend_profile_id,
            str(uuid4()),
            "Cutover friend",
            installation_id,
            daily_device_id,
            hashlib.sha256(uuid4().bytes).hexdigest(),
        )
        await safety.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Cutover safety",
            installation_id=installation_id,
            token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
        )

        assert await installations.shared_cutover_ready() is True
        assert set(await installations.device_ids(installation_id)) == {
            payload.source.device_id
        }
        assert any(
            row["installation_id"] == installation_id
            for row in await installations.list_installations()
        )
    finally:
        try:
            await safety.delete_profile(profile_id)
        except Exception:
            pass
        try:
            await repository.delete_friend_profile_data(
                friend_profile_id,
                daily_device_id,
                include_disabled=True,
            )
        except Exception:
            pass
        try:
            await repository.delete_device(payload.source.device_id)
        except Exception:
            pass
        try:
            await installations.delete_installation(installation_id)
        except Exception:
            pass
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_erasure_wins_against_already_claimed_delayed_sync() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
    )
    installations = PostgresInstallationRepository(repository)
    installation_id = str(uuid4())
    token_hash = hashlib.sha256(uuid4().bytes).hexdigest()
    device_id = f"ios:{installation_id}:strap"
    first = _load_fixture("apple_sync_v1.json")
    first_body = first.model_dump(mode="json")
    first_body["batch_id"] = str(uuid4())
    first_body["source"]["device_id"] = device_id
    first_body["source"]["metadata"]["installation_id"] = installation_id
    first = SyncPayload.model_validate(first_body)
    delayed_body = first.model_dump(mode="json")
    delayed_body["batch_id"] = str(uuid4())
    delayed_body["source"]["sent_at"] = (
        datetime.now(UTC) + timedelta(seconds=1)
    ).isoformat()
    delayed = SyncPayload.model_validate(delayed_body)

    await repository.startup()
    blocker = None
    try:
        now = datetime.now(UTC)
        await installations.create_installation(
            installation_id=installation_id,
            enrollment_id=str(uuid4()),
            token_hash=token_hash,
            now=now,
        )
        await installations.claim_device(
            installation_id=installation_id,
            device_id=device_id,
            now=now,
        )
        await repository.sync(
            first,
            _payload_hash(first),
            installation_id=installation_id,
        )
        await installations.revoke_installation(
            installation_id=installation_id,
            now=now + timedelta(seconds=1),
        )

        pool = repository._require_pool()
        blocker = await pool.acquire()
        await blocker.execute(
            "SELECT pg_advisory_lock(hashtextextended($1, 0))",
            f"noop-device:{device_id}",
        )
        delete_task = asyncio.create_task(
            repository.delete_device(
                device_id,
                now + timedelta(days=30),
            )
        )
        await _wait_for_advisory_waiters(pool, minimum=1)
        sync_task = asyncio.create_task(
            repository.sync(
                delayed,
                _payload_hash(delayed),
                installation_id=installation_id,
            )
        )
        await _wait_for_advisory_waiters(pool, minimum=2)
        await blocker.execute(
            "SELECT pg_advisory_unlock(hashtextextended($1, 0))",
            f"noop-device:{device_id}",
        )
        await pool.release(blocker)
        blocker = None

        deleted = await delete_task
        assert deleted["devices"] == 1
        with pytest.raises(SyncForbiddenError):
            await sync_task
        exported = await repository.export_device(device_id, None, None)
        assert exported["device"] is None
        assert exported["metric_samples"] == []
    finally:
        if blocker is not None:
            await blocker.execute(
                "SELECT pg_advisory_unlock(hashtextextended($1, 0))",
                f"noop-device:{device_id}",
            )
            await repository._require_pool().release(blocker)
        try:
            await repository.delete_device(device_id)
        except Exception:
            pass
        try:
            await installations.delete_installation(installation_id)
        except Exception:
            pass
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_safety_lifecycle_export_retention_and_erasure() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    safety = PostgresSafetyRepository(repository)
    installation_id = str(uuid4())
    profile_id = str(uuid4())
    old = datetime.now(UTC) - timedelta(days=60)
    now = datetime.now(UTC)
    token_hash = hashlib.sha256(uuid4().bytes).hexdigest()

    await repository.startup()
    original_control: dict | None = None
    try:
        original_control = await safety.paging_control()
        if not original_control["enabled"]:
            await safety.set_paging_control(
                enabled=True,
                reason="PostgreSQL lifecycle integration test",
                expected_revision=int(original_control["revision"]),
                now=now,
            )
        await safety.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Lifecycle integration",
            installation_id=installation_id,
            token_hash=token_hash,
        )
        replacement_hash = hashlib.sha256(uuid4().bytes).hexdigest()
        rotated = await safety.rotate_profile_token(
            profile_id=profile_id,
            rotation_id=str(uuid4()),
            expected_version=1,
            token_hash=replacement_hash,
            now=now,
        )
        assert rotated["token_version"] == 2
        for index in range(2):
            invite_hash = hashlib.sha256(
                f"lifecycle-invite-{uuid4()}".encode()
            ).hexdigest()
            await safety.create_contact(
                contact_id=str(uuid4()),
                profile_id=profile_id,
                display_name=f"Contact {index}",
                phone_e164=f"+1415555050{index}",
                invite_token_hash=invite_hash,
                invited_at=old,
                invite_expires_at=old + timedelta(days=7),
            )
            await safety.decide_invitation(
                invite_token_hash=invite_hash,
                decision="accept",
                now=old,
            )
        await safety.create_contact(
            contact_id=str(uuid4()),
            profile_id=profile_id,
            display_name="Expired invitation",
            phone_e164="+14155550599",
            invite_token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
            invited_at=old,
            invite_expires_at=old + timedelta(days=7),
        )
        idempotency_key = str(uuid4())
        request_hash = hashlib.sha256(b"manual_sos").hexdigest()
        dispatch_id = str(uuid4())
        await safety.create_dispatch(
            dispatch_id=dispatch_id,
            profile_id=profile_id,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            trigger="manual_sos",
            now=old,
            expires_at=old + timedelta(minutes=30),
            voice_fallback_at=old + timedelta(seconds=90),
        )
        await safety.transition_dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
            action="resolve",
            note=None,
            now=old + timedelta(minutes=1),
        )
        exported = await safety.export_profile(profile_id)
        assert len(exported["contacts"]) == 3
        assert len(exported["incidents"]) == 1
        assert exported["row_count"] > 1
        with pytest.raises(ExportLimitExceededError):
            await safety.export_profile(profile_id, max_rows=1)

        counts = await safety.purge_retained_data(
            incident_cutoff=now - timedelta(days=30),
            contact_cutoff=now - timedelta(days=30),
            replay_guard_until=now + timedelta(days=30),
            now=now,
            limit=100,
        )
        assert counts["incidents"] == 1
        assert counts["contacts"] == 1
        with pytest.raises(SafetyConflictError, match="retired"):
            await safety.create_dispatch(
                dispatch_id=str(uuid4()),
                profile_id=profile_id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                trigger="manual_sos",
                now=now,
                expires_at=now + timedelta(minutes=30),
                voice_fallback_at=now + timedelta(seconds=90),
            )
        deleted = await safety.delete_profiles_for_installation(installation_id)
        assert deleted["profiles"] == 1
        assert deleted["contacts"] == 2
        assert deleted["dispatch_tombstones"] == 1
        assert await safety.profile_for_token(replacement_hash) is None
    finally:
        try:
            await safety.delete_profiles_for_installation(installation_id)
        except Exception:
            pass
        if original_control is not None:
            current = await safety.paging_control()
            if bool(current["enabled"]) != bool(original_control["enabled"]):
                await safety.set_paging_control(
                    enabled=bool(original_control["enabled"]),
                    reason="PostgreSQL lifecycle integration test cleanup",
                    expected_revision=int(current["revision"]),
                    now=datetime.now(UTC),
                )
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_safety_escalation_and_fall_event_contract() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    safety = PostgresSafetyRepository(repository)
    installation_id = str(uuid4())
    profile_id = str(uuid4())
    now = datetime.now(UTC)
    original_control: dict | None = None
    event_id = str(uuid4())
    evidence = {
        "detector_id": "noop_band_fall",
        "detector_version": 1,
        "event_id": event_id,
        "detected_at": (now - timedelta(seconds=47)).isoformat(),
        "warning_haptic_confirmed_at": (now - timedelta(seconds=46)).isoformat(),
        "response_deadline_at": (now - timedelta(seconds=1)).isoformat(),
    }

    await repository.startup()
    try:
        original_control = await safety.paging_control()
        if not original_control["enabled"]:
            await safety.set_paging_control(
                enabled=True,
                reason="PostgreSQL Safety escalation integration test",
                expected_revision=int(original_control["revision"]),
                now=now,
            )
        await safety.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Escalation integration",
            installation_id=installation_id,
            token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
        )
        for index in range(2):
            invite_hash = hashlib.sha256(
                f"escalation-invite-{uuid4()}".encode()
            ).hexdigest()
            await safety.create_contact(
                contact_id=str(uuid4()),
                profile_id=profile_id,
                display_name=f"Contact {index}",
                phone_e164=f"+1415555070{index}",
                invite_token_hash=invite_hash,
                invited_at=now,
                invite_expires_at=now + timedelta(days=7),
            )
            await safety.decide_invitation(
                invite_token_hash=invite_hash,
                decision="accept",
                now=now,
            )

        idempotency_key = str(uuid4())
        request_hash = hashlib.sha256(b"validated-fall-rounds").hexdigest()
        dispatch = await safety.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            accepted_request_hashes=frozenset({request_hash}),
            trigger="validated_fall",
            share_duration_hours=12,
            evidence=evidence,
            escalation_rounds=3,
            escalation_interval_seconds=15 * 60,
            now=now,
            expires_at=now + timedelta(hours=12),
            voice_fallback_at=now + timedelta(seconds=90),
        )
        assert dispatch["share_duration_hours"] == 12
        assert dispatch["evidence"]["event_id"] == event_id
        assert dispatch["escalation_rounds"] == 3
        assert len(dispatch["deliveries"]) == 12
        assert {row["escalation_round"] for row in dispatch["deliveries"]} == {
            0,
            1,
            2,
        }
        first_contact_id = str(dispatch["deliveries"][0]["contact_id"])
        await safety.update_incident_location(
            profile_id=profile_id,
            dispatch_id=str(dispatch["dispatch_id"]),
            sequence=1,
            latitude=40.7131,
            longitude=-74.0057,
            horizontal_accuracy_meters=12.0,
            captured_at=now + timedelta(seconds=1),
            received_at=now + timedelta(seconds=2),
        )
        active_preview = await safety.responder_preview(
            dispatch_id=str(dispatch["dispatch_id"]),
            contact_id=first_contact_id,
            now=now + timedelta(seconds=3),
        )
        assert active_preview is not None
        assert active_preview["latest_location"]["sequence"] == 1

        replay = await safety.dispatch_for_idempotency_key(
            profile_id=profile_id,
            idempotency_key=idempotency_key,
            accepted_request_hashes=frozenset({request_hash}),
        )
        assert replay is not None
        assert replay["dispatch_id"] == dispatch["dispatch_id"]
        assert replay["idempotent_replay"] is True

        acknowledged = await safety.record_responder_decision(
            dispatch_id=str(dispatch["dispatch_id"]),
            contact_id=first_contact_id,
            decision="responding",
            source="sms_link",
            now=now + timedelta(minutes=1),
        )
        assert acknowledged["status"] == "acknowledged"
        assert (
            await safety.expire_due_dispatches(now=now + timedelta(hours=12, seconds=1))
            == 1
        )
        expired = await safety.dispatch_for_idempotency_key(
            profile_id=profile_id,
            idempotency_key=idempotency_key,
            accepted_request_hashes=frozenset({request_hash}),
        )
        assert expired is not None
        assert expired["status"] == "expired"
        expired_preview = await safety.responder_preview(
            dispatch_id=str(dispatch["dispatch_id"]),
            contact_id=first_contact_id,
            now=now + timedelta(hours=12, seconds=2),
        )
        assert expired_preview is not None
        assert expired_preview["latest_location"] is None

        stale_key = str(uuid4())
        stale_hash = hashlib.sha256(b"stale-acknowledged-page").hexdigest()
        stale_now = now + timedelta(hours=12, seconds=2)
        stale = await safety.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=stale_key,
            request_hash=stale_hash,
            trigger="manual_sos",
            share_duration_hours=8,
            escalation_rounds=1,
            now=stale_now,
            expires_at=stale_now + timedelta(hours=8),
            voice_fallback_at=stale_now + timedelta(seconds=90),
        )
        stale_acknowledged = await safety.record_responder_decision(
            dispatch_id=str(stale["dispatch_id"]),
            contact_id=str(stale["deliveries"][0]["contact_id"]),
            decision="responding",
            source="sms_link",
            now=stale_now + timedelta(minutes=1),
        )
        assert stale_acknowledged["status"] == "acknowledged"

        replacement_now = stale_now + timedelta(hours=8, seconds=1)
        with pytest.raises(
            SafetyConflictError,
            match="no longer accepting responses",
        ):
            await safety.record_responder_decision(
                dispatch_id=str(stale["dispatch_id"]),
                contact_id=str(stale["deliveries"][0]["contact_id"]),
                decision="responding",
                source="sms_link",
                now=replacement_now,
            )
        retired = await safety.dispatch_for_idempotency_key(
            profile_id=profile_id,
            idempotency_key=stale_key,
            accepted_request_hashes=frozenset({stale_hash}),
        )
        assert retired is not None
        assert retired["status"] == "expired"
        assert all(
            row["status"] not in {"pending", "retry_wait", "leased"}
            for row in retired["deliveries"]
        )

        replacement = await safety.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=str(uuid4()),
            request_hash=hashlib.sha256(b"replacement-page").hexdigest(),
            trigger="manual_sos",
            share_duration_hours=8,
            escalation_rounds=1,
            now=replacement_now,
            expires_at=replacement_now + timedelta(hours=8),
            voice_fallback_at=replacement_now + timedelta(seconds=90),
        )
        assert replacement["status"] == "open"
        await safety.transition_dispatch(
            profile_id=profile_id,
            dispatch_id=str(replacement["dispatch_id"]),
            action="cancel",
            note=None,
            now=replacement_now + timedelta(seconds=1),
        )

        with pytest.raises(SafetyConflictError, match="fall event was already used"):
            await safety.create_dispatch(
                dispatch_id=str(uuid4()),
                profile_id=profile_id,
                idempotency_key=str(uuid4()),
                request_hash=hashlib.sha256(b"duplicate-fall-event").hexdigest(),
                trigger="validated_fall",
                share_duration_hours=8,
                evidence=evidence,
                escalation_rounds=1,
                now=replacement_now + timedelta(seconds=2),
                expires_at=replacement_now + timedelta(hours=8, seconds=2),
                voice_fallback_at=replacement_now + timedelta(seconds=92),
            )
    finally:
        try:
            await safety.delete_profiles_for_installation(installation_id)
        except Exception:
            pass
        if original_control is not None:
            current = await safety.paging_control()
            if bool(current["enabled"]) != bool(original_control["enabled"]):
                await safety.set_paging_control(
                    enabled=bool(original_control["enabled"]),
                    reason="PostgreSQL Safety escalation integration test cleanup",
                    expected_revision=int(current["revision"]),
                    now=datetime.now(UTC),
                )
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_profile_erasure_drains_provider_submission_permit() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
    )
    safety = PostgresSafetyRepository(repository)
    profile_id = str(uuid4())
    installation_id = str(uuid4())
    now = datetime.now(UTC)
    original_control: dict | None = None

    await repository.startup()
    try:
        original_control = await safety.paging_control()
        if not original_control["enabled"]:
            await safety.set_paging_control(
                enabled=True,
                reason="PostgreSQL erase race integration test",
                expected_revision=int(original_control["revision"]),
                now=now,
            )
        await safety.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Erase race",
            installation_id=installation_id,
            token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
        )
        for index in range(2):
            invite_hash = hashlib.sha256(f"erase-race-{uuid4()}".encode()).hexdigest()
            await safety.create_contact(
                contact_id=str(uuid4()),
                profile_id=profile_id,
                display_name=f"Contact {index}",
                phone_e164=f"+1415555060{index}",
                invite_token_hash=invite_hash,
                invited_at=now,
                invite_expires_at=now + timedelta(days=7),
            )
            await safety.decide_invitation(
                invite_token_hash=invite_hash,
                decision="accept",
                now=now,
            )
        await safety.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=str(uuid4()),
            request_hash=hashlib.sha256(b"erase-race").hexdigest(),
            trigger="manual_sos",
            now=now,
            expires_at=now + timedelta(minutes=30),
            voice_fallback_at=now + timedelta(seconds=90),
        )
        job = (
            await safety.claim_due_deliveries(
                worker_id="erase-race-worker",
                now=now,
                lease_until=now + timedelta(seconds=30),
                limit=1,
            )
        )[0]
        permit_started = asyncio.Event()
        release_permit = asyncio.Event()

        async def hold_provider_permit() -> None:
            async with safety.paging_submission_permit(
                job_kind="delivery",
                job_id=str(job["delivery_id"]),
                attempt_id=str(job["attempt_id"]),
                worker_id="erase-race-worker",
            ) as permitted:
                assert permitted is True
                permit_started.set()
                await release_permit.wait()

        permit_task = asyncio.create_task(hold_provider_permit())
        await asyncio.wait_for(permit_started.wait(), timeout=1)
        delete_task = asyncio.create_task(safety.delete_profile(profile_id))
        await _wait_for_lock_waiters(repository._require_pool(), minimum=1)
        assert delete_task.done() is False

        release_permit.set()
        await asyncio.wait_for(permit_task, timeout=1)
        deleted = await asyncio.wait_for(delete_task, timeout=1)
        assert deleted["profiles"] == 1
        async with safety.paging_submission_permit(
            job_kind="delivery",
            job_id=str(job["delivery_id"]),
            attempt_id=str(job["attempt_id"]),
            worker_id="erase-race-worker",
        ) as permitted:
            assert permitted is False
    finally:
        try:
            await safety.delete_profile(profile_id)
        except Exception:
            pass
        if original_control is not None:
            current = await safety.paging_control()
            if bool(current["enabled"]) != bool(original_control["enabled"]):
                await safety.set_paging_control(
                    enabled=bool(original_control["enabled"]),
                    reason="PostgreSQL erase race integration test cleanup",
                    expected_revision=int(current["revision"]),
                    now=datetime.now(UTC),
                )
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_safety_control_heartbeat_and_monitoring() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    safety = PostgresSafetyRepository(repository)
    worker_prefix = f"integration-{uuid4()}"
    now = datetime.now(UTC)

    await repository.startup()
    try:
        control = await safety.paging_control()
        await safety.set_paging_control(
            enabled=True,
            reason="PostgreSQL integration test setup",
            expected_revision=int(control["revision"]),
            now=now,
        )
        await safety.record_worker_heartbeat(
            worker_id=f"{worker_prefix}-active",
            now=now,
        )
        await safety.record_worker_heartbeat(
            worker_id=f"{worker_prefix}-stale",
            now=now - timedelta(seconds=90),
        )
        await repository._require_pool().execute(
            """
            UPDATE safety_worker_heartbeats
            SET started_at = $2, last_seen_at = $2
            WHERE worker_id = $1
            """,
            f"{worker_prefix}-stale",
            now - timedelta(seconds=90),
        )

        snapshot = await safety.monitoring_snapshot(
            now=now,
            worker_cutoff=now - timedelta(seconds=30),
        )

        assert snapshot["paging_control"]["enabled"] is True
        assert snapshot["workers"]["active"] >= 1
        assert snapshot["workers"]["stale"] >= 1
        assert snapshot["workers"]["oldest_heartbeat_age_seconds"] >= 90
    finally:
        if repository._pool is not None:
            pool = repository._require_pool()
            await pool.execute(
                "DELETE FROM safety_worker_heartbeats WHERE worker_id LIKE $1",
                f"{worker_prefix}%",
            )
            await safety.set_paging_control(
                enabled=True,
                reason="PostgreSQL integration test cleanup",
                expected_revision=int((await safety.paging_control())["revision"]),
                now=datetime.now(UTC),
            )
        await repository.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for TimescaleDB integration tests",
)
@pytest.mark.asyncio
async def test_postgres_safety_recovers_an_exhausted_final_lease() -> None:
    repository = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
    )
    safety = PostgresSafetyRepository(repository)
    profile_id = str(uuid4())
    dispatch_id = str(uuid4())
    now = datetime.now(UTC)

    await repository.startup()
    try:
        await safety.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Lease recovery test",
            installation_id=str(uuid4()),
            token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
        )
        for index in range(2):
            invite_hash = hashlib.sha256(f"pg-invite-{uuid4()}".encode()).hexdigest()
            await safety.create_contact(
                contact_id=str(uuid4()),
                profile_id=profile_id,
                display_name=f"Contact {index}",
                phone_e164=f"+1415555020{index}",
                invite_token_hash=invite_hash,
                invited_at=now,
                invite_expires_at=now + timedelta(hours=1),
            )
            await safety.decide_invitation(
                invite_token_hash=invite_hash,
                decision="accept",
                now=now,
            )
        await safety.create_dispatch(
            dispatch_id=dispatch_id,
            profile_id=profile_id,
            idempotency_key=str(uuid4()),
            request_hash=hashlib.sha256(b"manual_sos").hexdigest(),
            trigger="manual_sos",
            now=now,
            expires_at=now + timedelta(minutes=30),
            voice_fallback_at=now + timedelta(minutes=5),
        )
        jobs = await safety.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=1),
            limit=2,
        )
        target = jobs[0]
        pool = repository._require_pool()
        await pool.execute(
            """
            UPDATE safety_deliveries
            SET max_attempts = 1
            WHERE delivery_id = $1
            """,
            target["delivery_id"],
        )

        recovered_at = now + timedelta(seconds=2)
        await safety.claim_due_deliveries(
            worker_id="worker-b",
            now=recovered_at,
            lease_until=recovered_at + timedelta(seconds=1),
            limit=10,
        )

        incident = await safety.dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
        )
        delivery = next(
            row
            for row in incident["deliveries"]
            if str(row["delivery_id"]) == str(target["delivery_id"])
        )
        assert delivery["status"] == "failed"
        assert delivery["error"] == "delivery retry limit reached"
        attempt_status = await pool.fetchval(
            """
            SELECT status
            FROM safety_delivery_attempts
            WHERE attempt_id = $1
            """,
            target["attempt_id"],
        )
        assert attempt_status == "unknown"
        voice = next(
            row
            for row in incident["deliveries"]
            if str(row["contact_id"]) == str(target["contact_id"])
            and row["channel"] == "voice"
        )
        assert voice["available_at"] == recovered_at
    finally:
        if repository._pool is not None:
            pool = repository._require_pool()
            await pool.execute(
                "DELETE FROM safety_dispatches WHERE profile_id = $1",
                UUID(profile_id),
            )
            await pool.execute(
                "DELETE FROM safety_contacts WHERE profile_id = $1",
                UUID(profile_id),
            )
            await pool.execute(
                "DELETE FROM safety_profiles WHERE profile_id = $1",
                UUID(profile_id),
            )
        await repository.shutdown()


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
        assert await repository.ready() is True
        await repository.delete_device(raw.source.device_id)
        await repository.delete_device(official.source.device_id)
        pool = repository._require_pool()
        await pool.execute(
            "DELETE FROM sync_batch_tombstones WHERE batch_id = ANY($1::uuid[])",
            [raw.batch_id, official.batch_id],
        )

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

        async with pool.acquire() as connection:
            migration_count = await connection.fetchval(
                "SELECT count(*) FROM noop_schema_migrations"
            )
            assert migration_count == len(list(MIGRATIONS.glob("*.sql")))
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

        async with pool.acquire() as lock_connection:
            await lock_connection.execute(
                "SELECT pg_advisory_lock(hashtextextended($1, 0))",
                "noop-retention",
            )
            retention_task = asyncio.create_task(
                repository.purge_before(
                    datetime(1970, 1, 2, tzinfo=UTC),
                    replay_guard_until=datetime.now(UTC) + timedelta(days=30),
                )
            )
            await asyncio.sleep(0.05)
            try:
                assert retention_task.done() is False
            finally:
                await lock_connection.execute(
                    "SELECT pg_advisory_unlock(hashtextextended($1, 0))",
                    "noop-retention",
                )
            await asyncio.wait_for(retention_task, timeout=5)

        await repository.delete_device(
            raw.source.device_id,
            datetime.now(UTC) + timedelta(days=30),
        )
        with pytest.raises(SyncRetiredError):
            await repository.sync(raw, _payload_hash(raw))
    finally:
        if repository._pool is not None:
            await repository._pool.execute(
                "DELETE FROM sync_batch_tombstones WHERE batch_id = ANY($1::uuid[])",
                [raw.batch_id, official.batch_id],
            )
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

        with pytest.raises(FriendForbiddenError):
            await repository.delete_friend_enrollment_data(
                bob_enrollment,
                hashlib.sha256(b"wrong-member-token").hexdigest(),
            )
        await repository.disable_friend_profile(bob_id)
        enrollment_deleted = await repository.delete_friend_enrollment_data(
            bob_enrollment,
            bob_token_hash,
        )
        assert enrollment_deleted["friend_profiles"] == 1
        assert (
            await repository.delete_friend_enrollment_data(
                bob_enrollment,
                bob_token_hash,
            )
            == {}
        )
    finally:
        pool = repository._require_pool()
        await pool.execute(
            "DELETE FROM friend_profiles WHERE profile_id = ANY($1::uuid[])",
            [UUID(alice_id), UUID(bob_id)],
        )
        await repository.shutdown()
