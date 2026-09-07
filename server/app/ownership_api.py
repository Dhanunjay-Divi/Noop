from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    Header,
    HTTPException,
    Path,
    Query,
    Request,
    Response,
    status,
)
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings
from app.managed_app_check import (
    ManagedAppCheckClaims,
    ManagedAppCheckRejectedError,
    ManagedAppCheckUnavailableError,
    ManagedAppCheckVerifying,
)
from app.managed_identity import (
    ManagedIdentityClaims,
    ManagedIdentityRejectedError,
    ManagedIdentityUnavailableError,
    ManagedTokenVerifying,
)
from app.models import INSTALLATION_ID_PATTERN
from app.observability import OperationalSink, emit_operational_event
from app.ownership_models import (
    LOCALE_PATTERN,
    OWNERSHIP_INSTALLATION_TOKEN_PATTERN,
    POLICY_VERSION_PATTERN,
    OwnershipAccountRegistration,
    OwnershipChallengeRequest,
    OwnershipInstallationAuthorization,
    OwnershipPlanSelection,
    OwnershipPossessionSubmission,
    OwnershipTermsAcceptance,
)
from app.ownership_possession import (
    OwnershipPossessionRejectedError,
    OwnershipPossessionUnavailableError,
    OwnershipPossessionVerifying,
)
from app.ownership_repository import (
    OwnershipChallengeError,
    OwnershipConfigurationError,
    OwnershipConflictError,
    OwnershipForbiddenError,
    OwnershipNotFoundError,
    OwnershipPrincipal,
    OwnershipRepository,
    valid_possession_evidence,
)

ownership_security = HTTPBearer(auto_error=False)
INSTALLATION_RE = re.compile(INSTALLATION_ID_PATTERN)


@dataclass(frozen=True, slots=True)
class OwnershipAppAssertion:
    token: str
    claims: ManagedAppCheckClaims


@dataclass(frozen=True, slots=True)
class OwnershipRequestIdentity:
    claims: ManagedIdentityClaims
    principal: OwnershipPrincipal
    installation_id: str
    app_assertion: OwnershipAppAssertion


