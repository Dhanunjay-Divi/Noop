from __future__ import annotations

import asyncio
import base64
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
    ManagedPushTokenCorruptError,
    ManagedPushTokenError,
    ManagedPushTokenUnavailableError,
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
        platform: str,
        target_kind: str,
        token_ciphertext: str,
    ) -> None:
        self.delivery_id = uuid4()
        self.claim_id = uuid4()
        self.account_id = account_id
        self.installation_id = installation_id
        self.platform = platform
        self.target_kind = target_kind
        self.token_ciphertext = token_ciphertext
        self.token_hash = "a" * 64
        self.completed = []
        self.reencrypted = []
        self.due_claimed = False

    async def claim_push_deliveries(
        self,
        *,
        exclude_delivery_ids=(),
        **_,
    ):
        if self.delivery_id in exclude_delivery_ids:
            return []
        return [
            {
                "delivery_id": self.delivery_id,
                "claim_id": self.claim_id,
                "incident_id": uuid4(),
                "account_id": self.account_id,
                "installation_id": self.installation_id,
                "platform": self.platform,
                "target_kind": self.target_kind,
                "token_hash": self.token_hash,
                "token_ciphertext": self.token_ciphertext,
                "expires_at": datetime.now(UTC) + timedelta(hours=8),
                "attempt": 1,
            }
        ]

    async def claim_due_push_deliveries(self, **_):
        if self.due_claimed:
            return []
        self.due_claimed = True
        return await self.claim_push_deliveries()

    async def complete_push_delivery(self, **values):
        self.completed.append(values)

    async def reencrypt_push_installation_token(self, **values):
        self.reencrypted.append(values)
        self.token_ciphertext = values["replacement_ciphertext"]
        return True

    async def delivery_summary(self, **_):
        return {
            "contacts_targeted": 1,
            "contacts_reached": 0,
            "installations_targeted": 1,
            "installations_reached": 0,
        }


class _WaveDeliveryRepository:
    def __init__(self, deliveries: list[dict]) -> None:
        self.pending = list(deliveries)
        self.claim_limits: list[int] = []
        self.completed: list[dict] = []

    async def claim_due_push_deliveries(self, *, limit: int):
        self.claim_limits.append(limit)
        claimed = self.pending[:limit]
        self.pending = self.pending[limit:]
        return claimed

    async def complete_push_delivery(self, **values):
        self.completed.append(values)


class _IncidentWaveDeliveryRepository:
    def __init__(self, deliveries: list[dict]) -> None:
        self.deliveries = list(deliveries)
        self.claim_limits: list[int] = []
        self.claim_exclusions: list[set] = []
        self.completed: list[dict] = []

    async def claim_push_deliveries(
        self,
        *,
        limit: int,
        exclude_delivery_ids,
        **_,
    ):
        excluded = set(exclude_delivery_ids)
        self.claim_limits.append(limit)
        self.claim_exclusions.append(excluded)
        return [
            delivery
            for delivery in self.deliveries
            if delivery["delivery_id"] not in excluded
        ][:limit]

    async def complete_push_delivery(self, **values):
        self.completed.append(values)

    async def delivery_summary(self, **_):
        targeted = len(self.deliveries)
        return {
            "contacts_targeted": targeted,
            "contacts_reached": targeted,
            "installations_targeted": targeted,
            "installations_reached": targeted,
        }


class _ConcurrentAcceptingProvider:
    def __init__(self) -> None:
        self.active = 0
        self.maximum_active = 0

    @property
    def available(self) -> bool:
        return True

    async def send_safety_incident(self, **_) -> ManagedPushResult:
        self.active += 1
        self.maximum_active = max(self.maximum_active, self.active)
        try:
            await asyncio.sleep(0.01)
        finally:
            self.active -= 1
        return ManagedPushResult(
            outcome="sent",
            provider_reference_hash="a" * 64,
        )


