from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

import jwt
from jwt import PyJWKClient
from jwt.exceptions import (
    InvalidTokenError,
    PyJWKClientConnectionError,
    PyJWKClientError,
    PyJWKError,
    PyJWKSetError,
)


class ManagedAppCheckError(Exception):
    """Base class for managed client-attestation failures."""


class ManagedAppCheckRejectedError(ManagedAppCheckError):
    """The supplied App Check token is missing, invalid, or from another app."""


class ManagedAppCheckUnavailableError(ManagedAppCheckError):
    """The App Check key service could not be reached or returned invalid keys."""


@dataclass(frozen=True, slots=True)
class ManagedAppCheckClaims:
    app_id: str
    issuer: str
    audience: tuple[str, ...]
    issued_at: datetime
    expires_at: datetime


class ManagedAppCheckVerifying(Protocol):
    async def verify(self, token: str) -> ManagedAppCheckClaims: ...


class StaticManagedAppCheckVerifier:
    """Test verifier that never parses or accepts an unlisted token."""

    def __init__(self, tokens: dict[str, ManagedAppCheckClaims]) -> None:
        self._tokens = dict(tokens)

    async def verify(self, token: str) -> ManagedAppCheckClaims:
        claims = self._tokens.get(token)
        if claims is None or claims.expires_at <= datetime.now(UTC):
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        return claims


class FirebaseAppCheckTokenVerifier:
    """Verify Firebase App Check JWTs against Google's rotating JWKS.

    App Check proves that a request came through a registered NOOP client. It
    supplements, rather than replaces, Firebase user authentication and tenant
    authorization.
    """

    def __init__(
        self,
        *,
        project_number: str,
        allowed_app_ids: frozenset[str],
        jwks_cache_seconds: int = 6 * 60 * 60,
        timeout_seconds: float = 10,
        jwks_url: str = "https://firebaseappcheck.googleapis.com/v1/jwks",
        jwk_client: Any | None = None,
    ) -> None:
        self.project_number = project_number
        self.allowed_app_ids = allowed_app_ids
        self.issuer = f"https://firebaseappcheck.googleapis.com/{project_number}"
        self.audience = f"projects/{project_number}"
        self._jwk_client = jwk_client or PyJWKClient(
            jwks_url,
            cache_keys=True,
            max_cached_keys=16,
            cache_jwk_set=True,
            lifespan=float(jwks_cache_seconds),
            timeout=timeout_seconds,
        )

    async def verify(self, token: str) -> ManagedAppCheckClaims:
        if not 64 <= len(token) <= 8192 or not token.isascii() or token.count(".") != 2:
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        try:
            return await asyncio.to_thread(self._verify_sync, token)
        except PyJWKClientConnectionError:
            raise ManagedAppCheckUnavailableError(
                "managed app verification is unavailable"
            ) from None
        except (PyJWKSetError, PyJWKError):
            raise ManagedAppCheckUnavailableError(
                "managed app verification returned invalid keys"
            ) from None
        except PyJWKClientError:
            # A well-formed token with an unknown key ID is an untrusted token,
            # not a service outage. PyJWKClientConnectionError was handled above.
            raise ManagedAppCheckRejectedError(
                "managed app assertion was rejected"
            ) from None
        except InvalidTokenError:
            raise ManagedAppCheckRejectedError(
                "managed app assertion was rejected"
            ) from None
        except (TypeError, ValueError, OverflowError):
            raise ManagedAppCheckRejectedError(
                "managed app assertion was rejected"
            ) from None

    def _verify_sync(self, token: str) -> ManagedAppCheckClaims:
        header = jwt.get_unverified_header(token)
        if (
            header.get("alg") != "RS256"
            or header.get("typ") != "JWT"
            or not isinstance(header.get("kid"), str)
            or not 1 <= len(header["kid"]) <= 256
        ):
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        signing_key = self._jwk_client.get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=self.audience,
            issuer=self.issuer,
            leeway=30,
            options={
                "require": ["aud", "exp", "iat", "iss", "sub"],
                "verify_signature": True,
                "verify_aud": True,
                "verify_exp": True,
                "verify_iat": True,
                "verify_iss": True,
            },
        )
        app_id = payload.get("sub")
        if not isinstance(app_id, str) or app_id not in self.allowed_app_ids:
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        audience_raw = payload.get("aud")
        if isinstance(audience_raw, str):
            audience = (audience_raw,)
        elif (
            isinstance(audience_raw, list)
            and audience_raw
            and all(isinstance(value, str) for value in audience_raw)
        ):
            audience = tuple(audience_raw)
        else:
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        issued_at = self._claim_time(payload, "iat")
        expires_at = self._claim_time(payload, "exp")
        if expires_at <= issued_at:
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        return ManagedAppCheckClaims(
            app_id=app_id,
            issuer=self.issuer,
            audience=audience,
            issued_at=issued_at,
            expires_at=expires_at,
        )

    @staticmethod
    def _claim_time(payload: dict[str, Any], name: str) -> datetime:
        value = payload.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ManagedAppCheckRejectedError("managed app assertion was rejected")
        try:
            return datetime.fromtimestamp(value, UTC)
        except (ValueError, OSError, OverflowError):
            raise ManagedAppCheckRejectedError(
                "managed app assertion was rejected"
            ) from None
