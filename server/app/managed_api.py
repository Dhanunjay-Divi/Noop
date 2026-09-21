from __future__ import annotations

import base64
import hashlib
import hmac
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Literal
from uuid import UUID

from fastapi import (
    APIRouter,
    Depends,
    Header,
    HTTPException,
    Path,
    Query,
    Request,
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
from app.managed_identity_deletion import ManagedIdentityDeletionTicketCodec
from app.managed_formula_executor import (
    ClientFormulaObservation,
    FormulaDayContext,
    FormulaInputContractError,
    FormulaProvenance,
    ManagedFormulaExecutor,
)
from app.managed_formula_repository import (
    FormulaShadowAccountUnavailableError,
    FormulaShadowConflictError,
    PostgresManagedFormulaRepository,
)
from app.managed_formula_registry import CANONICAL_FORMULA_METRIC_KEYS
from app.managed_document_keys import (
    ManagedDocumentKeyConflictError,
    ManagedDocumentKeyDisabledError,
    ManagedDocumentKeyNotFoundError,
    ManagedWrappedKeyMutation,
    PostgresManagedDocumentKeyRepository,
)
from app.managed_models import (
    MANAGED_DOCUMENT_KINDS,
    MANAGED_INSTALLATION_TOKEN_PATTERN,
    ManagedAccountEnrollment,
    ManagedAccessRequest,
    ManagedAuthorityOptOutRequest,
    ManagedAuthorityReconsentRequest,
    ManagedChunkCompletion,
    ManagedChunkReservation,
    ManagedClientPlatform,
    ManagedClientKeyRegistration,
    ManagedDocumentMutation,
    ManagedEnrollment,
    ManagedErasureRequest,
    ManagedExportCompletion,
    ManagedExportRequest,
    ManagedFormulaShadowRequest,
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
    ManagedWrappedDocumentKeyMutation,
    ManagedWrappedDocumentKeyRevocation,
    ManagedWrappedDocumentKeyRotation,
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
from app.unified_identity_authority import (
    AuthorityTransitionConflictError,
    AuthorityTransitionRejectedError,
    PostgresUnifiedIdentityAuthorityRepository,
    UnifiedIdentityCollisionError,
    UnifiedIdentityUnavailableError,
    UnifiedPrincipal,
)

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
    platform: ManagedClientPlatform
    unified_principal: UnifiedPrincipal | None = None


MACOS_VIEWER_RESTORE_POST_ROUTES = frozenset(
    {
        "/v1/managed/chunks/{chunk_id}/download",
        "/v1/managed/restores",
        "/v1/managed/restores/{restore_job_id}/complete",
    }
)


def macos_managed_viewer_access(
    *,
    method: str,
    route_template: str | None,
) -> str | None:
    """Return the bounded macOS viewer capability for one managed route."""

    normalized_method = method.upper()
    if normalized_method == "GET":
        return "read"
    if (
        normalized_method == "POST"
        and route_template in MACOS_VIEWER_RESTORE_POST_ROUTES
    ):
        return "restore"
    return None


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
    unified_identity_authority_repository: (
        PostgresUnifiedIdentityAuthorityRepository | None
    ) = None,
    formula_repository: PostgresManagedFormulaRepository | None = None,
    formula_executor: ManagedFormulaExecutor | None = None,
    document_key_repository: PostgresManagedDocumentKeyRepository | None = None,
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
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
        installation_id: str = Depends(installation_header),
        installation_token_hash: str = Depends(installation_token_header),
    ) -> ManagedRequestIdentity:
        try:
            principal = await repository.principal_for_identity(claims)
            installation = await repository.ensure_installation(
                principal=principal,
                installation_id=installation_id,
                installation_token_hash=installation_token_hash,
            )
        except ManagedStorageError as error:
            request.state.auth_result = "installation_rejected"
            _raise_managed(error)
            raise AssertionError("unreachable")
        platform = installation.get("platform")
        if platform not in {"ios", "android", "macos"}:
            request.state.auth_result = "installation_platform_rejected"
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="managed installation platform is not supported",
            )
        if platform in {"ios", "android"}:
            require_matching_platform(
                platform=platform,
                app_assertion=app_assertion,
                request=request,
            )
        if platform == "macos":
            if not settings.managed_macos_app_id:
                request.state.auth_result = "macos_viewer_unavailable"
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="managed macOS viewer is not configured",
                )
            if app_assertion.claims.app_id != settings.managed_macos_app_id:
                request.state.auth_result = "macos_viewer_app_check_rejected"
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="managed app assertion does not match installation platform",
                )
            route = request.scope.get("route")
            route_template = getattr(route, "path", None)
            if (
                macos_managed_viewer_access(
                    method=request.method,
                    route_template=route_template,
                )
                is None
            ):
                request.state.auth_result = "macos_viewer_write_rejected"
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="managed macOS viewer is read-only",
                )
        unified_principal = await reconcile_unified_identity(
            request=request,
            claims=claims,
            principal=principal,
        )
        request.state.auth_scope = "managed_installation"
        request.state.auth_result = "installation_accepted"
        return ManagedRequestIdentity(
            claims=claims,
            principal=principal,
            installation_id=installation_id,
            platform=platform,
            unified_principal=unified_principal,
        )

    async def reconcile_unified_identity(
        *,
        request: Request,
        claims: ManagedIdentityClaims,
        principal: ManagedPrincipal,
    ) -> UnifiedPrincipal | None:
        if unified_identity_authority_repository is None:
            return None
        try:
            unified = await unified_identity_authority_repository.reconcile_identity(
                claims
            )
        except (
            UnifiedIdentityCollisionError,
            AuthorityTransitionConflictError,
        ) as error:
            request.state.auth_result = "unified_identity_conflict"
            _raise_unified_identity(error)
            raise AssertionError("unreachable")
        except UnifiedIdentityUnavailableError as error:
            request.state.auth_result = "unified_identity_unavailable"
            _raise_unified_identity(error)
            raise AssertionError("unreachable")
        if (
            unified.managed_account_id != principal.account_id
            or unified.managed_identity_id != principal.identity_id
        ):
            request.state.auth_result = "unified_identity_mismatch"
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="managed account identity is linked differently",
            )
        request.state.auth_result = "unified_identity_accepted"
        return unified

    def require_unified_principal(
        identity: ManagedRequestIdentity,
    ) -> UnifiedPrincipal:
        if (
            unified_identity_authority_repository is None
            or identity.unified_principal is None
        ):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed authority state is not configured",
            )
        return identity.unified_principal

    def require_formula_shadow() -> tuple[
        PostgresManagedFormulaRepository,
        ManagedFormulaExecutor,
    ]:
        if (
            not settings.managed_formula_shadow_enabled
            or formula_repository is None
            or formula_executor is None
        ):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed formula shadow comparison is not configured",
            )
        return formula_repository, formula_executor

    def require_document_key_recovery() -> PostgresManagedDocumentKeyRepository:
        if (
            not settings.managed_document_key_recovery_enabled
            or document_key_repository is None
        ):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed document key recovery is not configured",
            )
        return document_key_repository

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

    def require_available_safety_push() -> ManagedSafetyPushService:
        push = require_safety_push()
        if not push.available:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed Safety push is temporarily unavailable",
            )
        return push

    def require_matching_platform(
        *,
        platform: ManagedClientPlatform,
        app_assertion: ManagedAppAssertion,
        request: Request,
    ) -> None:
        expected_app_id = {
            "ios": settings.managed_apple_app_id,
            "android": settings.managed_android_app_id,
            "macos": settings.managed_macos_app_id,
        }[platform]
        if not expected_app_id:
            request.state.auth_result = "managed_platform_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed enrollment is not configured for this platform",
            )
        if app_assertion.claims.app_id != expected_app_id:
            request.state.auth_result = "managed_platform_app_check_mismatch"
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="managed app assertion does not match enrollment platform",
            )

    @router.post(
        "/account/enroll",
        status_code=status.HTTP_201_CREATED,
    )
    async def enroll_account(
        body: ManagedAccountEnrollment,
        request: Request,
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
        claims: ManagedIdentityClaims = Depends(require_claims),
    ) -> dict:
        outcome = "rejected"
        try:
            require_matching_platform(
                platform=body.platform,
                app_assertion=app_assertion,
                request=request,
            )
            try:
                result = await repository.enroll_account(
                    claims=claims,
                    enrollment=body,
                )
                principal = await repository.principal_for_identity(claims)
            except ManagedStorageError as error:
                _raise_managed(error)
                raise AssertionError("unreachable")
            await reconcile_unified_identity(
                request=request,
                claims=claims,
                principal=principal,
            )
            outcome = "created" if result["created"] else "existing"
            return {
                **result,
                "product_boundary": {
                    "account_ready": True,
                    "health_data_consent_granted": bool(
                        result["account"]["health_data_consent_granted"]
                    ),
                    "health_data_uploaded": bool(
                        result["account"]["health_data_uploaded"]
                    ),
                    "edge_collection_required": True,
                },
            }
        finally:
            emit_operational_event(
                "managed_account.enrollment",
                service="noop-managed-api",
                outcome=outcome,
                platform=body.platform,
            )

    @router.post(
        "/enroll",
        status_code=status.HTTP_201_CREATED,
    )
    async def enroll(
        body: ManagedEnrollment,
        request: Request,
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
        claims: ManagedIdentityClaims = Depends(require_claims),
    ) -> dict:
        outcome = "rejected"
        try:
            require_matching_platform(
                platform=body.platform,
                app_assertion=app_assertion,
                request=request,
            )
            if (
                body.policy_version != settings.managed_consent_policy_version
                or body.policy_sha256 != settings.managed_consent_policy_sha256
            ):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=(
                        "managed storage policy has changed; review the current policy"
                    ),
                )
            try:
                result = await repository.enroll(claims=claims, enrollment=body)
                principal = await repository.principal_for_identity(claims)
            except ManagedStorageError as error:
                _raise_managed(error)
                raise AssertionError("unreachable")
            await reconcile_unified_identity(
                request=request,
                claims=claims,
                principal=principal,
            )
            outcome = "created" if result["created"] else "existing"
            return {
                **result,
                "product_boundary": {
                    "account_optional": True,
                    "local_metrics_available": True,
                    "storage_only_entitlement": True,
                    "cloud_authority_mode": "staged_per_data_class",
                    "formula_authority": "client_until_parity_approved",
                    "edge_collection_required": True,
                },
            }
        finally:
            emit_operational_event(
                "managed_storage.enrollment",
                service="noop-managed-api",
                outcome=outcome,
                platform=body.platform,
                data_class_count=len(body.data_classes),
            )

    @router.get("/me")
    async def me(
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        try:
            return await repository.overview(principal=identity.principal)
        except ManagedStorageError as error:
            _raise_managed(error)
            raise AssertionError("unreachable")

    @router.get("/authority/{data_class}")
    async def get_authority_state(
        data_class: str,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if DATA_CLASS_RE.fullmatch(data_class) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed data class is invalid",
            )
        unified = require_unified_principal(identity)
        try:
            authority = await unified_identity_authority_repository.authority_state(
                principal_id=unified.principal_id,
                managed_account_id=identity.principal.account_id,
                data_class=data_class,
            )
        except (
            UnifiedIdentityUnavailableError,
            UnifiedIdentityCollisionError,
            AuthorityTransitionConflictError,
            AuthorityTransitionRejectedError,
        ) as error:
            _raise_unified_identity(error)
            raise AssertionError("unreachable")
        return {"authority": _authority_response(authority)}

    @router.post("/authority/{data_class}/opt-out")
    async def opt_out_authority(
        data_class: str,
        body: ManagedAuthorityOptOutRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if DATA_CLASS_RE.fullmatch(data_class) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed data class is invalid",
            )
        unified = require_unified_principal(identity)
        try:
            result = await unified_identity_authority_repository.request_rollback(
                principal_id=unified.principal_id,
                managed_account_id=identity.principal.account_id,
                data_class=data_class,
                request_id=body.request_id,
                opt_out=True,
            )
            current = await unified_identity_authority_repository.authority_state(
                principal_id=unified.principal_id,
                managed_account_id=identity.principal.account_id,
                data_class=data_class,
            )
        except (
            UnifiedIdentityUnavailableError,
            UnifiedIdentityCollisionError,
            AuthorityTransitionConflictError,
            AuthorityTransitionRejectedError,
        ) as error:
            _raise_unified_identity(error)
            raise AssertionError("unreachable")
        emit_operational_event(
            "managed_authority.opt_out",
            service="noop-managed-api",
            outcome="completed",
            authority_state=result.state,
            pruning_authorized=result.pruning_authorized,
            duplicate=result.duplicate,
        )
        return {
            "authority": _authority_response(current),
            "duplicate": result.duplicate,
        }

    @router.post("/authority/{data_class}/re-consent")
    async def reconsent_authority(
        data_class: str,
        body: ManagedAuthorityReconsentRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if DATA_CLASS_RE.fullmatch(data_class) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="managed data class is invalid",
            )
        if (
            body.policy_version != settings.managed_consent_policy_version
            or body.policy_sha256 != settings.managed_consent_policy_sha256
        ):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="managed storage policy has changed; review the current policy",
            )
        unified = require_unified_principal(identity)
        try:
            result = await unified_identity_authority_repository.record_reconsent(
                principal_id=unified.principal_id,
                managed_account_id=identity.principal.account_id,
                data_class=data_class,
                request_id=body.request_id,
                policy_kind=settings.managed_consent_policy_kind,
                policy_version=body.policy_version,
                policy_sha256=body.policy_sha256,
                installation_id=identity.installation_id,
            )
            current = await unified_identity_authority_repository.authority_state(
                principal_id=unified.principal_id,
                managed_account_id=identity.principal.account_id,
                data_class=data_class,
            )
        except (
            UnifiedIdentityUnavailableError,
            UnifiedIdentityCollisionError,
            AuthorityTransitionConflictError,
            AuthorityTransitionRejectedError,
        ) as error:
            _raise_unified_identity(error)
            raise AssertionError("unreachable")
        emit_operational_event(
            "managed_authority.reconsent",
            service="noop-managed-api",
            outcome="completed",
            authority_state=result.state,
            pruning_authorized=result.pruning_authorized,
            duplicate=result.duplicate,
        )
        return {
            "authority": _authority_response(current),
            "duplicate": result.duplicate,
        }

    @router.post("/formula-shadow/{metric_key}/{formula_revision}")
    async def publish_formula_shadow(
        metric_key: str,
        formula_revision: str,
        body: ManagedFormulaShadowRequest,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        formula_store, executor = require_formula_shadow()
        outcome = "rejected"
        parity_status = "unknown"
        server_status = "unknown"
        try:
            execution = executor.execute(
                metric_key=metric_key,
                formula_revision=formula_revision,
                context=FormulaDayContext.create(
                    account_id=identity.principal.account_id,
                    local_day=body.local_day,
                    timezone_name=body.timezone_name,
                ),
                inputs=body.inputs,
                provenance=FormulaProvenance(
                    source_kind=body.provenance.source_kind,
                    source_revision=body.provenance.source_revision,
                    input_manifest_sha256=(body.provenance.input_manifest_sha256),
                    calibration_revision=(body.provenance.calibration_revision),
                ),
                client_observation=ClientFormulaObservation(
                    status=body.client_observation.status,
                    formula_revision=(body.client_observation.formula_revision),
                    value=body.client_observation.value,
                ),
            )
            record = await formula_store.publish_shadow(
                principal=identity.principal,
                request_id=body.request_id,
                execution=execution,
                now=await repository.coordination_now(),
            )
            parity_status = record.parity_status
            server_status = record.server_status
            outcome = "completed"
            return {
                "authority": "shadow_only",
                "result": _formula_shadow_response(record),
            }
        except (KeyError, FormulaInputContractError):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="formula shadow request did not match a registered contract",
            ) from None
        except FormulaShadowConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="formula shadow request conflicted with existing work",
            ) from None
        except FormulaShadowAccountUnavailableError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="formula shadow account is not active",
            ) from None
        finally:
            emit_operational_event(
                "managed_formula.shadow_publication",
                service="noop-managed-api",
                outcome=outcome,
                metric_key=(
                    metric_key
                    if metric_key in CANONICAL_FORMULA_METRIC_KEYS
                    else "unregistered"
                ),
                parity_status=parity_status,
                server_status=server_status,
                authority="shadow_only",
            )

    @router.get("/formula-shadow/{metric_key}/current")
    async def current_formula_shadow(
        metric_key: str,
        local_day: date = Query(),
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        if DATA_CLASS_RE.fullmatch(metric_key) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="formula metric key is invalid",
            )
        formula_store, _ = require_formula_shadow()
        try:
            record = await formula_store.current_result(
                principal=identity.principal,
                metric_key=metric_key,
                local_day=local_day,
            )
        except FormulaShadowAccountUnavailableError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="formula shadow account is not active",
            ) from None
        if record is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="formula shadow result was not found",
            )
        return {
            "authority": "shadow_only",
            "result": _formula_shadow_response(record),
        }

    @router.put("/document-keys/{key_id}")
    async def put_document_key(
        key_id: UUID,
        body: ManagedWrappedDocumentKeyMutation,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        key_store = require_document_key_recovery()
        outcome = "rejected"
        try:
            record = await key_store.put(
                principal=identity.principal,
                mutation=_wrapped_key_mutation(key_id, body),
                now=await repository.coordination_now(),
            )
            outcome = "completed"
            return {"key": _wrapped_key_response(record)}
        except (
            ManagedDocumentKeyDisabledError,
            ManagedDocumentKeyConflictError,
            ManagedDocumentKeyNotFoundError,
            ValueError,
        ) as error:
            _raise_document_key(error)
            raise AssertionError("unreachable")
        finally:
            emit_operational_event(
                "managed_documents.key_mutation",
                service="noop-managed-api",
                outcome=outcome,
                operation="put",
                key_kind=body.key_kind,
            )

    @router.get("/document-keys/{key_id}")
    async def get_document_key(
        key_id: UUID,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        key_store = require_document_key_recovery()
        outcome = "not_found"
        key_kind = "unknown"
        try:
            record = await key_store.get(
                principal=identity.principal,
                key_id=key_id,
            )
            outcome = "completed"
            key_kind = record.key_kind
            return {"key": _wrapped_key_response(record)}
        except (
            ManagedDocumentKeyDisabledError,
            ManagedDocumentKeyConflictError,
            ManagedDocumentKeyNotFoundError,
            ValueError,
        ) as error:
            _raise_document_key(error)
            raise AssertionError("unreachable")
        finally:
            emit_operational_event(
                "managed_documents.key_read",
                service="noop-managed-api",
                outcome=outcome,
                key_kind=key_kind,
            )

    @router.get("/document-keys/{key_id}/versions/{wrapping_revision}")
    async def get_document_key_version(
        key_id: UUID,
        wrapping_revision: Annotated[int, Path(ge=1, le=1_000_000)],
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        key_store = require_document_key_recovery()
        outcome = "not_found"
        key_kind = "unknown"
        try:
            record = await key_store.get_version(
                principal=identity.principal,
                key_id=key_id,
                wrapping_revision=wrapping_revision,
            )
            outcome = "completed"
            key_kind = record.key_kind
            return {"key_version": _wrapped_key_version_response(record)}
        except (
            ManagedDocumentKeyDisabledError,
            ManagedDocumentKeyConflictError,
            ManagedDocumentKeyNotFoundError,
            ValueError,
        ) as error:
            _raise_document_key(error)
            raise AssertionError("unreachable")
        finally:
            emit_operational_event(
                "managed_documents.key_version_read",
                service="noop-managed-api",
                outcome=outcome,
                key_kind=key_kind,
            )

    @router.post("/document-keys/{key_id}/rotate")
    async def rotate_document_key(
        key_id: UUID,
        body: ManagedWrappedDocumentKeyRotation,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        key_store = require_document_key_recovery()
        outcome = "rejected"
        try:
            record = await key_store.rotate_wrapping(
                principal=identity.principal,
                mutation=_wrapped_key_mutation(key_id, body),
                expected_wrapping_revision=(body.expected_wrapping_revision),
                now=await repository.coordination_now(),
            )
            outcome = "completed"
            return {"key": _wrapped_key_response(record)}
        except (
            ManagedDocumentKeyDisabledError,
            ManagedDocumentKeyConflictError,
            ManagedDocumentKeyNotFoundError,
            ValueError,
        ) as error:
            _raise_document_key(error)
            raise AssertionError("unreachable")
        finally:
            emit_operational_event(
                "managed_documents.key_mutation",
                service="noop-managed-api",
                outcome=outcome,
                operation="rotate",
                key_kind=body.key_kind,
            )

    @router.post("/document-keys/{key_id}/revoke")
    async def revoke_document_key(
        key_id: UUID,
        body: ManagedWrappedDocumentKeyRevocation,
        identity: ManagedRequestIdentity = Depends(require_identity),
    ) -> dict:
        key_store = require_document_key_recovery()
        outcome = "not_found"
        key_kind = "unknown"
        try:
            record = await key_store.revoke(
                principal=identity.principal,
                key_id=key_id,
                successor_key_id=body.successor_key_id,
                now=await repository.coordination_now(),
            )
            outcome = "completed"
            key_kind = record.key_kind
            return {"key": _wrapped_key_response(record)}
        except (
            ManagedDocumentKeyDisabledError,
            ManagedDocumentKeyConflictError,
            ManagedDocumentKeyNotFoundError,
            ValueError,
        ) as error:
            _raise_document_key(error)
            raise AssertionError("unreachable")
        finally:
            emit_operational_event(
                "managed_documents.key_mutation",
                service="noop-managed-api",
                outcome=outcome,
                operation="revoke",
                key_kind=key_kind,
            )

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
            contacts, delivery_capable_count = await repository.contact_snapshot(
                principal=identity.principal,
            )
            if safety_push_service is None or not safety_push_service.available:
                delivery_capable_count = 0
            return {
                "contacts": contacts,
                "delivery_capable_count": delivery_capable_count,
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
        push = require_available_safety_push()
        try:
            incident = await repository.create_incident(
                principal=identity.principal,
                request=body,
            )
            duplicate = bool(incident.get("duplicate", False))
            delivery_outcome = "attempted"
            try:
                await push.dispatch(
                    principal=identity.principal,
                    incident_id=UUID(incident["incident_id"]),
                )
                incident = await repository.get_incident(
                    principal=identity.principal,
                    incident_id=UUID(incident["incident_id"]),
                )
                incident["duplicate"] = duplicate
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
        content_mode: Literal["server_readable", "client_encrypted"] = (
            "server_readable"
        ),
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
                content_mode=content_mode,
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

    @router.get("/erasure/{erasure_job_id}/receipt")
    async def get_erasure_receipt(
        erasure_job_id: UUID,
        app_assertion: ManagedAppAssertion = Depends(require_app_check),
        installation_id: str = Depends(installation_header),
        installation_token_hash: str = Depends(installation_token_header),
    ) -> dict:
        try:
            job, platform = await repository.get_erasure_receipt(
                erasure_job_id=erasure_job_id,
                installation_id=installation_id,
                installation_token_hash=installation_token_hash,
            )
            expected_app_id = {
                "ios": settings.managed_apple_app_id,
                "android": settings.managed_android_app_id,
                "macos": settings.managed_macos_app_id,
            }.get(platform)
            if (
                expected_app_id is None
                or app_assertion.claims.app_id != expected_app_id
            ):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="managed app assertion does not match installation platform",
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


def _authority_response(authority: object) -> dict:
    return {
        "data_class": getattr(authority, "data_class"),
        "state": getattr(authority, "state"),
        "transition_version": getattr(authority, "transition_version"),
        "pruning_authorized": bool(getattr(authority, "pruning_authorized")),
        "last_opt_out_at": getattr(authority, "last_opt_out_at"),
        "last_reconsented_at": getattr(authority, "last_reconsented_at"),
        "reconsent_policy_version": getattr(
            authority,
            "reconsent_policy_version",
        ),
        "reconsent_policy_sha256": getattr(
            authority,
            "reconsent_policy_sha256",
        ),
    }


def _formula_shadow_response(record: object) -> dict:
    return {
        "metric_key": getattr(record, "metric_key"),
        "formula_revision": getattr(record, "formula_revision"),
        "input_schema_revision": getattr(record, "input_schema_revision"),
        "output_unit": getattr(record, "output_unit"),
        "local_day": getattr(record, "local_day"),
        "server_status": getattr(record, "server_status"),
        "server_value": getattr(record, "server_value"),
        "client_status": getattr(record, "client_status"),
        "client_formula_revision": getattr(record, "client_formula_revision"),
        "client_value": getattr(record, "client_value"),
        "parity_status": getattr(record, "parity_status"),
        "absolute_delta": getattr(record, "absolute_delta"),
        "parity_tolerance": getattr(record, "parity_tolerance"),
        "missing_inputs": list(getattr(record, "missing_inputs")),
        "publication_kind": getattr(record, "publication_kind"),
        "is_current": bool(getattr(record, "is_current")),
        "created_at": getattr(record, "created_at"),
    }


def _wrapped_key_mutation(
    key_id: UUID,
    body: ManagedWrappedDocumentKeyMutation,
) -> ManagedWrappedKeyMutation:
    try:
        wrapped_key = base64.b64decode(
            body.wrapped_key_base64.get_secret_value(),
            validate=True,
        )
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="wrapped document key is invalid",
        ) from error
    try:
        return ManagedWrappedKeyMutation(
            key_id=key_id,
            key_kind=body.key_kind,
            wrapping_key_id=body.wrapping_key_id,
            wrapping_revision=body.wrapping_revision,
            algorithm=body.algorithm,
            wrapped_key=wrapped_key,
            wrapped_key_sha256=body.wrapped_key_sha256,
            master_key_confirmation_hmac_sha256=(
                body.master_key_confirmation_hmac_sha256
            ),
            recovery_method=body.recovery_method,
        )
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="wrapped document key contract is invalid",
        ) from error


def _wrapped_key_response(record: object) -> dict:
    return {
        "key_id": getattr(record, "key_id"),
        "key_kind": getattr(record, "key_kind"),
        "wrapping_key_id": getattr(record, "wrapping_key_id"),
        "wrapping_revision": getattr(record, "wrapping_revision"),
        "algorithm": getattr(record, "algorithm"),
        "wrapped_key_base64": base64.b64encode(getattr(record, "wrapped_key")).decode(
            "ascii"
        ),
        "wrapped_key_sha256": getattr(record, "wrapped_key_sha256"),
        "master_key_confirmation_hmac_sha256": getattr(
            record,
            "master_key_confirmation_hmac_sha256",
        ),
        "recovery_method": getattr(record, "recovery_method"),
        "status": getattr(record, "status"),
        "successor_key_id": getattr(record, "successor_key_id"),
        "created_at": getattr(record, "created_at"),
        "updated_at": getattr(record, "updated_at"),
        "revoked_at": getattr(record, "revoked_at"),
    }


def _wrapped_key_version_response(record: object) -> dict:
    return {
        "key_id": getattr(record, "key_id"),
        "key_kind": getattr(record, "key_kind"),
        "wrapping_key_id": getattr(record, "wrapping_key_id"),
        "wrapping_revision": getattr(record, "wrapping_revision"),
        "algorithm": getattr(record, "algorithm"),
        "wrapped_key_base64": base64.b64encode(getattr(record, "wrapped_key")).decode(
            "ascii"
        ),
        "wrapped_key_sha256": getattr(record, "wrapped_key_sha256"),
        "master_key_confirmation_hmac_sha256": getattr(
            record,
            "master_key_confirmation_hmac_sha256",
        ),
        "recovery_method": getattr(record, "recovery_method"),
        "created_at": getattr(record, "created_at"),
    }


def _raise_document_key(error: Exception) -> None:
    if isinstance(error, ManagedDocumentKeyDisabledError):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="managed document key recovery is not configured",
        )
    if isinstance(error, ManagedDocumentKeyNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="managed document key was not found",
        )
    if isinstance(error, ManagedDocumentKeyConflictError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="managed document key conflicted with existing state",
        )
    if isinstance(error, ValueError):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="managed document key request was invalid",
        )
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="managed document key request failed",
    )


def _raise_unified_identity(error: Exception) -> None:
    if isinstance(error, UnifiedIdentityUnavailableError):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="managed account identity is temporarily unavailable",
            headers={"Retry-After": "5"},
        )
    if isinstance(
        error,
        (
            UnifiedIdentityCollisionError,
            AuthorityTransitionConflictError,
        ),
    ):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="managed account identity or authority state conflicted",
        )
    if isinstance(error, AuthorityTransitionRejectedError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="managed authority transition was rejected",
        )
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="managed identity authority request failed",
    )
