from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings
from app.feedback_archive import (
    FeedbackArchiveRejectedError,
    validate_feedback_archive,
)
from app.feedback_capability import FeedbackCapabilityCodec
from app.feedback_models import (
    FeedbackCompletionRequest,
    FeedbackReservationRequest,
    FeedbackReservationResponse,
    FeedbackStatusResponse,
    FeedbackUploadCapability,
)
from app.feedback_repository import (
    FeedbackConflictError,
    FeedbackNotFoundError,
    FeedbackQuotaExceededError,
    FeedbackReport,
    FeedbackRepository,
)
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
from app.managed_object_store import (
    ManagedObjectNotFoundError,
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.observability import emit_operational_event


_IDEMPOTENCY_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-"
    r"[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
_REPORT_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,64}$")
_security = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class FeedbackPrincipal:
    app_check: ManagedAppCheckClaims
    identity: ManagedIdentityClaims


def feedback_router(
    *,
    settings: Settings,
    repository: FeedbackRepository,
    app_check_verifier: ManagedAppCheckVerifying,
    token_verifier: ManagedTokenVerifying,
    object_store: ManagedObjectStoring,
    capability_codec: FeedbackCapabilityCodec,
) -> APIRouter:
    router = APIRouter(prefix="/v1/feedback", tags=["feedback"])

    @dataclass(frozen=True, slots=True)
    class AppAssertion:
        token: str
        claims: ManagedAppCheckClaims

    async def require_app_check(
        request: Request,
        app_check_token: Annotated[
            str | None,
            Header(alias="X-Firebase-AppCheck"),
        ] = None,
    ) -> AppAssertion:
        supplied = app_check_token or ""
        try:
            claims = await app_check_verifier.verify(supplied)
        except ManagedAppCheckRejectedError:
            request.state.auth_scope = "feedback_app_check"
            request.state.auth_result = "app_check_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired feedback app assertion",
            ) from None
        except ManagedAppCheckUnavailableError:
            request.state.auth_scope = "feedback_app_check"
            request.state.auth_result = "app_check_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="feedback app verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_scope = "feedback_app_check"
        request.state.auth_result = "app_check_accepted"
        return AppAssertion(token=supplied, claims=claims)

    async def require_identity(
        request: Request,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(_security),
        ],
        app_assertion: AppAssertion = Depends(require_app_check),
    ) -> FeedbackPrincipal:
        supplied = (
            credentials.credentials
            if credentials is not None and credentials.scheme.casefold() == "bearer"
            else ""
        )
        try:
            identity = await token_verifier.verify(
                supplied,
                app_check_token=app_assertion.token,
            )
        except ManagedIdentityRejectedError:
            request.state.auth_scope = "feedback_identity"
            request.state.auth_result = "identity_rejected"
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired feedback identity token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from None
        except ManagedIdentityUnavailableError:
            request.state.auth_scope = "feedback_identity"
            request.state.auth_result = "identity_unavailable"
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="feedback identity verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        request.state.auth_scope = "feedback_identity"
        request.state.auth_result = "identity_accepted"
        return FeedbackPrincipal(
            app_check=app_assertion.claims,
            identity=identity,
        )

    def report_token_header(
        report_token: Annotated[
            str | None,
            Header(alias="X-NOOP-Feedback-Token"),
        ] = None,
    ) -> str:
        supplied = report_token or ""
        if _REPORT_TOKEN_RE.fullmatch(supplied) is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="feedback report capability was rejected",
            )
        return supplied

    def expected_app_id(platform: str) -> str:
        expected = {
            "ios": settings.managed_apple_app_id,
            "android": settings.managed_android_app_id,
        }[platform]
        return expected or ""

    async def authorized_report(
        *,
        report_id: UUID,
        principal: FeedbackPrincipal,
        report_token: str,
    ) -> FeedbackReport:
        try:
            report = await repository.get(
                report_id=report_id,
                client_app_id=principal.app_check.app_id,
            )
        except FeedbackNotFoundError:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="feedback report was not found",
            ) from None
        if report.subject_hash != principal.identity.subject_hash:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="feedback report was not found",
            )
        if not capability_codec.verify(
            report_token,
            report_id=report_id,
            app_id=principal.app_check.app_id,
        ):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="feedback report capability was rejected",
            )
        return report

    @router.post(
        "/reports/reservations",
        response_model=FeedbackReservationResponse,
        status_code=status.HTTP_201_CREATED,
    )
    async def reserve_report(
        payload: FeedbackReservationRequest,
        request: Request,
        principal: FeedbackPrincipal = Depends(require_identity),
        idempotency_key: Annotated[
            str | None,
            Header(alias="Idempotency-Key"),
        ] = None,
    ) -> FeedbackReservationResponse:
        if principal.app_check.app_id != expected_app_id(payload.platform):
            request.state.auth_result = "platform_app_mismatch"
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="feedback platform assertion did not match",
            )
        if (
            idempotency_key is None
            or _IDEMPOTENCY_RE.fullmatch(idempotency_key) is None
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Idempotency-Key must be a UUID",
            )
        if payload.archive_bytes > settings.feedback_max_archive_bytes:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail="feedback archive exceeds the configured limit",
            )

        now = datetime.now(UTC)
        report_id = uuid4()
        idempotency_hash = hashlib.sha256(
            (
                f"{principal.app_check.app_id}\0"
                f"{principal.identity.subject_hash}\0"
                f"{idempotency_key.lower()}"
            ).encode("utf-8")
        ).hexdigest()
        request_hash = hashlib.sha256(
            json.dumps(
                payload.model_dump(mode="json"),
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        object_key = (
            f"v1/feedback/{now:%Y/%m/%d}/{report_id}.zip"
        )
        upload_expires_at = now + timedelta(
            seconds=settings.feedback_upload_ttl_seconds
        )
        retained_until = now + timedelta(days=settings.feedback_retention_days)
        candidate = FeedbackReport(
            report_id=report_id,
            client_app_id=principal.app_check.app_id,
            subject_hash=principal.identity.subject_hash,
            idempotency_hash=idempotency_hash,
            request_hash=request_hash,
            platform=payload.platform,
            app_version=payload.app_version,
            archive_bytes=payload.archive_bytes,
            archive_sha256=payload.archive_sha256,
            includes_user_note=payload.includes_user_note,
            includes_screenshot=payload.includes_screenshot,
            receipt=capability_codec.receipt(
                report_id=report_id,
                app_id=principal.app_check.app_id,
            ),
            object_key=object_key,
            status="reserved",
            object_generation=None,
            created_at=now,
            upload_expires_at=upload_expires_at,
            completed_at=None,
            retained_until=retained_until,
            deleted_at=None,
        )
        try:
            report, created = await repository.reserve(
                report=candidate,
                daily_report_limit=settings.feedback_daily_report_limit,
                pending_byte_limit=settings.feedback_pending_byte_limit,
            )
        except FeedbackQuotaExceededError:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="feedback submission quota was reached",
                headers={"Retry-After": "3600"},
            ) from None
        except FeedbackConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="feedback idempotency key conflicts with another report",
            ) from None
        if report.status == "deleted":
            raise HTTPException(
                status_code=status.HTTP_410_GONE,
                detail="feedback report was deleted",
            )
        token = capability_codec.issue(
            report_id=report.report_id,
            app_id=report.client_app_id,
        )
        upload: FeedbackUploadCapability | None = None
        if report.status == "reserved":
            try:
                capability = await object_store.upload_capability(
                    object_key=report.object_key,
                    content_type="application/zip",
                    content_sha256=report.archive_sha256,
                    content_length=report.archive_bytes,
                    expires_in_seconds=settings.feedback_upload_ttl_seconds,
                )
            except (ManagedObjectStoreError, ValueError):
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="feedback upload is temporarily unavailable",
                    headers={"Retry-After": "5"},
                ) from None
            try:
                report = await repository.activate_upload_capability(
                    report_id=report.report_id,
                    client_app_id=report.client_app_id,
                    activated_at=datetime.now(UTC),
                    upload_expires_at=capability.expires_at,
                    pending_byte_limit=settings.feedback_pending_byte_limit,
                )
            except FeedbackQuotaExceededError:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="feedback submission quota was reached",
                    headers={"Retry-After": "3600"},
                ) from None
            except FeedbackNotFoundError:
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail="feedback report was deleted",
                ) from None
            except FeedbackConflictError:
                try:
                    report = await repository.get(
                        report_id=report.report_id,
                        client_app_id=report.client_app_id,
                    )
                except FeedbackNotFoundError:
                    raise HTTPException(
                        status_code=status.HTTP_410_GONE,
                        detail="feedback report was deleted",
                    ) from None
                if report.status == "reserved":
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail="feedback upload capability could not be activated",
                    ) from None
            if report.status == "deleted":
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail="feedback report was deleted",
                )
            if report.status == "reserved":
                upload = FeedbackUploadCapability(
                    method="PUT",
                    url=capability.url,
                    headers=capability.headers,
                    expires_at=capability.expires_at,
                )
        emit_operational_event(
            "feedback.reservation",
            service="noop-managed-api",
            outcome="created" if created else "replayed",
            platform=report.platform,
            state=report.status,
            size_bucket=_size_bucket(report.archive_bytes),
            attachment_count=(
                int(report.includes_user_note) + int(report.includes_screenshot)
            ),
        )
        return FeedbackReservationResponse(
            report_id=report.report_id,
            report_token=token,
            status=report.status,  # type: ignore[arg-type]
            upload=upload,
            retained_until=report.retained_until,
        )

    @router.post(
        "/reports/{report_id}/complete",
        response_model=FeedbackStatusResponse,
    )
    async def complete_report(
        report_id: UUID,
        _: FeedbackCompletionRequest,
        principal: FeedbackPrincipal = Depends(require_identity),
        report_token: str = Depends(report_token_header),
    ) -> FeedbackStatusResponse:
        report = await authorized_report(
            report_id=report_id,
            principal=principal,
            report_token=report_token,
        )
        if report.status == "sent":
            return _status_response(report)
        if report.status != "reserved":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="feedback report cannot be completed",
            )
        try:
            metadata = await object_store.latest_metadata(
                object_key=report.object_key,
            )
        except ManagedObjectNotFoundError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="feedback upload has not completed",
            ) from None
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="feedback verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None

        if (
            metadata.object_key != report.object_key
            or metadata.size != report.archive_bytes
            or metadata.content_type != "application/zip"
            or metadata.metadata.get("noop-sha256") != report.archive_sha256
        ):
            await _reject_object(
                report=report,
                repository=repository,
                object_store=object_store,
            )
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="feedback upload metadata did not match its reservation",
            )
        try:
            archive = await object_store.read(
                object_key=report.object_key,
                generation=metadata.generation,
                maximum_bytes=settings.feedback_max_archive_bytes,
            )
            if hashlib.sha256(archive).hexdigest() != report.archive_sha256:
                raise FeedbackArchiveRejectedError(
                    "feedback archive digest did not match"
                )
            summary = validate_feedback_archive(
                archive,
                expected_platform=report.platform,
                expected_app_version=report.app_version,
                includes_user_note=report.includes_user_note,
                includes_screenshot=report.includes_screenshot,
            )
        except ManagedObjectStoreError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="feedback verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        except FeedbackArchiveRejectedError:
            await _reject_object(
                report=report,
                repository=repository,
                object_store=object_store,
                generation=metadata.generation,
            )
            emit_operational_event(
                "feedback.completion",
                service="noop-managed-api",
                outcome="rejected",
                platform=report.platform,
                size_bucket=_size_bucket(report.archive_bytes),
            )
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="feedback archive failed validation",
            ) from None

        try:
            report = await repository.mark_sent(
                report_id=report.report_id,
                client_app_id=report.client_app_id,
                object_generation=metadata.generation,
                completed_at=datetime.now(UTC),
            )
        except FeedbackConflictError:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="feedback report cannot be completed",
            ) from None
        emit_operational_event(
            "feedback.completion",
            service="noop-managed-api",
            outcome="sent",
            platform=report.platform,
            size_bucket=_size_bucket(report.archive_bytes),
            file_count=summary.file_count,
            attachment_count=(
                int(report.includes_user_note) + int(report.includes_screenshot)
            ),
        )
        return _status_response(report)

    @router.get(
        "/reports/{report_id}",
        response_model=FeedbackStatusResponse,
    )
    async def report_status(
        report_id: UUID,
        principal: FeedbackPrincipal = Depends(require_identity),
        report_token: str = Depends(report_token_header),
    ) -> FeedbackStatusResponse:
        report = await authorized_report(
            report_id=report_id,
            principal=principal,
            report_token=report_token,
        )
        return _status_response(report)

    @router.delete(
        "/reports/{report_id}",
        response_model=FeedbackStatusResponse,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def delete_report(
        report_id: UUID,
        principal: FeedbackPrincipal = Depends(require_identity),
        report_token: str = Depends(report_token_header),
    ) -> FeedbackStatusResponse:
        report = await authorized_report(
            report_id=report_id,
            principal=principal,
            report_token=report_token,
        )
        if report.status in {"deleting", "deleted"}:
            return _status_response(report)

        prior_state = report.status
        requested_at = datetime.now(UTC)
        report = await repository.request_delete(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            requested_at=requested_at,
        )
        immediate_outcome = "not_found"
        try:
            await object_store.delete(
                object_key=report.object_key,
                generation=None,
            )
        except ManagedObjectNotFoundError:
            pass
        except ManagedObjectStoreError:
            immediate_outcome = "deferred"
        else:
            immediate_outcome = "deleted"
        emit_operational_event(
            "feedback.deletion",
            service="noop-managed-api",
            outcome="accepted",
            platform=report.platform,
            prior_state=prior_state,
            immediate_outcome=immediate_outcome,
        )
        return _status_response(report)

    return router


async def _reject_object(
    *,
    report: FeedbackReport,
    repository: FeedbackRepository,
    object_store: ManagedObjectStoring,
    generation: int | None = None,
) -> None:
    rejected_at = datetime.now(UTC)
    try:
        await repository.mark_rejected(
            report_id=report.report_id,
            client_app_id=report.client_app_id,
            rejected_at=rejected_at,
        )
    except FeedbackConflictError:
        # A concurrent user deletion already owns the terminal state.
        pass
    try:
        await object_store.delete(
            object_key=report.object_key,
            generation=generation,
        )
    except ManagedObjectStoreError:
        pass


def _status_response(
    report: FeedbackReport,
) -> FeedbackStatusResponse:
    return FeedbackStatusResponse(
        status=report.status,  # type: ignore[arg-type]
        receipt=(
            report.receipt
            if report.status == "sent"
            else None
        ),
        retained_until=report.retained_until,
    )


def _size_bucket(value: int) -> str:
    if value < 256 * 1024:
        return "lt_256_kib"
    if value < 1024 * 1024:
        return "lt_1_mib"
    if value < 5 * 1024 * 1024:
        return "lt_5_mib"
    if value < 10 * 1024 * 1024:
        return "lt_10_mib"
    return "gte_10_mib"
