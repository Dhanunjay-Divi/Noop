from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.managed_app_check import (
    ManagedAppCheckClaims,
    StaticManagedAppCheckVerifier,
)
from app.managed_identity import (
    ManagedIdentityClaims,
    StaticManagedTokenVerifier,
)
from app.ownership_main import create_ownership_app
from app.ownership_models import OwnershipTermsManifest
from app.ownership_possession import (
    OwnershipPossessionEvidence,
    OwnershipPossessionRejectedError,
    OwnershipPossessionUnavailableError,
)
from app.ownership_repository import (
    OwnershipChallenge,
    OwnershipChallengeError,
    OwnershipChallengeWindow,
    OwnershipClaimResult,
    OwnershipConfigurationError,
    OwnershipForbiddenError,
    OwnershipPrincipal,
)

APPLE_APP_ID = "1:123456789:ios:abcdef12"
ANDROID_APP_ID = "1:123456789:android:abcdef12"
INSTALLATION_ID = "ios-installation-1"
INSTALLATION_TOKEN = "noopo_" + "A" * 43
CHALLENGE = "C" * 43
CHALLENGE_ID = UUID("11111111-1111-4111-8111-111111111111")
TERMS_SHA256 = "a" * 64
BAND_IDENTITY_HASH = "b" * 64


def _settings() -> Settings:
    return Settings(
        api_token=None,
        database_url=None,
        ownership_service_enabled=True,
        ownership_project_id="noop-test-project",
        ownership_project_number="123456789",
        ownership_identity_api_key="test_identity_api_key",
        ownership_apple_app_id=APPLE_APP_ID,
        ownership_android_app_id=ANDROID_APP_ID,
    )


def _identity_claims(
    *,
    email_verified: bool = True,
    sign_in_provider: str = "password",
) -> ManagedIdentityClaims:
    now = datetime.now(UTC)
    return ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject="firebase-subject",
        provider_tenant="",
        issued_at=now,
        auth_time=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
        email_verified=email_verified,
        phone_verified=False,
        sign_in_provider=sign_in_provider,
    )


