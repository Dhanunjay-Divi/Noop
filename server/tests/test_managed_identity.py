from __future__ import annotations

import base64
import json
from datetime import UTC, datetime, timedelta

import pytest

from app.managed_identity import (
    IdentityToolkitTokenVerifier,
    ManagedIdentityRejectedError,
)


def _part(value: dict) -> str:
    encoded = base64.urlsafe_b64encode(
        json.dumps(value, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    return encoded.rstrip("=")


def _token(
    *,
    project: str,
    subject: str,
    now: datetime,
    sign_in_provider: str = "password",
) -> str:
    return ".".join(
        (
            _part({"alg": "RS256", "typ": "JWT"}),
            _part(
                {
                    "aud": project,
                    "iss": f"https://securetoken.google.com/{project}",
                    "sub": subject,
                    "iat": int(now.timestamp()),
                    "auth_time": int((now - timedelta(minutes=1)).timestamp()),
                    "exp": int((now + timedelta(hours=1)).timestamp()),
                    "firebase": {
                        "tenant": "noop-staging",
                        "sign_in_provider": sign_in_provider,
                    },
                }
            ),
            "signature-placeholder",
        )
    )


class StubIdentityVerifier(IdentityToolkitTokenVerifier):
    def __init__(self, *, response: dict, now: datetime) -> None:
        super().__init__(
            project_id="noop-test-project",
            api_key="test-api-key",
            clock=lambda: now,
        )
        self.response = response
        self.lookups = 0
        self.app_check_tokens: list[str] = []

    def _lookup(
        self,
        token: str,
        app_check_token: str = "",
    ) -> dict:
        del token
        self.lookups += 1
        self.app_check_tokens.append(app_check_token)
        return self.response


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_binds_lookup_user_and_project() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "validSince": str(int((now - timedelta(days=1)).timestamp())),
                    "emailVerified": True,
                    "phoneNumber": "+15555550123",
                    "providerUserInfo": [{"providerId": "password"}],
                }
            ]
        },
        now=now,
    )
    token = _token(
        project="noop-test-project",
        subject="firebase-user-1",
        now=now,
    )

    first = await verifier.verify(token, app_check_token="app-check-1")
    second = await verifier.verify(token, app_check_token="app-check-2")

    assert first == second
    assert first.provider_tenant == "noop-staging"
    assert first.subject_hash != first.subject
    assert len(first.subject_hash) == 64
    assert first.email_verified is True
    assert first.phone_verified is True
    assert first.sign_in_provider == "password"
    assert verifier.lookups == 1
    assert verifier.app_check_tokens == ["app-check-1"]


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_reads_current_pilot_claim() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "customAttributes": '{"noop_managed_pilot":true}',
                }
            ]
        },
        now=now,
    )

    claims = await verifier.verify(
        _token(
            project="noop-test-project",
            subject="firebase-user-1",
            now=now,
        )
    )

    assert claims.managed_pilot is True


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_keeps_contact_values_out_of_claims() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "email": "private@example.test",
                    "emailVerified": False,
                }
            ]
        },
        now=now,
    )

    claims = await verifier.verify(
        _token(
            project="noop-test-project",
            subject="firebase-user-1",
            now=now,
        )
    )

    assert claims.email_verified is False
    assert claims.phone_verified is False
    assert not hasattr(claims, "email")
    assert not hasattr(claims, "phone_number")


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_uses_current_sign_in_provider() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "emailVerified": True,
                    "providerUserInfo": [{"providerId": "password"}],
                }
            ]
        },
        now=now,
    )

    claims = await verifier.verify(
        _token(
            project="noop-test-project",
            subject="firebase-user-1",
            now=now,
            sign_in_provider="phone",
        )
    )

    assert claims.sign_in_provider == "phone"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "custom_attributes",
    [
        "[]",
        '{"noop_managed_pilot":"true"}',
        "{not-json}",
    ],
)
async def test_identity_toolkit_verifier_rejects_invalid_pilot_claim(
    custom_attributes: str,
) -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "customAttributes": custom_attributes,
                }
            ]
        },
        now=now,
    )

    with pytest.raises(ManagedIdentityRejectedError):
        await verifier.verify(
            _token(
                project="noop-test-project",
                subject="firebase-user-1",
                now=now,
            )
        )


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_rejects_lookup_subject_mismatch() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={"users": [{"localId": "different-user"}]},
        now=now,
    )
    token = _token(
        project="noop-test-project",
        subject="firebase-user-1",
        now=now,
    )

    with pytest.raises(ManagedIdentityRejectedError):
        await verifier.verify(token)


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_rejects_revoked_auth_time() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(
        response={
            "users": [
                {
                    "localId": "firebase-user-1",
                    "validSince": str(int(now.timestamp())),
                }
            ]
        },
        now=now,
    )
    token = _token(
        project="noop-test-project",
        subject="firebase-user-1",
        now=now,
    )

    with pytest.raises(ManagedIdentityRejectedError):
        await verifier.verify(token)


@pytest.mark.asyncio
async def test_identity_toolkit_verifier_rejects_non_jwt_without_lookup() -> None:
    now = datetime(2026, 9, 3, 12, tzinfo=UTC)
    verifier = StubIdentityVerifier(response={"users": []}, now=now)

    with pytest.raises(ManagedIdentityRejectedError):
        await verifier.verify("not-a-token")

    assert verifier.lookups == 0
