from __future__ import annotations

import io
import json
from datetime import UTC, datetime, timedelta
from urllib.error import HTTPError
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.managed_push import (
    FirebaseCloudMessagingProvider,
    ManagedPushResult,
    ManagedPushTokenCodec,
    ManagedPushTokenError,
    UnavailableManagedPushProvider,
)
from app.managed_safety_models import (
    ManagedPushRegistration,
    ManagedSafetyIncidentCreate,
    ManagedSafetyInviteCreate,
    ManagedSafetyLocationUpdate,
    ManagedSafetyRequestCreate,
)
from app.managed_safety_repository import ManagedSafetyPushService


class _Response:
    def __init__(self, value: dict) -> None:
        self._body = json.dumps(value).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, limit: int = -1) -> bytes:
        return self._body[:limit]


class _ExplodingProvider:
    @property
    def available(self) -> bool:
        return True

    async def send_safety_incident(self, **_) -> ManagedPushResult:
        raise RuntimeError("untrusted provider failure text")


class _DeliveryRepository:
    def __init__(
        self,
        *,
        account_id,
        installation_id: str,
        target_kind: str,
        token_ciphertext: str,
    ) -> None:
        self.delivery_id = uuid4()
        self.claim_id = uuid4()
        self.account_id = account_id
        self.installation_id = installation_id
        self.target_kind = target_kind
        self.token_ciphertext = token_ciphertext
        self.completed = []

    async def claim_push_deliveries(self, **_):
        return [
            {
                "delivery_id": self.delivery_id,
                "claim_id": self.claim_id,
                "incident_id": uuid4(),
                "account_id": self.account_id,
                "installation_id": self.installation_id,
                "target_kind": self.target_kind,
                "token_ciphertext": self.token_ciphertext,
                "expires_at": datetime.now(UTC) + timedelta(hours=8),
                "attempt": 1,
            }
        ]

    async def claim_due_push_deliveries(self, **_):
        return await self.claim_push_deliveries()

    async def complete_push_delivery(self, **values):
        self.completed.append(values)

    async def delivery_summary(self, **_):
        return {
            "contacts_targeted": 1,
            "contacts_reached": 0,
            "installations_targeted": 1,
            "installations_reached": 0,
        }


def test_managed_push_token_codec_binds_ciphertext_to_installation() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    token = "fcm-token:ABC_def-1234567890"
    sealed = codec.seal(
        token,
        account_id=account_id,
        installation_id="ios-test-1",
    )
    assert token not in sealed
    assert codec.token_hash(token) != token
    assert (
        codec.open(
            sealed,
            account_id=account_id,
            installation_id="ios-test-1",
        )
        == token
    )
    with pytest.raises(ManagedPushTokenError):
        codec.open(
            sealed,
            account_id=account_id,
            installation_id="android-test-2",
        )


@pytest.mark.asyncio
async def test_unexpected_provider_failure_becomes_retryable_unavailable() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    installation_id = "ios-test-provider-failure"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        target_kind="fid",
        token_ciphertext=codec.seal(
            "fcm-token:ABC_def-1234567890",
            account_id=account_id,
            installation_id=installation_id,
        ),
    )
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=codec,
        provider=_ExplodingProvider(),
    )

    summary = await service.dispatch(
        principal=object(),
        incident_id=uuid4(),
    )

    assert summary["installations_reached"] == 0
    assert len(repository.completed) == 1
    assert repository.completed[0]["outcome"] == "unavailable"
    assert repository.completed[0]["provider_reference_hash"] is None


@pytest.mark.asyncio
async def test_due_push_retry_reports_only_bounded_outcomes() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    installation_id = "android-test-due-retry"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        target_kind="token",
        token_ciphertext=codec.seal(
            "fcm-token:ABC_def-1234567890",
            account_id=account_id,
            installation_id=installation_id,
        ),
    )
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=codec,
        provider=_ExplodingProvider(),
    )

    result = await service.dispatch_due(limit=20)

    assert result.claimed == 1
    assert result.provider_accepted == 0
    assert result.retryable_failures == 1
    assert result.terminal_failures == 0
    assert result.receipt_failures == 0


