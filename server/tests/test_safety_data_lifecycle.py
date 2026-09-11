from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.repository import ExportLimitExceededError, MemoryRepository
from app.safety_repository import (
    MemorySafetyRepository,
    SafetyConflictError,
)

ADMIN_TOKEN = "lifecycle-admin-token-abcdefghijklmnopqrstuvwxyz"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


async def _profile_with_contacts(
    repository: MemorySafetyRepository,
    *,
    now: datetime,
    installation_id: str | None = None,
) -> tuple[str, str, list[str]]:
    profile_id = str(uuid4())
    token_hash = _digest(str(uuid4()))
    await repository.create_profile(
        profile_id=profile_id,
        enrollment_id=str(uuid4()),
        display_name="Jordan",
        installation_id=installation_id or str(uuid4()),
        token_hash=token_hash,
    )
    contact_ids = []
    for index in range(2):
        contact_id = str(uuid4())
        invite_hash = _digest(f"invite-{uuid4()}")
        await repository.create_contact(
            contact_id=contact_id,
            profile_id=profile_id,
            display_name=f"Contact {index}",
            phone_e164=f"+1415555040{index}",
            invite_token_hash=invite_hash,
            invited_at=now,
            invite_expires_at=now + timedelta(days=7),
        )
        await repository.decide_invitation(
            invite_token_hash=invite_hash,
            decision="accept",
            now=now,
        )
        contact_ids.append(contact_id)
    return profile_id, token_hash, contact_ids


async def _incident_with_location(
    repository: MemorySafetyRepository,
    *,
    now: datetime,
    expires_at: datetime | None = None,
) -> tuple[str, str, list[str]]:
    profile_id, _, contact_ids = await _profile_with_contacts(
        repository,
        now=now,
    )
    dispatch_id = str(uuid4())
    await repository.create_dispatch(
        dispatch_id=dispatch_id,
        profile_id=profile_id,
        idempotency_key=str(uuid4()),
        request_hash=_digest(f"manual_sos-{dispatch_id}"),
        trigger="manual_sos",
        now=now,
        expires_at=expires_at or now + timedelta(minutes=30),
        voice_fallback_at=now + timedelta(seconds=90),
    )
    await repository.update_incident_location(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        sequence=1,
        latitude=37.7749,
        longitude=-122.4194,
        horizontal_accuracy_meters=12,
        captured_at=now,
        received_at=now,
    )
    return profile_id, dispatch_id, contact_ids


async def _assert_terminal_location_deleted(
    repository: MemorySafetyRepository,
    *,
    profile_id: str,
    dispatch_id: str,
    status: str,
) -> None:
    incident = await repository.dispatch(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
    )
    exported = await repository.export_profile(profile_id)
    exported_incident = next(
        row for row in exported["incidents"] if row["dispatch_id"] == dispatch_id
    )

    assert incident["status"] == status
    assert incident["latest_location"] is None
    assert dispatch_id not in repository._locations
    assert exported_incident["status"] == status
    assert exported_incident["latest_location"] is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("action", "status"),
    [("resolve", "resolved"), ("cancel", "cancelled")],
)
async def test_owner_terminal_transitions_delete_precise_location(
    action: str,
    status: str,
) -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, _ = await _incident_with_location(
        repository,
        now=now,
    )

    transitioned = await repository.transition_dispatch(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        action=action,
        note="owner completed incident",
        now=now + timedelta(minutes=1),
    )

    assert transitioned["latest_location"] is None
    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status=status,
    )


@pytest.mark.asyncio
async def test_expiry_sweep_deletes_precise_location() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, _ = await _incident_with_location(
        repository,
        now=now,
        expires_at=now + timedelta(minutes=5),
    )

    assert await repository.expire_due_dispatches(now=now + timedelta(minutes=5)) == 1

    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="expired",
    )


