from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Protocol
from uuid import UUID

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


class ManagedIdentityDeletionError(Exception):
    """Identity deletion could not be completed and must be retried."""


class ManagedIdentityDeletionTicketError(ManagedIdentityDeletionError):
    """An encrypted deletion ticket is invalid or cannot be opened."""


class ManagedIdentityDeleting(Protocol):
    async def delete(
        self,
        *,
        ticket: bytes,
        account_id: UUID,
        request_id: UUID,
    ) -> None: ...


@dataclass(frozen=True, slots=True)
class ManagedIdentityDeletionSubject:
    local_id: str
    provider_tenant: str


class ManagedIdentityDeletionTicketCodec:
    """Seal a short-lived Firebase UID for delayed account deletion.

    The database otherwise retains only a one-way subject digest. Account
    deletion has a cooling-off period, so the lifecycle worker needs a
    reversible provider identifier after the authenticated request has ended.
    Tickets are AEAD-bound to the NOOP account and erasure request and are
    cleared when the request is canceled or completed.
    """

    VERSION = 1
    NONCE_BYTES = 12
    CONTEXT = b"noop-managed-identity-deletion-ticket-v1"

    def __init__(
        self,
        secret: str,
        *,
        random_bytes: Callable[[int], bytes] | None = None,
    ) -> None:
        material = secret.encode("utf-8")
        if len(material) < 32:
            raise ValueError(
                "identity deletion ticket secret must be at least 32 bytes"
            )
        self._key = hmac.new(material, self.CONTEXT, hashlib.sha256).digest()
        self._random_bytes = random_bytes or os.urandom

    def seal(
        self,
        *,
        local_id: str,
        provider_tenant: str,
        account_id: UUID,
        request_id: UUID,
    ) -> bytes:
        self._validate_subject(local_id, provider_tenant)
        payload = json.dumps(
            {
                "local_id": local_id,
                "provider_tenant": provider_tenant,
                "version": self.VERSION,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        nonce = self._random_bytes(self.NONCE_BYTES)
        if len(nonce) != self.NONCE_BYTES:
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket nonce generation failed"
            )
        ciphertext = AESGCM(self._key).encrypt(
            nonce,
            payload,
            self._associated_data(account_id, request_id),
        )
        return bytes((self.VERSION,)) + nonce + ciphertext

    def open(
        self,
        *,
        ticket: bytes,
        account_id: UUID,
        request_id: UUID,
    ) -> ManagedIdentityDeletionSubject:
        minimum_length = 1 + self.NONCE_BYTES + 16
        if (
            not isinstance(ticket, bytes)
            or not minimum_length <= len(ticket) <= 1_024
            or ticket[0] != self.VERSION
        ):
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket is invalid"
            )
        nonce = ticket[1 : 1 + self.NONCE_BYTES]
        ciphertext = ticket[1 + self.NONCE_BYTES :]
        try:
            plaintext = AESGCM(self._key).decrypt(
                nonce,
                ciphertext,
                self._associated_data(account_id, request_id),
            )
            payload = json.loads(plaintext.decode("utf-8"))
        except (InvalidTag, UnicodeDecodeError, ValueError, json.JSONDecodeError):
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket is invalid"
            ) from None
        if not isinstance(payload, dict) or payload.get("version") != self.VERSION:
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket is invalid"
            )
        local_id = payload.get("local_id")
        provider_tenant = payload.get("provider_tenant")
        if not isinstance(local_id, str) or not isinstance(provider_tenant, str):
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket is invalid"
            )
        try:
            self._validate_subject(local_id, provider_tenant)
        except ValueError:
            raise ManagedIdentityDeletionTicketError(
                "identity deletion ticket is invalid"
            ) from None
        return ManagedIdentityDeletionSubject(
            local_id=local_id,
            provider_tenant=provider_tenant,
        )

    @classmethod
    def _associated_data(cls, account_id: UUID, request_id: UUID) -> bytes:
        return cls.CONTEXT + b":" + account_id.bytes + b":" + request_id.bytes

    @staticmethod
    def _validate_subject(local_id: str, provider_tenant: str) -> None:
        if (
            not 1 <= len(local_id) <= 128
            or not local_id.isascii()
            or any(character.isspace() for character in local_id)
        ):
            raise ValueError("identity local ID is invalid")
        if (
            len(provider_tenant) > 128
            or not provider_tenant.isascii()
            or any(
                character.isspace() or character == "/" for character in provider_tenant
            )
        ):
            raise ValueError("identity provider tenant is invalid")