def _tamper_envelope(sealed: str) -> str:
    parts = sealed.split(".")
    payload = parts[-1]
    decoded = bytearray(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    decoded[-1] ^= 0x01
    parts[-1] = base64.urlsafe_b64encode(bytes(decoded)).decode("ascii").rstrip("=")
    return ".".join(parts)


def test_managed_push_token_codec_binds_ciphertext_to_installation() -> None:
    codec = ManagedPushTokenCodec(
        "managed-push-secret-" + ("x" * 32),
        write_version="v2",
    )
    account_id = uuid4()
    token = "fcm-token:ABC_def-1234567890"
    sealed = codec.seal(
        token,
        account_id=account_id,
        installation_id="ios-test-1",
    )
    assert sealed.startswith("v2.")
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


def test_managed_push_rollout_stays_v1_until_every_reader_is_dual_version() -> None:
    secret = "managed-push-rollout-" + ("r" * 32)
    account_id = uuid4()
    installation_id = "ios-rolling-deployment"
    token = "fcm-token:rolling_deployment_1234567890"
    compatibility_writer = ManagedPushTokenCodec(secret)
    legacy_envelope = compatibility_writer.seal(
        token,
        account_id=account_id,
        installation_id=installation_id,
    )

    assert legacy_envelope.startswith("v1.")
    assert (
        ManagedPushTokenCodec(secret).open(
            legacy_envelope,
            account_id=account_id,
            installation_id=installation_id,
        )
        == token
    )

    promoted_writer = ManagedPushTokenCodec(secret, write_version="v2")
    opened_legacy = promoted_writer.open_with_rotation(
        legacy_envelope,
        account_id=account_id,
        installation_id=installation_id,
    )
    assert opened_legacy.token == token
    assert opened_legacy.needs_reseal is True

    promoted_envelope = promoted_writer.seal(
        token,
        account_id=account_id,
        installation_id=installation_id,
    )
    assert promoted_envelope.startswith("v2.")
    opened_during_rollback = compatibility_writer.open_with_rotation(
        promoted_envelope,
        account_id=account_id,
        installation_id=installation_id,
    )
    assert opened_during_rollback.token == token
    assert opened_during_rollback.needs_reseal is True


def test_managed_push_token_codec_classifies_corruption_and_missing_keys() -> None:
    current_secret = "managed-push-current-" + ("c" * 32)
    previous_secret = "managed-push-previous-" + ("p" * 32)
    account_id = uuid4()
    installation_id = "android-token-classification"
    current = ManagedPushTokenCodec(current_secret, write_version="v2")
    previous = ManagedPushTokenCodec(previous_secret, write_version="v2")
    current_envelope = current.seal(
        "fcm-token:classification_1234567890",
        account_id=account_id,
        installation_id=installation_id,
    )

    with pytest.raises(ManagedPushTokenCorruptError, match="authentication"):
        current.open(
            _tamper_envelope(current_envelope),
            account_id=account_id,
            installation_id=installation_id,
        )
    with pytest.raises(ManagedPushTokenCorruptError, match="could not be opened"):
        current.open(
            "v1.abc",
            account_id=account_id,
            installation_id=installation_id,
        )
    with pytest.raises(ManagedPushTokenUnavailableError, match="key is unavailable"):
        current.open(
            previous.seal(
                "fcm-token:missing_key_1234567890",
                account_id=account_id,
                installation_id=installation_id,
            ),
            account_id=account_id,
            installation_id=installation_id,
        )


def test_managed_push_token_codec_preserves_previous_and_legacy_envelopes() -> None:
    previous_secret = "managed-push-previous-" + ("p" * 32)
    current_secret = "managed-push-current-" + ("c" * 32)
    previous = ManagedPushTokenCodec(previous_secret, write_version="v2")
    rotated = ManagedPushTokenCodec(
        current_secret,
        previous_secrets=(previous_secret,),
        write_version="v2",
    )
    account_id = uuid4()
    installation_id = "ios-key-rotation"
    token = "fcm-token:key_rotation_1234567890"
    old_v2 = previous.seal(
        token,
        account_id=account_id,
        installation_id=installation_id,
    )
    old_v1 = "v1." + old_v2.split(".", 2)[2]

    opened_v2 = rotated.open_with_rotation(
        old_v2,
        account_id=account_id,
        installation_id=installation_id,
    )
    opened_v1 = rotated.open_with_rotation(
        old_v1,
        account_id=account_id,
        installation_id=installation_id,
    )

    assert opened_v2.token == token
    assert opened_v2.needs_reseal is True
    assert opened_v1.token == token
    assert opened_v1.needs_reseal is True
    current = rotated.open_with_rotation(
        rotated.seal(
            token,
            account_id=account_id,
            installation_id=installation_id,
        ),
        account_id=account_id,
        installation_id=installation_id,
    )
    assert current.needs_reseal is False

    staged = ManagedPushTokenCodec(
        previous_secret,
        previous_secrets=(current_secret,),
        write_version="v2",
    )
    assert (
        staged.open(
            rotated.seal(
                token,
                account_id=account_id,
                installation_id=installation_id,
            ),
            account_id=account_id,
            installation_id=installation_id,
        )
        == token
    )

    without_previous = ManagedPushTokenCodec(
        current_secret,
        write_version="v2",
    )
    with pytest.raises(ManagedPushTokenUnavailableError, match="key is unavailable"):
        without_previous.open(
            old_v2,
            account_id=account_id,
            installation_id=installation_id,
        )


@pytest.mark.asyncio
async def test_unexpected_provider_failure_becomes_retryable_unavailable() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    installation_id = "ios-test-provider-failure"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        platform="ios",
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
    assert repository.completed[0]["claimed_token_hash"] == repository.token_hash


@pytest.mark.asyncio
async def test_push_key_rotation_reseals_before_delivery() -> None:
    previous_secret = "managed-push-previous-" + ("p" * 32)
    current_secret = "managed-push-current-" + ("c" * 32)
    previous = ManagedPushTokenCodec(previous_secret, write_version="v2")
    rotated = ManagedPushTokenCodec(
        current_secret,
        previous_secrets=(previous_secret,),
        write_version="v2",
    )
    account_id = uuid4()
    installation_id = "android-key-rotation"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        platform="android",
        target_kind="token",
        token_ciphertext=previous.seal(
            "fcm-token:key_rotation_1234567890",
            account_id=account_id,
            installation_id=installation_id,
        ),
    )
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=rotated,
        provider=_ConcurrentAcceptingProvider(),
    )

    await service.dispatch(principal=object(), incident_id=uuid4())

    assert len(repository.reencrypted) == 1
    replacement = repository.reencrypted[0]["replacement_ciphertext"]
    assert replacement.startswith("v2.")
    assert (
        rotated.open(
            replacement,
            account_id=account_id,
            installation_id=installation_id,
        )
        == "fcm-token:key_rotation_1234567890"
    )
    assert repository.completed[0]["outcome"] == "sent"