def _app_claims(app_id: str = APPLE_APP_ID) -> ManagedAppCheckClaims:
    now = datetime.now(UTC)
    return ManagedAppCheckClaims(
        app_id=app_id,
        issuer="https://firebaseappcheck.googleapis.com/123456789",
        audience=("projects/123456789",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )


class StaticPossessionVerifier:
    def __init__(
        self,
        *,
        unavailable: bool = False,
        rejected: bool = False,
    ) -> None:
        self.unavailable = unavailable
        self.rejected = rejected
        self.calls = 0

    async def verify(
        self,
        *,
        challenge: str,
        response: str,
    ) -> OwnershipPossessionEvidence:
        self.calls += 1
        if self.unavailable:
            raise OwnershipPossessionUnavailableError("unavailable")
        if self.rejected:
            raise OwnershipPossessionRejectedError("rejected")
        assert challenge == CHALLENGE
        assert response == "virtual-signed-response"
        return OwnershipPossessionEvidence(
            provisioned_identity_hash=BAND_IDENTITY_HASH,
            protocol_version="test-v1",
            firmware_version="test-1.0.0",
            confirmed_at=datetime.now(UTC),
        )


class FakeOwnershipRepository:
    def __init__(self) -> None:
        self.principal = OwnershipPrincipal(
            account_id=UUID("22222222-2222-4222-8222-222222222222"),
            identity_id=UUID("33333333-3333-4333-8333-333333333333"),
            account_status="active",
            auth_valid_after=datetime.now(UTC) - timedelta(minutes=1),
        )
        self.claim_outcome = "claimed"
        self.replayed_claim: OwnershipClaimResult | None = None
        self.replayed_authorization: dict | None = None
        self.replay_identity_auth_time: datetime | None = None
        self.rejected_challenges = 0
        self.revoked_installation: str | None = None
        self.installation_platform = "ios"
        self.challenge_active = True

    async def terms_manifest(self, *, locale: str) -> dict:
        return {
            "policy_version": "ownership-v1",
            "locale": locale,
            "document_sha256": TERMS_SHA256,
            "document_uri": "https://terms.noop.example/ownership-v1/en",
            "effective_at": datetime(2026, 9, 5, tzinfo=UTC),
        }

    async def terms_manifest_version(
        self,
        *,
        policy_version: str,
        locale: str,
    ) -> dict:
        assert policy_version == "ownership-v1"
        return await self.terms_manifest(locale=locale)

    async def create_challenge(
        self,
        *,
        request_id,
        platform: str,
        app_id: str,
        ttl_seconds: int,
    ) -> OwnershipChallenge:
        del request_id
        assert platform == "ios"
        assert app_id == APPLE_APP_ID
        assert ttl_seconds == 180
        return OwnershipChallenge(
            challenge_id=CHALLENGE_ID,
            challenge=CHALLENGE,
            expires_at=datetime.now(UTC) + timedelta(minutes=3),
        )

    async def reject_challenge(self, **_: object) -> None:
        self.rejected_challenges += 1

    async def require_active_challenge(
        self,
        *,
        challenge_id,
        challenge: str,
        app_id: str,
        platform: str,
    ) -> OwnershipChallengeWindow:
        assert challenge_id == CHALLENGE_ID
        assert challenge == CHALLENGE
        assert app_id == APPLE_APP_ID
        assert platform == "ios"
        if not self.challenge_active:
            raise OwnershipChallengeError("challenge is no longer active")
        now = datetime.now(UTC)
        return OwnershipChallengeWindow(
            created_at=now - timedelta(seconds=5),
            expires_at=now + timedelta(minutes=3),
        )

    async def register_account(self, *, claims, registration) -> dict:
        assert claims.email_verified
        assert registration.installation_id == INSTALLATION_ID
        return {
            "created": True,
            "account_state": "active",
            "email_verified": True,
            "phone_verified": False,
            "band_state": "unclaimed",
            "active_installations": 1,
            "current_installation_id": INSTALLATION_ID,
            "plan_selection": "noop",
            "noop_plus_entitled": False,
        }

    async def accept_terms(self, *, principal, acceptance) -> dict:
        assert principal == self.principal
        assert acceptance.policy_version == "ownership-v1"
        assert acceptance.policy_sha256 == TERMS_SHA256
        return {
            "acceptance_state": "accepted",
            "policy_version": acceptance.policy_version,
            "locale": acceptance.locale,
            "resumed": False,
        }

    async def bootstrap_status(self, *, claims) -> dict:
        assert claims.subject == "firebase-subject"
        return {
            "account_state": "active",
            "band_state": "claimed",
            "replacement_authorization_required": True,
            "terms_acceptance_required": False,
        }

    async def principal_for_identity(self, claims) -> OwnershipPrincipal:
        assert claims.subject == "firebase-subject"
        return self.principal

    async def ensure_installation(
        self,
        *,
        principal,
        installation_id: str,
        installation_token_hash: str,
        expected_platform: str,
        identity_auth_time: datetime,
    ) -> None:
        assert principal == self.principal
        assert installation_id == INSTALLATION_ID
        if expected_platform != self.installation_platform:
            raise OwnershipForbiddenError("ownership installation was rejected")
        assert identity_auth_time.tzinfo is not None
        assert (
            installation_token_hash
            == hashlib.sha256(INSTALLATION_TOKEN.encode("ascii")).hexdigest()
        )

    async def ensure_current_terms(self, *, principal) -> None:
        assert principal == self.principal

    async def overview(self, *, principal, current_installation_id: str) -> dict:
        assert principal == self.principal
        return {
            "account_state": "active",
            "email_verified": True,
            "phone_verified": False,
            "band_state": "unclaimed",
            "active_installations": 1,
            "current_installation_id": current_installation_id,
            "plan_selection": "noop",
            "noop_plus_entitled": False,
        }

    async def claim_replay(self, **_: object) -> OwnershipClaimResult | None:
        return self.replayed_claim

    async def claim_band(self, **_: object) -> OwnershipClaimResult:
        return OwnershipClaimResult(
            outcome=self.claim_outcome,
            band_state=(
                "claimed" if self.claim_outcome != "conflict" else "unavailable"
            ),
        )

    async def installation_authorization_replay(
        self,
        *,
        identity_auth_time: datetime,
        **_: object,
    ) -> dict | None:
        self.replay_identity_auth_time = identity_auth_time
        return self.replayed_authorization

    async def authorize_installation(self, *, submission, **_: object) -> dict:
        return {
            "installation_state": "active",
            "installation_id": submission.new_installation_id,
        }

    async def list_installations(
        self,
        *,
        principal,
        current_installation_id: str,
    ) -> list[dict]:
        assert principal == self.principal
        return [
            {
                "installation_id": current_installation_id,
                "platform": "ios",
                "status": "active",
                "current": True,
                "registered_at": datetime.now(UTC),
                "last_seen_at": datetime.now(UTC),
            }
        ]

    async def revoke_installation(
        self,
        *,
        target_installation_id: str,
        **_: object,
    ) -> None:
        self.revoked_installation = target_installation_id

    async def select_plan(
        self,
        *,
        installation_id: str,
        selection,
        **_: object,
    ) -> dict:
        assert installation_id == INSTALLATION_ID
        return {
            "plan_selection": selection.selection,
            "noop_plus_entitled": False,
            "payment_state": "unavailable",
        }


def _client(
    *,
    repository: FakeOwnershipRepository | None = None,
    email_verified: bool = True,
    sign_in_provider: str = "password",
    possession_verifier: StaticPossessionVerifier | None = None,
    events: list[dict] | None = None,
    app_id: str = APPLE_APP_ID,
) -> TestClient:
    repo = repository or FakeOwnershipRepository()
    token_verifier = StaticManagedTokenVerifier(
        {
            "identity-token": _identity_claims(
                email_verified=email_verified,
                sign_in_provider=sign_in_provider,
            )
        }
    )
    app_check_verifier = StaticManagedAppCheckVerifier(
        {"app-token": _app_claims(app_id)}
    )

    def sink(event: str, **fields: object) -> None:
        if events is not None:
            events.append({"event": event, **fields})

    app = create_ownership_app(
        settings=_settings(),
        repository=repo,
        app_check_verifier=app_check_verifier,
        token_verifier=token_verifier,
        possession_verifier=(possession_verifier or StaticPossessionVerifier()),
        event_sink=sink,
    )
    return TestClient(app)


def _identity_headers(*, installation: bool = False) -> dict[str, str]:
    result = {
        "Authorization": "Bearer identity-token",
        "X-Firebase-AppCheck": "app-token",
    }
    if installation:
        result.update(
            {
                "X-Noop-Ownership-Installation-ID": INSTALLATION_ID,
                "X-Noop-Ownership-Installation-Token": INSTALLATION_TOKEN,
            }
        )
    return result


def _registration() -> dict:
    return {
        "request_id": str(uuid4()),
        "installation_id": INSTALLATION_ID,
        "installation_token": INSTALLATION_TOKEN,
        "platform": "ios",
        "policy_version": "ownership-v1",
        "policy_sha256": TERMS_SHA256,
        "locale": "en",
    }


def _terms_acceptance() -> dict:
    return {
        "request_id": str(uuid4()),
        "policy_version": "ownership-v1",
        "policy_sha256": TERMS_SHA256,
        "locale": "en",
    }


def _possession() -> dict:
    return {
        "request_id": str(uuid4()),
        "challenge_id": str(CHALLENGE_ID),
        "challenge": CHALLENGE,
        "possession_response": "virtual-signed-response",
    }


def test_ownership_terms_are_public_and_no_store() -> None:
    with _client() as client:
        response = client.get("/v1/ownership/terms/current?locale=en")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["document_sha256"] == TERMS_SHA256


def test_historical_ownership_terms_are_public_and_exact() -> None:
    with _client() as client:
        response = client.get("/v1/ownership/terms/history/ownership-v1?locale=en")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["policy_version"] == "ownership-v1"
    assert response.json()["document_sha256"] == TERMS_SHA256


def test_existing_account_can_reaccept_current_terms_without_an_installation() -> None:
    events: list[dict] = []
    with _client(events=events) as client:
        response = client.put(
            "/v1/ownership/terms/acceptance",
            headers=_identity_headers(),
            json=_terms_acceptance(),
        )

    assert response.status_code == 200
    assert response.json() == {
        "acceptance_state": "accepted",
        "policy_version": "ownership-v1",
        "locale": "en",
        "resumed": False,
    }
    assert events[-1] == {
        "event": "ownership.lifecycle",
        "service": "noop-ownership-api",
        "phase": "terms",
        "outcome": "accepted",
    }


@pytest.mark.parametrize(
    "document_uri",
    [
        "https://user@terms.noop.example/ownership-v1/en",
        "https://user:secret@terms.noop.example/ownership-v1/en",
        "https://terms.noop.example:8443/ownership-v1/en",
        "https://terms.noop.example/ownership-v1/en?next=other",
        "https://terms.noop.example/ownership-v1/en#current",
        "http://terms.noop.example/ownership-v1/en",
    ],
)
def test_ownership_terms_manifest_rejects_dynamic_or_credentialed_urls(
    document_uri: str,
) -> None:
    with pytest.raises(ValueError):
        OwnershipTermsManifest.model_validate(
            {
                "policy_version": "ownership-v1",
                "locale": "en",
                "document_sha256": TERMS_SHA256,
                "document_uri": document_uri,
                "effective_at": datetime(2026, 9, 5, tzinfo=UTC),
            }
        )


def test_ownership_registration_requires_verified_email() -> None:
    with _client(email_verified=False) as client:
        response = client.put(
            "/v1/ownership/account",
            headers=_identity_headers(),
            json=_registration(),
        )

    assert response.status_code == 403
    assert response.json() == {"detail": "verify the email address before continuing"}


def test_ownership_registration_requires_current_password_sign_in() -> None:
    with _client(sign_in_provider="phone") as client:
        response = client.put(
            "/v1/ownership/account",
            headers=_identity_headers(),
            json=_registration(),
        )

    assert response.status_code == 403
    assert response.json() == {"detail": "email and password sign-in is required"}


def test_ownership_registration_distinguishes_changed_terms() -> None:
    class ChangedTermsRepository(FakeOwnershipRepository):
        async def register_account(self, **_: object) -> dict:
            raise OwnershipConfigurationError("terms changed")

    with _client(repository=ChangedTermsRepository()) as client:
        response = client.put(
            "/v1/ownership/account",
            headers=_identity_headers(),
            json=_registration(),
        )

    assert response.status_code == 412
    assert response.json() == {
        "detail": "ownership terms changed; review the current version"
    }


def test_ownership_account_challenge_claim_and_plan_flow() -> None:
    events: list[dict] = []
    with _client(events=events) as client:
        account = client.put(
            "/v1/ownership/account",
            headers=_identity_headers(),
            json=_registration(),
        )
        challenge = client.post(
            "/v1/ownership/possession-challenges",
            headers={"X-Firebase-AppCheck": "app-token"},
            json={"request_id": str(uuid4()), "platform": "ios"},
        )
        claim = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )
        plan = client.put(
            "/v1/ownership/plan-selection",
            headers=_identity_headers(installation=True),
            json={"request_id": str(uuid4()), "selection": "noop_plus"},
        )

    assert account.status_code == 200
    assert challenge.status_code == 201
    assert challenge.json()["challenge"] == CHALLENGE
    assert re.fullmatch(
        r"[0-9a-f]{32}",
        challenge.headers["X-Noop-Request-ID"],
    )
    assert claim.status_code == 200
    assert claim.json()["band_state"] == "claimed"
    assert claim.json()["core_local_access"] == "independent"
    assert plan.status_code == 200
    assert plan.json() == {
        "plan_selection": "noop_plus",
        "noop_plus_entitled": False,
        "payment_state": "unavailable",
    }
    serialized_events = repr(events)
    assert "virtual-signed-response" not in serialized_events
    assert INSTALLATION_ID not in serialized_events
    assert BAND_IDENTITY_HASH not in serialized_events
    assert events
    assert all(
        set(event) == {"event", "service", "phase", "outcome"} for event in events
    )
    assert {event["event"] for event in events} == {"ownership.lifecycle"}
    assert all(len(str(value)) <= 64 for event in events for value in event.values())


