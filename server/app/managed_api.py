from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
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
from app.managed_identity_deletion import ManagedIdentityDeletionTicketCodec
from app.managed_models import (
    MANAGED_DOCUMENT_KINDS,
    MANAGED_INSTALLATION_TOKEN_PATTERN,
    ManagedAccessRequest,
    ManagedChunkCompletion,
    ManagedChunkReservation,
    ManagedClientKeyRegistration,
    ManagedDocumentMutation,
    ManagedEnrollment,
    ManagedErasureRequest,
    ManagedExportCompletion,
    ManagedExportRequest,
    ManagedRestoreCompletion,
    ManagedRestoreRequest,
    ManagedSocialInviteCreate,
    ManagedSocialInviteRedeem,
    ManagedSocialPokeAcknowledgement,
    ManagedSocialPokeCreate,
    ManagedSocialProfileCreate,
    ManagedSocialProfilePatch,
    ManagedSocialRequestCreate,
    ManagedSocialRequestDecision,
    ManagedSocialSummaryMutation,
    ManagedSocialVisibilityPatch,
    ManagedSourceRegistration,
)
from app.observability import emit_operational_event
from app.managed_object_store import (
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.managed_safety_models import (
    ManagedPushRegistration,
    ManagedSafetyIncidentCreate,
    ManagedSafetyIncidentEnd,
    ManagedSafetyInviteCreate,
    ManagedSafetyInviteRedeem,
    ManagedSafetyLocationUpdate,
    ManagedSafetyRequestCreate,
    ManagedSafetyRequestDecision,
    ManagedSafetyResponse,
)
from app.managed_safety_repository import (
    ManagedSafetyPushService,
    PostgresManagedSafetyRepository,
)
from app.managed_repository import (
    ManagedConfigurationError,
    ManagedConflictError,
    ManagedCursorExpiredError,
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedPrincipal,
    ManagedQuotaExceededError,
    ManagedRateLimitError,
    ManagedStorageError,
    PostgresManagedRepository,
)
from app.models import INSTALLATION_ID_PATTERN

managed_security = HTTPBearer(auto_error=False)
INSTALLATION_RE = re.compile(INSTALLATION_ID_PATTERN)
DATA_CLASS_RE = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
DOCUMENT_KINDS = MANAGED_DOCUMENT_KINDS
ERASURE_CONFIRMATION_SHA256 = {
    scope: hashlib.sha256(phrase.encode("utf-8")).hexdigest()
    for scope, phrase in {
        "account": "delete-noop-plus-managed-account-v1",
        "all_managed_data": "delete-noop-plus-all-managed-data-v1",
        "raw_chunks": "delete-noop-plus-raw-chunks-v1",
        "derived_data": "delete-noop-plus-derived-data-v1",
    }.items()
}


@dataclass(frozen=True, slots=True)
class ManagedRequestIdentity:
    claims: ManagedIdentityClaims
    principal: ManagedPrincipal
    installation_id: str


@dataclass(frozen=True, slots=True)
class ManagedAppAssertion:
    token: str
    claims: ManagedAppCheckClaims


def managed_router(
    *,
    settings: Settings,
    repository: PostgresManagedRepository,
    app_check_verifier: ManagedAppCheckVerifying,
    token_verifier: ManagedTokenVerifying,
    object_store: ManagedObjectStoring,
    identity_deletion_ticket_codec: ManagedIdentityDeletionTicketCodec,
    safety_repository: PostgresManagedSafetyRepository | None = None,
    safety_push_service: ManagedSafetyPushService | None = None,
) -> APIRouter:
    router = APIRouter(prefix="/v1/managed", tags=["managed-storage"])

    async def require_app_check(
        request: Request,
        app_check_token: Annotated[
            str | None,
            Header(alias="X-Firebase-AppCheck"),
        ] = None,
    ) -> ManagedAppAssertion:
        supplied = app_check_token or ""
        try:
            claims = await app_check_verifier.verify(supplied)
        except ManagedAppCheckRejectedError:
            request.state.auth_result = "app_check_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired managed app assertion",
            ) from None
        except ManagedAppCheckUnavailableError:
            request.state.auth_result = "app_check_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed app verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_result = "app_check_accepted"
        return ManagedAppAssertion(token=supplied, claims=claims)

    async def require_claims(
        request: Request,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(managed_security),
        ],
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
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
                detail="invalid or expired managed identity token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from None
        except ManagedIdentityUnavailableError:
            request.state.auth_result = "identity_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed identity verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_scope = "managed_identity"
        request.state.auth_result = "identity_accepted"
        return claims

    def installation_header(
        request: Request,
        installation_id: Annotated[
            str | None,
            Header(alias="X-Noop-Installation-ID"),
        ] = None,
    ) -> str:
        if (
            installation_id is None
            or INSTALLATION_RE.fullmatch(installation_id) is None
        ):
            request.state.auth_result = "installation_id_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="managed installation credential was rejected",
            )
        request.state.auth_result = "installation_id_accepted"
        return installation_id

    def installation_token_header(
        request: Request,
        installation_token: Annotated[
            str | None,
            Header(alias="X-Noop-Installation-Token"),
        ] = None,
    ) -> str:
        if (
            installation_token is None
            or re.fullmatch(
                MANAGED_INSTALLATION_TOKEN_PATTERN,
                installation_token,
            )
            is None
        ):
            request.state.auth_result = "installation_token_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="managed installation credential was rejected",
            )
        request.state.auth_result = "installation_token_accepted"
        return hashlib.sha256(installation_token.encode("ascii")).hexdigest()

    async def require_identity(
        request: Request,
        claims: ManagedIdentityClaims = Depends(require_claims),
        installation_id: str = Depends(installation_header),
        installation_token_hash: str = Depends(installation_token_header),
    ) -> ManagedRequestIdentity:
        try:
            principal = await repository.principal_for_identity(claims)
            await repository.ensure_installation(
                principal=principal,
                installation_id=installation_id,
                installation_token_hash=installation_token_hash,
            )
        except ManagedStorageError as error:
            request.state.auth_result = "installation_rejected"
            _raise_managed(error)
            raise AssertionError("unreachable")
        request.state.auth_scope = "managed_installation"
        request.state.auth_result = "installation_accepted"
        return ManagedRequestIdentity(
            claims=claims,
            principal=principal,
            installation_id=installation_id,
        )

    def require_safety_repository() -> PostgresManagedSafetyRepository:
        if safety_repository is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed Safety is not configured",
            )
        return safety_repository

    def require_safety_push() -> ManagedSafetyPushService:
        if safety_push_service is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed Safety push is not configured",
            )
        return safety_push_service

    @router.post(
        "/enroll",
        status_code=status.HTTP_201_CREATED,
    )
    async def enroll(
        body: ManagedEnrollment,
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
        claims: ManagedIdentityClaims = Depends(require_claims),
    ) -> dict:
        expected_app_id = (
            settings.managed_apple_app_id
            if body.platform == "ios"
            else settings.managed_android_app_id
        )
        if app_assertion.claims.app_id != expected_app_id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="managed app assertion does not match enrollment platform",
            )
        if (
            body.policy_version != settings.managed_consent_policy_version
            or body.policy_sha256 != settings.managed_consent_policy_sha256
        ):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="managed storage policy has changed; review the current policy",
            )
        try:
            result = await repository.enroll(claims=claims, enrollment=body)
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")
        return {
            **result,
            "product_boundary": {
                "account_optional": True,
                "local_metrics_available": True,
                "storage_only_entitlement": True,
            },
        }

    @router.get("/me")
    async def me(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return await repository.overview(principal=identity.principal)
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/social/profile",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_social_profile(
        body: ManagedSocialProfileCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "profile": await repository.create_social_profile(
                    principal=identity.principal,
                    request=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.put("/push/installations/current")
    async def register_push_installation(
        body: ManagedPushRegistration,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        push = require_safety_push()
        try:
            registration = await push.register(
                principal=identity.principal,
                installation_id=identity.installation_id,
                registration=body,
            )
            emit_operational_event(
                "managed_safety.push_registered",
                service="noop-managed-api",
                outcome="completed",
                platform=body.platform,
                environment=body.environment,
                target_kind=body.target_kind,
                duplicate=bool(registration["duplicate"]),
            )
            return {"registration": registration}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/push/installations/current",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def revoke_push_installation(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        repository = require_safety_repository()
        try:
            await repository.revoke_push_installation(
                principal=identity.principal,
                installation_id=identity.installation_id,
            )
            emit_operational_event(
                "managed_safety.push_revoked",
                service="noop-managed-api",
                outcome="completed",
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/safety/invites",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_safety_invite(
        body: ManagedSafetyInviteCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            invite = await repository.create_invite(
                principal=identity.principal,
                request=body,
            )
            emit_operational_event(
                "managed_safety.invite_created",
                service="noop-managed-api",
                outcome="completed",
                duplicate=bool(invite["duplicate"]),
            )
            return {"invite": invite}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/safety/invites/{invite_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def revoke_safety_invite(
        invite_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        repository = require_safety_repository()
        try:
            await repository.revoke_invite(
                principal=identity.principal,
                invite_id=invite_id,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/safety/invites:redeem")
    async def redeem_safety_invite(
        body: ManagedSafetyInviteRedeem,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            request = await repository.redeem_invite(
                principal=identity.principal,
                request_id=body.request_id,
                capability=body.capability.get_secret_value(),
            )
            emit_operational_event(
                "managed_safety.invite_redeemed",
                service="noop-managed-api",
                outcome="pending_acceptance",
                duplicate=bool(request["duplicate"]),
            )
            return {"request": request}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/safety/requests",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_safety_request(
        body: ManagedSafetyRequestCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            request = await repository.create_request(
                principal=identity.principal,
                request=body,
            )
            emit_operational_event(
                "managed_safety.request_created",
                service="noop-managed-api",
                outcome="pending_acceptance",
                duplicate=bool(request["duplicate"]),
            )
            return {"request": request}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/safety/requests")
    async def safety_requests(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            return {
                "requests": await repository.list_requests(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/safety/requests/{request_id}")
    async def decide_safety_request(
        request_id: UUID,
        body: ManagedSafetyRequestDecision,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            request = await repository.decide_request(
                principal=identity.principal,
                request_id=request_id,
                decision=body.decision,
            )
            emit_operational_event(
                "managed_safety.request_decided",
                service="noop-managed-api",
                outcome=body.decision,
                duplicate=bool(request["duplicate"]),
            )
            return {"request": request}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/safety/contacts")
    async def safety_contacts(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            return {
                "contacts": await repository.list_contacts(
                    principal=identity.principal,
                ),
                "minimum_required": 2,
                "maximum_allowed": 5,
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/safety/contacts/{profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def remove_safety_contact(
        profile_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        repository = require_safety_repository()
        try:
            await repository.remove_contact(
                principal=identity.principal,
                other_profile_id=profile_id,
            )
            emit_operational_event(
                "managed_safety.contact_removed",
                service="noop-managed-api",
                outcome="completed",
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/safety/incidents",
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def create_safety_incident(
        body: ManagedSafetyIncidentCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            incident = await repository.create_incident(
                principal=identity.principal,
                request=body,
            )
            duplicate = bool(incident.get("duplicate", False))
            delivery_outcome = "not_configured"
            if safety_push_service is not None:
                try:
                    await safety_push_service.dispatch(
                        principal=identity.principal,
                        incident_id=UUID(incident["incident_id"]),
                    )
                    incident = await repository.get_incident(
                        principal=identity.principal,
                        incident_id=UUID(incident["incident_id"]),
                    )
                    incident["duplicate"] = duplicate
                    delivery_outcome = "attempted"
                except ManagedStorageError:
                    delivery_outcome = "deferred"
            emit_operational_event(
                "managed_safety.incident_created",
                service="noop-managed-api",
                outcome="accepted",
                duplicate=duplicate,
                push=delivery_outcome,
                contacts_targeted=int(
                    incident.get("delivery", {}).get(
                        "contacts_targeted",
                        0,
                    )
                ),
                contacts_reached=int(
                    incident.get("delivery", {}).get(
                        "contacts_reached",
                        0,
                    )
                ),
            )
            return {
                "incident": incident,
                "push_outcome": delivery_outcome,
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/safety/incidents")
    async def safety_incidents(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            return {
                "incidents": await repository.list_incidents(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/safety/incidents/{incident_id}")
    async def safety_incident(
        incident_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            return {
                "incident": await repository.get_incident(
                    principal=identity.principal,
                    incident_id=incident_id,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.put("/safety/incidents/{incident_id}/location")
    async def update_safety_location(
        incident_id: UUID,
        body: ManagedSafetyLocationUpdate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            location = await repository.update_location(
                principal=identity.principal,
                incident_id=incident_id,
                update=body,
            )
            emit_operational_event(
                "managed_safety.location_replaced",
                service="noop-managed-api",
                outcome="completed",
                duplicate=bool(location["duplicate"]),
            )
            return {"location": location}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/safety/incidents/{incident_id}/response")
    async def respond_to_safety_incident(
        incident_id: UUID,
        body: ManagedSafetyResponse,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            incident = await repository.respond(
                principal=identity.principal,
                incident_id=incident_id,
                decision=body.decision,
            )
            emit_operational_event(
                "managed_safety.response_recorded",
                service="noop-managed-api",
                outcome=body.decision,
                duplicate=bool(incident["duplicate"]),
            )
            return {"incident": incident}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/safety/incidents/{incident_id}:end")
    async def end_safety_incident(
        incident_id: UUID,
        body: ManagedSafetyIncidentEnd,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        repository = require_safety_repository()
        try:
            incident = await repository.end_incident(
                principal=identity.principal,
                incident_id=incident_id,
                outcome=body.outcome,
            )
            emit_operational_event(
                "managed_safety.incident_ended",
                service="noop-managed-api",
                outcome=body.outcome,
                duplicate=bool(incident["duplicate"]),
            )
            return {"incident": incident}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/safety/incidents/{incident_id}:retry-push")
    async def retry_safety_push(
        incident_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        push = require_safety_push()
        try:
            delivery = await push.dispatch(
                principal=identity.principal,
                incident_id=incident_id,
            )
            emit_operational_event(
                "managed_safety.push_retried",
                service="noop-managed-api",
                outcome="completed",
                contacts_targeted=delivery["contacts_targeted"],
                contacts_reached=delivery["contacts_reached"],
            )
            return {"delivery": delivery}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/profile")
    async def social_profile(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "profile": await repository.get_social_profile(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/social/profile",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def delete_social_profile(
        confirmation: Annotated[
            str | None,
            Header(alias="X-Noop-Confirm"),
        ] = None,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        if confirmation != "DELETE MANAGED FRIENDS":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="set X-Noop-Confirm to 'DELETE MANAGED FRIENDS'",
            )
        try:
            await repository.delete_social_profile(
                principal=identity.principal,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.patch("/social/profile")
    async def update_social_profile(
        body: ManagedSocialProfilePatch,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "profile": await repository.update_social_profile(
                    principal=identity.principal,
                    patch=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/social/noop-id:rotate")
    async def rotate_social_noop_id(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "profile": await repository.rotate_social_alias(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/lookup")
    async def lookup_social_profile(
        noop_id: Annotated[str, Query(min_length=24, max_length=24)],
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        canonical = noop_id.upper()
        if (
            re.fullmatch(
                (
                    r"NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-"
                    r"[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}"
                ),
                canonical,
            )
            is None
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="NOOP ID is invalid",
            )
        try:
            return {
                "profile": await repository.lookup_social_profile(
                    principal=identity.principal,
                    noop_id=canonical,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/social/invites",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_social_invite(
        body: ManagedSocialInviteCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "invite": await repository.create_social_invite(
                    principal=identity.principal,
                    request=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/social/invites/{invite_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def revoke_social_invite(
        invite_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        try:
            await repository.revoke_social_invite(
                principal=identity.principal,
                invite_id=invite_id,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/social/invites:redeem")
    async def redeem_social_invite(
        body: ManagedSocialInviteRedeem,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "request": await repository.redeem_social_invite(
                    principal=identity.principal,
                    request_id=body.request_id,
                    capability=body.capability.get_secret_value(),
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/social/requests",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_social_request(
        body: ManagedSocialRequestCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "request": await repository.create_social_request(
                    principal=identity.principal,
                    request=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/requests")
    async def social_requests(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "requests": await repository.list_social_requests(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/social/requests/{request_id}")
    async def decide_social_request(
        request_id: UUID,
        body: ManagedSocialRequestDecision,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "request": await repository.decide_social_request(
                    principal=identity.principal,
                    request_id=request_id,
                    decision=body.decision,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/friends")
    async def social_friends(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "friends": await repository.list_social_friends(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.patch("/social/friends/{friend_profile_id}/privacy")
    async def update_social_visibility(
        friend_profile_id: UUID,
        body: ManagedSocialVisibilityPatch,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "sharing": await repository.update_social_visibility(
                    principal=identity.principal,
                    friend_profile_id=friend_profile_id,
                    patch=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/social/friends/{friend_profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def remove_social_friend(
        friend_profile_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        try:
            await repository.remove_social_friend(
                principal=identity.principal,
                friend_profile_id=friend_profile_id,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/social/blocks/{blocked_profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def block_social_profile(
        blocked_profile_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        try:
            await repository.block_social_profile(
                principal=identity.principal,
                blocked_profile_id=blocked_profile_id,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/blocks")
    async def social_blocks(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "blocks": await repository.list_social_blocks(
                    principal=identity.principal,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete(
        "/social/blocks/{blocked_profile_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        response_model=None,
    )
    async def unblock_social_profile(
        blocked_profile_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> None:
        try:
            await repository.unblock_social_profile(
                principal=identity.principal,
                blocked_profile_id=blocked_profile_id,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.put("/social/summaries/{summary_day}")
    async def put_social_summary(
        summary_day: date,
        body: ManagedSocialSummaryMutation,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return {
                "summary": await repository.put_social_summary(
                    principal=identity.principal,
                    day=summary_day,
                    mutation=body,
                )
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/social/feed")
    async def social_feed(
        identity: ManagedRequestIdentity = Depends(require_identity),
        start: date | None = None,
        end: date | None = None,
    ) -> dict:
        selected_end = end or datetime.now(UTC).date()
        selected_start = start or selected_end - timedelta(days=6)
        try:
            return {
                "start": selected_start.isoformat(),
                "end": selected_end.isoformat(),
                "days": await repository.social_feed(
                    principal=identity.principal,
                    start=selected_start,
                    end=selected_end,
                ),
                "units": {
                    "charge": "score_0_to_100",
                    "effort": "score_0_to_100",
                    "rest": "score_0_to_100",
                    "sleep_duration": "minutes",
                    "hrv": "milliseconds",
                    "rhr": "beats_per_minute",
                },
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/social/pokes",
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def create_social_poke(
        body: ManagedSocialPokeCreate,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            poke = await repository.create_social_poke(
                principal=identity.principal,
                request=body,
            )
            emit_operational_event(
                "managed_social.poke_created",
                service="noop-managed-api",
                outcome="queued",
                duplicate=bool(poke["duplicate"]),
            )
            return {"poke": poke}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/social/pokes:claim")
    async def claim_social_pokes(
        limit: Annotated[int, Query(ge=1, le=10)] = 3,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            pokes = await repository.claim_social_pokes(
                principal=identity.principal,
                installation_id=identity.installation_id,
                limit=limit,
            )
            emit_operational_event(
                "managed_social.pokes_claimed",
                service="noop-managed-api",
                outcome="completed",
                count=len(pokes),
            )
            return {"pokes": pokes}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/social/pokes/{poke_id}:ack")
    async def acknowledge_social_poke(
        poke_id: UUID,
        body: ManagedSocialPokeAcknowledgement,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            result = await repository.acknowledge_social_poke(
                principal=identity.principal,
                installation_id=identity.installation_id,
                poke_id=poke_id,
                acknowledgement=body,
            )
            emit_operational_event(
                "managed_social.poke_acknowledged",
                service="noop-managed-api",
                outcome="completed",
                duplicate=bool(result["duplicate"]),
                notification=result.get("notification_outcome", "reported"),
                haptic=result.get("haptic_outcome", "reported"),
            )
            return {"poke": result}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/installations")
    async def list_installations(
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            rows = await repository.list_installations(
                principal=identity.principal,
            )
            return {
                "installations": [
                    {
                        **row,
                        "current": row["installation_id"] == installation_id,
                    }
                    for row in rows
                ]
            }
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.delete("/installations/{target_installation_id}")
    async def revoke_installation(
        target_installation_id: str,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        if INSTALLATION_RE.fullmatch(target_installation_id) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed installation id is invalid",
            )
        try:
            revoked = await repository.revoke_installation(
                principal=identity.principal,
                requesting_installation_id=installation_id,
                installation_id=target_installation_id,
            )
            return {"installation": revoked}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/sources",
        status_code=status.HTTP_201_CREATED,
    )
    async def register_source(
        body: ManagedSourceRegistration,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            source = await repository.register_source(
                principal=identity.principal,
                installation_id=installation_id,
                registration=body,
            )
            return {"source": source}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/keys",
        status_code=status.HTTP_201_CREATED,
    )
    async def register_key(
        body: ManagedClientKeyRegistration,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            key = await repository.register_client_key(
                principal=identity.principal,
                installation_id=installation_id,
                registration=body,
            )
            return {"key": key}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/chunks:reserve",
        status_code=status.HTTP_201_CREATED,
    )
    async def reserve_chunk(
        body: ManagedChunkReservation,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            chunk = await repository.reserve_chunk(
                principal=identity.principal,
                installation_id=installation_id,
                reservation=body,
            )
            if chunk["state"] not in {"reserved", "uploading"}:
                return {"chunk": chunk, "upload": None}
            capability = await object_store.upload_capability(
                object_key=chunk["object_key"],
                content_type=chunk["content_type"],
                content_sha256=chunk["expected_sha256"],
                content_length=chunk["expected_compressed_bytes"],
                expires_in_seconds=settings.managed_upload_ttl_seconds,
            )
            grant_id = await repository.record_upload_grant(
                principal=identity.principal,
                installation_id=installation_id,
                chunk_id=body.chunk_id,
                capability_hash=hashlib.sha256(
                    capability.url.encode("utf-8")
                ).hexdigest(),
                expires_at=capability.expires_at,
            )
            return {
                "chunk": chunk,
                "upload": {
                    "grant_id": grant_id,
                    "method": capability.method,
                    "url": capability.url,
                    "headers": capability.headers,
                    "expires_at": capability.expires_at,
                },
            }
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed object upload is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/chunks/{chunk_id}/complete",
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def complete_chunk(
        chunk_id: UUID,
        body: ManagedChunkCompletion,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            chunk = await repository.chunk_for_upload_completion(
                principal=identity.principal,
                installation_id=installation_id,
                chunk_id=chunk_id,
            )
            metadata = await object_store.metadata(
                object_key=chunk["object_key"],
                generation=body.object_generation,
            )
            if (
                metadata.generation != body.object_generation
                or metadata.metageneration != body.object_metageneration
                or metadata.crc32c != body.object_crc32c
            ):
                raise ManagedConflictError(
                    "object completion does not match Cloud Storage metadata"
                )
            completed = await repository.complete_chunk_upload(
                principal=identity.principal,
                installation_id=installation_id,
                chunk_id=chunk_id,
                metadata=metadata,
            )
            return {
                "chunk": completed,
                "processing": "queued",
            }
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed object metadata is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/chunks")
    async def chunks(
        identity: ManagedRequestIdentity = Depends(require_identity),
        start: datetime | None = None,
        end: datetime | None = None,
        data_class: str | None = None,
        snapshot_at: datetime | None = None,
        after_event_start: datetime | None = None,
        after_chunk_id: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 100,
    ) -> dict:
        if start is not None:
            start = _utc_query(start, "start")
        if end is not None:
            end = _utc_query(end, "end")
        if start is not None and end is not None and start >= end:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="start must be before end",
            )
        if data_class is not None and DATA_CLASS_RE.fullmatch(data_class) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid data_class",
            )
        if snapshot_at is not None:
            snapshot_at = _utc_query(snapshot_at, "snapshot_at")
        if after_event_start is not None:
            after_event_start = _utc_query(
                after_event_start,
                "after_event_start",
            )
        if (after_event_start is None) != (after_chunk_id is None):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="both managed chunk cursor fields are required",
            )
        try:
            rows = await repository.list_available_chunks(
                principal=identity.principal,
                start=start,
                end=end,
                data_class=data_class,
                after_event_start=after_event_start,
                after_chunk_id=after_chunk_id,
                limit=limit + 1,
                snapshot_at=snapshot_at,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")
        has_more = len(rows) > limit
        selected = rows[:limit]
        next_cursor = (
            {
                "after_event_start": selected[-1]["event_start"],
                "after_chunk_id": selected[-1]["chunk_id"],
            }
            if has_more
            else None
        )
        return {"chunks": selected, "next_cursor": next_cursor}

    @router.get("/changes")
    async def changes(
        identity: ManagedRequestIdentity = Depends(require_identity),
        after_sequence: Annotated[int, Query(ge=0)] = 0,
        limit: Annotated[int, Query(ge=1, le=500)] = 200,
        document_kind: Annotated[list[str] | None, Query()] = None,
    ) -> dict:
        if document_kind is not None and (
            len(document_kind) > len(DOCUMENT_KINDS)
            or len(set(document_kind)) != len(document_kind)
            or any(kind not in DOCUMENT_KINDS for kind in document_kind)
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid managed document kind filter",
            )
        try:
            return await repository.list_changes(
                principal=identity.principal,
                after_sequence=after_sequence,
                limit=limit,
                document_kinds=sorted(document_kind)
                if document_kind is not None
                else None,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/chunks/{chunk_id}/download")
    async def download_chunk(
        chunk_id: UUID,
        body: ManagedAccessRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            chunk = await repository.available_chunk(
                principal=identity.principal,
                chunk_id=chunk_id,
            )
            capability = await object_store.download_capability(
                object_key=chunk["object_key"],
                generation=int(chunk["object_generation"]),
                expires_in_seconds=settings.managed_download_ttl_seconds,
            )
            grant_id = await repository.record_access_grant(
                principal=identity.principal,
                installation_id=installation_id,
                chunk_id=chunk_id,
                request_id=body.request_id,
                capability_hash=hashlib.sha256(
                    capability.url.encode("utf-8")
                ).hexdigest(),
                purpose="restore",
                expires_at=capability.expires_at,
            )
            return {
                "grant_id": grant_id,
                "method": capability.method,
                "url": capability.url,
                "headers": capability.headers,
                "expires_at": capability.expires_at,
                "chunk": {
                    "chunk_id": str(chunk["chunk_id"]),
                    "expected_sha256": str(chunk["expected_sha256"]).strip(),
                    "compression": chunk["compression"],
                    "content_type": chunk["content_type"],
                    "expected_uncompressed_bytes": (
                        chunk["expected_uncompressed_bytes"]
                    ),
                },
            }
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed object download is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.put("/documents/{document_kind}/{document_id}")
    async def put_document(
        document_kind: str,
        document_id: UUID,
        body: ManagedDocumentMutation,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        if (
            document_kind not in DOCUMENT_KINDS
            or body.document_kind != document_kind
            or body.document_id != document_id
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed document path and body do not match",
            )
        try:
            document = await repository.put_document(
                principal=identity.principal,
                installation_id=installation_id,
                mutation=body,
            )
            return {"document": document}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/documents/{document_kind}/{document_id}")
    async def get_document(
        document_kind: str,
        document_id: UUID,
        revision: Annotated[int | None, Query(ge=1)] = None,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if document_kind not in DOCUMENT_KINDS:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid managed document kind",
            )
        try:
            document = await repository.get_document(
                principal=identity.principal,
                document_kind=document_kind,
                document_id=document_id,
                revision=revision,
            )
            return {"document": document}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/documents")
    async def list_documents(
        identity: ManagedRequestIdentity = Depends(require_identity),
        document_kind: str | None = None,
        include_deleted: bool = False,
        snapshot_at: datetime | None = None,
        after_updated_at: datetime | None = None,
        after_document_kind: str | None = None,
        after_document_id: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 100,
    ) -> dict:
        if document_kind is not None and document_kind not in DOCUMENT_KINDS:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid managed document kind",
            )
        if (
            after_document_kind is not None
            and after_document_kind not in DOCUMENT_KINDS
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="invalid managed document cursor kind",
            )
        document_cursor = (
            after_updated_at,
            after_document_kind,
            after_document_id,
        )
        if any(value is None for value in document_cursor) and any(
            value is not None for value in document_cursor
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="all managed document cursor fields are required",
            )
        if snapshot_at is not None:
            snapshot_at = _utc_query(snapshot_at, "snapshot_at")
        if after_updated_at is not None:
            after_updated_at = _utc_query(
                after_updated_at,
                "after_updated_at",
            )
        try:
            rows = await repository.list_documents(
                principal=identity.principal,
                document_kind=document_kind,
                include_deleted=include_deleted,
                after_updated_at=after_updated_at,
                after_document_kind=after_document_kind,
                after_document_id=after_document_id,
                snapshot_at=snapshot_at,
                limit=limit + 1,
            )
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")
        has_more = len(rows) > limit
        selected = rows[:limit]
        next_cursor = (
            {
                "after_updated_at": selected[-1]["updated_at"],
                "after_document_kind": selected[-1]["document_kind"],
                "after_document_id": selected[-1]["document_id"],
            }
            if has_more
            else None
        )
        return {"documents": selected, "next_cursor": next_cursor}

    @router.post(
        "/restores",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_restore(
        body: ManagedRestoreRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            restore = await repository.create_restore(
                principal=identity.principal,
                installation_id=installation_id,
                request=body,
            )
            return {"restore": restore}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/exports",
        status_code=status.HTTP_201_CREATED,
    )
    async def create_export(
        body: ManagedExportRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            export = await repository.create_export(
                principal=identity.principal,
                installation_id=installation_id,
                request=body,
            )
            upload = None
            if export["status"] == "running":
                capability = await object_store.upload_capability(
                    object_key=export["object_key"],
                    content_type=body.content_type,
                    content_sha256=body.expected_sha256,
                    content_length=body.expected_bytes,
                    expires_in_seconds=settings.managed_upload_ttl_seconds,
                )
                upload = {
                    "method": capability.method,
                    "url": capability.url,
                    "headers": capability.headers,
                    "expires_at": capability.expires_at,
                }
            return {"export": export, "upload": upload}
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed export upload is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/exports/{export_job_id}/complete")
    async def complete_export(
        export_job_id: UUID,
        body: ManagedExportCompletion,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            export = await repository.get_export(
                principal=identity.principal,
                installation_id=installation_id,
                export_job_id=export_job_id,
            )
            metadata = await object_store.metadata(
                object_key=export["object_key"],
                generation=body.object_generation,
            )
            if (
                metadata.generation != body.object_generation
                or metadata.metageneration != body.object_metageneration
                or metadata.crc32c != body.object_crc32c
            ):
                raise ManagedConflictError(
                    "managed export completion does not match object metadata"
                )
            completed = await repository.complete_export(
                principal=identity.principal,
                installation_id=installation_id,
                export_job_id=export_job_id,
                metadata=metadata,
            )
            return {"export": completed}
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed export verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/exports/{export_job_id}")
    async def get_export(
        export_job_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            export = await repository.get_export(
                principal=identity.principal,
                installation_id=installation_id,
                export_job_id=export_job_id,
            )
            return {"export": export}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/exports/{export_job_id}/download")
    async def download_export(
        export_job_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            export = await repository.get_export(
                principal=identity.principal,
                installation_id=installation_id,
                export_job_id=export_job_id,
            )
            now = await repository.coordination_now()
            if (
                export["status"] != "completed"
                or export["output_generation"] is None
                or export["expires_at"] <= now
            ):
                raise ManagedConflictError(
                    "managed export is not available for download"
                )
            capability = await object_store.download_capability(
                object_key=export["object_key"],
                generation=int(export["output_generation"]),
                expires_in_seconds=settings.managed_download_ttl_seconds,
            )
            return {
                "export": export,
                "download": {
                    "method": capability.method,
                    "url": capability.url,
                    "headers": capability.headers,
                    "expires_at": capability.expires_at,
                },
            }
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed export download is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/restores/{restore_job_id}")
    async def get_restore(
        restore_job_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            restore = await repository.get_restore(
                principal=identity.principal,
                installation_id=installation_id,
                restore_job_id=restore_job_id,
            )
            return {"restore": restore}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/restores/{restore_job_id}/complete")
    async def complete_restore(
        restore_job_id: UUID,
        body: ManagedRestoreCompletion,
        identity: ManagedRequestIdentity = Depends(require_identity),
        installation_id: str = Depends(installation_header),
    ) -> dict:
        try:
            restore = await repository.complete_restore(
                principal=identity.principal,
                installation_id=installation_id,
                restore_job_id=restore_job_id,
                delivered_objects=body.delivered_objects,
                delivered_bytes=body.delivered_bytes,
            )
            return {"restore": restore}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post(
        "/erasure",
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def request_erasure(
        body: ManagedErasureRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if not hmac.compare_digest(
            body.confirmation_sha256,
            ERASURE_CONFIRMATION_SHA256[body.scope],
        ):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed erasure confirmation does not match its scope",
            )
        now = await repository.coordination_now()
        if now - identity.claims.auth_time > timedelta(minutes=5):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="recent reauthentication is required for erasure",
                headers={"WWW-Authenticate": "Bearer"},
            )
        try:
            identity_deletion_ticket = None
            if body.scope == "account":
                identity_deletion_ticket = identity_deletion_ticket_codec.seal(
                    local_id=identity.claims.subject,
                    provider_tenant=identity.claims.provider_tenant,
                    account_id=identity.principal.account_id,
                    request_id=body.request_id,
                )
            job = await repository.request_erasure(
                principal=identity.principal,
                request_id=body.request_id,
                scope=body.scope,
                confirmation_sha256=body.confirmation_sha256,
                identity_deletion_ticket=identity_deletion_ticket,
                cooling_off=(
                    timedelta(hours=24)
                    if body.scope in {"all_managed_data", "account"}
                    else timedelta(0)
                ),
            )
            return {"erasure": job}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/erasure/{erasure_job_id}")
    async def get_erasure(
        erasure_job_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            job = await repository.get_erasure(
                principal=identity.principal,
                erasure_job_id=erasure_job_id,
            )
            return {"erasure": job}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.post("/erasure/{erasure_job_id}/cancel")
    async def cancel_erasure(
        erasure_job_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            job = await repository.cancel_erasure(
                principal=identity.principal,
                erasure_job_id=erasure_job_id,
            )
            return {"erasure": job}
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    return router


def _utc_query(value: datetime, name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"{name} must include a UTC offset",
        )
    return value.astimezone(UTC)


def _raise_managed(error: ManagedStorageError) -> None:
    if isinstance(error, ManagedNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(error),
        )
    if isinstance(error, ManagedForbiddenError):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=str(error),
        )
    if isinstance(error, ManagedRateLimitError):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=str(error),
            headers={"Retry-After": str(error.retry_after_seconds)},
        )
    if isinstance(error, ManagedQuotaExceededError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": str(error),
                "maximum_bytes": error.maximum_bytes,
                "projected_usage": error.used_bytes,
            },
        )
    if isinstance(error, ManagedConflictError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(error),
        )
    if isinstance(error, ManagedCursorExpiredError):
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail={
                "message": str(error),
                "minimum_sequence": error.minimum_sequence,
                "restore_required": True,
            },
        )
    if isinstance(error, ManagedConfigurationError):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="managed storage is not configured for this request",
        )
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="managed storage request failed",
    )