@pytest.mark.asyncio
async def test_unavailable_push_token_key_does_not_invalidate_registration() -> None:
    current = ManagedPushTokenCodec(
        "managed-push-current-" + ("c" * 32),
        write_version="v2",
    )
    previous = ManagedPushTokenCodec(
        "managed-push-previous-" + ("p" * 32),
        write_version="v2",
    )
    account_id = uuid4()
    installation_id = "ios-missing-key"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        platform="ios",
        target_kind="token",
        token_ciphertext=previous.seal(
            "fcm-token:missing_key_1234567890",
            account_id=account_id,
            installation_id=installation_id,
        ),
    )
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=current,
        provider=_ConcurrentAcceptingProvider(),
    )

    await service.dispatch(principal=object(), incident_id=uuid4())

    assert repository.completed[0]["outcome"] == "unavailable"
    assert repository.reencrypted == []


@pytest.mark.asyncio
@pytest.mark.parametrize("corruption_kind", ["malformed-v1", "tampered-current-v2"])
async def test_corrupt_push_token_envelope_is_terminal(
    corruption_kind: str,
) -> None:
    codec = ManagedPushTokenCodec(
        "managed-push-corrupt-" + ("x" * 32),
        write_version="v2",
    )
    account_id = uuid4()
    installation_id = f"ios-{corruption_kind}"
    if corruption_kind == "malformed-v1":
        ciphertext = "v1.abc"
    else:
        ciphertext = _tamper_envelope(
            codec.seal(
                "fcm-token:corrupt_1234567890",
                account_id=account_id,
                installation_id=installation_id,
            )
        )
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        platform="ios",
        target_kind="token",
        token_ciphertext=ciphertext,
    )
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=codec,
        provider=_ConcurrentAcceptingProvider(),
    )

    await service.dispatch(principal=object(), incident_id=uuid4())

    assert repository.completed[0]["outcome"] == "invalid"
    assert repository.completed[0]["provider_reference_hash"] is None
    assert repository.reencrypted == []