def test_ownership_bootstrap_is_coarse_and_requires_verified_identity() -> None:
    with _client() as client:
        response = client.get(
            "/v1/ownership/bootstrap",
            headers=_identity_headers(),
        )

    assert response.status_code == 200
    assert response.json() == {
        "account_state": "active",
        "band_state": "claimed",
        "replacement_authorization_required": True,
        "terms_acceptance_required": False,
    }
    assert INSTALLATION_ID not in response.text

    with _client(email_verified=False) as client:
        rejected = client.get(
            "/v1/ownership/bootstrap",
            headers=_identity_headers(),
        )

    assert rejected.status_code == 403


def test_ownership_claim_uses_uniform_conflict_response() -> None:
    repository = FakeOwnershipRepository()
    repository.claim_outcome = "conflict"
    with _client(repository=repository) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 409
    assert response.json() == {"detail": "band is not available for claim"}


def test_ownership_claim_checks_current_terms_before_one_time_proof() -> None:
    events: list[dict] = []

    class ChangedTermsRepository(FakeOwnershipRepository):
        async def ensure_current_terms(self, **_: object) -> None:
            raise OwnershipConfigurationError("terms changed")

    verifier = StaticPossessionVerifier()
    with _client(
        repository=ChangedTermsRepository(),
        possession_verifier=verifier,
        events=events,
    ) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 412
    assert response.json() == {
        "detail": "ownership terms changed; review the current version"
    }
    assert verifier.calls == 0
    assert events[-1]["phase"] == "claim"
    assert events[-1]["outcome"] == "policy_changed"


