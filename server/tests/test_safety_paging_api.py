from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode, urlparse
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import (
    _safety_dispatch_response,
    _safety_page_request_hashes,
    create_app,
)
from app.models import SafetyPageCreate
from app.paging import (
    PagingOutcomeUnknownError,
    PagingSubmission,
    PagingUnavailableError,
)
from app.repository import MemoryRepository
from app.safety_capabilities import SafetyCapabilitySigner
from app.safety_repository import MemorySafetyRepository, SafetyConflictError
from app.safety_worker import SafetyDeliveryWorker


TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"
PUBLIC_BASE_URL = "https://safety.example.test"
TWILIO_AUTH_TOKEN = "twilio-auth-token-for-signed-callback-tests"
TWILIO_CALLBACK_SECRET = "callback-secret-abcdefghijklmnopqrstuvwxyz"


@dataclass
class SentMessage:
    channel: str
    phone: str
    body_marker: str
    response_url: str


class FakePagingProvider:
    available = True

    def __init__(
        self,
        *,
        fail_first_sms: bool = False,
        fail_first_sms_status: bool = False,
    ) -> None:
        self.invitations: list[tuple[str, str]] = []
        self.pages: list[SentMessage] = []
        self.fail_first_sms = fail_first_sms
        self.fail_first_sms_status = fail_first_sms_status
        self.sms_attempts = 0

    async def send_invitation(
        self,
        *,
        to_phone: str,
        contact_name: str,
        owner_name: str,
        acceptance_url: str,
    ) -> PagingSubmission:
        assert contact_name
        assert owner_name
        self.invitations.append((to_phone, acceptance_url))
        return PagingSubmission(
            provider_reference=f"SM{len(self.invitations):032d}",
            status="queued",
        )

    async def send_page_sms(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission:
        assert incident_summary
        self.sms_attempts += 1
        if self.fail_first_sms and self.sms_attempts == 1:
            raise PagingUnavailableError("temporary provider failure")
        self.pages.append(SentMessage("sms", to_phone, owner_name, response_url))
        return PagingSubmission(
            provider_reference=f"SMpage{len(self.pages):026d}",
            status=(
                "failed"
                if self.fail_first_sms_status and self.sms_attempts == 1
                else "queued"
            ),
        )

    async def send_page_voice(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission:
        assert incident_summary
        self.pages.append(SentMessage("voice", to_phone, owner_name, response_url))
        return PagingSubmission(
            provider_reference=f"CApage{len(self.pages):026d}",
            status="queued",
        )


def _client(
    provider: FakePagingProvider,
    *,
    acknowledgement_timeout_seconds: int = 2,
    retry_base_seconds: int = 1,
    signed_callbacks: bool = False,
    worker_enabled: bool = True,
    escalation_rounds: int = 1,
    escalation_interval_seconds: int = 15 * 60,
    automatic_paging_enabled: bool = False,
    approved_fall_detectors: frozenset[str] = frozenset(),
    incident_ttl_seconds: int = 12 * 60 * 60,
) -> tuple[TestClient, MemorySafetyRepository]:
    safety = MemorySafetyRepository()
    callback_settings = (
        {
            "public_base_url": PUBLIC_BASE_URL,
            "twilio_account_sid": f"AC{'1' * 32}",
            "twilio_auth_token": TWILIO_AUTH_TOKEN,
            "twilio_from_phone": "+14155550100",
            "twilio_status_callback_secret": TWILIO_CALLBACK_SECRET,
            "safety_capability_secret": "capability-secret-abcdefghijklmnopqrstuvwxyz",
        }
        if signed_callbacks
        else {}
    )
    app = create_app(
        settings=Settings(
            api_token=TOKEN,
            database_url=None,
            max_request_bytes=1_000_000,
            safety_acknowledgement_timeout_seconds=(acknowledgement_timeout_seconds),
            safety_escalation_rounds=escalation_rounds,
            safety_escalation_interval_seconds=escalation_interval_seconds,
            safety_automatic_paging_enabled=automatic_paging_enabled,
            safety_approved_fall_detectors=approved_fall_detectors,
            safety_incident_ttl_seconds=incident_ttl_seconds,
            safety_retry_base_seconds=retry_base_seconds,
            safety_worker_poll_seconds=1,
            safety_worker_enabled=worker_enabled,
            **callback_settings,
        ),
        repository=MemoryRepository(),
        safety_repository=safety,
        paging_provider=provider,
    )
    return TestClient(
        app,
        base_url=PUBLIC_BASE_URL if signed_callbacks else "http://testserver",
    ), safety


def _twilio_signature(url: str, values: dict[str, str]) -> str:
    signed = url + "".join(
        name + value for name in sorted(values) for value in sorted({values[name]})
    )
    digest = hmac.new(
        TWILIO_AUTH_TOKEN.encode(),
        signed.encode(),
        hashlib.sha1,
    ).digest()
    return base64.b64encode(digest).decode()


def _bootstrap(client: TestClient) -> tuple[dict, dict[str, str], str]:
    safety_token = f"noop_safety_{'s' * 43}"
    response = client.post(
        "/v1/safety/bootstrap",
        headers={"Authorization": f"Bearer {TOKEN}"},
        json={
            "display_name": "Jordan",
            "installation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "enrollment_id": str(uuid4()),
            "safety_token": safety_token,
        },
    )
    assert response.status_code == 201, response.text
    return (
        response.json()["profile"],
        {"Authorization": f"Bearer {safety_token}"},
        safety_token,
    )


def _accept_latest(
    client: TestClient,
    provider: FakePagingProvider,
    *,
    expected_count: int | None = None,
) -> None:
    _wait_until(
        lambda: len(provider.invitations) >= (expected_count or 1),
    )
    acceptance_url = provider.invitations[-1][1]
    path = urlparse(acceptance_url).path
    response = client.post(
        path,
        content="decision=accept",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert response.status_code == 200, response.text
    assert "response saved" in response.text


def _wait_until(
    predicate,
    *,
    timeout: float = 4.0,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    assert predicate()


def _ready_contacts(
    client: TestClient,
    provider: FakePagingProvider,
    headers: dict[str, str],
) -> None:
    for name, phone in (
        ("Alex", "+14155550101"),
        ("Morgan", "+14155550102"),
    ):
        expected_invitation_count = len(provider.invitations) + 1
        created = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": name, "phone_e164": phone},
        )
        assert created.status_code == 201, created.text
        _accept_latest(
            client,
            provider,
            expected_count=expected_invitation_count,
        )


async def _ready_memory_dispatch(
    repository: MemorySafetyRepository,
    *,
    now: datetime,
) -> tuple[str, str]:
    profile_id = str(uuid4())
    await repository.create_profile(
        profile_id=profile_id,
        enrollment_id=str(uuid4()),
        display_name="Jordan",
        installation_id=str(uuid4()),
        token_hash=hashlib.sha256(uuid4().bytes).hexdigest(),
    )
    for index in range(2):
        invite_hash = hashlib.sha256(f"invite-{uuid4()}".encode()).hexdigest()
        await repository.create_contact(
            contact_id=str(uuid4()),
            profile_id=profile_id,
            display_name=f"Contact {index}",
            phone_e164=f"+1415555030{index}",
            invite_token_hash=invite_hash,
            invited_at=now,
            invite_expires_at=now + timedelta(hours=1),
        )
        await repository.decide_invitation(
            invite_token_hash=invite_hash,
            decision="accept",
            now=now,
        )
    dispatch_id = str(uuid4())
    await repository.create_dispatch(
        dispatch_id=dispatch_id,
        profile_id=profile_id,
        idempotency_key=str(uuid4()),
        request_hash=hashlib.sha256(b"manual_sos").hexdigest(),
        trigger="manual_sos",
        now=now,
        expires_at=now + timedelta(minutes=30),
        voice_fallback_at=now + timedelta(minutes=5),
    )
    return profile_id, dispatch_id


def test_elapsed_acknowledged_page_does_not_block_a_new_sos() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime(2026, 8, 25, 12, 0, tzinfo=UTC)
        profile_id, dispatch_id = await _ready_memory_dispatch(
            repository,
            now=now,
        )
        first_delivery = next(
            row
            for row in repository._deliveries.values()
            if row["dispatch_id"] == dispatch_id
        )
        acknowledged = await repository.record_responder_decision(
            dispatch_id=dispatch_id,
            contact_id=first_delivery["contact_id"],
            decision="responding",
            source="sms_link",
            now=now + timedelta(minutes=1),
        )
        assert acknowledged["status"] == "acknowledged"

        elapsed_at = now + timedelta(minutes=31)
        preview = await repository.responder_preview(
            dispatch_id=dispatch_id,
            contact_id=first_delivery["contact_id"],
            now=elapsed_at,
        )
        monitoring = await repository.monitoring_snapshot(now=elapsed_at)
        assert preview is not None
        assert preview["status"] == "expired"
        assert monitoring["incidents"]["overdue"] == 0
        assert repository._dispatches[dispatch_id]["status"] == "expired"

        next_page = await repository.create_dispatch(
            dispatch_id=str(uuid4()),
            profile_id=profile_id,
            idempotency_key=str(uuid4()),
            request_hash=hashlib.sha256(b"next-manual-sos").hexdigest(),
            trigger="manual_sos",
            now=elapsed_at,
            expires_at=elapsed_at + timedelta(hours=8),
            voice_fallback_at=elapsed_at + timedelta(seconds=90),
        )
        assert repository._dispatches[dispatch_id]["status"] == "expired"
        assert next_page["status"] == "open"

    asyncio.run(exercise())


def test_contacts_require_acceptance_and_page_is_sms_first_and_idempotent() -> None:
    provider = FakePagingProvider()
    client, safety = _client(provider)
    with client:
        profile, headers, plaintext_token = _bootstrap(client)
        assert profile["paging_enabled"] is True
        assert plaintext_token not in safety._profile_tokens

        _ready_contacts(client, provider, headers)

        contacts = client.get("/v1/safety/contacts", headers=headers)
        assert contacts.status_code == 200
        assert contacts.json()["accepted_count"] == 2
        assert contacts.json()["minimum_accepted"] == 2
        assert contacts.json()["maximum_contacts"] == 5

        key = str(uuid4())
        page = client.post(
            "/v1/safety/pages",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert page.status_code == 202, page.text
        assert page.json()["status"] == "open"
        assert len(page.json()["deliveries"]) == 4
        assert {row["channel"] for row in page.json()["deliveries"]} == {
            "sms",
            "voice",
        }
        assert all("phone_e164" not in row for row in page.json()["deliveries"])
        assert all("signature" not in str(row) for row in page.json()["deliveries"])
        _wait_until(lambda: len(provider.pages) == 2)
        assert {sent.channel for sent in provider.pages} == {"sms"}
        assert all("/safety/respond/" in sent.response_url for sent in provider.pages)

        replay = client.post(
            "/v1/safety/pages",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert replay.status_code == 202
        assert replay.json()["idempotent_replay"] is True
        time.sleep(0.1)
        assert len(provider.pages) == 2


def test_contact_summary_counts_people_and_records_last_reach_time() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, signed_callbacks=True)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202, created.text
        assert created.json()["contact_summary"] == {
            "targeted": 2,
            "reached": 0,
            "pending": 2,
            "failed": 0,
            "last_reached_at": None,
            "all_contacts_failed": False,
        }
        _wait_until(lambda: len(provider.pages) == 2)

        path = f"/v1/safety/provider/twilio/status?token={TWILIO_CALLBACK_SECRET}"
        callback_url = f"{PUBLIC_BASE_URL}{path}"
        for index in range(1, 3):
            values = {
                "MessageSid": f"SMpage{index:026d}",
                "MessageStatus": "delivered",
            }
            receipt = client.post(
                path,
                content=urlencode(values),
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Twilio-Signature": _twilio_signature(
                        callback_url,
                        values,
                    ),
                },
            )
            assert receipt.status_code == 204

        incident = client.get(
            f"/v1/safety/incidents/{created.json()['dispatch_id']}",
            headers=headers,
        ).json()
        assert incident["contact_summary"]["targeted"] == 2
        assert incident["contact_summary"]["reached"] == 2
        assert incident["contact_summary"]["pending"] == 0
        assert incident["contact_summary"]["failed"] == 0
        assert incident["contact_summary"]["last_reached_at"] is not None
        assert incident["contact_summary"]["all_contacts_failed"] is False


def test_admin_kill_switch_blocks_new_pages_and_invitations() -> None:
    provider = FakePagingProvider()
    client, safety = _client(provider)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        admin = {
            "Authorization": f"Bearer {TOKEN}",
            "X-Noop-Operator": "paging-test",
        }

        missing_operator = client.put(
            "/v1/safety/operations/paging-control",
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={
                "enabled": False,
                "reason": "Carrier incident",
                "expected_revision": 1,
            },
        )
        assert missing_operator.status_code == 422

        missing_reason = client.put(
            "/v1/safety/operations/paging-control",
            headers=admin,
            json={"enabled": False, "expected_revision": 1},
        )
        assert missing_reason.status_code == 422

        disabled = client.put(
            "/v1/safety/operations/paging-control",
            headers=admin,
            json={
                "enabled": False,
                "reason": "Carrier incident",
                "expected_revision": 1,
            },
        )
        assert disabled.status_code == 200
        assert disabled.json()["enabled"] is False
        assert disabled.json()["revision"] == 2
        assert disabled.json()["request_id"]
        assert safety._paging_control_audit[-1]["actor"] == "paging-test"
        assert (
            safety._paging_control_audit[-1]["request_id"]
            == disabled.json()["request_id"]
        )

        contacts = client.get("/v1/safety/contacts", headers=headers)
        assert contacts.status_code == 200
        assert contacts.json()["paging_configured"] is True
        assert contacts.json()["paging_enabled"] is False
        profile = client.get("/v1/safety/me", headers=headers)
        assert profile.status_code == 200
        assert profile.json()["profile"]["paging_enabled"] is False

        blocked_invite = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": "Taylor", "phone_e164": "+14155550103"},
        )
        assert blocked_invite.status_code == 503
        blocked_page = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert blocked_page.status_code == 412
        assert "paused" in blocked_page.json()["detail"]

        operations = client.get("/v1/safety/operations", headers=admin).json()
        assert operations["paging_control"]["enabled"] is False
        assert operations["paging_control"]["reason"] == "Carrier incident"

        stale_enable = client.put(
            "/v1/safety/operations/paging-control",
            headers=admin,
            json={"enabled": True, "expected_revision": 1},
        )
        assert stale_enable.status_code == 409

        enabled = client.put(
            "/v1/safety/operations/paging-control",
            headers=admin,
            json={"enabled": True, "expected_revision": 2},
        )
        assert enabled.status_code == 200
        assert enabled.json()["enabled"] is True
        assert enabled.json()["revision"] == 3


def test_paused_paging_still_returns_an_idempotent_incident_replay() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        key = str(uuid4())
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202

        admin = {
            "Authorization": f"Bearer {TOKEN}",
            "X-Noop-Operator": "paging-test",
        }
        disabled = client.put(
            "/v1/safety/operations/paging-control",
            headers=admin,
            json={
                "enabled": False,
                "reason": "Carrier incident",
                "expected_revision": 1,
            },
        )
        assert disabled.status_code == 200

        replay = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert replay.status_code == 202
        assert replay.json()["dispatch_id"] == created.json()["dispatch_id"]
        assert replay.json()["idempotent_replay"] is True


def test_external_worker_heartbeat_gates_new_paging() -> None:
    provider = FakePagingProvider()
    client, safety = _client(provider, worker_enabled=False)
    now = datetime.now(UTC)
    asyncio.run(
        safety.record_worker_heartbeat(
            worker_id="external-worker",
            now=now,
        )
    )
    with client:
        _, headers, _ = _bootstrap(client)
        for index, name in enumerate(("Alex", "Morgan"), start=1):
            created = client.post(
                "/v1/safety/contacts",
                headers=headers,
                json={
                    "display_name": name,
                    "phone_e164": f"+1415555010{index}",
                },
            )
            assert created.status_code == 201, created.text
            client.portal.call(client.app.state.safety_worker.process_once)
            _accept_latest(
                client,
                provider,
                expected_count=index,
            )
        stale_at = now - timedelta(minutes=5)
        for heartbeat in safety._worker_heartbeats.values():
            heartbeat["last_seen_at"] = stale_at

        contacts = client.get("/v1/safety/contacts", headers=headers)
        assert contacts.status_code == 200
        assert contacts.json()["paging_enabled"] is False

        page = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert page.status_code == 412
        assert "unavailable" in page.json()["detail"]


def test_bootstrap_does_not_claim_paging_without_a_healthy_worker() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, worker_enabled=False)

    with client:
        profile, _, _ = _bootstrap(client)

    assert profile["paging_enabled"] is False