@pytest.mark.asyncio
async def test_due_push_retry_reports_only_bounded_outcomes() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    installation_id = "android-test-due-retry"
    repository = _DeliveryRepository(
        account_id=account_id,
        installation_id=installation_id,
        platform="android",
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


@pytest.mark.asyncio
async def test_due_push_dispatch_claims_only_one_concurrency_wave_at_a_time() -> None:
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    deliveries = []
    for index in range(7):
        installation_id = f"android-wave-{index}"
        deliveries.append(
            {
                "delivery_id": uuid4(),
                "claim_id": uuid4(),
                "incident_id": uuid4(),
                "account_id": account_id,
                "installation_id": installation_id,
                "platform": "android",
                "target_kind": "token",
                "token_hash": codec.token_hash(f"fcm-token:wave_{index}_1234567890"),
                "token_ciphertext": codec.seal(
                    f"fcm-token:wave_{index}_1234567890",
                    account_id=account_id,
                    installation_id=installation_id,
                ),
                "expires_at": datetime.now(UTC) + timedelta(hours=8),
                "attempt": 1,
            }
        )
    repository = _WaveDeliveryRepository(deliveries)
    provider = _ConcurrentAcceptingProvider()
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=codec,
        provider=provider,
        max_concurrency=3,
    )

    result = await service.dispatch_due(limit=7)

    assert repository.claim_limits == [3, 3, 1]
    assert provider.maximum_active == 3
    assert len(repository.completed) == 7
    assert result.claimed == 7
    assert result.provider_accepted == 7
    assert result.retryable_failures == 0
    assert result.terminal_failures == 0
    assert result.receipt_failures == 0


@pytest.mark.asyncio
async def test_initial_push_dispatch_claims_only_one_concurrency_wave_at_a_time() -> (
    None
):
    codec = ManagedPushTokenCodec("managed-push-secret-" + ("x" * 32))
    account_id = uuid4()
    deliveries = []
    for index in range(5):
        installation_id = f"ios-initial-wave-{index}"
        deliveries.append(
            {
                "delivery_id": uuid4(),
                "claim_id": uuid4(),
                "incident_id": uuid4(),
                "account_id": account_id,
                "installation_id": installation_id,
                "platform": "ios",
                "target_kind": "token",
                "token_hash": codec.token_hash(
                    f"fcm-token:initial_wave_{index}_1234567890"
                ),
                "token_ciphertext": codec.seal(
                    f"fcm-token:initial_wave_{index}_1234567890",
                    account_id=account_id,
                    installation_id=installation_id,
                ),
                "expires_at": datetime.now(UTC) + timedelta(hours=8),
                "attempt": 1,
            }
        )
    repository = _IncidentWaveDeliveryRepository(deliveries)
    provider = _ConcurrentAcceptingProvider()
    service = ManagedSafetyPushService(
        repository=repository,
        token_codec=codec,
        provider=provider,
        max_concurrency=2,
    )

    summary = await service.dispatch(
        principal=object(),
        incident_id=uuid4(),
    )

    assert repository.claim_limits == [2, 2, 2]
    assert repository.claim_exclusions == [
        set(),
        {delivery["delivery_id"] for delivery in deliveries[:2]},
        {delivery["delivery_id"] for delivery in deliveries[:4]},
    ]
    assert provider.maximum_active == 2
    assert len(repository.completed) == 5
    assert summary["installations_targeted"] == 5
    assert summary["installations_reached"] == 5


