from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import math
import os
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal, Protocol
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import UUID

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PUSH_TOKEN_CONTEXT = b"noop-managed-push-token-v1"
METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/service-accounts/default/token"
)


class ManagedPushError(Exception):
    pass


class ManagedPushTokenError(ManagedPushError):
    pass


@dataclass(frozen=True, slots=True)
class ManagedPushResult:
    outcome: Literal[
        "sent",
        "invalid",
        "transient_failure",
        "unavailable",
        "rejected",
    ]
    provider_reference_hash: str | None = None


class ManagedPushSending(Protocol):
    @property
    def available(self) -> bool: ...

    async def send_safety_incident(
        self,
        *,
        token: str,
        platform: Literal["ios", "android"],
        target_kind: Literal["token", "fid"],
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult: ...


class ManagedPushTokenCodec:
    def __init__(self, secret: str) -> None:
        if len(secret.encode("utf-8")) < 32:
            raise ValueError("managed push token secret must be at least 32 bytes")
        self._key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=PUSH_TOKEN_CONTEXT,
        ).derive(secret.encode("utf-8"))

    @staticmethod
    def token_hash(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    @staticmethod
    def _aad(account_id: UUID, installation_id: str) -> bytes:
        return f"{account_id}:{installation_id}".encode("utf-8")

    def seal(
        self,
        token: str,
        *,
        account_id: UUID,
        installation_id: str,
    ) -> str:
        nonce = os.urandom(12)
        ciphertext = AESGCM(self._key).encrypt(
            nonce,
            token.encode("utf-8"),
            self._aad(account_id, installation_id),
        )
        encoded = base64.urlsafe_b64encode(nonce + ciphertext).decode("ascii")
        return "v1." + encoded.rstrip("=")

    def open(
        self,
        sealed: str,
        *,
        account_id: UUID,
        installation_id: str,
    ) -> str:
        if not sealed.startswith("v1."):
            raise ManagedPushTokenError("push token envelope is unsupported")
        raw = sealed.removeprefix("v1.")
        try:
            decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
            if len(decoded) < 29:
                raise ValueError("short envelope")
            plaintext = AESGCM(self._key).decrypt(
                decoded[:12],
                decoded[12:],
                self._aad(account_id, installation_id),
            )
            return plaintext.decode("utf-8")
        except (InvalidTag, ValueError, UnicodeDecodeError) as exc:
            raise ManagedPushTokenError(
                "push token envelope could not be opened"
            ) from exc


class UnavailableManagedPushProvider:
    @property
    def available(self) -> bool:
        return False

    async def send_safety_incident(
        self,
        *,
        token: str,
        platform: Literal["ios", "android"],
        target_kind: Literal["token", "fid"],
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        del token, platform, target_kind, incident_id, expires_at
        return ManagedPushResult(outcome="unavailable")


class FirebaseCloudMessagingProvider:
    def __init__(
        self,
        *,
        project_id: str,
        timeout_seconds: int = 5,
        token_url: str = METADATA_TOKEN_URL,
        opener: Any = urlopen,
    ) -> None:
        if not project_id:
            raise ValueError("FCM project id is required")
        if not 1 <= timeout_seconds <= 30:
            raise ValueError("FCM timeout must be between 1 and 30 seconds")
        self.project_id = project_id
        self.timeout_seconds = timeout_seconds
        self.token_url = token_url
        self._opener = opener
        self._access_token: str | None = None
        self._access_token_expires_at = 0.0
        self._token_lock = asyncio.Lock()

    @property
    def available(self) -> bool:
        return True

    @staticmethod
    def payload(
        *,
        token: str,
        platform: Literal["ios", "android"],
        incident_id: UUID,
        expires_at: datetime,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        if platform not in {"ios", "android"}:
            raise ValueError("push platform is unsupported")
        if expires_at.tzinfo is None or expires_at.utcoffset() is None:
            raise ValueError("push expiry must include a UTC offset")
        current = now or datetime.now(UTC)
        if current.tzinfo is None or current.utcoffset() is None:
            raise ValueError("push clock must include a UTC offset")
        expiry_value = expires_at.astimezone(UTC)
        current_value = current.astimezone(UTC)
        remaining_seconds = max(
            1,
            math.ceil((expiry_value - current_value).total_seconds()),
        )
        expiry = expiry_value.isoformat().replace("+00:00", "Z")
        collapse_id = f"noop-safety-{incident_id}"
        message: dict[str, Any] = {
            "token": token,
            "data": {
                "kind": "managed_safety_incident",
                "incident_id": str(incident_id),
                "expires_at": expiry,
                "route": "safety",
                "schema": "1",
            },
        }
        if platform == "android":
            # Android receives data-only high-priority delivery so
            # FirebaseMessagingService always creates the incident-specific
            # immutable PendingIntent, including while the app is backgrounded.
            message["android"] = {
                "priority": "HIGH",
                "ttl": f"{remaining_seconds}s",
            }
        else:
            # FCM routes the registration token through APNs. APNs shows the
            # private generic alert while the app fetches incident details only
            # after authenticated entry.
            message["apns"] = {
                "headers": {
                    "apns-collapse-id": collapse_id,
                    "apns-expiration": str(int(expiry_value.timestamp())),
                    "apns-priority": "10",
                    "apns-push-type": "alert",
                },
                "payload": {
                    "aps": {
                        "alert": {
                            "title-loc-key": "managed.safety.notification.title",
                            "loc-key": "managed.safety.notification.body",
                        },
                        "content-available": 1,
                        "interruption-level": "time-sensitive",
                        "sound": "default",
                    }
                },
            }
        return {"message": message}

    async def _metadata_access_token(self) -> str:
        now = time.monotonic()
        if self._access_token is not None and now < self._access_token_expires_at - 60:
            return self._access_token
        async with self._token_lock:
            now = time.monotonic()
            if (
                self._access_token is not None
                and now < self._access_token_expires_at - 60
            ):
                return self._access_token
            token, expires_in = await asyncio.to_thread(self._read_metadata_token)
            self._access_token = token
            self._access_token_expires_at = now + expires_in
            return token

    async def _invalidate_access_token(self, rejected_token: str) -> None:
        async with self._token_lock:
            if self._access_token == rejected_token:
                self._access_token = None
                self._access_token_expires_at = 0.0

    def _read_metadata_token(self) -> tuple[str, int]:
        request = Request(
            self.token_url,
            headers={"Metadata-Flavor": "Google"},
            method="GET",
        )
        try:
            with self._opener(request, timeout=self.timeout_seconds) as response:
                value = json.loads(response.read(64 * 1024))
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
            raise ManagedPushError("metadata token could not be acquired") from exc
        token = value.get("access_token")
        expires_in = value.get("expires_in")
        if (
            not isinstance(token, str)
            or not token
            or not isinstance(expires_in, int)
            or expires_in <= 0
        ):
            raise ManagedPushError("metadata token response was invalid")
        return token, expires_in

    async def send_safety_incident(
        self,
        *,
        token: str,
        platform: Literal["ios", "android"],
        target_kind: Literal["token", "fid"],
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        if expires_at <= datetime.now(UTC):
            return ManagedPushResult(outcome="rejected")
        if platform == "android" and target_kind != "token":
            return ManagedPushResult(outcome="rejected")
        try:
            for attempt in range(2):
                access_token = await self._metadata_access_token()
                try:
                    return await asyncio.to_thread(
                        self._send,
                        access_token,
                        token,
                        platform,
                        incident_id,
                        expires_at,
                    )
                except HTTPError as error:
                    if error.code != 401:
                        raise
                    await self._invalidate_access_token(access_token)
                    if attempt == 1:
                        raise
            raise AssertionError("unreachable")
        except (
            ManagedPushError,
            HTTPError,
            URLError,
            TimeoutError,
            OSError,
            ValueError,
        ):
            return ManagedPushResult(outcome="unavailable")

    def _send(
        self,
        access_token: str,
        token: str,
        platform: Literal["ios", "android"],
        incident_id: UUID,
        expires_at: datetime,
    ) -> ManagedPushResult:
        endpoint = (
            f"https://fcm.googleapis.com/v1/projects/{self.project_id}/messages:send"
        )
        body = json.dumps(
            self.payload(
                token=token,
                platform=platform,
                incident_id=incident_id,
                expires_at=expires_at,
            ),
            separators=(",", ":"),
        ).encode("utf-8")
        request = Request(
            endpoint,
            data=body,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with self._opener(request, timeout=self.timeout_seconds) as response:
                value = json.loads(response.read(64 * 1024))
            name = value.get("name")
            if not isinstance(name, str) or not name:
                return ManagedPushResult(outcome="rejected")
            return ManagedPushResult(
                outcome="sent",
                provider_reference_hash=hashlib.sha256(
                    name.encode("utf-8")
                ).hexdigest(),
            )
        except HTTPError as error:
            if error.code == 401:
                raise
            provider_code = self._provider_error_code(error)
            if provider_code in {"UNREGISTERED", "SENDER_ID_MISMATCH"}:
                return ManagedPushResult(outcome="invalid")
            if error.code == 429 or 500 <= error.code <= 599:
                return ManagedPushResult(outcome="transient_failure")
            if error.code == 403:
                return ManagedPushResult(outcome="unavailable")
            return ManagedPushResult(outcome="rejected")

    @staticmethod
    def _provider_error_code(error: HTTPError) -> str | None:
        try:
            value = json.loads(error.read(64 * 1024))
        except (OSError, ValueError):
            return None
        details = value.get("error", {}).get("details", [])
        if not isinstance(details, list):
            return None
        for detail in details:
            if not isinstance(detail, dict):
                continue
            code = detail.get("errorCode")
            if isinstance(code, str):
                return code
        return None