def test_signed_callbacks_have_a_separate_post_authentication_budget() -> None:
    provider = FakePagingProvider()
    client, _ = _client(
        provider,
        signed_callbacks=True,
        worker_enabled=False,
    )
    client.app.state.provider_callback_rate_limiter.limit = 1
    path = f"/v1/safety/provider/twilio/status?token={TWILIO_CALLBACK_SECRET}"
    callback_url = f"{PUBLIC_BASE_URL}{path}"
    values = {
        "MessageSid": "SMcallbackbudget00000000000000000",
        "MessageStatus": "delivered",
    }
    body = urlencode(values)
    signature = _twilio_signature(callback_url, values)
    content_type = {"Content-Type": "application/x-www-form-urlencoded"}

    with client:
        forged = client.post(
            path,
            content=body,
            headers={**content_type, "X-Twilio-Signature": "forged"},
        )
        accepted = client.post(
            path,
            content=body,
            headers={**content_type, "X-Twilio-Signature": signature},
        )
        limited = client.post(
            path,
            content=body,
            headers={**content_type, "X-Twilio-Signature": signature},
        )

    assert forged.status_code == 401
    assert accepted.status_code == 204
    assert limited.status_code == 429
    assert (
        limited.headers["x-noop-ratelimit-scope"] == "provider-callback-authenticated"
    )
    assert int(limited.headers["retry-after"]) >= 1