def test_managed_safety_models_are_strict_and_bounded() -> None:
    registration = ManagedPushRegistration(
        platform="ios",
        environment="production",
        target_kind="token",
        token="fcm-token:ABC_def-1234567890",
    )
    assert registration.token.get_secret_value().startswith("fcm-token:")
    legacy_registration = ManagedPushRegistration(
        platform="ios",
        environment="production",
        target_kind="fid",
        token="fcm-token:ABC_def-1234567890",
    )
    assert legacy_registration.target_kind == "fid"
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
            platform="android",
            environment="production",
            target_kind="fid",
            token="fcm-token:ABC_def-1234567890",
        )


def test_fcm_payload_contains_only_generic_notification_and_opaque_reference() -> None:
    incident_id = uuid4()
    now = datetime(2026, 9, 8, 8, 0, tzinfo=UTC)
    expires_at = now + timedelta(hours=8)
    payload = FirebaseCloudMessagingProvider.payload(
        token="fcm-token:ABC_def-1234567890",
        platform="android",
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

    ios_payload = FirebaseCloudMessagingProvider.payload(
        token="fcm-ios-token:ABC_def-1234567890",
        platform="ios",
        incident_id=incident_id,
        expires_at=expires_at,
        now=now,
    )
    assert ios_payload["message"]["token"] == "fcm-ios-token:ABC_def-1234567890"
    assert "fid" not in ios_payload["message"]
    assert "android" not in ios_payload["message"]
    assert "notification" not in ios_payload["message"]
    assert ios_payload["message"]["apns"]["payload"]["aps"]["alert"] == {
        "title-loc-key": "managed.safety.notification.title",
        "loc-key": "managed.safety.notification.body",
    }
    assert ios_payload["message"]["apns"]["headers"] == {
        "apns-collapse-id": f"noop-safety-{incident_id}",
        "apns-expiration": str(int(expires_at.timestamp())),
        "apns-priority": "10",
        "apns-push-type": "alert",
    }
    assert ios_payload["message"]["apns"]["payload"]["aps"]["sound"] == "default"
    assert (
        ios_payload["message"]["apns"]["payload"]["aps"]["interruption-level"]
        == "time-sensitive"
    )


@pytest.mark.asyncio
async def test_unavailable_provider_fails_closed_without_delivery_claim() -> None:
    provider = UnavailableManagedPushProvider()
    assert provider.available is False
    result = await provider.send_safety_incident(
        token="fcm-token:ABC_def-1234567890",
        platform="android",
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
        platform="android",
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
        platform="android",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "invalid"


@pytest.mark.asyncio
async def test_fcm_provider_does_not_invalidate_ios_token_from_bare_404() -> None:
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
        token="fcm-ios-token:ABC_def-1234567890",
        platform="ios",
        target_kind="fid",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "rejected"


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
        platform="android",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )
    assert result.outcome == "rejected"


@pytest.mark.asyncio
async def test_fcm_provider_refreshes_cached_token_once_after_401() -> None:
    requests: list[tuple[str, str | None]] = []
    metadata_tokens = iter(("stale-access-token", "fresh-access-token"))

    def opener(request, timeout):
        del timeout
        if request.full_url.startswith("http://metadata."):
            token = next(metadata_tokens)
            requests.append(("metadata", token))
            return _Response({"access_token": token, "expires_in": 3600})
        authorization = request.get_header("Authorization")
        requests.append(("send", authorization))
        if authorization == "Bearer stale-access-token":
            raise HTTPError(
                request.full_url,
                401,
                "unauthorized",
                {},
                io.BytesIO(b'{"error":{"status":"UNAUTHENTICATED"}}'),
            )
        assert authorization == "Bearer fresh-access-token"
        return _Response({"name": "projects/test/messages/refreshed"})

    provider = FirebaseCloudMessagingProvider(
        project_id="noop-test-project",
        opener=opener,
    )
    result = await provider.send_safety_incident(
        token="fcm-ios-token:ABC_def-1234567890",
        platform="ios",
        target_kind="token",
        incident_id=uuid4(),
        expires_at=datetime.now(UTC) + timedelta(hours=8),
    )

    assert result.outcome == "sent"
    assert requests == [
        ("metadata", "stale-access-token"),
        ("send", "Bearer stale-access-token"),
        ("metadata", "fresh-access-token"),
        ("send", "Bearer fresh-access-token"),
    ]