def ownership_router(
    *,
    settings: Settings,
    repository: OwnershipRepository,
    app_check_verifier: ManagedAppCheckVerifying,
    token_verifier: ManagedTokenVerifying,
    possession_verifier: OwnershipPossessionVerifying,
    event_sink: OperationalSink = emit_operational_event,
) -> APIRouter:
    router = APIRouter(prefix="/v1/ownership", tags=["band-ownership"])

    async def require_app_check(
        request: Request,
        app_check_token: Annotated[
            str | None,
            Header(alias="X-Firebase-AppCheck"),
        ] = None,
    ) -> OwnershipAppAssertion:
        supplied = app_check_token or ""
        try:
            claims = await app_check_verifier.verify(supplied)
        except ManagedAppCheckRejectedError:
            request.state.auth_result = "app_check_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired app assertion",
            ) from None
        except ManagedAppCheckUnavailableError:
            request.state.auth_result = "app_check_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="app verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_result = "app_check_accepted"
        return OwnershipAppAssertion(token=supplied, claims=claims)

    async def require_claims(
        request: Request,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(ownership_security),
        ],
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> ManagedIdentityClaims:
        supplied = (
            credentials.credentials
            if credentials is not None and credentials.scheme.casefold() == "bearer"
            else ""
        )
        try:
            claims = await token_verifier.verify(
                supplied,
                app_check_token=app_assertion.token,
            )
        except ManagedIdentityRejectedError:
            request.state.auth_result = "identity_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired identity token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from None
        except ManagedIdentityUnavailableError:
            request.state.auth_result = "identity_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="identity verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_scope = "ownership_identity"
        request.state.auth_result = "identity_accepted"
        return claims

    def installation_id_header(
        request: Request,
        installation_id: Annotated[
            str | None,
            Header(alias="X-Noop-Ownership-Installation-ID"),
        ] = None,
    ) -> str:
        if (
            installation_id is None
            or INSTALLATION_RE.fullmatch(installation_id) is None
        ):
            request.state.auth_result = "installation_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="ownership installation credential was rejected",
            )
        return installation_id

    def installation_token_hash_header(
        request: Request,
        installation_token: Annotated[
            str | None,
            Header(alias="X-Noop-Ownership-Installation-Token"),
        ] = None,
    ) -> str:
        if (
            installation_token is None
            or re.fullmatch(
                OWNERSHIP_INSTALLATION_TOKEN_PATTERN,
                installation_token,
            )
            is None
        ):
            request.state.auth_result = "installation_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="ownership installation credential was rejected",
            )
        return hashlib.sha256(installation_token.encode("ascii")).hexdigest()

    async def require_identity(
        request: Request,
        claims: ManagedIdentityClaims = Depends(require_claims),
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
        installation_id: str = Depends(installation_id_header),
        installation_token_hash: str = Depends(installation_token_hash_header),
    ) -> OwnershipRequestIdentity:
        try:
            platform = _platform_for_app(
                settings=settings,
                app_id=app_assertion.claims.app_id,
            )
            principal = await repository.principal_for_identity(claims)
            await repository.ensure_installation(
                principal=principal,
                installation_id=installation_id,
                installation_token_hash=installation_token_hash,
                expected_platform=platform,
                identity_auth_time=claims.auth_time,
            )
        except (
            OwnershipNotFoundError,
            OwnershipForbiddenError,
        ):
            request.state.auth_result = "installation_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="ownership installation credential was rejected",
            ) from None
        request.state.auth_scope = "ownership_installation"
        request.state.auth_result = "installation_accepted"
        return OwnershipRequestIdentity(
            claims=claims,
            principal=principal,
            installation_id=installation_id,
            app_assertion=app_assertion,
        )

    @router.get("/terms/current")
    async def current_terms(
        response: Response,
        locale: Annotated[
            str,
            Query(
                min_length=2,
                max_length=32,
                pattern=LOCALE_PATTERN,
            ),
        ] = "en",
    ) -> dict:
        try:
            manifest = await repository.terms_manifest(locale=locale)
        except OwnershipConfigurationError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="ownership terms are temporarily unavailable",
                headers={"Retry-After": "30"},
            ) from None
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        return manifest

    @router.get("/terms/history/{policy_version}")
    async def historical_terms(
        response: Response,
        policy_version: Annotated[
            str,
            Path(
                min_length=1,
                max_length=64,
                pattern=POLICY_VERSION_PATTERN,
            ),
        ],
        locale: Annotated[
            str,
            Query(
                min_length=2,
                max_length=32,
                pattern=LOCALE_PATTERN,
            ),
        ] = "en",
    ) -> dict:
        try:
            manifest = await repository.terms_manifest_version(
                policy_version=policy_version,
                locale=locale,
            )
        except OwnershipNotFoundError:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="ownership terms version is unavailable",
            ) from None
        except OwnershipConfigurationError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="ownership terms are temporarily unavailable",
                headers={"Retry-After": "30"},
            ) from None
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        return manifest

    @router.put("/terms/acceptance")
    async def accept_terms(
        body: OwnershipTermsAcceptance,
        claims: ManagedIdentityClaims = Depends(require_claims),
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> dict:
        _platform_for_app(
            settings=settings,
            app_id=app_assertion.claims.app_id,
        )
        _require_verified_fresh_identity(settings=settings, claims=claims)
        try:
            principal = await repository.principal_for_identity(claims)
            result = await repository.accept_terms(
                principal=principal,
                acceptance=body,
            )
        except OwnershipConfigurationError:
            _emit(event_sink, phase="terms", outcome="policy_changed")
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        except OwnershipConflictError:
            _emit(event_sink, phase="terms", outcome="conflict")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="ownership terms acceptance request conflicts",
            ) from None
        except (
            OwnershipNotFoundError,
            OwnershipForbiddenError,
        ):
            _emit(event_sink, phase="terms", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="ownership terms acceptance was rejected",
            ) from None
        _emit(
            event_sink,
            phase="terms",
            outcome="resumed" if result.get("resumed") else "accepted",
        )
        return result

    @router.post(
        "/possession-challenges",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_possession_challenge(
        body: OwnershipChallengeRequest,
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> dict:
        _require_platform_app(
            settings=settings,
            platform=body.platform,
            app_id=app_assertion.claims.app_id,
        )
        try:
            challenge = await repository.create_challenge(
                request_id=body.request_id,
                platform=body.platform,
                app_id=app_assertion.claims.app_id,
                ttl_seconds=settings.ownership_challenge_ttl_seconds,
            )
        except OwnershipConflictError:
            _emit(event_sink, phase="challenge", outcome="conflict")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="possession challenge request conflicts",
            ) from None
        except OwnershipChallengeError:
            _emit(event_sink, phase="challenge", outcome="expired")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="possession challenge is no longer active",
            ) from None
        _emit(event_sink, phase="challenge", outcome="issued")
        return {
            "challenge_id": challenge.challenge_id,
            "challenge": challenge.challenge,
            "expires_at": challenge.expires_at,
        }

    @router.put("/account")
    async def register_account(
        body: OwnershipAccountRegistration,
        claims: ManagedIdentityClaims = Depends(require_claims),
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> dict:
        _require_platform_app(
            settings=settings,
            platform=body.platform,
            app_id=app_assertion.claims.app_id,
        )
        _require_verified_fresh_identity(settings=settings, claims=claims)
        try:
            result = await repository.register_account(
                claims=claims,
                registration=body,
            )
        except OwnershipConfigurationError:
            _emit(event_sink, phase="account", outcome="policy_changed")
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        except OwnershipConflictError:
            _emit(event_sink, phase="account", outcome="conflict")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="account registration request conflicts",
            ) from None
        except OwnershipForbiddenError:
            _emit(event_sink, phase="account", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="account registration was rejected",
            ) from None
        _emit(
            event_sink,
            phase="account",
            outcome="created" if result.get("created") else "resumed",
        )
        return result

    @router.get("/bootstrap")
    async def bootstrap_account(
        claims: ManagedIdentityClaims = Depends(require_claims),
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> dict:
        _platform_for_app(
            settings=settings,
            app_id=app_assertion.claims.app_id,
        )
        _require_verified_fresh_identity(settings=settings, claims=claims)
        try:
            result = await repository.bootstrap_status(claims=claims)
        except OwnershipForbiddenError:
            _emit(event_sink, phase="bootstrap", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="ownership account bootstrap was rejected",
            ) from None
        _emit(
            event_sink,
            phase="bootstrap",
            outcome=(
                "registered"
                if result.get("account_state") == "active"
                else "unregistered"
            ),
        )
        return result

    @router.get("/me")
    async def account_overview(
        identity: OwnershipRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            await repository.ensure_current_terms(
                principal=identity.principal,
            )
            return await repository.overview(
                principal=identity.principal,
                current_installation_id=identity.installation_id,
            )
        except OwnershipConfigurationError:
            _emit(event_sink, phase="overview", outcome="policy_changed")
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        except OwnershipNotFoundError:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="ownership account is unavailable",
            ) from None

    @router.post("/claims")
    async def claim_band(
        body: OwnershipPossessionSubmission,
        identity: OwnershipRequestIdentity = Depends(require_identity),
    ) -> dict:
        _require_verified_fresh_identity(
            settings=settings,
            claims=identity.claims,
        )
        try:
            replay = await repository.claim_replay(
                principal=identity.principal,
                installation_id=identity.installation_id,
                submission=body,
            )
        except OwnershipConflictError:
            _emit(event_sink, phase="claim", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="band is not available for claim",
            ) from None
        if replay is not None:
            if replay.outcome == "conflict":
                _emit(event_sink, phase="claim", outcome="conflict")
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="band is not available for claim",
                )
            _emit(event_sink, phase="claim", outcome="resumed")
            return {
                "claim_state": replay.outcome,
                "band_state": replay.band_state,
                "core_local_access": "independent",
                "noop_plus_entitled": False,
            }
        try:
            await repository.ensure_current_terms(
                principal=identity.principal,
            )
        except OwnershipConfigurationError:
            _emit(event_sink, phase="claim", outcome="policy_changed")
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        platform = _platform_for_app(
            settings=settings,
            app_id=identity.app_assertion.claims.app_id,
        )
        evidence = await _verify_possession(
            repository=repository,
            verifier=possession_verifier,
            event_sink=event_sink,
            body=body,
            app_id=identity.app_assertion.claims.app_id,
            platform=platform,
            phase="claim",
        )
        try:
            result = await repository.claim_band(
                principal=identity.principal,
                installation_id=identity.installation_id,
                submission=body,
                evidence=evidence,
                app_id=identity.app_assertion.claims.app_id,
                platform=platform,
            )
        except OwnershipConfigurationError:
            _emit(event_sink, phase="claim", outcome="policy_changed")
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        except OwnershipChallengeError:
            _emit(event_sink, phase="claim", outcome="challenge_inactive")
            raise HTTPException(
                status_code=status.HTTP_410_GONE,
                detail="band confirmation is no longer active; start again",
            ) from None
        except OwnershipForbiddenError:
            _emit(event_sink, phase="claim", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="ownership installation credential was rejected",
            ) from None
        except OwnershipConflictError:
            _emit(event_sink, phase="claim", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="band is not available for claim",
            ) from None
        if result.outcome == "conflict":
            _emit(event_sink, phase="claim", outcome="conflict")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="band is not available for claim",
            )
        _emit(event_sink, phase="claim", outcome=result.outcome)
        return {
            "claim_state": result.outcome,
            "band_state": result.band_state,
            "core_local_access": "independent",
            "noop_plus_entitled": False,
        }

    @router.post("/installations:authorize")
    async def authorize_installation(
        body: OwnershipInstallationAuthorization,
        claims: ManagedIdentityClaims = Depends(require_claims),
        app_assertion: OwnershipAppAssertion = Depends(require_app_check),
    ) -> dict:
        _require_platform_app(
            settings=settings,
            platform=body.new_platform,
            app_id=app_assertion.claims.app_id,
        )
        _require_verified_fresh_identity(settings=settings, claims=claims)
        try:
            principal = await repository.principal_for_identity(claims)
        except (OwnershipNotFoundError, OwnershipForbiddenError):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="installation authorization was rejected",
            ) from None
        try:
            replay = await repository.installation_authorization_replay(
                principal=principal,
                submission=body,
                app_id=app_assertion.claims.app_id,
                identity_auth_time=claims.auth_time,
            )
        except (
            OwnershipConflictError,
            OwnershipForbiddenError,
        ):
            _emit(event_sink, phase="installation", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="installation authorization was rejected",
            ) from None
        if replay is not None:
            _emit(event_sink, phase="installation", outcome="resumed")
            return replay
        try:
            await repository.ensure_current_terms(principal=principal)
        except OwnershipConfigurationError:
            _emit(
                event_sink,
                phase="installation",
                outcome="policy_changed",
            )
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        evidence = await _verify_possession(
            repository=repository,
            verifier=possession_verifier,
            event_sink=event_sink,
            body=body,
            app_id=app_assertion.claims.app_id,
            platform=body.new_platform,
            phase="installation",
        )
        try:
            result = await repository.authorize_installation(
                principal=principal,
                submission=body,
                evidence=evidence,
                app_id=app_assertion.claims.app_id,
                identity_auth_time=claims.auth_time,
            )
        except OwnershipChallengeError:
            _emit(
                event_sink,
                phase="installation",
                outcome="challenge_inactive",
            )
            raise HTTPException(
                status_code=status.HTTP_410_GONE,
                detail="band confirmation is no longer active; start again",
            ) from None
        except OwnershipConfigurationError:
            _emit(
                event_sink,
                phase="installation",
                outcome="policy_changed",
            )
            raise HTTPException(
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                detail="ownership terms changed; review the current version",
            ) from None
        except (
            OwnershipConflictError,
            OwnershipForbiddenError,
        ):
            _emit(event_sink, phase="installation", outcome="rejected")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="installation authorization was rejected",
            ) from None
        _emit(event_sink, phase="installation", outcome="authorized")
        return result

    @router.get("/installations")
    async def list_installations(
        identity: OwnershipRequestIdentity = Depends(require_identity),
    ) -> dict:
        installations = await repository.list_installations(
            principal=identity.principal,
            current_installation_id=identity.installation_id,
        )
        return {"installations": installations}

    @router.delete(
        "/installations/{target_installation_id}",
        status_code=status.HTTP_204_NO_CONTENT,
    )
    async def revoke_installation(
        target_installation_id: str,
        identity: OwnershipRequestIdentity = Depends(require_identity),
    ) -> Response:
        if INSTALLATION_RE.fullmatch(target_installation_id) is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="ownership installation is unavailable",
            )
        _require_verified_fresh_identity(
            settings=settings,
            claims=identity.claims,
        )
        try:
            await repository.revoke_installation(
                principal=identity.principal,
                current_installation_id=identity.installation_id,
                target_installation_id=target_installation_id,
            )
        except OwnershipForbiddenError:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="installation revocation was rejected",
            ) from None
        except OwnershipNotFoundError:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="ownership installation is unavailable",
            ) from None
        _emit(event_sink, phase="installation", outcome="revoked")
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.put("/plan-selection")
    async def select_plan(
        body: OwnershipPlanSelection,
        identity: OwnershipRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            result = await repository.select_plan(
                principal=identity.principal,
                installation_id=identity.installation_id,
                selection=body,
            )
        except OwnershipConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="plan selection request conflicts",
            ) from None
        except OwnershipForbiddenError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="ownership installation credential was rejected",
            ) from None
        _emit(event_sink, phase="plan", outcome=body.selection)
        return result

    return router