def test_recipient_acknowledgement_stops_voice_fallback_and_is_owner_visible() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=1)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202, created.text
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: len(provider.pages) == 2)

        response_url = provider.pages[0].response_url
        preview = client.get(response_url)
        assert preview.status_code == 200
        assert "I’m responding" in preview.text
        acknowledged = client.post(
            response_url,
            content="decision=responding",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert acknowledged.status_code == 200
        assert "response saved" in acknowledged.text

        time.sleep(1.3)
        assert len(provider.pages) == 2
        status_response = client.get(
            f"/v1/safety/incidents/{incident_id}",
            headers=headers,
        )
        assert status_response.status_code == 200
        status_payload = status_response.json()
        assert status_payload["status"] == "acknowledged"
        assert status_payload["acknowledged_contact_display_name"] in {
            "Alex",
            "Morgan",
        }
        assert status_payload["responses"][0]["decision"] == "responding"
        assert all(
            delivery["status"] != "pending"
            for delivery in status_payload["deliveries"]
            if delivery["channel"] == "voice"
        )


def test_band_page_uses_requested_lifetime_and_ack_cancels_future_rounds() -> None:
    provider = FakePagingProvider()
    client, safety = _client(
        provider,
        acknowledgement_timeout_seconds=1,
        escalation_rounds=3,
        escalation_interval_seconds=60,
    )
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "band_sos", "share_duration_hours": 12},
        )
        assert created.status_code == 202, created.text
        payload = created.json()
        assert payload["trigger"] == "band_sos"
        assert payload["share_duration_hours"] == 12
        assert payload["escalation_rounds"] == 3
        assert {row["escalation_round"] for row in payload["deliveries"]} == {
            0,
            1,
            2,
        }
        created_at = datetime.fromisoformat(
            payload["created_at"].replace("Z", "+00:00")
        )
        expires_at = datetime.fromisoformat(
            payload["expires_at"].replace("Z", "+00:00")
        )
        assert expires_at - created_at == timedelta(hours=12)

        _wait_until(lambda: len(provider.pages) == 2)
        response_url = provider.pages[0].response_url
        preview = client.get(response_url)
        assert "repeated SOS gesture on their Noop Band" in preview.text
        acknowledged = client.post(
            response_url,
            content="decision=responding",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert acknowledged.status_code == 200
        assert len(provider.pages) == 2

        incident = client.get(
            f"/v1/safety/incidents/{payload['dispatch_id']}",
            headers=headers,
        ).json()
        assert incident["status"] == "acknowledged"
        assert all(
            row["status"] not in {"pending", "retry_wait", "leased"}
            for row in incident["deliveries"]
        )

        async def expire_acknowledged_page() -> int:
            return await safety.expire_due_dispatches(
                now=expires_at + timedelta(seconds=1)
            )

        expired_count = client.portal.call(expire_acknowledged_page)
        assert expired_count == 1
        expired = client.get(
            f"/v1/safety/incidents/{payload['dispatch_id']}",
            headers=headers,
        )
        assert expired.status_code == 200
        assert expired.json()["status"] == "expired"


def test_unacknowledged_page_runs_bounded_follow_up_round() -> None:
    provider = FakePagingProvider()
    client, safety = _client(
        provider,
        acknowledgement_timeout_seconds=1,
        escalation_rounds=2,
        escalation_interval_seconds=60,
    )
    clock_offset = {"seconds": 0}

    async def coordination_now() -> datetime:
        return datetime.now(UTC) + timedelta(seconds=clock_offset["seconds"])

    safety.coordination_now = coordination_now  # type: ignore[method-assign]
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos", "share_duration_hours": 8},
        )
        assert created.status_code == 202
        _wait_until(lambda: len(provider.pages) == 4)
        clock_offset["seconds"] = 61
        _wait_until(lambda: len(provider.pages) == 8, timeout=5)
        assert [page.channel for page in provider.pages].count("sms") == 4
        assert [page.channel for page in provider.pages].count("voice") == 4