@pytest.mark.asyncio
async def test_elapsed_responder_action_deletes_precise_location() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, contact_ids = await _incident_with_location(
        repository,
        now=now,
        expires_at=now + timedelta(minutes=5),
    )

    with pytest.raises(SafetyConflictError, match="no longer accepting responses"):
        await repository.record_responder_decision(
            dispatch_id=dispatch_id,
            contact_id=contact_ids[0],
            decision="responding",
            source="sms_link",
            now=now + timedelta(minutes=5),
        )

    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="expired",
    )


@pytest.mark.asyncio
async def test_elapsed_responder_preview_persists_expiry_and_deletes_location() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, contact_ids = await _incident_with_location(
        repository,
        now=now,
        expires_at=now + timedelta(minutes=5),
    )

    preview = await repository.responder_preview(
        dispatch_id=dispatch_id,
        contact_id=contact_ids[0],
        now=now + timedelta(minutes=5),
    )

    assert preview is not None
    assert preview["status"] == "expired"
    assert preview["latest_location"] is None
    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="expired",
    )


@pytest.mark.asyncio
async def test_new_incident_preflight_deletes_elapsed_incident_location() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, _ = await _incident_with_location(
        repository,
        now=now,
        expires_at=now + timedelta(minutes=5),
    )

    await repository.create_dispatch(
        dispatch_id=str(uuid4()),
        profile_id=profile_id,
        idempotency_key=str(uuid4()),
        request_hash=_digest("replacement-manual-sos"),
        trigger="manual_sos",
        now=now + timedelta(minutes=5),
        expires_at=now + timedelta(minutes=35),
        voice_fallback_at=now + timedelta(minutes=6),
    )

    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="expired",
    )


@pytest.mark.asyncio
async def test_all_delivery_failures_delete_precise_location() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, _ = await _incident_with_location(
        repository,
        now=now,
    )
    for delivery in repository._deliveries.values():
        if delivery["dispatch_id"] == dispatch_id:
            delivery["max_attempts"] = 1

    sms_jobs = await repository.claim_due_deliveries(
        worker_id="worker-sms",
        now=now,
        lease_until=now + timedelta(seconds=30),
        limit=10,
    )
    assert len(sms_jobs) == 2
    for job in sms_jobs:
        await repository.complete_delivery_attempt(
            delivery_id=job["delivery_id"],
            attempt_id=job["attempt_id"],
            worker_id="worker-sms",
            submission_status="failed",
            provider_reference=None,
            error="provider rejected delivery",
            now=now + timedelta(seconds=1),
            retry_at=now + timedelta(seconds=2),
        )

    voice_jobs = await repository.claim_due_deliveries(
        worker_id="worker-voice",
        now=now + timedelta(seconds=2),
        lease_until=now + timedelta(seconds=32),
        limit=10,
    )
    assert len(voice_jobs) == 2
    for job in voice_jobs:
        await repository.complete_delivery_attempt(
            delivery_id=job["delivery_id"],
            attempt_id=job["attempt_id"],
            worker_id="worker-voice",
            submission_status="failed",
            provider_reference=None,
            error="provider rejected delivery",
            now=now + timedelta(seconds=3),
            retry_at=now + timedelta(seconds=4),
        )

    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="failed",
    )


@pytest.mark.asyncio
async def test_idempotent_terminal_replay_removes_legacy_coordinate() -> None:
    repository = MemorySafetyRepository()
    now = datetime(2026, 9, 11, 12, 0, tzinfo=UTC)
    profile_id, dispatch_id, _ = await _incident_with_location(
        repository,
        now=now,
    )
    await repository.transition_dispatch(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        action="resolve",
        note=None,
        now=now + timedelta(minutes=1),
    )
    repository._locations[dispatch_id] = {
        "sequence": 2,
        "latitude": 37.775,
        "longitude": -122.419,
        "horizontal_accuracy_meters": 10,
        "captured_at": now + timedelta(seconds=1),
        "received_at": now + timedelta(seconds=1),
    }

    exported = await repository.export_profile(profile_id)
    assert exported["incidents"][0]["latest_location"] is None
    replay = await repository.transition_dispatch(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        action="resolve",
        note=None,
        now=now + timedelta(minutes=2),
    )

    assert replay["idempotent_replay"] is True
    await _assert_terminal_location_deleted(
        repository,
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        status="resolved",
    )