def test_managed_safety_models_are_strict_and_bounded() -> None:
    registration = ManagedPushRegistration(
        platform="ios",
        environment="production",
        target_kind="fid",
        token="fcm-token:ABC_def-1234567890",
    )
    assert registration.token.get_secret_value().startswith("fcm-token:")
    assert (
        ManagedSafetyIncidentCreate(
            request_id=uuid4(),
            duration_hours=8,
            share_location=True,
        ).duration_hours
        == 8
    )
    assert (
        ManagedSafetyRequestCreate(
            request_id=uuid4(),
            noop_id="noop-abcd-efgh-jklm-npqr",
        ).noop_id
        == "NOOP-ABCD-EFGH-JKLM-NPQR"
    )
    with pytest.raises(ValidationError):
        ManagedSafetyIncidentCreate(
            request_id=uuid4(),
            duration_hours=10,
        )
    with pytest.raises(ValidationError):
        ManagedSafetyInviteCreate(
            request_id=uuid4(),
            capability="unsafe",
        )
    with pytest.raises(ValidationError):
        ManagedSafetyLocationUpdate(
            sequence=1,
            latitude=91,
            longitude=0,
            horizontal_accuracy_m=5,
            captured_at=datetime.now(UTC),
        )
    with pytest.raises(ValidationError):
        ManagedSafetyLocationUpdate(
            sequence=1,
            latitude=1,
            longitude=2,
            horizontal_accuracy_m=5,
            captured_at=datetime.now(),
        )
    with pytest.raises(ValidationError):
        ManagedPushRegistration(
            platform="ios",
            environment="production",
            target_kind="token",
            token="fcm-token:ABC_def-1234567890",
        )


def test_fcm_payload_contains_only_generic_notification_and_opaque_reference() -> None:
    incident_id = uuid4()
    now = datetime(2026, 9, 8, 8, 0, tzinfo=UTC)
    expires_at = now + timedelta(hours=8)
    payload = FirebaseCloudMessagingProvider.payload(
        token="fcm-token:ABC_def-1234567890",
        target_kind="token",
        incident_id=incident_id,
        expires_at=expires_at,
        now=now,
    )
    serialized = json.dumps(payload, sort_keys=True)
    assert str(incident_id) in serialized
    assert "managed_safety_incident" in serialized
    assert "location" not in serialized.casefold()
    assert "latitude" not in serialized.casefold()
    assert "longitude" not in serialized.casefold()
    assert "health" not in serialized.casefold()
    assert "display_name" not in serialized.casefold()
    assert payload["message"]["android"]["ttl"] == "28800s"
    assert payload["message"]["android"]["priority"] == "HIGH"
    assert "notification" not in payload["message"]
    assert "apns" not in payload["message"]
    assert payload["message"]["token"] == "fcm-token:ABC_def-1234567890"
    assert "fid" not in payload["message"]

    fid_payload = FirebaseCloudMessagingProvider.payload(
        token="firebase-installation-id",
        target_kind="fid",
        incident_id=incident_id,
        expires_at=expires_at,
        now=now,
    )
    assert fid_payload["message"]["fid"] == "firebase-installation-id"
    assert "token" not in fid_payload["message"]
    assert "android" not in fid_payload["message"]
    assert fid_payload["message"]["notification"] == {
        "title": "Safety page",
        "body": "Open NOOP to review an urgent contact request.",
    }
    assert fid_payload["message"]["apns"]["headers"] == {
        "apns-collapse-id": f"noop-safety-{incident_id}",
        "apns-expiration": str(int(expires_at.timestamp())),
        "apns-priority": "10",
        "apns-push-type": "alert",
    }
    assert fid_payload["message"]["apns"]["payload"]["aps"]["sound"] == "default"
    assert (
        fid_payload["message"]["apns"]["payload"]["aps"]["interruption-level"]
        == "time-sensitive"
    )