def test_unacknowledged_incident_uses_voice_fallback_and_owner_can_resolve() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=1)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: len(provider.pages) == 4)
        assert [sent.channel for sent in provider.pages].count("sms") == 2
        assert [sent.channel for sent in provider.pages].count("voice") == 2

        resolved = client.post(
            f"/v1/safety/incidents/{incident_id}/resolve",
            headers=headers,
            json={"note": "Reached by phone"},
        )
        assert resolved.status_code == 200, resolved.text
        assert resolved.json()["status"] == "resolved"
        assert resolved.json()["resolution_note"] == "Reached by phone"

        repeated = client.post(
            f"/v1/safety/incidents/{incident_id}/resolve",
            headers=headers,
            json={"note": "Reached by phone"},
        )
        assert repeated.status_code == 200
        assert repeated.json()["idempotent_replay"] is True


def test_cannot_respond_skips_that_contact_and_voice_dtmf_can_acknowledge() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=1)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: len(provider.pages) == 2)

        declined_phone = provider.pages[0].phone
        declined = client.post(
            provider.pages[0].response_url,
            content="decision=cannot_respond",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert declined.status_code == 200
        _wait_until(lambda: any(sent.channel == "voice" for sent in provider.pages))
        voice_pages = [sent for sent in provider.pages if sent.channel == "voice"]
        assert len(voice_pages) == 1
        assert voice_pages[0].phone != declined_phone

        dtmf = client.post(
            voice_pages[0].response_url,
            content="Digits=1",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert dtmf.status_code == 200
        assert "response is recorded" in dtmf.text
        incident = client.get(
            f"/v1/safety/incidents/{incident_id}",
            headers=headers,
        ).json()
        assert incident["status"] == "acknowledged"
        assert {row["decision"] for row in incident["responses"]} == {
            "cannot_respond",
            "responding",
        }
        assert {row["source"] for row in incident["responses"]} == {
            "sms_link",
            "voice_dtmf",
        }


def test_delivery_submission_failure_is_retried_durably() -> None:
    provider = FakePagingProvider(fail_first_sms=True)
    client, _ = _client(
        provider,
        acknowledgement_timeout_seconds=3,
        retry_base_seconds=1,
    )
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: provider.sms_attempts >= 3)

        status_payload = client.get(
            f"/v1/safety/incidents/{incident_id}",
            headers=headers,
        ).json()
        retried = [
            delivery
            for delivery in status_payload["deliveries"]
            if delivery["channel"] == "sms" and delivery["attempt_count"] == 2
        ]
        assert len(retried) == 1
        assert retried[0]["status"] in {"queued", "sent", "delivered"}


def test_immediate_provider_failure_status_is_retried_durably() -> None:
    provider = FakePagingProvider(fail_first_sms_status=True)
    client, _ = _client(
        provider,
        acknowledgement_timeout_seconds=3,
        retry_base_seconds=1,
    )
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: provider.sms_attempts >= 3)

        status_payload = client.get(
            f"/v1/safety/incidents/{incident_id}",
            headers=headers,
        ).json()
        retried = [
            delivery
            for delivery in status_payload["deliveries"]
            if delivery["channel"] == "sms" and delivery["attempt_count"] == 2
        ]
        assert len(retried) == 1
        assert retried[0]["status"] in {"queued", "sent", "delivered"}


def test_worker_releases_preleased_job_when_paging_is_disabled() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        await _ready_memory_dispatch(repository, now=now)
        jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=30),
            limit=2,
        )
        assert len(jobs) == 2
        target = jobs[0]
        await repository.set_paging_control(
            enabled=False,
            reason="Provider incident",
            expected_revision=1,
            now=now + timedelta(milliseconds=1),
        )
        provider = FakePagingProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=1,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
        )
        worker.worker_id = "worker-a"
        await worker._submit_delivery(target)

        released = repository._deliveries[target["delivery_id"]]
        assert released["status"] == "retry_wait"
        assert released["attempt_count"] == 0
        assert target["attempt_id"] not in repository._delivery_attempts
        assert provider.pages == []
        assert (
            await repository.claim_due_deliveries(
                worker_id="worker-b",
                now=now + timedelta(seconds=1),
                lease_until=now + timedelta(seconds=31),
                limit=10,
            )
            == []
        )

    asyncio.run(exercise())


def test_worker_claims_only_jobs_it_can_submit_concurrently() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        _, dispatch_id = await _ready_memory_dispatch(repository, now=now)
        provider = FakePagingProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=1,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
            batch_size=20,
            max_concurrency=1,
        )

        assert await worker.process_once() == 1
        assert len(provider.pages) == 1
        dispatch = repository._dispatches[dispatch_id]
        sms = [
            row
            for row in repository._deliveries.values()
            if row["dispatch_id"] == dispatch["dispatch_id"] and row["channel"] == "sms"
        ]
        assert sum(row["status"] == "queued" for row in sms) == 1
        assert sum(row["status"] == "pending" for row in sms) == 1

    asyncio.run(exercise())


def test_sender_slots_are_shared_and_rate_shaped_across_workers() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime(2026, 8, 24, 12, 0, tzinfo=UTC)

        worker_a_delay = await repository.reserve_provider_submission_slot(
            now=now,
            requests_per_second=5,
        )
        worker_b_delay = await repository.reserve_provider_submission_slot(
            now=now,
            requests_per_second=5,
        )
        worker_a_next_delay = await repository.reserve_provider_submission_slot(
            now=now,
            requests_per_second=5,
        )

        assert worker_a_delay == 0
        assert worker_b_delay == pytest.approx(0.2)
        assert worker_a_next_delay == pytest.approx(0.4)

    asyncio.run(exercise())


def test_stale_receipt_cleanup_honours_the_shared_batch_limit() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        await _ready_memory_dispatch(repository, now=now)
        stale_at = now - timedelta(minutes=10)
        for index, delivery in enumerate(repository._deliveries.values()):
            delivery.update(
                {
                    "status": "queued",
                    "provider_reference": f"SMstale{index:026d}",
                    "updated_at": stale_at,
                }
            )

        changed = await repository.mark_stale_provider_receipts(
            cutoff=stale_at,
            now=now,
            limit=2,
        )

        assert changed == 2
        statuses = [delivery["status"] for delivery in repository._deliveries.values()]
        assert statuses.count("unknown") == 2
        assert statuses.count("queued") == 2

    asyncio.run(exercise())