@pytest.mark.asyncio
async def test_safety_token_rotation_is_versioned_retry_safe_and_private() -> None:
    repository = MemorySafetyRepository()
    now = datetime.now(UTC)
    profile_id, old_hash, _ = await _profile_with_contacts(
        repository,
        now=now,
    )
    rotation_id = str(uuid4())
    new_hash = _digest("replacement")

    rotated = await repository.rotate_profile_token(
        profile_id=profile_id,
        rotation_id=rotation_id,
        expected_version=1,
        token_hash=new_hash,
        now=now + timedelta(minutes=1),
    )
    replay = await repository.rotate_profile_token(
        profile_id=profile_id,
        rotation_id=rotation_id,
        expected_version=1,
        token_hash=new_hash,
        now=now + timedelta(minutes=2),
    )

    assert rotated == replay
    assert rotated["token_version"] == 2
    assert "token_hash" not in rotated
    assert "last_rotation_token_hash" not in rotated
    assert await repository.profile_for_token(old_hash) is None
    assert await repository.profile_for_token(new_hash) == rotated
    with pytest.raises(SafetyConflictError):
        await repository.rotate_profile_token(
            profile_id=profile_id,
            rotation_id=str(uuid4()),
            expected_version=1,
            token_hash=_digest("another"),
            now=now,
        )


@pytest.mark.asyncio
async def test_safety_export_and_hard_delete_cover_profile_data_without_secrets() -> (
    None
):
    repository = MemorySafetyRepository()
    now = datetime.now(UTC)
    profile_id, token_hash, _ = await _profile_with_contacts(
        repository,
        now=now,
    )
    dispatch_id = str(uuid4())
    await repository.create_dispatch(
        dispatch_id=dispatch_id,
        profile_id=profile_id,
        idempotency_key=str(uuid4()),
        request_hash=_digest("manual_sos"),
        trigger="manual_sos",
        now=now,
        expires_at=now + timedelta(minutes=30),
        voice_fallback_at=now + timedelta(seconds=90),
    )
    await repository.update_incident_location(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        sequence=1,
        latitude=37.7749,
        longitude=-122.4194,
        horizontal_accuracy_meters=12,
        captured_at=now,
        received_at=now,
    )

    exported = await repository.export_profile(profile_id)
    encoded = str(exported)

    assert exported["schema_version"] == 1
    assert len(exported["contacts"]) == 2
    assert len(exported["incidents"]) == 1
    assert exported["incidents"][0]["latest_location"]["sequence"] == 1
    assert token_hash not in encoded
    assert "invite_token_hash" not in encoded
    assert "last_rotation_token_hash" not in encoded
    counts = await repository.delete_profile(profile_id)
    assert counts["profiles"] == 1
    assert counts["contacts"] == 2
    assert counts["incidents"] == 1
    assert counts["deliveries"] == 4
    assert counts["locations"] == 1
    assert await repository.profile_for_token(token_hash) is None


@pytest.mark.asyncio
async def test_safety_export_is_bounded_and_can_be_windowed() -> None:
    repository = MemorySafetyRepository()
    now = datetime.now(UTC)
    profile_id, _, _ = await _profile_with_contacts(repository, now=now)

    with pytest.raises(ExportLimitExceededError, match="start/end"):
        await repository.export_profile(profile_id, max_rows=2)

    bounded = await repository.export_profile(
        profile_id,
        start=now + timedelta(seconds=1),
        max_rows=2,
    )

    assert bounded["row_count"] == 1
    assert bounded["contacts"] == []
    assert bounded["incidents"] == []