def test_ownership_overview_requires_current_terms() -> None:
    class ChangedTermsRepository(FakeOwnershipRepository):
        async def ensure_current_terms(self, **_: object) -> None:
            raise OwnershipConfigurationError("terms changed")

    with _client(repository=ChangedTermsRepository()) as client:
        response = client.get(
            "/v1/ownership/me",
            headers=_identity_headers(installation=True),
        )

    assert response.status_code == 412
    assert response.json() == {
        "detail": "ownership terms changed; review the current version"
    }


def test_installation_revocation_requires_verified_password_session() -> None:
    repository = FakeOwnershipRepository()
    with _client(
        repository=repository,
        sign_in_provider="phone",
    ) as client:
        response = client.delete(
            "/v1/ownership/installations/replacement-ios",
            headers=_identity_headers(installation=True),
        )

    assert response.status_code == 403
    assert response.json() == {"detail": "email and password sign-in is required"}
    assert repository.revoked_installation is None


def test_installation_credential_is_bound_to_attested_app_platform() -> None:
    with _client(app_id=ANDROID_APP_ID) as client:
        response = client.get(
            "/v1/ownership/me",
            headers=_identity_headers(installation=True),
        )

    assert response.status_code == 401
    assert response.json() == {
        "detail": "ownership installation credential was rejected"
    }