def test_monitoring_windows_attempt_level_unknown_outcomes() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        await _ready_memory_dispatch(repository, now=now)
        job = (
            await repository.claim_due_deliveries(
                worker_id="worker-a",
                now=now,
                lease_until=now + timedelta(seconds=30),
                limit=1,
            )
        )[0]
        finished_at = now + timedelta(seconds=1)
        await repository.complete_delivery_attempt(
            delivery_id=job["delivery_id"],
            attempt_id=job["attempt_id"],
            worker_id="worker-a",
            submission_status="unknown",
            provider_reference=None,
            error="connection closed after upload",
            now=finished_at,
            retry_at=finished_at + timedelta(seconds=5),
        )

        current = await repository.monitoring_snapshot(
            now=now + timedelta(seconds=2),
            window_seconds=60,
        )
        expired = await repository.monitoring_snapshot(
            now=now + timedelta(seconds=122),
            window_seconds=60,
        )

        assert current["telemetry_window"]["seconds"] == 60
        assert current["unknown_attempts"] == 1
        assert current["unknown_delivery_attempts"] == 1
        assert current["unknown_invitation_attempts"] == 0
        assert expired["unknown_attempts"] == 0

    asyncio.run(exercise())


def test_worker_graceful_stop_drains_the_started_submission_wave() -> None:
    class BlockingProvider(FakePagingProvider):
        def __init__(self) -> None:
            super().__init__()
            self.started = asyncio.Event()
            self.release = asyncio.Event()

        async def send_page_sms(
            self,
            *,
            to_phone: str,
            owner_name: str,
            incident_summary: str,
            response_url: str,
        ) -> PagingSubmission:
            self.started.set()
            await self.release.wait()
            return await super().send_page_sms(
                to_phone=to_phone,
                owner_name=owner_name,
                incident_summary=incident_summary,
                response_url=response_url,
            )

    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id, dispatch_id = await _ready_memory_dispatch(
            repository,
            now=now,
        )
        provider = BlockingProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=60,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
            batch_size=20,
            max_concurrency=1,
        )
        stop_event = asyncio.Event()
        running = asyncio.create_task(worker.run(stop_event=stop_event))

        await asyncio.wait_for(provider.started.wait(), timeout=1)
        stop_event.set()
        worker.wake()
        await asyncio.sleep(0)
        assert not running.done()

        provider.release.set()
        await asyncio.wait_for(running, timeout=1)

        incident = await repository.dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
        )
        sms = [row for row in incident["deliveries"] if row["channel"] == "sms"]
        assert len(provider.pages) == 1
        assert sum(row["status"] == "queued" for row in sms) == 1
        assert sum(row["status"] == "pending" for row in sms) == 1
        assert all(row["status"] != "leased" for row in incident["deliveries"])

    asyncio.run(exercise())


def test_worker_drains_consecutive_due_waves_without_idle_poll_delay() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        await _ready_memory_dispatch(repository, now=now)
        stop_event = asyncio.Event()

        class StopAfterTwoProvider(FakePagingProvider):
            async def send_page_sms(
                self,
                *,
                to_phone: str,
                owner_name: str,
                incident_summary: str,
                response_url: str,
            ) -> PagingSubmission:
                submission = await super().send_page_sms(
                    to_phone=to_phone,
                    owner_name=owner_name,
                    incident_summary=incident_summary,
                    response_url=response_url,
                )
                if len(self.pages) == 2:
                    stop_event.set()
                return submission

        provider = StopAfterTwoProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=60,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
            batch_size=20,
            max_concurrency=1,
        )

        await asyncio.wait_for(
            worker.run(stop_event=stop_event),
            timeout=1,
        )
        assert len(provider.pages) == 2

    asyncio.run(exercise())


def test_ambiguous_provider_outcome_stays_unknown_not_failed() -> None:
    class AmbiguousProvider(FakePagingProvider):
        async def send_page_sms(
            self,
            *,
            to_phone: str,
            owner_name: str,
            incident_summary: str,
            response_url: str,
        ) -> PagingSubmission:
            raise PagingOutcomeUnknownError("connection closed after upload")

    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id, dispatch_id = await _ready_memory_dispatch(repository, now=now)
        for delivery in repository._deliveries.values():
            if delivery["channel"] == "sms":
                delivery["max_attempts"] = 1
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=AmbiguousProvider(),
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=1,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
        )

        assert await worker.process_once() == 2
        incident = await repository.dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
        )
        assert incident["status"] == "open"
        sms = [row for row in incident["deliveries"] if row["channel"] == "sms"]
        assert all(row["status"] == "unknown" for row in sms)
        summary = _safety_dispatch_response(incident)["contact_summary"]
        assert summary["failed"] == 0
        assert summary["pending"] == 2
        assert summary["all_contacts_failed"] is False

    asyncio.run(exercise())


def test_disabling_paging_waits_for_started_provider_submission() -> None:
    class BlockingProvider(FakePagingProvider):
        def __init__(self) -> None:
            super().__init__()
            self.started = asyncio.Event()
            self.release = asyncio.Event()

        async def send_page_sms(
            self,
            *,
            to_phone: str,
            owner_name: str,
            incident_summary: str,
            response_url: str,
        ) -> PagingSubmission:
            self.started.set()
            await self.release.wait()
            return await super().send_page_sms(
                to_phone=to_phone,
                owner_name=owner_name,
                incident_summary=incident_summary,
                response_url=response_url,
            )

    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        await _ready_memory_dispatch(repository, now=now)
        jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=30),
            limit=1,
        )
        provider = BlockingProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=1,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
        )
        worker.worker_id = "worker-a"
        submission = asyncio.create_task(worker._submit_delivery(jobs[0]))
        await provider.started.wait()
        disable = asyncio.create_task(
            repository.set_paging_control(
                enabled=False,
                reason="Carrier incident",
                expected_revision=1,
                now=now + timedelta(seconds=1),
            )
        )
        await asyncio.sleep(0)
        assert not disable.done()

        provider.release.set()
        await submission
        control = await disable
        assert control["enabled"] is False
        assert len(provider.pages) == 1

    asyncio.run(exercise())


def test_profile_erasure_drains_started_page_and_blocks_cached_jobs() -> None:
    class BlockingProvider(FakePagingProvider):
        def __init__(self) -> None:
            super().__init__()
            self.started = asyncio.Event()
            self.release = asyncio.Event()

        async def send_page_sms(
            self,
            *,
            to_phone: str,
            owner_name: str,
            incident_summary: str,
            response_url: str,
        ) -> PagingSubmission:
            self.started.set()
            await self.release.wait()
            return await super().send_page_sms(
                to_phone=to_phone,
                owner_name=owner_name,
                incident_summary=incident_summary,
                response_url=response_url,
            )

    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id, _ = await _ready_memory_dispatch(repository, now=now)
        jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=30),
            limit=2,
        )
        assert len(jobs) == 2
        provider = BlockingProvider()
        worker = SafetyDeliveryWorker(
            repository=repository,
            provider=provider,
            public_base_url=PUBLIC_BASE_URL,
            capability_signer=SafetyCapabilitySigner("s" * 32),
            poll_seconds=1,
            lease_seconds=30,
            retry_base_seconds=1,
            provider_receipt_timeout_seconds=300,
        )
        worker.worker_id = "worker-a"

        submission = asyncio.create_task(worker._submit_delivery(jobs[0]))
        await asyncio.wait_for(provider.started.wait(), timeout=1)
        deletion = asyncio.create_task(repository.delete_profile(profile_id))
        await asyncio.sleep(0)
        assert deletion.done() is False

        provider.release.set()
        counts = await asyncio.wait_for(deletion, timeout=1)
        await asyncio.wait_for(submission, timeout=1)
        assert counts["profiles"] == 1
        assert len(provider.pages) == 1

        await worker._submit_delivery(jobs[1])
        assert len(provider.pages) == 1
        assert profile_id not in repository._profiles

    asyncio.run(exercise())