@pytest.mark.asyncio
async def test_unavailable_provider_fails_closed_without_delivery_claim() -> None:
    provider = UnavailableManagedPushProvider()
    assert provider.available is False
    result = await provider.send_safety_incident(
        token="fcm-token:ABC_def-1234567890",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "unavailable"


@pytest.mark.asyncio
async def test_fcm_provider_uses_metadata_token_and_hashes_provider_reference() -> None:
    requests = []

    def opener(request, timeout):
        requests.append((request, timeout))
        if request.full_url.startswith("http://metadata."):
            assert request.get_header("Metadata-flavor") == "Google"
            return _Response(
                {
                    "access_token": "metadata-access-token",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                }
            )
        assert request.full_url.endswith("/messages:send")
        assert request.get_header("Authorization") == "Bearer metadata-access-token"
        body = json.loads(request.data)
        assert body["message"]["data"]["kind"] == "managed_safety_incident"
        return _Response({"name": "projects/test/messages/opaque-provider-id"})

    provider = FirebaseCloudMessagingProvider(
        project_id="noop-test-project",
        opener=opener,
    )
    result = await provider.send_safety_incident(
        token="fcm-token:ABC_def-1234567890",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "sent"
    assert result.provider_reference_hash is not None
    assert "opaque-provider-id" not in result.provider_reference_hash
    assert len(requests) == 2


@pytest.mark.asyncio
async def test_fcm_provider_invalidates_only_explicit_unregistered_tokens() -> None:
    calls = 0

    def opener(request, timeout):
        nonlocal calls
        calls += 1
        if calls == 1:
            return _Response(
                {
                    "access_token": "metadata-access-token",
                    "expires_in": 3600,
                }
            )
        body = json.dumps(
            {
                "error": {
                    "status": "NOT_FOUND",
                    "details": [{"errorCode": "UNREGISTERED"}],
                }
            }
        ).encode("utf-8")
        raise HTTPError(
            request.full_url,
            404,
            "not found",
            {},
            io.BytesIO(body),
        )

    provider = FirebaseCloudMessagingProvider(
        project_id="noop-test-project",
        opener=opener,
    )
    result = await provider.send_safety_incident(
        token="fcm-token:ABC_def-1234567890",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "invalid"


@pytest.mark.asyncio
async def test_fcm_provider_treats_unregistered_fid_404_as_invalid() -> None:
    calls = 0

    def opener(request, timeout):
        nonlocal calls
        calls += 1
        if calls == 1:
            return _Response(
                {
                    "access_token": "metadata-access-token",
                    "expires_in": 3600,
                }
            )
        raise HTTPError(
            request.full_url,
            404,
            "not found",
            {},
            io.BytesIO(b'{"error":{"status":"NOT_FOUND"}}'),
        )

    provider = FirebaseCloudMessagingProvider(
        project_id="noop-test-project",
        opener=opener,
    )
    result = await provider.send_safety_incident(
        token="firebase-installation-id",
        target_kind="fid",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "invalid"


@pytest.mark.asyncio
async def test_fcm_provider_does_not_invalidate_from_unstructured_error_text() -> None:
    calls = 0

    def opener(request, timeout):
        nonlocal calls
        calls += 1
        if calls == 1:
            return _Response(
                {
                    "access_token": "metadata-access-token",
                    "expires_in": 3600,
                }
            )
        raise HTTPError(
            request.full_url,
            400,
            "UNREGISTERED appears only in untrusted text",
            {},
            io.BytesIO(b'{"error":{"message":"UNREGISTERED"}}'),
        )

    provider = FirebaseCloudMessagingProvider(
        project_id="noop-test-project",
        opener=opener,
    )
    result = await provider.send_safety_incident(
        token="fcm-token:ABC_def-1234567890",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "rejected"