@pytest.mark.asyncio
async def test_safety_retention_is_terminal_bounded_and_preserves_replay_guard() -> (
    None
):
    repository = MemorySafetyRepository()
    old = datetime.now(UTC) - timedelta(days=60)
    profile_id, _, _ = await _profile_with_contacts(repository, now=old)
    stale_contact_id = str(uuid4())
    await repository.create_contact(
        contact_id=stale_contact_id,
        profile_id=profile_id,
        display_name="Expired invite",
        phone_e164="+14155550499",
        invite_token_hash=_digest("expired-invite"),
        invited_at=old,
        invite_expires_at=old + timedelta(days=7),
    )
    idempotency_key = str(uuid4())
    request_hash = _digest("manual_sos")
    dispatch_id = str(uuid4())
    await repository.create_dispatch(
        dispatch_id=dispatch_id,
        profile_id=profile_id,
        idempotency_key=idempotency_key,
        request_hash=request_hash,
        trigger="manual_sos",
        now=old,
        expires_at=old + timedelta(minutes=30),
        voice_fallback_at=old + timedelta(seconds=90),
    )
    await repository.transition_dispatch(
        profile_id=profile_id,
        dispatch_id=dispatch_id,
        action="resolve",
        note=None,
        now=old + timedelta(minutes=1),
    )
    now = datetime.now(UTC)

    counts = await repository.purge_retained_data(
        incident_cutoff=now - timedelta(days=30),
        contact_cutoff=now - timedelta(days=30),
        replay_guard_until=now + timedelta(days=30),
        now=now,
        limit=10,
    )

    assert counts == {"incidents": 1, "contacts": 1, "tombstones": 0}
    assert len(await repository.list_contacts(profile_id)) == 2
    with pytest.raises(SafetyConflictError, match="retired"):
        await repository.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            trigger="manual_sos",
            now=now,
            expires_at=now + timedelta(minutes=30),
            voice_fallback_at=now + timedelta(seconds=90),
        )


def test_safety_self_service_rotation_export_and_erasure_routes() -> None:
    safety = MemorySafetyRepository()
    app = create_app(
        settings=Settings(
            api_token=ADMIN_TOKEN,
            database_url=None,
            safety_incident_retention_days=None,
            safety_contact_retention_days=None,
        ),
        repository=MemoryRepository(),
        safety_repository=safety,
    )
    old_token = "noop_safety_" + "a" * 43
    new_token = "noop_safety_" + "b" * 43
    with TestClient(app) as client:
        enrolled = client.post(
            "/v1/safety/bootstrap",
            headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
            json={
                "display_name": "Jordan",
                "installation_id": str(uuid4()),
                "enrollment_id": str(uuid4()),
                "safety_token": old_token,
            },
        )
        assert enrolled.status_code == 201, enrolled.text
        rotation = {
            "rotation_id": str(uuid4()),
            "expected_version": 1,
            "safety_token": new_token,
        }
        rotated = client.put(
            "/v1/safety/me/token",
            headers={"Authorization": f"Bearer {old_token}"},
            json=rotation,
        )
        replay = client.put(
            "/v1/safety/me/token",
            headers={"Authorization": f"Bearer {new_token}"},
            json=rotation,
        )

        assert rotated.status_code == 200, rotated.text
        assert replay.json() == rotated.json()
        assert (
            client.get(
                "/v1/safety/me",
                headers={"Authorization": f"Bearer {old_token}"},
            ).status_code
            == 401
        )
        exported = client.get(
            "/v1/safety/me/export",
            headers={"Authorization": f"Bearer {new_token}"},
        )
        assert exported.status_code == 200
        assert old_token not in exported.text
        assert new_token not in exported.text
        assert "attachment;" in exported.headers["content-disposition"]
        missing_confirmation = client.delete(
            "/v1/safety/me",
            headers={"Authorization": f"Bearer {new_token}"},
        )
        deleted = client.delete(
            "/v1/safety/me",
            headers={
                "Authorization": f"Bearer {new_token}",
                "X-Noop-Confirm": "DELETE MY SAFETY PROFILE",
            },
        )
        assert missing_confirmation.status_code == 412
        assert deleted.status_code == 200
        assert deleted.json()["counts"]["profiles"] == 1
        assert (
            client.get(
                "/v1/safety/me",
                headers={"Authorization": f"Bearer {new_token}"},
            ).status_code
            == 401
        )