def test_all_explicit_delivery_failures_close_incident() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id, dispatch_id = await _ready_memory_dispatch(
            repository,
            now=now,
        )
        for delivery in repository._deliveries.values():
            delivery["max_attempts"] = 1

        sms_jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=30),
            limit=10,
        )
        assert len(sms_jobs) == 2
        for job in sms_jobs:
            await repository.complete_delivery_attempt(
                delivery_id=job["delivery_id"],
                attempt_id=job["attempt_id"],
                worker_id="worker-a",
                submission_status="failed",
                provider_reference=None,
                error="provider rejected delivery",
                now=now + timedelta(seconds=1),
                retry_at=now + timedelta(seconds=2),
            )

        voice_jobs = await repository.claim_due_deliveries(
            worker_id="worker-b",
            now=now + timedelta(seconds=2),
            lease_until=now + timedelta(seconds=32),
            limit=10,
        )
        assert len(voice_jobs) == 2
        for job in voice_jobs:
            await repository.complete_delivery_attempt(
                delivery_id=job["delivery_id"],
                attempt_id=job["attempt_id"],
                worker_id="worker-b",
                submission_status="failed",
                provider_reference=None,
                error="provider rejected delivery",
                now=now + timedelta(seconds=3),
                retry_at=now + timedelta(seconds=4),
            )

        incident = await repository.dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
        )
        assert incident["status"] == "failed"
        assert incident["completed_at"] == now + timedelta(seconds=3)
        assert all(row["status"] == "failed" for row in incident["deliveries"])

    asyncio.run(exercise())


def test_unconfirmed_attempt_prevents_false_all_contacts_failed_claim() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id, dispatch_id = await _ready_memory_dispatch(
            repository,
            now=now,
        )
        for delivery in repository._deliveries.values():
            delivery["max_attempts"] = 1

        sms_jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=30),
            limit=10,
        )
        for index, job in enumerate(sms_jobs):
            await repository.complete_delivery_attempt(
                delivery_id=job["delivery_id"],
                attempt_id=job["attempt_id"],
                worker_id="worker-a",
                submission_status="queued" if index == 0 else "failed",
                provider_reference=(
                    "SMunconfirmed000000000000000000000" if index == 0 else None
                ),
                error=None,
                now=now + timedelta(seconds=1),
                retry_at=now + timedelta(seconds=2),
            )
        await repository.mark_stale_provider_receipts(
            cutoff=now + timedelta(seconds=1),
            now=now + timedelta(seconds=2),
        )

        voice_jobs = await repository.claim_due_deliveries(
            worker_id="worker-b",
            now=now + timedelta(seconds=3),
            lease_until=now + timedelta(seconds=33),
            limit=10,
        )
        assert len(voice_jobs) == 2
        for job in voice_jobs:
            await repository.complete_delivery_attempt(
                delivery_id=job["delivery_id"],
                attempt_id=job["attempt_id"],
                worker_id="worker-b",
                submission_status="failed",
                provider_reference=None,
                error="provider rejected delivery",
                now=now + timedelta(seconds=4),
                retry_at=now + timedelta(seconds=5),
            )

        incident = await repository.dispatch(
            profile_id=profile_id,
            dispatch_id=dispatch_id,
        )
        response = _safety_dispatch_response(incident)
        assert response["status"] == "open"
        assert response["contact_summary"]["failed"] == 1
        assert response["contact_summary"]["pending"] == 1
        assert response["contact_summary"]["all_contacts_failed"] is False

    asyncio.run(exercise())


def test_expired_final_lease_is_terminal_and_expedites_voice() -> None:
    async def exercise() -> None:
        repository = MemorySafetyRepository()
        now = datetime.now(UTC)
        profile_id = str(uuid4())
        await repository.create_profile(
            profile_id=profile_id,
            enrollment_id=str(uuid4()),
            display_name="Jordan",
            installation_id=str(uuid4()),
            token_hash=hashlib.sha256(b"safety-token").hexdigest(),
        )
        for index in range(2):
            invite_hash = hashlib.sha256(f"invite-{index}".encode()).hexdigest()
            await repository.create_contact(
                contact_id=str(uuid4()),
                profile_id=profile_id,
                display_name=f"Contact {index}",
                phone_e164=f"+1415555010{index}",
                invite_token_hash=invite_hash,
                invited_at=now,
                invite_expires_at=now + timedelta(hours=1),
            )
            await repository.decide_invitation(
                invite_token_hash=invite_hash,
                decision="accept",
                now=now,
            )

        dispatch_id = str(uuid4())
        await repository.create_dispatch(
            dispatch_id=dispatch_id,
            profile_id=profile_id,
            idempotency_key=str(uuid4()),
            request_hash=hashlib.sha256(b"manual_sos").hexdigest(),
            trigger="manual_sos",
            now=now,
            expires_at=now + timedelta(minutes=30),
            voice_fallback_at=now + timedelta(minutes=5),
        )
        jobs = await repository.claim_due_deliveries(
            worker_id="worker-a",
            now=now,
            lease_until=now + timedelta(seconds=1),
            limit=2,
        )
        target = jobs[0]
        repository._deliveries[target["delivery_id"]]["max_attempts"] = 1

        recovered_at = now + timedelta(seconds=2)
        await repository.claim_due_deliveries(
            worker_id="worker-b",
            now=recovered_at,
            lease_until=recovered_at + timedelta(seconds=1),
            limit=10,
        )

        delivery = repository._deliveries[target["delivery_id"]]
        assert delivery["status"] == "failed"
        assert delivery["lease_owner"] is None
        assert (
            repository._delivery_attempts[target["attempt_id"]]["status"] == "unknown"
        )
        voice = next(
            row
            for row in repository._deliveries.values()
            if row["dispatch_id"] == dispatch_id
            and row["contact_id"] == target["contact_id"]
            and row["channel"] == "voice"
        )
        assert voice["available_at"] == recovered_at

    asyncio.run(exercise())


def test_owner_can_cancel_open_incident_and_monitoring_has_no_pii() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=10)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        incident_id = created.json()["dispatch_id"]
        cancelled = client.post(
            f"/v1/safety/incidents/{incident_id}/cancel",
            headers=headers,
            json={"note": "Sent by mistake"},
        )
        assert cancelled.status_code == 200
        assert cancelled.json()["status"] == "cancelled"

        operations = client.get(
            "/v1/safety/operations",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        assert operations.status_code == 200
        assert "queue" in operations.json()
        assert "+1415" not in operations.text
        assert "Alex" not in operations.text


def test_automated_or_anomaly_trigger_is_not_an_incident_entry_point() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider)
    with client:
        _, headers, _ = _bootstrap(client)
        rejected = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "automatic_anomaly"},
        )
        assert rejected.status_code == 422
        assert provider.pages == []