async def _verify_possession(
    *,
    repository: OwnershipRepository,
    verifier: OwnershipPossessionVerifying,
    event_sink: OperationalSink,
    body: OwnershipPossessionSubmission,
    app_id: str,
    platform: str,
    phase: str,
):
    challenge = body.challenge.get_secret_value()
    try:
        challenge_window = await repository.require_active_challenge(
            challenge_id=body.challenge_id,
            challenge=challenge,
            app_id=app_id,
            platform=platform,
        )
    except OwnershipChallengeError:
        _emit(event_sink, phase=phase, outcome="challenge_inactive")
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail="band confirmation is no longer active; start again",
        ) from None
    try:
        evidence = await verifier.verify(
            challenge=challenge,
            response=body.possession_response.get_secret_value(),
        )
    except OwnershipPossessionUnavailableError:
        _emit(event_sink, phase=phase, outcome="verifier_unavailable")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="band possession verification is temporarily unavailable",
            headers={"Retry-After": "30"},
        ) from None
    except OwnershipPossessionRejectedError:
        await repository.reject_challenge(
            challenge_id=body.challenge_id,
            challenge=challenge,
            app_id=app_id,
        )
        _emit(event_sink, phase=phase, outcome="proof_rejected")
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="band possession proof was rejected",
        ) from None
    evidence_valid = valid_possession_evidence(evidence)
    confirmed_at = evidence.confirmed_at.astimezone(UTC) if evidence_valid else None
    if (
        not evidence_valid
        or confirmed_at is None
        or confirmed_at < challenge_window.created_at
        or confirmed_at >= challenge_window.expires_at
    ):
        await repository.reject_challenge(
            challenge_id=body.challenge_id,
            challenge=challenge,
            app_id=app_id,
        )
        _emit(event_sink, phase=phase, outcome="proof_rejected")
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="band possession proof was rejected",
        )
    return evidence


