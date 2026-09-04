from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
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
    ManagedSourceRegistration,
)
from app.managed_object_store import (
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.managed_repository import (
    ManagedConfigurationError,
    ManagedConflictError,
    ManagedCursorExpiredError,
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedPrincipal,
    ManagedQuotaExceededError,
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
) -> APIRouter:
    router = APIRouter(prefix="/v1/managed", tags=["managed-storage"])

    async def require_app_check(
        app_check_token: Annotated[
            str | None,
            Header(alias="X-Firebase-AppCheck"),
        ] = None,
    ) -> ManagedAppAssertion:
        supplied = app_check_token or ""
        try:
            claims = await app_check_verifier.verify(supplied)
        except ManagedAppCheckRejectedError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired managed app assertion",
            ) from None
        except ManagedAppCheckUnavailableError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed app verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None
        return ManagedAppAssertion(token=supplied, claims=claims)

    async def require_claims(
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
            return await token_verifier.verify(
                supplied,
                app_check_token=app_assertion.token,
            )
        except ManagedIdentityRejectedError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid or expired managed identity token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from None
        except ManagedIdentityUnavailableError:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="managed identity verification is temporarily unavailable",
                headers={"Retry-After": "5"},
            ) from None

    def installation_header(
        installation_id: Annotated[
            str | None,
            Header(alias="X-Noop-Installation-ID"),
        ] = None,
    ) -> str:
        if (
            installation_id is None
            or INSTALLATION_RE.fullmatch(installation_id) is None
        ):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="managed installation credential was rejected",
            )
        return installation_id

    def installation_token_header(
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
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="managed installation credential was rejected",
            )
        return hashlib.sha256(installation_token.encode("ascii")).hexdigest()

    async def require_identity(
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
            _raise_managed(error)
            raise AssertionError("unreachable")
        return ManagedRequestIdentity(
            claims=claims,
            principal=principal,
            installation_id=installation_id,
        )

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
    ) -> dict:
        try:
            return await repository.list_changes(
                principal=identity.principal,
                after_sequence=after_sequence,
                limit=limit,
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