def test_validated_fall_is_fail_closed_without_approved_live_contract() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider)
    now = datetime.now(UTC)
    with client:
        _, headers, _ = _bootstrap(client)
        rejected = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={
                "trigger": "validated_fall",
                "share_duration_hours": 8,
                "evidence": {
                    "detector_id": "noop_band_fall",
                    "detector_version": 1,
                    "event_id": str(uuid4()),
                    "detected_at": (now - timedelta(seconds=47)).isoformat(),
                    "warning_haptic_confirmed_at": (
                        now - timedelta(seconds=46)
                    ).isoformat(),
                    "response_deadline_at": (now - timedelta(seconds=1)).isoformat(),
                },
            },
        )
        assert rejected.status_code == 409
        assert "disabled" in rejected.json()["detail"]
        assert provider.pages == []


def test_allowlist_cannot_replace_authenticated_fall_evidence() -> None:
    provider = FakePagingProvider()
    client, _ = _client(
        provider,
        automatic_paging_enabled=True,
        approved_fall_detectors=frozenset({"noop_band_fall:1"}),
    )
    now = datetime.now(UTC)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        rejected = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={
                "trigger": "validated_fall",
                "share_duration_hours": 8,
                "evidence": {
                    "detector_id": "noop_band_fall",
                    "detector_version": 1,
                    "event_id": str(uuid4()),
                    "detected_at": (now - timedelta(seconds=47)).isoformat(),
                    "warning_haptic_confirmed_at": (
                        now - timedelta(seconds=46)
                    ).isoformat(),
                    "response_deadline_at": (now - timedelta(seconds=1)).isoformat(),
                },
            },
        )
        assert rejected.status_code == 409, rejected.text
        assert "authenticated fall-detector evidence" in rejected.json()["detail"]
        assert provider.pages == []


def test_validated_fall_retry_replays_after_evidence_freshness_window() -> None:
    provider = FakePagingProvider()
    client, safety = _client(
        provider,
        automatic_paging_enabled=True,
        approved_fall_detectors=frozenset({"noop_band_fall:1"}),
    )
    clock = {"now": datetime(2026, 8, 24, 18, 0, tzinfo=UTC)}

    async def coordination_now() -> datetime:
        return clock["now"]

    safety.coordination_now = coordination_now  # type: ignore[method-assign]
    event_id = str(uuid4())
    key = str(uuid4())
    body = {
        "trigger": "validated_fall",
        "share_duration_hours": 8,
        "evidence": {
            "detector_id": "noop_band_fall",
            "detector_version": 1,
            "event_id": event_id,
            "detected_at": (clock["now"] - timedelta(seconds=47)).isoformat(),
            "warning_haptic_confirmed_at": (
                clock["now"] - timedelta(seconds=46)
            ).isoformat(),
            "response_deadline_at": (clock["now"] - timedelta(seconds=1)).isoformat(),
        },
    }
    with client:
        profile, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        page = SafetyPageCreate.model_validate(body)
        request_hash, accepted_hashes = _safety_page_request_hashes(page)

        async def seed_authenticated_future_incident() -> dict:
            return await safety.create_dispatch(
                dispatch_id=str(uuid4()),
                profile_id=profile["profile_id"],
                idempotency_key=key,
                request_hash=request_hash,
                accepted_request_hashes=accepted_hashes,
                trigger="validated_fall",
                share_duration_hours=8,
                evidence=page.evidence.model_dump(mode="json"),
                escalation_rounds=1,
                now=clock["now"],
                expires_at=clock["now"] + timedelta(hours=8),
                voice_fallback_at=clock["now"] + timedelta(seconds=90),
            )

        created = client.portal.call(seed_authenticated_future_incident)

        clock["now"] += timedelta(minutes=5)
        replay = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": key},
            json=body,
        )
        assert replay.status_code == 202, replay.text
        assert replay.json()["dispatch_id"] == created["dispatch_id"]
        assert replay.json()["idempotent_replay"] is True


def test_repository_rejects_a_second_incident_for_the_same_fall_event() -> None:
    provider = FakePagingProvider()
    client, safety = _client(
        provider,
        automatic_paging_enabled=True,
        approved_fall_detectors=frozenset({"noop_band_fall:1"}),
    )
    now = datetime.now(UTC)
    body = {
        "trigger": "validated_fall",
        "share_duration_hours": 8,
        "evidence": {
            "detector_id": "noop_band_fall",
            "detector_version": 1,
            "event_id": str(uuid4()),
            "detected_at": (now - timedelta(seconds=47)).isoformat(),
            "warning_haptic_confirmed_at": (now - timedelta(seconds=46)).isoformat(),
            "response_deadline_at": (now - timedelta(seconds=1)).isoformat(),
        },
    }
    with client:
        profile, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        page = SafetyPageCreate.model_validate(body)

        async def exercise() -> None:
            first = await safety.create_dispatch(
                dispatch_id=str(uuid4()),
                profile_id=profile["profile_id"],
                idempotency_key=str(uuid4()),
                request_hash=hashlib.sha256(b"first-fall-event").hexdigest(),
                trigger="validated_fall",
                evidence=page.evidence.model_dump(mode="json"),
                now=now,
                expires_at=now + timedelta(hours=8),
                voice_fallback_at=now + timedelta(seconds=90),
            )
            await safety.transition_dispatch(
                profile_id=profile["profile_id"],
                dispatch_id=first["dispatch_id"],
                action="cancel",
                note=None,
                now=now + timedelta(seconds=1),
            )
            with pytest.raises(
                SafetyConflictError,
                match="fall event was already used",
            ):
                await safety.create_dispatch(
                    dispatch_id=str(uuid4()),
                    profile_id=profile["profile_id"],
                    idempotency_key=str(uuid4()),
                    request_hash=hashlib.sha256(b"duplicate-fall-event").hexdigest(),
                    trigger="validated_fall",
                    evidence=page.evidence.model_dump(mode="json"),
                    now=now + timedelta(seconds=2),
                    expires_at=now + timedelta(hours=8, seconds=2),
                    voice_fallback_at=now + timedelta(seconds=92),
                )

        client.portal.call(exercise)


def test_manual_page_replays_a_pre_escalation_request_hash() -> None:
    provider = FakePagingProvider()
    client, safety = _client(provider)
    key = str(uuid4())
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202, created.text
        legacy_hash = hashlib.sha256(b'{"trigger":"manual_sos"}').hexdigest()

        async def set_legacy_hash() -> None:
            async with safety._lock:
                safety._dispatches[created.json()["dispatch_id"]]["request_hash"] = (
                    legacy_hash
                )

        client.portal.call(set_legacy_hash)
        replay = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": key},
            json={"trigger": "manual_sos"},
        )
        assert replay.status_code == 202, replay.text
        assert replay.json()["dispatch_id"] == created.json()["dispatch_id"]
        assert replay.json()["idempotent_replay"] is True