def _require_verified_fresh_identity(
    *,
    settings: Settings,
    claims: ManagedIdentityClaims,
) -> None:
    if not claims.email_verified:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="verify the email address before continuing",
        )
    if claims.sign_in_provider != "password":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="email and password sign-in is required",
        )
    _require_fresh_identity(settings=settings, claims=claims)


def _require_fresh_identity(
    *,
    settings: Settings,
    claims: ManagedIdentityClaims,
) -> None:
    if claims.auth_time < datetime.now(UTC) - timedelta(
        seconds=settings.ownership_fresh_auth_seconds
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="recent sign-in is required",
            headers={"WWW-Authenticate": "Bearer"},
        )


def _require_platform_app(
    *,
    settings: Settings,
    platform: str,
    app_id: str,
) -> None:
    expected = (
        settings.ownership_apple_app_id
        if platform == "ios"
        else settings.ownership_android_app_id
    )
    if app_id != expected:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="app assertion does not match the selected platform",
        )


def _platform_for_app(*, settings: Settings, app_id: str) -> str:
    if app_id == settings.ownership_apple_app_id:
        return "ios"
    if app_id == settings.ownership_android_app_id:
        return "android"
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="app assertion is not eligible for ownership",
    )


def _emit(
    sink: OperationalSink,
    *,
    phase: str,
    outcome: str,
) -> None:
    try:
        sink(
            "ownership.lifecycle",
            service="noop-ownership-api",
            phase=phase,
            outcome=outcome,
        )
    except Exception:
        return
