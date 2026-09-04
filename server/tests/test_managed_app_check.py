from __future__ import annotations

from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.exceptions import PyJWKClientConnectionError

from app.managed_app_check import (
    FirebaseAppCheckTokenVerifier,
    ManagedAppCheckRejectedError,
    ManagedAppCheckUnavailableError,
)

PROJECT_NUMBER = "123456789012"
APPLE_APP_ID = f"1:{PROJECT_NUMBER}:ios:0123456789abcdef"
ANDROID_APP_ID = f"1:{PROJECT_NUMBER}:android:fedcba9876543210"


class StubJWKClient:
    def __init__(self, key: jwt.PyJWK | Exception) -> None:
        self.key = key

    def get_signing_key_from_jwt(self, token: str) -> jwt.PyJWK:
        del token
        if isinstance(self.key, Exception):
            raise self.key
        return self.key


def _keys() -> tuple[object, jwt.PyJWK]:
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )
    public_jwk = jwt.algorithms.RSAAlgorithm.to_jwk(
        private_key.public_key(),
        as_dict=True,
    )
    public_jwk.update({"kid": "test-key", "alg": "RS256", "use": "sig"})
    return private_key, jwt.PyJWK.from_dict(public_jwk)


def _token(
    private_key: object,
    *,
    app_id: str = APPLE_APP_ID,
    project_number: str = PROJECT_NUMBER,
    expires_in: timedelta = timedelta(minutes=5),
) -> str:
    now = datetime.now(UTC)
    return jwt.encode(
        {
            "aud": [f"projects/{project_number}"],
            "iss": (f"https://firebaseappcheck.googleapis.com/{project_number}"),
            "sub": app_id,
            "iat": int((now - timedelta(seconds=1)).timestamp()),
            "exp": int((now + expires_in).timestamp()),
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


@pytest.mark.asyncio
async def test_app_check_verifier_accepts_only_registered_project_app() -> None:
    private_key, public_key = _keys()
    verifier = FirebaseAppCheckTokenVerifier(
        project_number=PROJECT_NUMBER,
        allowed_app_ids=frozenset({APPLE_APP_ID, ANDROID_APP_ID}),
        jwk_client=StubJWKClient(public_key),
    )

    claims = await verifier.verify(_token(private_key))

    assert claims.app_id == APPLE_APP_ID
    assert claims.issuer.endswith(PROJECT_NUMBER)
    assert claims.audience == (f"projects/{PROJECT_NUMBER}",)
    assert claims.expires_at > claims.issued_at


@pytest.mark.asyncio
async def test_app_check_verifier_rejects_other_app_and_project() -> None:
    private_key, public_key = _keys()
    verifier = FirebaseAppCheckTokenVerifier(
        project_number=PROJECT_NUMBER,
        allowed_app_ids=frozenset({APPLE_APP_ID, ANDROID_APP_ID}),
        jwk_client=StubJWKClient(public_key),
    )

    with pytest.raises(ManagedAppCheckRejectedError):
        await verifier.verify(
            _token(
                private_key,
                app_id=f"1:{PROJECT_NUMBER}:ios:unregistered",
            )
        )
    with pytest.raises(ManagedAppCheckRejectedError):
        await verifier.verify(_token(private_key, project_number="999999999999"))


@pytest.mark.asyncio
async def test_app_check_verifier_rejects_expired_and_bad_signature() -> None:
    private_key, public_key = _keys()
    other_private_key, _ = _keys()
    verifier = FirebaseAppCheckTokenVerifier(
        project_number=PROJECT_NUMBER,
        allowed_app_ids=frozenset({APPLE_APP_ID}),
        jwk_client=StubJWKClient(public_key),
    )

    with pytest.raises(ManagedAppCheckRejectedError):
        await verifier.verify(_token(private_key, expires_in=timedelta(minutes=-1)))
    with pytest.raises(ManagedAppCheckRejectedError):
        await verifier.verify(_token(other_private_key))


@pytest.mark.asyncio
async def test_app_check_key_fetch_outage_is_retryable() -> None:
    private_key, _ = _keys()
    verifier = FirebaseAppCheckTokenVerifier(
        project_number=PROJECT_NUMBER,
        allowed_app_ids=frozenset({APPLE_APP_ID}),
        jwk_client=StubJWKClient(
            PyJWKClientConnectionError("temporary network failure")
        ),
    )

    with pytest.raises(ManagedAppCheckUnavailableError):
        await verifier.verify(_token(private_key))