def test_pending_contacts_do_not_satisfy_page_threshold_and_invites_are_one_time() -> (
    None
):
    provider = FakePagingProvider()
    client, _ = _client(provider)
    with client:
        _, headers, _ = _bootstrap(client)
        created = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": "Alex", "phone_e164": "+14155550101"},
        )
        assert created.status_code == 201
        _wait_until(lambda: len(provider.invitations) == 1)
        invitation_path = urlparse(provider.invitations[-1][1]).path
        assert (
            client.post(
                invitation_path,
                content="decision=accept",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            ).status_code
            == 200
        )
        assert (
            client.post(
                invitation_path,
                content="decision=accept",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            ).status_code
            == 410
        )

        page = client.post(
            "/v1/safety/pages",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert page.status_code == 412
        assert "at least two accepted" in page.json()["detail"]
        assert provider.pages == []


def test_contact_cap_and_phone_validation_are_enforced() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider)
    with client:
        _, headers, _ = _bootstrap(client)
        invalid = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": "Bad", "phone_e164": "415-555-0100"},
        )
        assert invalid.status_code == 422

        for index in range(5):
            response = client.post(
                "/v1/safety/contacts",
                headers=headers,
                json={
                    "display_name": f"Contact {index}",
                    "phone_e164": f"+1415555010{index}",
                },
            )
            assert response.status_code == 201, response.text
        sixth = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": "Sixth", "phone_e164": "+14155550199"},
        )
        assert sixth.status_code == 409
        assert "at most five" in sixth.json()["detail"]


def test_twilio_delivery_receipts_require_capability_and_valid_signature() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, signed_callbacks=True)
    with client:
        _, safety_headers, _ = _bootstrap(client)
        created = client.post(
            "/v1/safety/contacts",
            headers=safety_headers,
            json={"display_name": "Alex", "phone_e164": "+14155550101"},
        )
        assert created.status_code == 201
        assert created.json()["contact"]["invitation_provider_reference"] is None
        _wait_until(lambda: len(provider.invitations) == 1)
        contacts = client.get(
            "/v1/safety/contacts",
            headers=safety_headers,
        )
        provider_reference = contacts.json()["contacts"][0][
            "invitation_provider_reference"
        ]
        values = {
            "MessageSid": provider_reference,
            "MessageStatus": "delivered",
        }
        path = f"/v1/safety/provider/twilio/status?token={TWILIO_CALLBACK_SECRET}"
        callback_url = f"{PUBLIC_BASE_URL}{path}"
        callback_headers = {"Content-Type": "application/x-www-form-urlencoded"}

        missing_capability = client.post(
            "/v1/safety/provider/twilio/status",
            content=urlencode(values),
            headers=callback_headers,
        )
        assert missing_capability.status_code == 401

        forged = client.post(
            path,
            content=urlencode(values),
            headers={**callback_headers, "X-Twilio-Signature": "forged"},
        )
        assert forged.status_code == 401

        accepted = client.post(
            path,
            content=urlencode(values),
            headers={
                **callback_headers,
                "X-Twilio-Signature": _twilio_signature(callback_url, values),
            },
        )
        assert accepted.status_code == 204
        contacts = client.get(
            "/v1/safety/contacts",
            headers=safety_headers,
        )
        assert contacts.status_code == 200
        assert (
            contacts.json()["contacts"][0]["invitation_delivery_status"] == "delivered"
        )


def test_incident_location_keeps_only_latest_fix_and_signed_link_shows_it() -> None:
    provider = FakePagingProvider()
    client, _ = _client(
        provider,
        acknowledgement_timeout_seconds=10,
        signed_callbacks=True,
    )
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        assert created.status_code == 202, created.text
        incident_id = created.json()["dispatch_id"]
        _wait_until(lambda: len(provider.pages) == 2)

        captured_at = datetime.now(UTC)
        first = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json={
                "sequence": 1,
                "latitude": 40.7128,
                "longitude": -74.0060,
                "horizontal_accuracy_meters": 24.5,
                "captured_at": captured_at.isoformat(),
            },
        )
        assert first.status_code == 200, first.text
        assert first.json()["retention"] == "latest_only"
        assert first.json()["location"]["idempotent_replay"] is False

        second_captured_at = captured_at + timedelta(seconds=1)
        second = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json={
                "sequence": 2,
                "latitude": 40.7131,
                "longitude": -74.0057,
                "horizontal_accuracy_meters": 12.0,
                "captured_at": second_captured_at.isoformat(),
            },
        )
        assert second.status_code == 200, second.text
        assert second.json()["location"]["idempotent_replay"] is False

        owner_view = client.get(
            f"/v1/safety/incidents/{incident_id}",
            headers=headers,
        )
        assert owner_view.status_code == 200
        assert owner_view.json()["latest_location"]["sequence"] == 2
        assert owner_view.json()["latest_location"]["latitude"] == 40.7131

        contact_view = client.get(provider.pages[0].response_url)
        assert contact_view.status_code == 200
        assert "Latest shared location" in contact_view.text
        assert "40.713100" in contact_view.text
        assert 'http-equiv="refresh"' in contact_view.text

        cancelled = client.post(
            f"/v1/safety/incidents/{incident_id}/cancel",
            headers=headers,
            json={},
        )
        assert cancelled.status_code == 200
        terminal_contact_view = client.get(provider.pages[0].response_url)
        assert terminal_contact_view.status_code == 200
        assert "Latest shared location" not in terminal_contact_view.text
        assert "40.713100" not in terminal_contact_view.text
        assert 'http-equiv="refresh"' not in terminal_contact_view.text


def test_location_replays_are_idempotent_and_stale_fixes_are_rejected() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=10)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        incident_id = created.json()["dispatch_id"]
        captured_at = datetime.now(UTC)
        payload = {
            "sequence": 1,
            "latitude": 37.7749,
            "longitude": -122.4194,
            "horizontal_accuracy_meters": 18.0,
            "captured_at": captured_at.isoformat(),
        }
        assert (
            client.put(
                f"/v1/safety/incidents/{incident_id}/location",
                headers=headers,
                json=payload,
            ).status_code
            == 200
        )

        replay = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json=payload,
        )
        assert replay.status_code == 200
        assert replay.json()["location"]["idempotent_replay"] is True

        out_of_order = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json={
                **payload,
                "sequence": 2,
                "latitude": 1.0,
                "captured_at": (captured_at - timedelta(seconds=1)).isoformat(),
            },
        )
        assert out_of_order.status_code == 200
        assert out_of_order.json()["location"]["idempotent_replay"] is True
        assert out_of_order.json()["location"]["latitude"] == 37.7749

        stale = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json={
                **payload,
                "sequence": 3,
                "captured_at": (datetime.now(UTC) - timedelta(minutes=6)).isoformat(),
            },
        )
        assert stale.status_code == 422
        assert "too old" in stale.json()["detail"]


def test_terminal_incident_rejects_location_updates() -> None:
    provider = FakePagingProvider()
    client, _ = _client(provider, acknowledgement_timeout_seconds=10)
    with client:
        _, headers, _ = _bootstrap(client)
        _ready_contacts(client, provider, headers)
        created = client.post(
            "/v1/safety/incidents",
            headers={**headers, "Idempotency-Key": str(uuid4())},
            json={"trigger": "manual_sos"},
        )
        incident_id = created.json()["dispatch_id"]
        cancelled = client.post(
            f"/v1/safety/incidents/{incident_id}/cancel",
            headers=headers,
            json={"note": "Cancelled during the confirmation window"},
        )
        assert cancelled.status_code == 200

        update = client.put(
            f"/v1/safety/incidents/{incident_id}/location",
            headers=headers,
            json={
                "sequence": 1,
                "latitude": 34.0522,
                "longitude": -118.2437,
                "captured_at": datetime.now(UTC).isoformat(),
            },
        )
        assert update.status_code == 409
        assert "no longer accepting" in update.json()["detail"]
