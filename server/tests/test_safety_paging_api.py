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

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.paging import PagingSubmission, PagingUnavailableError
from app.repository import MemoryRepository
from app.safety_repository import MemorySafetyRepository


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
        self, *, to_phone: str, owner_name: str, response_url: str
    ) -> PagingSubmission:
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
        self, *, to_phone: str, owner_name: str, response_url: str
    ) -> PagingSubmission:
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
            safety_retry_base_seconds=retry_base_seconds,
            safety_worker_poll_seconds=1,
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


def _accept_latest(client: TestClient, provider: FakePagingProvider) -> None:
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
        created = client.post(
            "/v1/safety/contacts",
            headers=headers,
            json={"display_name": name, "phone_e164": phone},
        )
        assert created.status_code == 201, created.text
        _accept_latest(client, provider)


def test_contacts_require_acceptance_and_page_is_sms_first_and_idempotent() -> None:
    provider = FakePagingProvider()
    client, safety = _client(provider)
    with client:
        _, headers, plaintext_token = _bootstrap(client)
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
        provider_reference = created.json()["contact"]["invitation_provider_reference"]
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