def test_revoked_installation_race_is_not_an_internal_error() -> None:
    class RevokedInstallationRepository(FakeOwnershipRepository):
        async def claim_band(self, **_: object) -> OwnershipClaimResult:
            raise OwnershipForbiddenError("revoked")

        async def select_plan(self, **_: object) -> dict:
            raise OwnershipForbiddenError("revoked")

    with _client(repository=RevokedInstallationRepository()) as client:
        claim = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )
        plan = client.put(
            "/v1/ownership/plan-selection",
            headers=_identity_headers(installation=True),
            json={"request_id": str(uuid4()), "selection": "noop_plus"},
        )

    assert claim.status_code == 401
    assert plan.status_code == 401
    assert claim.json() == {"detail": "ownership installation credential was rejected"}
    assert plan.json() == claim.json()


def test_inactive_claim_challenge_is_retryable_not_ownership_conflict() -> None:
    events: list[dict] = []
    repository = FakeOwnershipRepository()
    repository.challenge_active = False
    verifier = StaticPossessionVerifier()
    with _client(
        repository=repository,
        possession_verifier=verifier,
        events=events,
    ) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 410
    assert response.json() == {
        "detail": "band confirmation is no longer active; start again"
    }
    assert verifier.calls == 0
    assert events[-1]["phase"] == "claim"
    assert events[-1]["outcome"] == "challenge_inactive"


def test_rejected_possession_is_not_identity_authentication_failure() -> None:
    events: list[dict] = []
    repository = FakeOwnershipRepository()
    verifier = StaticPossessionVerifier(rejected=True)
    with _client(
        repository=repository,
        possession_verifier=verifier,
        events=events,
    ) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 422
    assert response.json() == {"detail": "band possession proof was rejected"}
    assert verifier.calls == 1
    assert repository.rejected_challenges == 1
    assert events[-1]["phase"] == "claim"
    assert events[-1]["outcome"] == "proof_rejected"


