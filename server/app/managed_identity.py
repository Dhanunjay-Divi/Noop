from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Callable, Protocol


class ManagedIdentityError(Exception):
    """Base class for managed identity verification failures."""


class ManagedIdentityRejectedError(ManagedIdentityError):
    """The supplied token is invalid, expired, disabled, or revoked."""


class ManagedIdentityUnavailableError(ManagedIdentityError):
    """Identity Platform could not be reached or returned an invalid response."""


@dataclass(frozen=True, slots=True)
class ManagedIdentityClaims:
    issuer: str
    subject: str
    provider_tenant: str
    issued_at: datetime
    auth_time: datetime
    expires_at: datetime

    @property
    def subject_hash(self) -> str:
        return hashlib.sha256(self.subject.encode("utf-8")).hexdigest()


class ManagedTokenVerifying(Protocol):
    async def verify(
        self,
        token: str,
        *,
        app_check_token: str = "",
    ) -> ManagedIdentityClaims: ...


class StaticManagedTokenVerifier:
    """Test and private-pilot verifier with no production token parsing."""

    def __init__(self, tokens: dict[str, ManagedIdentityClaims]) -> None:
        self._tokens = dict(tokens)

    async def verify(
        self,
        token: str,
        *,
        app_check_token: str = "",
    ) -> ManagedIdentityClaims:
        del app_check_token
        claims = self._tokens.get(token)
        if claims is None or claims.expires_at <= datetime.now(UTC):
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        return claims