class IdentityToolkitAccountDeleter:
    """Delete one Firebase Auth user with the Cloud Run service identity."""

    def __init__(
        self,
        *,
        project_id: str,
        ticket_codec: ManagedIdentityDeletionTicketCodec,
        timeout_seconds: float = 10,
        metadata_token_url: str = (
            "http://metadata.google.internal/computeMetadata/v1/"
            "instance/service-accounts/default/token"
        ),
        endpoint_base: str = "https://identitytoolkit.googleapis.com/v1/projects",
        monotonic_clock: Callable[[], float] | None = None,
    ) -> None:
        if not project_id:
            raise ValueError("identity deletion project ID is required")
        self.project_id = project_id
        self.ticket_codec = ticket_codec
        self.timeout_seconds = timeout_seconds
        self.metadata_token_url = metadata_token_url
        self.endpoint_base = endpoint_base.rstrip("/")
        self.monotonic_clock = monotonic_clock or time.monotonic
        self._token: str | None = None
        self._token_expires_at = 0.0
        self._token_lock = threading.Lock()

    async def delete(
        self,
        *,
        ticket: bytes,
        account_id: UUID,
        request_id: UUID,
    ) -> None:
        subject = self.ticket_codec.open(
            ticket=ticket,
            account_id=account_id,
            request_id=request_id,
        )
        await asyncio.to_thread(self._delete, subject)

    def _delete(self, subject: ManagedIdentityDeletionSubject) -> None:
        project = urllib.parse.quote(self.project_id, safe="")
        endpoint = f"{self.endpoint_base}/{project}"
        body: dict[str, str] = {
            "localId": subject.local_id,
            "targetProjectId": self.project_id,
        }
        if subject.provider_tenant:
            tenant = urllib.parse.quote(subject.provider_tenant, safe="")
            endpoint += f"/tenants/{tenant}"
            body["tenantId"] = subject.provider_tenant
        endpoint += "/accounts:delete"
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self._access_token()}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "NOOP-managed-identity-deleter/1",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                if not 200 <= response.status < 300:
                    raise ManagedIdentityDeletionError(
                        "identity deletion returned an invalid status"
                    )
        except urllib.error.HTTPError as error:
            if self._is_already_deleted(error):
                return
            raise ManagedIdentityDeletionError(
                "identity deletion is temporarily unavailable"
            ) from None
        except ManagedIdentityDeletionError:
            raise
        except (OSError, TimeoutError, ValueError):
            raise ManagedIdentityDeletionError(
                "identity deletion is temporarily unavailable"
            ) from None

    @staticmethod
    def _is_already_deleted(error: urllib.error.HTTPError) -> bool:
        if error.code == 404:
            return True
        try:
            raw = error.read(16_384)
            payload: Any = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
            return False
        message = ""
        if isinstance(payload, dict):
            detail = payload.get("error")
            if isinstance(detail, dict):
                candidate = detail.get("message")
                if isinstance(candidate, str):
                    message = candidate
            elif isinstance(detail, str):
                message = detail
        normalized = message.upper().replace("-", "_")
        return "USER_NOT_FOUND" in normalized or "LOCAL_ID_NOT_FOUND" in normalized

    def _access_token(self) -> str:
        with self._token_lock:
            now = self.monotonic_clock()
            if self._token is not None and self._token_expires_at > now + 60:
                return self._token
            request = urllib.request.Request(
                self.metadata_token_url,
                headers={
                    "Metadata-Flavor": "Google",
                    "Accept": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(
                    request,
                    timeout=self.timeout_seconds,
                ) as response:
                    payload = json.load(response)
                token = payload.get("access_token")
                expires_in = int(payload.get("expires_in", 0))
            except (
                OSError,
                TimeoutError,
                TypeError,
                ValueError,
                json.JSONDecodeError,
                urllib.error.HTTPError,
            ):
                raise ManagedIdentityDeletionError(
                    "identity deletion credentials are unavailable"
                ) from None
            if not isinstance(token, str) or not token or expires_in <= 0:
                raise ManagedIdentityDeletionError(
                    "identity deletion credentials returned an invalid response"
                )
            self._token = token
            self._token_expires_at = now + expires_in
            return token