def test_ownership_possession_verifier_fails_closed() -> None:
    verifier = StaticPossessionVerifier(unavailable=True)
    with _client(possession_verifier=verifier) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 503
    assert verifier.calls == 1


def test_completed_claim_replay_does_not_reverify_one_time_proof() -> None:
    repository = FakeOwnershipRepository()
    repository.replayed_claim = OwnershipClaimResult(
        outcome="claimed",
        band_state="claimed",
    )
    verifier = StaticPossessionVerifier(unavailable=True)
    with _client(
        repository=repository,
        possession_verifier=verifier,
    ) as client:
        response = client.post(
            "/v1/ownership/claims",
            headers=_identity_headers(installation=True),
            json=_possession(),
        )

    assert response.status_code == 200
    assert response.json()["claim_state"] == "claimed"
    assert verifier.calls == 0


def test_ownership_replacement_installation_uses_fresh_identity_and_proof() -> None:
    with _client() as client:
        response = client.post(
            "/v1/ownership/installations:authorize",
            headers=_identity_headers(),
            json={
                **_possession(),
                "new_installation_id": "replacement-android",
                "new_installation_token": "noopo_" + "R" * 43,
                "new_platform": "ios",
            },
        )

    assert response.status_code == 200
    assert response.json()["installation_state"] == "active"


def test_replacement_checks_current_terms_before_one_time_proof() -> None:
    class ChangedTermsRepository(FakeOwnershipRepository):
        async def ensure_current_terms(self, **_: object) -> None:
            raise OwnershipConfigurationError("terms changed")

    verifier = StaticPossessionVerifier()
    with _client(
        repository=ChangedTermsRepository(),
        possession_verifier=verifier,
    ) as client:
        response = client.post(
            "/v1/ownership/installations:authorize",
            headers=_identity_headers(),
            json={
                **_possession(),
                "new_installation_id": "replacement-ios",
                "new_installation_token": "noopo_" + "R" * 43,
                "new_platform": "ios",
            },
        )

    assert response.status_code == 412
    assert response.json() == {
        "detail": "ownership terms changed; review the current version"
    }
    assert verifier.calls == 0


def test_inactive_replacement_challenge_requires_a_new_confirmation() -> None:
    repository = FakeOwnershipRepository()
    repository.challenge_active = False
    verifier = StaticPossessionVerifier()
    with _client(
        repository=repository,
        possession_verifier=verifier,
    ) as client:
        response = client.post(
            "/v1/ownership/installations:authorize",
            headers=_identity_headers(),
            json={
                **_possession(),
                "new_installation_id": "replacement-ios",
                "new_installation_token": "noopo_" + "R" * 43,
                "new_platform": "ios",
            },
        )

    assert response.status_code == 410
    assert response.json() == {
        "detail": "band confirmation is no longer active; start again"
    }
    assert verifier.calls == 0


def test_completed_installation_replay_does_not_reverify_one_time_proof() -> None:
    repository = FakeOwnershipRepository()
    repository.replayed_authorization = {
        "installation_state": "active",
        "installation_id": "replacement-ios",
    }
    verifier = StaticPossessionVerifier(unavailable=True)
    with _client(
        repository=repository,
        possession_verifier=verifier,
    ) as client:
        response = client.post(
            "/v1/ownership/installations:authorize",
            headers=_identity_headers(),
            json={
                **_possession(),
                "new_installation_id": "replacement-ios",
                "new_installation_token": "noopo_" + "R" * 43,
                "new_platform": "ios",
            },
        )

    assert response.status_code == 200
    assert response.json()["installation_state"] == "active"
    assert verifier.calls == 0
    assert repository.replay_identity_auth_time is not None


def test_ownership_validation_does_not_echo_credentials() -> None:
    with _client() as client:
        response = client.put(
            "/v1/ownership/account",
            headers=_identity_headers(),
            json={
                **_registration(),
                "installation_token": "plaintext-invalid-token",
            },
        )

    assert response.status_code == 422
    serialized = response.text
    assert "plaintext-invalid-token" not in serialized
    assert "identity-token" not in serialized