class IdentityToolkitTokenVerifier:
    """Validate Firebase ID tokens through Identity Toolkit, then cache briefly.

    The lookup endpoint performs Google's signature, expiry, user-disablement,
    and refresh-token revocation checks. JWT claims are decoded only after that
    authenticated lookup and are constrained to this exact project and issuer.
    No phone number, email address, or plaintext token enters application logs
    or PostgreSQL.
    """

    def __init__(
        self,
        *,
        project_id: str,
        api_key: str,
        cache_seconds: int = 300,
        cache_entries: int = 10_000,
        timeout_seconds: float = 10,
        endpoint: str = "https://identitytoolkit.googleapis.com/v1/accounts:lookup",
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.project_id = project_id
        self.api_key = api_key
        self.cache_seconds = cache_seconds
        self.cache_entries = cache_entries
        self.timeout_seconds = timeout_seconds
        self.endpoint = endpoint
        self.clock = clock or (lambda: datetime.now(UTC))
        self._cache: OrderedDict[str, tuple[ManagedIdentityClaims, float]] = (
            OrderedDict()
        )
        self._lock = asyncio.Lock()

    async def verify(
        self,
        token: str,
        *,
        app_check_token: str = "",
    ) -> ManagedIdentityClaims:
        if not 64 <= len(token) <= 8192 or not token.isascii() or token.count(".") != 2:
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
        now_monotonic = time.monotonic()
        async with self._lock:
            cached = self._cache.get(token_hash)
            if cached is not None:
                claims, valid_until = cached
                if valid_until > now_monotonic and claims.expires_at > self.clock():
                    self._cache.move_to_end(token_hash)
                    return claims
                del self._cache[token_hash]

        response = await asyncio.to_thread(
            self._lookup,
            token,
            app_check_token,
        )
        claims = self._validated_claims(token, response)
        remaining = max((claims.expires_at - self.clock()).total_seconds(), 0)
        cache_for = min(float(self.cache_seconds), remaining)
        if cache_for > 0:
            async with self._lock:
                self._cache[token_hash] = (claims, time.monotonic() + cache_for)
                self._cache.move_to_end(token_hash)
                while len(self._cache) > self.cache_entries:
                    self._cache.popitem(last=False)
        return claims

    def _lookup(
        self,
        token: str,
        app_check_token: str = "",
    ) -> dict[str, Any]:
        query = urllib.parse.urlencode({"key": self.api_key})
        request = urllib.request.Request(
            f"{self.endpoint}?{query}",
            data=json.dumps(
                {"idToken": token},
                separators=(",", ":"),
            ).encode("utf-8"),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "NOOP-managed-identity/1",
                **({"X-Firebase-AppCheck": app_check_token} if app_check_token else {}),
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            if 400 <= error.code < 500:
                raise ManagedIdentityRejectedError(
                    "managed identity token was rejected"
                ) from None
            raise ManagedIdentityUnavailableError(
                "managed identity verification is unavailable"
            ) from None
        except (OSError, TimeoutError, ValueError, json.JSONDecodeError):
            raise ManagedIdentityUnavailableError(
                "managed identity verification is unavailable"
            ) from None
        if not isinstance(payload, dict):
            raise ManagedIdentityUnavailableError(
                "managed identity verification returned an invalid response"
            )
        return payload

    def _validated_claims(
        self,
        token: str,
        response: dict[str, Any],
    ) -> ManagedIdentityClaims:
        users = response.get("users")
        if not isinstance(users, list) or len(users) != 1:
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        user = users[0]
        if not isinstance(user, dict) or user.get("disabled") is True:
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        local_id = user.get("localId")
        if not isinstance(local_id, str) or not local_id:
            raise ManagedIdentityUnavailableError(
                "managed identity verification returned an invalid response"
            )

        try:
            encoded_payload = token.split(".", 2)[1]
            padded = encoded_payload + "=" * (-len(encoded_payload) % 4)
            payload = json.loads(
                base64.urlsafe_b64decode(padded.encode("ascii")).decode("utf-8")
            )
        except (
            UnicodeDecodeError,
            ValueError,
            json.JSONDecodeError,
        ):
            raise ManagedIdentityRejectedError(
                "managed identity token was rejected"
            ) from None
        if not isinstance(payload, dict):
            raise ManagedIdentityRejectedError("managed identity token was rejected")

        expected_issuer = f"https://securetoken.google.com/{self.project_id}"
        subject = payload.get("sub")
        if (
            payload.get("aud") != self.project_id
            or payload.get("iss") != expected_issuer
            or subject != local_id
            or not isinstance(subject, str)
            or not 1 <= len(subject) <= 128
        ):
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        issued_at = self._claim_time(payload, "iat")
        auth_time = self._claim_time(payload, "auth_time")
        expires_at = self._claim_time(payload, "exp")
        now = self.clock()
        if expires_at <= now or issued_at > now or auth_time > issued_at:
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        valid_since_raw = user.get("validSince")
        if valid_since_raw is not None:
            try:
                valid_since = datetime.fromtimestamp(int(valid_since_raw), UTC)
            except (TypeError, ValueError, OSError):
                raise ManagedIdentityUnavailableError(
                    "managed identity verification returned an invalid response"
                ) from None
            if auth_time < valid_since:
                raise ManagedIdentityRejectedError(
                    "managed identity token was rejected"
                )
        firebase = payload.get("firebase")
        tenant = ""
        if isinstance(firebase, dict):
            candidate = firebase.get("tenant")
            if candidate is not None:
                if not isinstance(candidate, str) or not candidate:
                    raise ManagedIdentityRejectedError(
                        "managed identity token was rejected"
                    )
                tenant = candidate
        return ManagedIdentityClaims(
            issuer=expected_issuer,
            subject=subject,
            provider_tenant=tenant,
            issued_at=issued_at,
            auth_time=auth_time,
            expires_at=expires_at,
        )

    @staticmethod
    def _claim_time(payload: dict[str, Any], name: str) -> datetime:
        value = payload.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ManagedIdentityRejectedError("managed identity token was rejected")
        try:
            return datetime.fromtimestamp(value, UTC)
        except (ValueError, OSError, OverflowError):
            raise ManagedIdentityRejectedError(
                "managed identity token was rejected"
            ) from None
