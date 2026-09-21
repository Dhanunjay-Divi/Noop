from __future__ import annotations

import base64
import hashlib
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import UUID, uuid4

from fastapi.testclient import TestClient

import app.managed_api as managed_api_module
from app.config import Settings
from app.main import create_app
from app.managed_app_check import (
    ManagedAppCheckClaims,
    StaticManagedAppCheckVerifier,
)
from app.managed_identity import (
    ManagedIdentityClaims,
    StaticManagedTokenVerifier,
)
from app.managed_formula_executor import ManagedFormulaExecutor
from app.managed_object_store import ManagedObjectCapability, ManagedObjectMetadata
from app.managed_repository import (
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedPrincipal,
    ManagedRateLimitError,
)
from app.repository import MemoryRepository
from app.unified_identity_authority import (
    AuthorityTransitionResult,
    ManagedAuthorityState,
    UnifiedPrincipal,
)

TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"
MANAGED_TOKEN = "managed-test-token"
OTHER_MANAGED_TOKEN = "managed-other-tenant-token"
APP_CHECK_TOKEN = "managed-app-check-token"
ANDROID_APP_CHECK_TOKEN = "managed-android-app-check-token"
MACOS_APP_CHECK_TOKEN = "managed-macos-app-check-token"
INSTALLATION_TOKEN = "noopm_" + ("a" * 43)
OTHER_INSTALLATION_TOKEN = "noopm_" + ("b" * 43)
POLICY_SHA256 = "a" * 64
PROJECT_NUMBER = "123456789012"
APPLE_APP_ID = f"1:{PROJECT_NUMBER}:ios:0123456789abcdef"
ANDROID_APP_ID = f"1:{PROJECT_NUMBER}:android:fedcba9876543210"
MACOS_APP_ID = f"1:{PROJECT_NUMBER}:ios:89abcdef01234567"


class FakeManagedRepository:
    def __init__(self, claims: ManagedIdentityClaims) -> None:
        self.identity_issuer = claims.issuer
        self.identity_provider_tenant = claims.provider_tenant
        self.identity_subject_hash = claims.subject_hash
        self.principal = ManagedPrincipal(
            account_id=uuid4(),
            identity_id=uuid4(),
            subject_hash=claims.subject_hash,
            account_status="active",
            auth_valid_after=claims.auth_time,
        )
        self.enrollments = []
        self.account_health_data_consent_granted = False
        self.account_health_data_uploaded = False
        self.installations = [
            {
                "installation_id": "ios-test-1",
                "platform": "ios",
                "status": "active",
                "attestation_state": "accepted",
                "registered_at": claims.issued_at,
                "last_seen_at": claims.issued_at,
                "revoked_at": None,
            },
            {
                "installation_id": "android-test-2",
                "platform": "android",
                "status": "active",
                "attestation_state": "accepted",
                "registered_at": claims.issued_at,
                "last_seen_at": claims.issued_at,
                "revoked_at": None,
            },
        ]
        self.chunk_rows: list[dict] = []
        self.document_rows: list[dict] = []
        self.change_rows: list[dict] = []
        self.available_chunk_row: dict | None = None
        self.chunk_list_calls: list[dict] = []
        self.chunk_reservations = []
        self.upload_grants = []
        self.restore_requests = []
        self.restore_jobs: dict[UUID, dict] = {}
        self.restore_completions: list[dict] = []
        self.export_row: dict | None = None
        self.completed_exports: list[dict] = []
        self.erasure_requests: list[dict] = []
        self.erasure_receipts: dict[UUID, dict] = {}
        self.social_profile_requests = []
        self.social_profile_deletions = 0
        self.social_invite_requests = []
        self.social_poke_requests = []
        self.social_claims = []
        self.social_acknowledgements = []
        self.social_profile_id = uuid4()
        self.social_friend_id = uuid4()
        self.social_poke_id = uuid4()
        self.social_claim_id = uuid4()
        self.installation_token_hashes = {
            "ios-test-1": hashlib.sha256(
                INSTALLATION_TOKEN.encode("ascii")
            ).hexdigest(),
            "android-test-2": hashlib.sha256(
                OTHER_INSTALLATION_TOKEN.encode("ascii")
            ).hexdigest(),
        }
        self.unified_authority = FakeUnifiedIdentityAuthorityRepository(
            managed_principal=self.principal,
        )

    async def principal_for_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> ManagedPrincipal:
        if (
            claims.issuer != self.identity_issuer
            or claims.provider_tenant != self.identity_provider_tenant
            or claims.subject_hash != self.identity_subject_hash
        ):
            raise ManagedForbiddenError("managed account authorization was rejected")
        return self.principal

    async def overview(self, *, principal: ManagedPrincipal) -> dict:
        assert principal == self.principal
        return {
            "account": {"status": "active"},
            "storage": {"rules": []},
            "entitlements": {
                "managed_storage": True,
                "feature_restrictions": [],
            },
        }

    async def enroll(self, *, claims, enrollment) -> dict:
        self.enrollments.append((claims, enrollment))
        return {
            "account": {"status": "active"},
            "storage": {"rules": []},
            "created": True,
        }

    async def enroll_account(self, *, claims, enrollment) -> dict:
        self.enrollments.append((claims, enrollment))
        return {
            "account": {
                "status": "active",
                "health_data_consent_granted": (
                    self.account_health_data_consent_granted
                ),
                "health_data_uploaded": self.account_health_data_uploaded,
            },
            "identity_id": self.principal.identity_id,
            "created": True,
        }

    async def ensure_installation(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        installation_token_hash: str,
    ) -> dict:
        assert principal == self.principal
        row = next(
            (
                candidate
                for candidate in self.installations
                if candidate["installation_id"] == installation_id
            ),
            None,
        )
        if (
            row is None
            or row["status"] not in {"active", "limited"}
            or self.installation_token_hashes.get(installation_id)
            != installation_token_hash
        ):
            raise ManagedForbiddenError("managed installation credential was rejected")
        return row

    async def list_installations(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict]:
        assert principal == self.principal
        return list(self.installations)

    async def revoke_installation(
        self,
        *,
        principal: ManagedPrincipal,
        requesting_installation_id: str,
        installation_id: str,
    ) -> dict:
        assert principal == self.principal
        assert requesting_installation_id == "ios-test-1"
        row = next(
            row
            for row in self.installations
            if row["installation_id"] == installation_id
        )
        row["status"] = "revoked"
        return {**row, "duplicate": False}

    async def list_available_chunks(self, *, principal, limit, **kwargs) -> list[dict]:
        assert principal == self.principal
        self.chunk_list_calls.append({"limit": limit, **kwargs})
        return self.chunk_rows[:limit]

    async def reserve_chunk(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        reservation,
    ) -> dict:
        assert principal == self.principal
        assert installation_id == "ios-test-1"
        self.chunk_reservations.append(reservation)
        return {
            "chunk_id": str(reservation.chunk_id),
            "source_id": str(reservation.source_id),
            "data_class": reservation.data_class,
            "schema_version": reservation.schema_version,
            "content_mode": reservation.content_mode,
            "authoritative_snapshot": True,
            "state": "reserved",
            "event_start": reservation.event_start,
            "event_end": reservation.event_end,
            "compression": reservation.compression,
            "content_type": reservation.content_type,
            "expected_sha256": reservation.expected_sha256,
            "expected_compressed_bytes": reservation.expected_compressed_bytes,
            "expected_uncompressed_bytes": reservation.expected_uncompressed_bytes,
            "object_key": f"v1/test/{reservation.chunk_id}",
            "object_generation": None,
            "expires_at": datetime.now(UTC) + timedelta(hours=1),
            "reserved_at": datetime.now(UTC),
            "uploaded_at": None,
            "available_at": None,
            "duplicate": False,
        }

    async def record_upload_grant(self, **kwargs):
        assert kwargs["principal"] == self.principal
        self.upload_grants.append(kwargs)
        return uuid4()

    async def list_documents(self, *, principal, limit, **kwargs) -> list[dict]:
        assert principal == self.principal
        return self.document_rows[:limit]

    async def list_changes(
        self,
        *,
        principal: ManagedPrincipal,
        after_sequence: int,
        limit: int,
        document_kinds: list[str] | None = None,
    ) -> dict:
        assert principal == self.principal
        assert after_sequence == 4
        assert limit == 20
        high_watermark = (
            int(self.change_rows[-1]["sequence"]) if self.change_rows else 4
        )
        rows = [
            row
            for row in self.change_rows
            if row["resource_kind"] != "document"
            or document_kinds is None
            or row["document"]["document_kind"] in document_kinds
        ]
        return {
            "changes": rows,
            "minimum_sequence": 1,
            "high_watermark": high_watermark,
            "next_sequence": high_watermark,
            "has_more": False,
        }

    async def available_chunk(self, *, principal, chunk_id) -> dict:
        assert principal == self.principal
        assert self.available_chunk_row is not None
        assert self.available_chunk_row["chunk_id"] == chunk_id
        return self.available_chunk_row

    async def create_restore(
        self,
        *,
        principal,
        installation_id,
        request,
    ) -> dict:
        assert principal == self.principal
        assert installation_id in {"ios-test-1", "macos-viewer-1"}
        self.restore_requests.append(request)
        now = datetime.now(UTC)
        restore_job_id = uuid4()
        restore = {
            "restore_job_id": str(restore_job_id),
            "status": "running",
            "snapshot_at": now,
            "change_sequence": 4,
            "selected_objects": 0,
            "selected_bytes": 0,
            "delivered_objects": 0,
            "delivered_bytes": 0,
            "expires_at": now + timedelta(days=1),
            "duplicate": False,
        }
        self.restore_jobs[restore_job_id] = restore
        return restore

    async def complete_restore(
        self,
        *,
        principal,
        installation_id,
        restore_job_id,
        delivered_objects,
        delivered_bytes,
    ) -> dict:
        assert principal == self.principal
        assert installation_id in {"ios-test-1", "macos-viewer-1"}
        restore = self.restore_jobs[restore_job_id]
        assert delivered_objects == restore["selected_objects"]
        assert delivered_bytes == restore["selected_bytes"]
        completion = {
            "restore_job_id": restore_job_id,
            "installation_id": installation_id,
            "delivered_objects": delivered_objects,
            "delivered_bytes": delivered_bytes,
        }
        self.restore_completions.append(completion)
        completed = {
            **restore,
            "status": "completed",
            "delivered_objects": delivered_objects,
            "delivered_bytes": delivered_bytes,
        }
        self.restore_jobs[restore_job_id] = completed
        return completed

    async def record_access_grant(self, **kwargs):
        assert kwargs["principal"] == self.principal
        return uuid4()

    async def get_export(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        export_job_id,
    ) -> dict:
        assert principal == self.principal
        assert installation_id == "ios-test-1"
        assert self.export_row is not None
        assert self.export_row["export_job_id"] == export_job_id
        return self.export_row

    async def complete_export(self, **kwargs) -> dict:
        self.completed_exports.append(kwargs)
        return {**self.export_row, "status": "completed"}

    async def cancel_erasure(
        self,
        *,
        principal: ManagedPrincipal,
        erasure_job_id,
    ) -> dict:
        assert principal == self.principal
        return {
            "erasure_job_id": str(erasure_job_id),
            "scope": "account",
            "status": "canceled",
        }

    async def coordination_now(self):
        return self.principal.auth_valid_after + timedelta(minutes=1)

    async def request_erasure(self, **kwargs) -> dict:
        self.erasure_requests.append(kwargs)
        erasure_job_id = uuid4()
        result = {
            "erasure_job_id": str(erasure_job_id),
            "scope": kwargs["scope"],
            "status": "cooling_off",
            "not_before": datetime.now(UTC) + timedelta(hours=24),
        }
        if kwargs["scope"] == "account":
            self.erasure_receipts[erasure_job_id] = result
        return result

    async def get_erasure_receipt(
        self,
        *,
        erasure_job_id: UUID,
        installation_id: str,
        installation_token_hash: str,
    ) -> tuple[dict, str]:
        receipt = self.erasure_receipts.get(erasure_job_id)
        installation = next(
            (
                row
                for row in self.installations
                if row["installation_id"] == installation_id
            ),
            None,
        )
        if (
            receipt is None
            or installation is None
            or self.installation_token_hashes.get(installation_id)
            != installation_token_hash
        ):
            raise ManagedNotFoundError("managed erasure receipt was not found")
        return receipt, str(installation["platform"])

    async def create_social_profile(self, *, principal, request) -> dict:
        assert principal == self.principal
        self.social_profile_requests.append(request)
        now = datetime.now(UTC)
        return {
            "profile_id": str(self.social_profile_id),
            "display_name": request.display_name,
            "noop_id": "NOOP-ABCD-EFGH-JKLM-NPQR",
            "poke_opt_in": False,
            "quiet_start_minute": 1320,
            "quiet_end_minute": 420,
            "time_zone": "UTC",
            "created_at": now,
            "updated_at": now,
            "duplicate": False,
        }

    async def delete_social_profile(self, *, principal) -> None:
        assert principal == self.principal
        self.social_profile_deletions += 1

    async def lookup_social_profile(self, *, principal, noop_id) -> dict:
        assert principal == self.principal
        assert noop_id == "NOOP-ABCD-EFGH-JKLM-NPQR"
        return {
            "profile_id": str(self.social_friend_id),
            "display_name": "Friend",
            "noop_id": noop_id,
            "self": False,
        }

    async def create_social_invite(self, *, principal, request) -> dict:
        assert principal == self.principal
        self.social_invite_requests.append(request)
        now = datetime.now(UTC)
        return {
            "invite_id": str(uuid4()),
            "capability": request.capability.get_secret_value(),
            "status": "active",
            "created_at": now,
            "expires_at": now + timedelta(hours=request.expires_in_hours),
            "duplicate": False,
        }

    async def create_social_poke(self, *, principal, request) -> dict:
        assert principal == self.principal
        self.social_poke_requests.append(request)
        now = datetime.now(UTC)
        return {
            "poke_id": str(self.social_poke_id),
            "recipient_profile_id": str(request.recipient_profile_id),
            "recipient_display_name": "Friend",
            "status": "queued",
            "created_at": now,
            "expires_at": now + timedelta(hours=24),
            "duplicate": False,
        }

    async def claim_social_pokes(
        self,
        *,
        principal,
        installation_id,
        limit,
    ) -> list[dict]:
        assert principal == self.principal
        self.social_claims.append((installation_id, limit))
        now = datetime.now(UTC)
        return [
            {
                "poke_id": str(self.social_poke_id),
                "claim_id": str(self.social_claim_id),
                "sender_profile_id": str(self.social_friend_id),
                "sender_display_name": "Friend",
                "created_at": now,
                "expires_at": now + timedelta(hours=1),
                "claim_expires_at": now + timedelta(minutes=5),
            }
        ]

    async def acknowledge_social_poke(self, **kwargs) -> dict:
        assert kwargs["principal"] == self.principal
        self.social_acknowledgements.append(kwargs)
        return {
            "poke_id": str(kwargs["poke_id"]),
            "status": "acknowledged",
            "duplicate": False,
        }


class FakeUnifiedIdentityAuthorityRepository:
    def __init__(
        self,
        *,
        managed_principal: ManagedPrincipal,
    ) -> None:
        self.principal = UnifiedPrincipal(
            principal_id=uuid4(),
            status="active",
            managed_account_id=managed_principal.account_id,
            managed_identity_id=managed_principal.identity_id,
            ownership_account_id=None,
            ownership_identity_id=None,
        )
        self.reconciled_claims: list[ManagedIdentityClaims] = []
        self.authority = self._state("local_only", transition_version=0)
        self.rollback_requests: list[dict] = []
        self.reconsent_requests: list[dict] = []

    def _state(
        self,
        state: str,
        *,
        transition_version: int,
        last_opt_out_at: datetime | None = None,
        last_reconsented_at: datetime | None = None,
        reconsent_consent_event_id: UUID | None = None,
        reconsent_policy_version: str | None = None,
        reconsent_policy_sha256: str | None = None,
    ) -> ManagedAuthorityState:
        managed_account_id = self.principal.managed_account_id
        assert managed_account_id is not None
        return ManagedAuthorityState(
            principal_id=self.principal.principal_id,
            managed_account_id=managed_account_id,
            data_class="essential_timeseries",
            state=state,  # type: ignore[arg-type]
            transition_version=transition_version,
            upload_acknowledgement_id=None,
            upload_acknowledgement_sha256=None,
            upload_acknowledged_at=None,
            restore_proof_id=None,
            restore_proof_sha256=None,
            restore_proven_at=None,
            pruning_authorized_at=None,
            last_opt_out_at=last_opt_out_at,
            last_reconsented_at=last_reconsented_at,
            reconsent_consent_event_id=reconsent_consent_event_id,
            reconsent_policy_version=reconsent_policy_version,
            reconsent_policy_sha256=reconsent_policy_sha256,
        )

    async def reconcile_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> UnifiedPrincipal:
        self.reconciled_claims.append(claims)
        return self.principal

    async def authority_state(
        self,
        *,
        principal_id,
        managed_account_id,
        data_class,
    ) -> ManagedAuthorityState:
        assert principal_id == self.principal.principal_id
        assert managed_account_id == self.principal.managed_account_id
        return replace(self.authority, data_class=data_class)

    async def request_rollback(self, **kwargs) -> AuthorityTransitionResult:
        assert kwargs["principal_id"] == self.principal.principal_id
        assert kwargs["managed_account_id"] == self.principal.managed_account_id
        assert kwargs["opt_out"] is True
        self.rollback_requests.append(kwargs)
        version = self.authority.transition_version + 1
        self.authority = self._state(
            "rollback",
            transition_version=version,
            last_opt_out_at=datetime.now(UTC),
            last_reconsented_at=self.authority.last_reconsented_at,
            reconsent_consent_event_id=(self.authority.reconsent_consent_event_id),
            reconsent_policy_version=self.authority.reconsent_policy_version,
            reconsent_policy_sha256=self.authority.reconsent_policy_sha256,
        )
        return AuthorityTransitionResult(
            transition_id=uuid4(),
            state="rollback",
            transition_version=version,
            pruning_authorized=False,
            duplicate=False,
        )

    async def record_reconsent(self, **kwargs) -> AuthorityTransitionResult:
        assert kwargs["principal_id"] == self.principal.principal_id
        assert kwargs["managed_account_id"] == self.principal.managed_account_id
        self.reconsent_requests.append(kwargs)
        version = self.authority.transition_version + 1
        self.authority = self._state(
            "local_only",
            transition_version=version,
            last_opt_out_at=self.authority.last_opt_out_at,
            last_reconsented_at=datetime.now(UTC),
            reconsent_consent_event_id=uuid4(),
            reconsent_policy_version=kwargs["policy_version"],
            reconsent_policy_sha256=kwargs["policy_sha256"],
        )
        return AuthorityTransitionResult(
            transition_id=uuid4(),
            state="local_only",
            transition_version=version,
            pruning_authorized=False,
            duplicate=False,
        )


class FakeManagedFormulaRepository:
    def __init__(self) -> None:
        self.publications: list[dict] = []
        self.current = None

    async def publish_shadow(self, **kwargs):
        execution = kwargs["execution"]
        self.publications.append(kwargs)
        self.current = SimpleNamespace(
            metric_key=execution.metric_key,
            formula_revision=execution.formula_revision,
            input_schema_revision=execution.input_schema_revision,
            output_unit=execution.output_unit,
            local_day=execution.context.local_day,
            server_status=execution.server_status,
            server_value=execution.server_value,
            client_status=execution.client_status,
            client_formula_revision=execution.client_formula_revision,
            client_value=execution.client_value,
            parity_status=execution.parity_status,
            absolute_delta=execution.absolute_delta,
            parity_tolerance=execution.parity_tolerance,
            missing_inputs=execution.missing_inputs,
            publication_kind="shadow",
            is_current=True,
            created_at=kwargs["now"],
        )
        return self.current

    async def current_result(self, **kwargs):
        if self.current is None:
            return None
        assert kwargs["metric_key"] == self.current.metric_key
        assert kwargs["local_day"] == self.current.local_day
        return self.current


class FakeManagedDocumentKeyRepository:
    def __init__(self) -> None:
        self.records: dict = {}
        self.versions: dict = {}
        self.mutations: list[dict] = []

    async def put(self, **kwargs):
        mutation = kwargs["mutation"]
        self.mutations.append(kwargs)
        record = SimpleNamespace(
            key_id=mutation.key_id,
            key_kind=mutation.key_kind,
            wrapping_key_id=mutation.wrapping_key_id,
            wrapping_revision=mutation.wrapping_revision,
            algorithm=mutation.algorithm,
            wrapped_key=mutation.wrapped_key,
            wrapped_key_sha256=mutation.wrapped_key_sha256,
            master_key_confirmation_hmac_sha256=(
                mutation.master_key_confirmation_hmac_sha256
            ),
            recovery_method=mutation.recovery_method,
            status="active",
            successor_key_id=None,
            created_at=kwargs["now"],
            updated_at=kwargs["now"],
            revoked_at=None,
        )
        self.records[mutation.key_id] = record
        self.versions[(mutation.key_id, mutation.wrapping_revision)] = SimpleNamespace(
            key_id=mutation.key_id,
            key_kind=mutation.key_kind,
            wrapping_key_id=mutation.wrapping_key_id,
            wrapping_revision=mutation.wrapping_revision,
            algorithm=mutation.algorithm,
            wrapped_key=mutation.wrapped_key,
            wrapped_key_sha256=mutation.wrapped_key_sha256,
            master_key_confirmation_hmac_sha256=(
                mutation.master_key_confirmation_hmac_sha256
            ),
            recovery_method=mutation.recovery_method,
            created_at=kwargs["now"],
        )
        return record

    async def get(self, **kwargs):
        from app.managed_document_keys import ManagedDocumentKeyNotFoundError

        try:
            return self.records[kwargs["key_id"]]
        except KeyError:
            raise ManagedDocumentKeyNotFoundError(
                "managed document key was not found"
            ) from None

    async def get_version(self, **kwargs):
        from app.managed_document_keys import ManagedDocumentKeyNotFoundError

        try:
            return self.versions[(kwargs["key_id"], kwargs["wrapping_revision"])]
        except KeyError:
            raise ManagedDocumentKeyNotFoundError(
                "managed document key version was not found"
            ) from None

    async def rotate_wrapping(self, **kwargs):
        return await self.put(
            principal=kwargs["principal"],
            mutation=kwargs["mutation"],
            now=kwargs["now"],
        )

    async def revoke(self, **kwargs):
        record = await self.get(
            principal=kwargs["principal"],
            key_id=kwargs["key_id"],
        )
        updated = SimpleNamespace(
            **{
                **vars(record),
                "status": "revoked",
                "successor_key_id": kwargs["successor_key_id"],
                "updated_at": kwargs["now"],
                "revoked_at": kwargs["now"],
            }
        )
        self.records[kwargs["key_id"]] = updated
        return updated


class UnusedObjectStore:
    async def upload_capability(self, **kwargs):
        raise AssertionError("object store should not be called")

    async def download_capability(self, **kwargs):
        raise AssertionError("object store should not be called")

    async def metadata(self, **kwargs):
        raise AssertionError("object store should not be called")


class DownloadObjectStore(UnusedObjectStore):
    async def download_capability(self, **kwargs):
        assert kwargs["object_key"] == "accounts/test/chunk.gz"
        assert kwargs["generation"] == 42
        return ManagedObjectCapability(
            method="GET",
            url="https://storage.googleapis.com/test/chunk.gz?signature=test",
            headers={},
            expires_at=datetime.now(UTC) + timedelta(minutes=5),
        )


class UploadObjectStore(UnusedObjectStore):
    async def upload_capability(self, **kwargs):
        assert kwargs["object_key"].startswith("v1/test/")
        assert kwargs["content_type"] == "application/vnd.noop.chunk+json"
        assert kwargs["content_sha256"] == "a" * 64
        assert kwargs["content_length"] == 128
        return ManagedObjectCapability(
            method="PUT",
            url="https://storage.googleapis.com/test/chunk.gz?signature=test",
            headers={
                "content-length": "128",
                "content-type": "application/vnd.noop.chunk+json",
            },
            expires_at=datetime.now(UTC) + timedelta(minutes=5),
        )


class MismatchedGenerationObjectStore(UnusedObjectStore):
    async def metadata(self, **kwargs):
        assert kwargs["generation"] == 42
        return ManagedObjectMetadata(
            object_key=kwargs["object_key"],
            generation=43,
            metageneration=1,
            crc32c="AAAAAA==",
            size=128,
            content_type="application/vnd.noop.backup",
            metadata={"noop-sha256": "a" * 64},
        )


def _settings(
    *,
    enabled: bool,
    formula_shadow: bool = False,
    document_key_recovery: bool = False,
    macos_app_id: str | None = None,
) -> Settings:
    return Settings(
        api_token=TOKEN,
        database_url=None,
        max_request_bytes=1_000_000,
        managed_storage_enabled=enabled,
        managed_project_id="noop-test-project",
        managed_project_number=PROJECT_NUMBER,
        managed_identity_api_key="identity-api-key",
        managed_apple_app_id=APPLE_APP_ID,
        managed_android_app_id=ANDROID_APP_ID,
        managed_macos_app_id=macos_app_id,
        managed_raw_bucket="noop-private-bucket",
        managed_signer_email="noop-api@example.iam.gserviceaccount.com",
        managed_replay_secret="managed-replay-secret-at-least-32-bytes",
        managed_consent_policy_version="staging-v1",
        managed_consent_policy_sha256=POLICY_SHA256,
        managed_formula_shadow_enabled=formula_shadow,
        managed_document_key_recovery_enabled=document_key_recovery,
    )


def _managed_client(
    *,
    auth_age: timedelta = timedelta(minutes=1),
    object_store=None,
    managed_safety_repository=None,
    managed_safety_push_service=None,
    unified_identity_authority_repository=None,
    formula_repository=None,
    formula_shadow: bool = False,
    document_key_repository=None,
    document_key_recovery: bool = False,
    macos_app_id: str | None = None,
    additional_identity_tokens: dict[str, ManagedIdentityClaims] | None = None,
    additional_app_check_tokens: dict[str, ManagedAppCheckClaims] | None = None,
) -> tuple[TestClient, FakeManagedRepository]:
    now = datetime.now(UTC)
    claims = ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject="firebase-user-1",
        provider_tenant="",
        issued_at=now,
        auth_time=now - auth_age,
        expires_at=now + timedelta(hours=1),
    )
    managed_repository = FakeManagedRepository(claims)
    unified_repository = (
        unified_identity_authority_repository or managed_repository.unified_authority
    )
    app_check_claims = ManagedAppCheckClaims(
        app_id=APPLE_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    app = create_app(
        settings=_settings(
            enabled=True,
            formula_shadow=formula_shadow,
            document_key_recovery=document_key_recovery,
            macos_app_id=macos_app_id,
        ),
        repository=MemoryRepository(),
        managed_repository=managed_repository,  # type: ignore[arg-type]
        managed_app_check_verifier=StaticManagedAppCheckVerifier(
            {
                APP_CHECK_TOKEN: app_check_claims,
                **(additional_app_check_tokens or {}),
            }
        ),
        managed_token_verifier=StaticManagedTokenVerifier(
            {
                MANAGED_TOKEN: claims,
                **(additional_identity_tokens or {}),
            }
        ),
        managed_object_store=object_store or UnusedObjectStore(),
        managed_safety_repository=managed_safety_repository,
        managed_safety_push_service=managed_safety_push_service,
        managed_unified_identity_authority_repository=unified_repository,
        managed_formula_repository=formula_repository,
        managed_formula_executor=(
            ManagedFormulaExecutor() if formula_repository is not None else None
        ),
        managed_document_key_repository=document_key_repository,
    )
    return TestClient(app), managed_repository


def _managed_headers(
    *,
    installation_id: str = "ios-test-1",
    installation_token: str = INSTALLATION_TOKEN,
    app_check_token: str = APP_CHECK_TOKEN,
) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": app_check_token,
        "X-Noop-Installation-ID": installation_id,
        "X-Noop-Installation-Token": installation_token,
    }


def _enable_macos_viewer(repository: FakeManagedRepository) -> None:
    now = datetime.now(UTC)
    repository.installations.append(
        {
            "installation_id": "macos-viewer-1",
            "platform": "macos",
            "status": "active",
            "attestation_state": "accepted",
            "registered_at": now,
            "last_seen_at": now,
            "revoked_at": None,
        }
    )
    repository.installation_token_hashes["macos-viewer-1"] = hashlib.sha256(
        OTHER_INSTALLATION_TOKEN.encode("ascii")
    ).hexdigest()


def _macos_headers(
    *,
    app_check_token: str = MACOS_APP_CHECK_TOKEN,
) -> dict[str, str]:
    return _managed_headers(
        installation_id="macos-viewer-1",
        installation_token=OTHER_INSTALLATION_TOKEN,
        app_check_token=app_check_token,
    )


def test_managed_routes_are_absent_when_feature_is_disabled() -> None:
    app = create_app(
        settings=_settings(enabled=False),
        repository=MemoryRepository(),
    )
    with TestClient(app) as client:
        response = client.get("/v1/managed/me")

    assert response.status_code == 404


def test_managed_route_requires_identity_token() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/me",
            headers={"X-Firebase-AppCheck": APP_CHECK_TOKEN},
        )

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_managed_route_requires_app_check_assertion() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/me",
            headers={"Authorization": f"Bearer {MANAGED_TOKEN}"},
        )

    assert response.status_code == 401
    assert response.json()["detail"] == ("invalid or expired managed app assertion")


def test_managed_overview_preserves_storage_only_product_boundary() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/me",
            headers=_managed_headers(),
        )

    assert response.status_code == 200
    assert response.json()["entitlements"] == {
        "managed_storage": True,
        "feature_restrictions": [],
    }


def test_managed_enrollment_requires_exact_policy_and_is_explicit() -> None:
    client, repository = _managed_client()
    body = {
        "installation_id": "ios-test-1",
        "installation_token": INSTALLATION_TOKEN,
        "platform": "ios",
        "enrollment_request_id": str(uuid4()),
        "policy_version": "staging-v1",
        "policy_sha256": POLICY_SHA256,
        "data_classes": ["essential_timeseries", "user_documents"],
    }
    headers = {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
    }
    with client:
        stale = client.post(
            "/v1/managed/enroll",
            headers=headers,
            json={**body, "policy_sha256": "b" * 64},
        )
        accepted = client.post(
            "/v1/managed/enroll",
            headers=headers,
            json=body,
        )

    assert stale.status_code == 409
    assert accepted.status_code == 201
    assert accepted.json()["product_boundary"] == {
        "account_optional": True,
        "local_metrics_available": True,
        "storage_only_entitlement": True,
        "cloud_authority_mode": "staged_per_data_class",
        "formula_authority": "client_until_parity_approved",
        "edge_collection_required": True,
    }
    assert len(repository.enrollments) == 1
    assert len(repository.unified_authority.reconciled_claims) == 1
    assert (
        repository.enrollments[0][1].installation_token.get_secret_value()
        == INSTALLATION_TOKEN
    )


def test_account_enrollment_reports_existing_privacy_state() -> None:
    client, repository = _managed_client()
    repository.account_health_data_consent_granted = True
    repository.account_health_data_uploaded = True

    with client:
        response = client.post(
            "/v1/managed/account/enroll",
            headers={
                "Authorization": f"Bearer {MANAGED_TOKEN}",
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
            },
            json={
                "installation_id": "ios-test-1",
                "installation_token": INSTALLATION_TOKEN,
                "platform": "ios",
                "enrollment_request_id": str(uuid4()),
            },
        )

    assert response.status_code == 201
    assert response.json()["product_boundary"] == {
        "account_ready": True,
        "health_data_consent_granted": True,
        "health_data_uploaded": True,
        "edge_collection_required": True,
    }


def test_mobile_enrollment_app_check_is_bound_to_declared_platform(
    monkeypatch,
) -> None:
    events: list[tuple[str, dict]] = []
    monkeypatch.setattr(
        managed_api_module,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )
    now = datetime.now(UTC)
    android_assertion = ManagedAppCheckClaims(
        app_id=ANDROID_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    client, repository = _managed_client(
        additional_app_check_tokens={
            ANDROID_APP_CHECK_TOKEN: android_assertion,
        }
    )
    storage_body = {
        "installation_id": "mobile-platform-binding",
        "installation_token": INSTALLATION_TOKEN,
        "platform": "ios",
        "enrollment_request_id": str(uuid4()),
        "policy_version": "staging-v1",
        "policy_sha256": POLICY_SHA256,
        "data_classes": ["essential_timeseries"],
    }
    account_body = {
        key: value
        for key, value in storage_body.items()
        if key
        not in {
            "policy_version",
            "policy_sha256",
            "data_classes",
        }
    }
    ios_headers = {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
    }
    android_headers = {
        **ios_headers,
        "X-Firebase-AppCheck": ANDROID_APP_CHECK_TOKEN,
    }

    with client:
        storage_ios_with_android = client.post(
            "/v1/managed/enroll",
            headers=android_headers,
            json=storage_body,
        )
        storage_android_with_ios = client.post(
            "/v1/managed/enroll",
            headers=ios_headers,
            json={**storage_body, "platform": "android"},
        )
        account_ios_with_android = client.post(
            "/v1/managed/account/enroll",
            headers=android_headers,
            json=account_body,
        )
        account_android_with_ios = client.post(
            "/v1/managed/account/enroll",
            headers=ios_headers,
            json={**account_body, "platform": "android"},
        )
        accepted_android = client.post(
            "/v1/managed/account/enroll",
            headers=android_headers,
            json={**account_body, "platform": "android"},
        )

    for response in (
        storage_ios_with_android,
        storage_android_with_ios,
        account_ios_with_android,
        account_android_with_ios,
    ):
        assert response.status_code == 403
        assert response.json()["detail"] == (
            "managed app assertion does not match enrollment platform"
        )
    assert accepted_android.status_code == 201
    assert repository.enrollments[-1][1].platform == "android"
    enrollment_events = [
        (event, fields)
        for event, fields in events
        if event
        in {
            "managed_account.enrollment",
            "managed_storage.enrollment",
        }
    ]
    assert [
        (
            event,
            fields["outcome"],
            fields["platform"],
            fields.get("data_class_count"),
        )
        for event, fields in enrollment_events
    ] == [
        ("managed_storage.enrollment", "rejected", "ios", 1),
        ("managed_storage.enrollment", "rejected", "android", 1),
        ("managed_account.enrollment", "rejected", "ios", None),
        ("managed_account.enrollment", "rejected", "android", None),
        ("managed_account.enrollment", "created", "android", None),
    ]


def test_macos_enrollment_is_default_off_and_app_check_platform_bound() -> None:
    now = datetime.now(UTC)
    macos_assertion = ManagedAppCheckClaims(
        app_id=MACOS_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    body = {
        "installation_id": "macos-viewer-1",
        "installation_token": INSTALLATION_TOKEN,
        "platform": "macos",
        "enrollment_request_id": str(uuid4()),
        "policy_version": "staging-v1",
        "policy_sha256": POLICY_SHA256,
        "data_classes": ["essential_timeseries", "user_documents"],
    }
    headers = {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
    }
    disabled_client, disabled_repository = _managed_client()
    with disabled_client:
        disabled = disabled_client.post(
            "/v1/managed/enroll",
            headers=headers,
            json=body,
        )

    client, repository = _managed_client(
        macos_app_id=MACOS_APP_ID,
        additional_app_check_tokens={
            MACOS_APP_CHECK_TOKEN: macos_assertion,
        },
    )
    with client:
        wrong_platform = client.post(
            "/v1/managed/enroll",
            headers=headers,
            json=body,
        )
        accepted = client.post(
            "/v1/managed/enroll",
            headers={
                **headers,
                "X-Firebase-AppCheck": MACOS_APP_CHECK_TOKEN,
            },
            json=body,
        )
        ios_with_macos_assertion = client.post(
            "/v1/managed/enroll",
            headers={
                **headers,
                "X-Firebase-AppCheck": MACOS_APP_CHECK_TOKEN,
            },
            json={**body, "platform": "ios"},
        )

    assert disabled.status_code == 503
    assert disabled_repository.enrollments == []
    assert wrong_platform.status_code == 403
    assert ios_with_macos_assertion.status_code == 403
    assert accepted.status_code == 201
    assert len(repository.enrollments) == 1
    assert repository.enrollments[0][1].platform == "macos"


def test_macos_viewer_route_contract_enumerates_allowed_and_denied_families() -> None:
    allowed = {
        ("GET", "/v1/managed/me"): "read",
        ("GET", "/v1/managed/chunks"): "read",
        ("GET", "/v1/managed/changes"): "read",
        ("GET", "/v1/managed/documents"): "read",
        ("GET", "/v1/managed/documents/{document_kind}/{document_id}"): "read",
        ("GET", "/v1/managed/restores/{restore_job_id}"): "read",
        ("GET", "/v1/managed/safety/incidents"): "read",
        ("GET", "/v1/managed/social/feed"): "read",
        ("POST", "/v1/managed/chunks/{chunk_id}/download"): "restore",
        ("POST", "/v1/managed/restores"): "restore",
        ("POST", "/v1/managed/restores/{restore_job_id}/complete"): "restore",
    }
    denied = {
        ("POST", "/v1/managed/sources"): "source_registration",
        ("POST", "/v1/managed/keys"): "collector_key_registration",
        ("POST", "/v1/managed/chunks:reserve"): "upload_reservation",
        ("POST", "/v1/managed/chunks/{chunk_id}/complete"): "upload_commit",
        ("PUT", "/v1/managed/documents/{document_kind}/{document_id}"): (
            "document_write"
        ),
        ("POST", "/v1/managed/authority/{data_class}/opt-out"): ("authority_mutation"),
        ("DELETE", "/v1/managed/installations/{target_installation_id}"): (
            "installation_ownership_mutation"
        ),
        ("POST", "/v1/managed/safety/incidents"): "safety_paging",
        ("PUT", "/v1/managed/safety/incidents/{incident_id}/location"): (
            "safety_location_write"
        ),
        ("POST", "/v1/managed/social/pokes/{poke_id}:ack"): ("social_acknowledgement"),
        ("POST", "/v1/managed/erasure"): "prune_or_erasure",
    }

    for (method, route_template), expected in allowed.items():
        assert (
            managed_api_module.macos_managed_viewer_access(
                method=method,
                route_template=route_template,
            )
            == expected
        )
    for (method, route_template), family in denied.items():
        assert (
            managed_api_module.macos_managed_viewer_access(
                method=method,
                route_template=route_template,
            )
            is None
        ), family
    assert (
        managed_api_module.macos_managed_viewer_access(
            method="POST",
            route_template=None,
        )
        is None
    )


def test_macos_viewer_authenticates_for_reads_and_restore_only() -> None:
    now = datetime.now(UTC)
    macos_assertion = ManagedAppCheckClaims(
        app_id=MACOS_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    client, repository = _managed_client(
        object_store=DownloadObjectStore(),
        macos_app_id=MACOS_APP_ID,
        additional_app_check_tokens={
            MACOS_APP_CHECK_TOKEN: macos_assertion,
        },
    )
    _enable_macos_viewer(repository)
    chunk_id = uuid4()
    repository.available_chunk_row = {
        "chunk_id": chunk_id,
        "object_key": "accounts/test/chunk.gz",
        "object_generation": 42,
        "expected_sha256": "a" * 64,
        "compression": "gzip",
        "content_type": "application/vnd.noop.chunk+json",
        "expected_uncompressed_bytes": 12_345,
    }

    with client:
        me = client.get("/v1/managed/me", headers=_macos_headers())
        chunks = client.get("/v1/managed/chunks", headers=_macos_headers())
        restore = client.post(
            "/v1/managed/restores",
            headers=_macos_headers(),
            json={
                "request_id": str(uuid4()),
                "data_classes": ["essential_timeseries"],
                "document_kinds": [],
                "include_documents": False,
            },
        )
        download = client.post(
            f"/v1/managed/chunks/{chunk_id}/download",
            headers=_macos_headers(),
            json={"request_id": str(uuid4())},
        )
        restore_body = restore.json()["restore"]
        complete = client.post(
            f"/v1/managed/restores/{restore_body['restore_job_id']}/complete",
            headers=_macos_headers(),
            json={
                "delivered_objects": restore_body["selected_objects"],
                "delivered_bytes": restore_body["selected_bytes"],
            },
        )

    assert me.status_code == 200
    assert chunks.status_code == 200
    assert restore.status_code == 201
    assert download.status_code == 200
    assert complete.status_code == 200
    assert complete.json()["restore"]["status"] == "completed"
    assert len(repository.restore_requests) == 1
    assert len(repository.restore_completions) == 1


def test_macos_viewer_rejects_cross_platform_assertion_and_writes_before_handler() -> (
    None
):
    disabled_client, disabled_repository = _managed_client()
    _enable_macos_viewer(disabled_repository)
    with disabled_client:
        disabled = disabled_client.get(
            "/v1/managed/me",
            headers=_macos_headers(app_check_token=APP_CHECK_TOKEN),
        )

    assertion_time = datetime.now(UTC)
    macos_assertion = ManagedAppCheckClaims(
        app_id=MACOS_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=assertion_time,
        expires_at=assertion_time + timedelta(hours=1),
    )
    client, repository = _managed_client(
        object_store=UploadObjectStore(),
        macos_app_id=MACOS_APP_ID,
        additional_app_check_tokens={
            MACOS_APP_CHECK_TOKEN: macos_assertion,
        },
    )
    _enable_macos_viewer(repository)
    event_end = datetime.now(UTC).replace(microsecond=0)

    with client:
        cross_platform = client.get(
            "/v1/managed/me",
            headers=_macos_headers(app_check_token=APP_CHECK_TOKEN),
        )
        reserve = client.post(
            "/v1/managed/chunks:reserve",
            headers=_macos_headers(),
            json={
                "chunk_id": str(uuid4()),
                "request_id": str(uuid4()),
                "source_id": str(uuid4()),
                "data_class": "essential_timeseries",
                "schema_version": 1,
                "content_mode": "server_readable",
                "event_start": (event_end - timedelta(minutes=5)).isoformat(),
                "event_end": event_end.isoformat(),
                "compression": "gzip",
                "content_type": "application/vnd.noop.chunk+json",
                "expected_sha256": "a" * 64,
                "expected_compressed_bytes": 128,
                "expected_uncompressed_bytes": 256,
                "streams": [],
            },
        )
        location = client.put(
            f"/v1/managed/safety/incidents/{uuid4()}/location",
            headers=_macos_headers(),
            json={
                "sequence": 1,
                "latitude": 0.0,
                "longitude": 0.0,
                "horizontal_accuracy_m": 5.0,
                "captured_at": event_end.isoformat(),
            },
        )

    assert disabled.status_code == 503
    assert disabled.json()["detail"] == "managed macOS viewer is not configured"
    assert cross_platform.status_code == 403
    assert cross_platform.json()["detail"] == (
        "managed app assertion does not match installation platform"
    )
    assert reserve.status_code == 403
    assert reserve.json()["detail"] == "managed macOS viewer is read-only"
    assert location.status_code == 403
    assert location.json()["detail"] == "managed macOS viewer is read-only"
    assert repository.chunk_reservations == []
    assert repository.upload_grants == []


def test_managed_installation_authorization_is_provider_tenant_bound() -> None:
    now = datetime.now(UTC)
    other_tenant_claims = ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject="firebase-user-1",
        provider_tenant="other-tenant",
        issued_at=now,
        auth_time=now - timedelta(minutes=1),
        expires_at=now + timedelta(hours=1),
    )
    client, _ = _managed_client(
        additional_identity_tokens={
            OTHER_MANAGED_TOKEN: other_tenant_claims,
        }
    )
    with client:
        response = client.get(
            "/v1/managed/me",
            headers={
                **_managed_headers(),
                "Authorization": f"Bearer {OTHER_MANAGED_TOKEN}",
            },
        )

    assert response.status_code == 403
    assert response.json()["detail"] == ("managed account authorization was rejected")


def test_managed_identity_reconciliation_rejects_cross_account_link() -> None:
    client, repository = _managed_client()
    repository.unified_authority.principal = UnifiedPrincipal(
        principal_id=uuid4(),
        status="active",
        managed_account_id=uuid4(),
        managed_identity_id=uuid4(),
        ownership_account_id=None,
        ownership_identity_id=None,
    )
    with client:
        response = client.get(
            "/v1/managed/me",
            headers=_managed_headers(),
        )

    assert response.status_code == 409
    assert response.json()["detail"] == (
        "managed account identity is linked differently"
    )


def test_managed_authority_state_and_opt_out_fail_closed() -> None:
    client, repository = _managed_client()
    with client:
        local = client.get(
            "/v1/managed/authority/essential_timeseries",
            headers=_managed_headers(),
        )
        local_opt_out = client.post(
            "/v1/managed/authority/essential_timeseries/opt-out",
            headers=_managed_headers(),
            json={"request_id": str(uuid4())},
        )
        repository.unified_authority.authority = repository.unified_authority._state(
            "shadow",
            transition_version=2,
        )
        rolled_back = client.post(
            "/v1/managed/authority/essential_timeseries/opt-out",
            headers=_managed_headers(),
            json={"request_id": str(uuid4())},
        )

    assert local.status_code == 200
    assert local.json()["authority"] == {
        "data_class": "essential_timeseries",
        "state": "local_only",
        "transition_version": 0,
        "pruning_authorized": False,
        "last_opt_out_at": None,
        "last_reconsented_at": None,
        "reconsent_policy_version": None,
        "reconsent_policy_sha256": None,
    }
    assert local_opt_out.status_code == 200
    assert local_opt_out.json()["duplicate"] is False
    assert local_opt_out.json()["authority"]["state"] == "rollback"
    assert local_opt_out.json()["authority"]["last_opt_out_at"] is not None
    assert rolled_back.status_code == 200
    assert rolled_back.json()["authority"]["state"] == "rollback"
    assert rolled_back.json()["authority"]["transition_version"] == 3
    assert rolled_back.json()["authority"]["pruning_authorized"] is False
    assert rolled_back.json()["duplicate"] is False
    assert len(repository.unified_authority.rollback_requests) == 2


def test_managed_authority_reconsent_requires_current_policy() -> None:
    client, repository = _managed_client()
    with client:
        opted_out = client.post(
            "/v1/managed/authority/essential_timeseries/opt-out",
            headers=_managed_headers(),
            json={"request_id": str(uuid4())},
        )
        stale = client.post(
            "/v1/managed/authority/essential_timeseries/re-consent",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "policy_version": "staging-v0",
                "policy_sha256": "b" * 64,
            },
        )
        accepted = client.post(
            "/v1/managed/authority/essential_timeseries/re-consent",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "policy_version": "staging-v1",
                "policy_sha256": POLICY_SHA256,
            },
        )

    assert opted_out.status_code == 200
    assert stale.status_code == 409
    assert accepted.status_code == 200
    assert accepted.json()["authority"]["state"] == "local_only"
    assert accepted.json()["authority"]["last_opt_out_at"] is not None
    assert accepted.json()["authority"]["last_reconsented_at"] is not None
    assert accepted.json()["authority"]["reconsent_policy_version"] == "staging-v1"
    assert len(repository.unified_authority.reconsent_requests) == 1


def test_managed_formula_shadow_is_default_off() -> None:
    client, _ = _managed_client(
        formula_repository=FakeManagedFormulaRepository(),
    )
    with client:
        response = client.post(
            "/v1/managed/formula-shadow/recovery/noop-charge-v2",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "local_day": "2026-09-19",
                "timezone_name": "America/Chicago",
                "inputs": {
                    "hrv": 55.0,
                    "rhr": 52.0,
                    "hrv_baseline": {
                        "mean": 50.0,
                        "spread": 5.0,
                        "usable": True,
                    },
                },
                "provenance": {
                    "source_kind": "synthetic_test",
                    "source_revision": "fixture-v1",
                    "input_manifest_sha256": "a" * 64,
                },
            },
        )

    assert response.status_code == 503
    assert response.json()["detail"] == (
        "managed formula shadow comparison is not configured"
    )


def test_managed_formula_shadow_is_tenant_bound_and_non_authoritative() -> None:
    formula_repository = FakeManagedFormulaRepository()
    client, repository = _managed_client(
        formula_repository=formula_repository,
        formula_shadow=True,
    )
    body = {
        "request_id": str(uuid4()),
        "local_day": "2026-09-19",
        "timezone_name": "America/Chicago",
        "inputs": {
            "hrv": 55.0,
            "rhr": 52.0,
            "hrv_baseline": {
                "mean": 50.0,
                "spread": 5.0,
                "usable": True,
            },
        },
        "provenance": {
            "source_kind": "synthetic_test",
            "source_revision": "fixture-v1",
            "input_manifest_sha256": "a" * 64,
        },
    }
    with client:
        published = client.post(
            "/v1/managed/formula-shadow/recovery/noop-charge-v2",
            headers=_managed_headers(),
            json=body,
        )
        current = client.get(
            "/v1/managed/formula-shadow/recovery/current?local_day=2026-09-19",
            headers=_managed_headers(),
        )

    assert published.status_code == 200
    assert published.json()["authority"] == "shadow_only"
    assert published.json()["result"]["metric_key"] == "recovery"
    assert published.json()["result"]["parity_status"] == "not_compared"
    assert current.status_code == 200
    assert current.json()["authority"] == "shadow_only"
    assert len(formula_repository.publications) == 1
    execution = formula_repository.publications[0]["execution"]
    assert execution.context.account_id == repository.principal.account_id


def test_managed_formula_shadow_exposes_no_authority_promotion_route() -> None:
    client, _ = _managed_client(
        formula_repository=FakeManagedFormulaRepository(),
        formula_shadow=True,
    )
    formula_routes = {
        path: frozenset(method.upper() for method in operation)
        for path, operation in client.app.openapi()["paths"].items()
        if path.startswith("/v1/managed/formula-shadow/")
    }

    assert formula_routes == {
        "/v1/managed/formula-shadow/{metric_key}/{formula_revision}": frozenset(
            {"POST"}
        ),
        "/v1/managed/formula-shadow/{metric_key}/current": frozenset({"GET"}),
    }


def test_managed_formula_huge_number_is_a_contract_rejection() -> None:
    client, _ = _managed_client(
        formula_repository=FakeManagedFormulaRepository(),
        formula_shadow=True,
    )
    with client:
        response = client.post(
            "/v1/managed/formula-shadow/recovery/noop-charge-v2",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "local_day": "2026-09-19",
                "timezone_name": "UTC",
                "inputs": {
                    "hrv": 10**400,
                    "rhr": 52.0,
                    "hrv_baseline": {
                        "mean": 50.0,
                        "spread": 5.0,
                        "usable": True,
                    },
                },
                "provenance": {
                    "source_kind": "synthetic_test",
                    "source_revision": "fixture-v1",
                    "input_manifest_sha256": "a" * 64,
                },
            },
        )

    assert response.status_code == 422
    assert response.json()["detail"] == (
        "formula shadow request did not match a registered contract"
    )


def test_formula_metric_event_cardinality_is_registry_bounded(
    monkeypatch,
) -> None:
    events: list[tuple[str, dict]] = []
    monkeypatch.setattr(
        managed_api_module,
        "emit_operational_event",
        lambda event, **fields: events.append((event, fields)),
    )
    client, _ = _managed_client(
        formula_repository=FakeManagedFormulaRepository(),
        formula_shadow=True,
    )
    unknown_metric = "synthetic_user_metric"
    with client:
        response = client.post(
            f"/v1/managed/formula-shadow/{unknown_metric}/v1",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "local_day": "2026-09-19",
                "timezone_name": "UTC",
                "inputs": {"value": 1},
                "provenance": {
                    "source_kind": "synthetic_test",
                    "source_revision": "fixture-v1",
                    "input_manifest_sha256": "a" * 64,
                },
            },
        )

    assert response.status_code == 422
    publication = next(
        fields
        for event, fields in events
        if event == "managed_formula.shadow_publication"
    )
    assert publication["metric_key"] == "unregistered"
    assert unknown_metric not in repr(events)


def test_managed_document_key_recovery_is_default_off() -> None:
    key_repository = FakeManagedDocumentKeyRepository()
    client, _ = _managed_client(document_key_repository=key_repository)
    wrapped = b"w" * 40
    with client:
        response = client.put(
            f"/v1/managed/document-keys/{uuid4()}",
            headers=_managed_headers(),
            json={
                "key_kind": "account_master",
                "wrapping_key_id": None,
                "wrapping_revision": 1,
                "algorithm": "A256GCM",
                "wrapped_key_base64": base64.b64encode(wrapped).decode("ascii"),
                "wrapped_key_sha256": hashlib.sha256(wrapped).hexdigest(),
                "master_key_confirmation_hmac_sha256": "f" * 64,
                "recovery_method": "recovery_key",
            },
        )

    assert response.status_code == 503
    assert response.json()["detail"] == (
        "managed document key recovery is not configured"
    )


def test_managed_document_key_recovery_is_account_scoped_and_opaque() -> None:
    key_repository = FakeManagedDocumentKeyRepository()
    client, repository = _managed_client(
        document_key_repository=key_repository,
        document_key_recovery=True,
    )
    key_id = uuid4()
    wrapped = b"k" * 40
    body = {
        "key_kind": "account_master",
        "wrapping_key_id": None,
        "wrapping_revision": 1,
        "algorithm": "A256GCM",
        "wrapped_key_base64": base64.b64encode(wrapped).decode("ascii"),
        "wrapped_key_sha256": hashlib.sha256(wrapped).hexdigest(),
        "master_key_confirmation_hmac_sha256": "e" * 64,
        "recovery_method": "device_transfer",
    }
    with client:
        stored = client.put(
            f"/v1/managed/document-keys/{key_id}",
            headers=_managed_headers(),
            json=body,
        )
        fetched = client.get(
            f"/v1/managed/document-keys/{key_id}",
            headers=_managed_headers(),
        )
        version = client.get(
            f"/v1/managed/document-keys/{key_id}/versions/1",
            headers=_managed_headers(),
        )
        revoked = client.post(
            f"/v1/managed/document-keys/{key_id}/revoke",
            headers=_managed_headers(),
            json={"successor_key_id": None},
        )

    assert stored.status_code == 200
    assert stored.json()["key"]["wrapped_key_base64"] == (
        base64.b64encode(wrapped).decode("ascii")
    )
    assert fetched.status_code == 200
    assert fetched.json()["key"]["key_kind"] == "account_master"
    assert fetched.json()["key"]["master_key_confirmation_hmac_sha256"] == "e" * 64
    assert version.status_code == 200
    assert version.json()["key_version"]["wrapped_key_base64"] == (
        base64.b64encode(wrapped).decode("ascii")
    )
    assert revoked.status_code == 200
    assert revoked.json()["key"]["status"] == "revoked"
    assert len(key_repository.mutations) == 1
    assert (
        key_repository.mutations[0]["principal"].account_id
        == repository.principal.account_id
    )


def test_standalone_managed_api_sets_private_response_headers(monkeypatch) -> None:
    monkeypatch.setenv("NOOP_MANAGED_REPLAY_SECRET", "s" * 32)
    from app.managed_main import create_managed_app

    app = create_managed_app(settings=_settings(enabled=True))
    client = TestClient(app)
    try:
        response = client.get("/v1/managed/me")
    finally:
        client.close()

    assert response.status_code == 401
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["x-content-type-options"] == "nosniff"


def test_managed_route_requires_installation_credential() -> None:
    client, _ = _managed_client()
    identity_headers = {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
    }
    with client:
        missing = client.get("/v1/managed/me", headers=identity_headers)
        missing_token = client.get(
            "/v1/managed/me",
            headers={
                **identity_headers,
                "X-Noop-Installation-ID": "ios-test-1",
            },
        )

    assert missing.status_code == 401
    assert missing_token.status_code == 401


def test_wrong_or_cross_installation_credential_is_rejected() -> None:
    client, _ = _managed_client()
    with client:
        wrong = client.get(
            "/v1/managed/me",
            headers=_managed_headers(
                installation_token="noopm_" + ("c" * 43),
            ),
        )
        spoofed = client.get(
            "/v1/managed/me",
            headers=_managed_headers(installation_id="android-test-2"),
        )

    assert wrong.status_code == 403
    assert spoofed.status_code == 403
    assert wrong.json()["detail"] == ("managed installation credential was rejected")


def test_managed_change_feed_uses_monotonic_sequence_cursor() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/changes?after_sequence=4&limit=20",
            headers=_managed_headers(),
        )

    assert response.status_code == 200
    assert response.json() == {
        "changes": [],
        "minimum_sequence": 1,
        "high_watermark": 4,
        "next_sequence": 4,
        "has_more": False,
    }


def test_managed_change_feed_preserves_mixed_document_modes_and_tombstones() -> None:
    client, repository = _managed_client()
    now = datetime.now(UTC).replace(microsecond=0)
    encrypted_id = uuid4()
    day_ownership_id = uuid4()
    repository.change_rows = [
        {
            "sequence": 5,
            "change_event_id": str(uuid4()),
            "resource_kind": "document",
            "resource_id": str(encrypted_id),
            "resource_revision": 1,
            "operation": "upsert",
            "content_sha256": "a" * 64,
            "data_class": "user_documents",
            "event_start": None,
            "event_end": None,
            "metadata": {"document_kind": "journal"},
            "occurred_at": now,
            "document": {
                "document_kind": "journal",
                "document_id": str(encrypted_id),
                "revision": 1,
                "content_mode": "client_encrypted",
                "client_key_id": str(uuid4()),
                "updated_at": now,
                "deleted_at": None,
            },
        },
        {
            "sequence": 6,
            "change_event_id": str(uuid4()),
            "resource_kind": "document",
            "resource_id": str(day_ownership_id),
            "resource_revision": 2,
            "operation": "tombstone",
            "content_sha256": "b" * 64,
            "data_class": "user_documents",
            "event_start": None,
            "event_end": None,
            "metadata": {"document_kind": "day_ownership"},
            "occurred_at": now,
            "document": {
                "document_kind": "day_ownership",
                "document_id": str(day_ownership_id),
                "revision": 2,
                "content_mode": "server_readable",
                "client_key_id": None,
                "updated_at": now,
                "deleted_at": now,
            },
        },
    ]

    with client:
        response = client.get(
            "/v1/managed/changes?after_sequence=4&limit=20",
            headers=_managed_headers(),
        )

    assert response.status_code == 200
    body = response.json()
    assert body["high_watermark"] == 6
    assert body["next_sequence"] == 6
    assert [
        (
            change["document"]["document_kind"],
            change["document"]["content_mode"],
            change["operation"],
        )
        for change in body["changes"]
    ] == [
        ("journal", "client_encrypted", "upsert"),
        ("day_ownership", "server_readable", "tombstone"),
    ]

    with client:
        filtered = client.get(
            (
                "/v1/managed/changes?after_sequence=4&limit=20"
                "&document_kind=day_ownership"
            ),
            headers=_managed_headers(),
        )

    assert filtered.status_code == 200
    filtered_body = filtered.json()
    assert filtered_body["high_watermark"] == 6
    assert filtered_body["next_sequence"] == 6
    assert filtered_body["has_more"] is False
    assert [
        change["document"]["document_kind"] for change in filtered_body["changes"]
    ] == ["day_ownership"]


def test_managed_change_feed_rejects_invalid_document_kind_filters() -> None:
    client, _ = _managed_client()
    with client:
        duplicate = client.get(
            (
                "/v1/managed/changes?after_sequence=4&limit=20"
                "&document_kind=day_ownership"
                "&document_kind=day_ownership"
            ),
            headers=_managed_headers(),
        )
        unknown = client.get(
            ("/v1/managed/changes?after_sequence=4&limit=20&document_kind=unsupported"),
            headers=_managed_headers(),
        )

    assert duplicate.status_code == 422
    assert unknown.status_code == 422


def test_managed_chunk_reservation_issues_one_bounded_upload_contract() -> None:
    client, repository = _managed_client(object_store=UploadObjectStore())
    now = datetime.now(UTC).replace(microsecond=0)
    chunk_id = uuid4()
    with client:
        response = client.post(
            "/v1/managed/chunks:reserve",
            headers=_managed_headers(),
            json={
                "chunk_id": str(chunk_id),
                "request_id": str(uuid4()),
                "source_id": str(uuid4()),
                "data_class": "essential_timeseries",
                "schema_version": 1,
                "content_mode": "server_readable",
                "event_start": (now - timedelta(minutes=5)).isoformat(),
                "event_end": now.isoformat(),
                "compression": "gzip",
                "content_type": "application/vnd.noop.chunk+json",
                "expected_sha256": "a" * 64,
                "expected_compressed_bytes": 128,
                "expected_uncompressed_bytes": 256,
                "streams": [],
            },
        )

    assert response.status_code == 201
    payload = response.json()
    assert payload["chunk"]["chunk_id"] == str(chunk_id)
    assert set(payload["upload"]) == {
        "grant_id",
        "method",
        "url",
        "headers",
        "expires_at",
    }
    assert payload["upload"]["method"] == "PUT"
    assert len(repository.chunk_reservations) == 1
    assert len(repository.upload_grants) == 1


def test_download_capability_includes_bounded_uncompressed_size() -> None:
    client, repository = _managed_client(object_store=DownloadObjectStore())
    chunk_id = uuid4()
    repository.available_chunk_row = {
        "chunk_id": chunk_id,
        "object_key": "accounts/test/chunk.gz",
        "object_generation": 42,
        "expected_sha256": "a" * 64,
        "compression": "gzip",
        "content_type": "application/vnd.noop.chunk+json",
        "expected_uncompressed_bytes": 12_345,
    }
    with client:
        response = client.post(
            f"/v1/managed/chunks/{chunk_id}/download",
            headers=_managed_headers(),
            json={"request_id": str(uuid4())},
        )

    assert response.status_code == 200
    assert response.json()["chunk"]["expected_uncompressed_bytes"] == 12_345


def test_export_completion_rejects_metadata_from_another_generation() -> None:
    client, repository = _managed_client(object_store=MismatchedGenerationObjectStore())
    export_job_id = uuid4()
    repository.export_row = {
        "export_job_id": export_job_id,
        "object_key": "exports/test/noop-export.noopbak",
        "status": "running",
    }
    with client:
        response = client.post(
            f"/v1/managed/exports/{export_job_id}/complete",
            headers=_managed_headers(),
            json={
                "object_generation": 42,
                "object_metageneration": 1,
                "object_crc32c": "AAAAAA==",
            },
        )

    assert response.status_code == 409
    assert repository.completed_exports == []


def test_managed_collection_cursors_are_atomic_and_use_lookahead() -> None:
    client, repository = _managed_client()
    now = datetime.now(UTC)
    repository.chunk_rows = [
        {
            "chunk_id": str(uuid4()),
            "event_start": now + timedelta(minutes=index),
        }
        for index in range(3)
    ]
    headers = _managed_headers()
    with client:
        partial = client.get(
            f"/v1/managed/chunks?after_chunk_id={uuid4()}",
            headers=headers,
        )
        page = client.get("/v1/managed/chunks?limit=2", headers=headers)
        repository.chunk_rows = repository.chunk_rows[:2]
        exact = client.get("/v1/managed/chunks?limit=2", headers=headers)

    assert partial.status_code == 422
    assert page.status_code == 200
    assert len(page.json()["chunks"]) == 2
    assert (
        page.json()["next_cursor"]["after_chunk_id"]
        == (repository.chunk_rows[1]["chunk_id"])
    )
    assert exact.status_code == 200
    assert exact.json()["next_cursor"] is None


def test_mobile_restore_is_chunk_only_and_snapshot_query_is_forwarded() -> None:
    client, repository = _managed_client()
    snapshot_at = "2026-09-01T02:00:00Z"
    headers = _managed_headers()
    with client:
        chunks = client.get(
            "/v1/managed/chunks"
            "?data_class=essential_timeseries"
            f"&snapshot_at={snapshot_at}"
            "&limit=10",
            headers=headers,
        )
        restore = client.post(
            "/v1/managed/restores",
            headers=headers,
            json={
                "request_id": str(uuid4()),
                "data_classes": ["essential_timeseries"],
                "document_kinds": [],
                "include_documents": False,
            },
        )
        tombstone_restore = client.post(
            "/v1/managed/restores",
            headers=headers,
            json={
                "request_id": str(uuid4()),
                "data_classes": ["essential_timeseries"],
                "document_kinds": ["day_ownership"],
                "include_documents": True,
                "include_deleted_documents": True,
            },
        )

    assert chunks.status_code == 200
    assert repository.chunk_list_calls[-1]["snapshot_at"] == datetime(
        2026, 9, 1, 2, tzinfo=UTC
    )
    assert restore.status_code == 201
    assert tombstone_restore.status_code == 201
    assert restore.json()["restore"]["change_sequence"] == 4
    assert repository.restore_requests[-2].include_documents is False
    assert repository.restore_requests[-2].include_deleted_documents is False
    assert repository.restore_requests[-1].include_documents is True
    assert repository.restore_requests[-1].include_deleted_documents is True


def test_managed_document_cursor_is_atomic() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/documents?after_document_kind=journal",
            headers=_managed_headers(),
        )

    assert response.status_code == 422
    assert response.json()["detail"] == (
        "all managed document cursor fields are required"
    )


def test_managed_document_rejects_plaintext_sensitive_kind() -> None:
    document_id = uuid4()
    client, _ = _managed_client()
    with client:
        response = client.put(
            f"/v1/managed/documents/journal/{document_id}",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "document_kind": "journal",
                "document_id": str(document_id),
                "base_revision": 0,
                "content_mode": "server_readable",
                "payload_json": {"notes": "must remain encrypted"},
                "updated_at": datetime.now(UTC).isoformat(),
                "deleted": False,
            },
        )

    assert response.status_code == 422


def test_managed_document_rejects_plaintext_escape_inside_day_ownership() -> None:
    document_id = uuid4()
    client, _ = _managed_client()
    with client:
        response = client.put(
            f"/v1/managed/documents/day_ownership/{document_id}",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "document_kind": "day_ownership",
                "document_id": str(document_id),
                "base_revision": 0,
                "content_mode": "server_readable",
                "payload_json": {
                    "schema_version": 1,
                    "table": "dayOwnership",
                    "key": {"day": "2026-09-11"},
                    "record": {
                        "day": "2026-09-11",
                        "deviceId": "test-device",
                        "locked": 0,
                        "notes": "must remain encrypted",
                    },
                },
                "updated_at": datetime.now(UTC).isoformat(),
                "deleted": False,
            },
        )

    assert response.status_code == 422


def test_managed_installations_can_list_and_revoke_another_device() -> None:
    client, _ = _managed_client()
    headers = _managed_headers()
    with client:
        listed = client.get("/v1/managed/installations", headers=headers)
        revoked = client.delete(
            "/v1/managed/installations/android-test-2",
            headers=headers,
        )

    assert listed.status_code == 200
    assert listed.json()["installations"][0]["current"] is True
    assert listed.json()["installations"][1]["current"] is False
    assert revoked.status_code == 200
    assert revoked.json()["installation"]["status"] == "revoked"


def test_revoked_installation_credential_cannot_read_identity_bound_routes() -> None:
    client, _ = _managed_client()
    with client:
        revoked = client.delete(
            "/v1/managed/installations/android-test-2",
            headers=_managed_headers(),
        )
        rejected = client.get(
            "/v1/managed/me",
            headers=_managed_headers(
                installation_id="android-test-2",
                installation_token=OTHER_INSTALLATION_TOKEN,
            ),
        )

    assert revoked.status_code == 200
    assert rejected.status_code == 403


def test_managed_erasure_requires_scope_bound_confirmation() -> None:
    client, _ = _managed_client()
    headers = _managed_headers()
    with client:
        response = client.post(
            "/v1/managed/erasure",
            headers=headers,
            json={
                "request_id": str(uuid4()),
                "scope": "account",
                "confirmation_sha256": hashlib.sha256(
                    b"delete-noop-plus-raw-chunks-v1"
                ).hexdigest(),
            },
        )

    assert response.status_code == 422
    assert response.json()["detail"] == (
        "managed erasure confirmation does not match its scope"
    )


def test_managed_account_erasure_seals_provider_identity_for_lifecycle() -> None:
    client, repository = _managed_client()
    request_id = uuid4()
    headers = _managed_headers()
    with client:
        response = client.post(
            "/v1/managed/erasure",
            headers=headers,
            json={
                "request_id": str(request_id),
                "scope": "account",
                "confirmation_sha256": hashlib.sha256(
                    b"delete-noop-plus-managed-account-v1"
                ).hexdigest(),
            },
        )

    assert response.status_code == 202
    assert len(repository.erasure_requests) == 1
    request = repository.erasure_requests[0]
    assert request["request_id"] == request_id
    assert request["scope"] == "account"
    ticket = request["identity_deletion_ticket"]
    assert isinstance(ticket, bytes)
    assert b"firebase-user-1" not in ticket


def test_managed_account_erasure_receipt_uses_installation_credential() -> None:
    now = datetime.now(UTC)
    android_assertion = ManagedAppCheckClaims(
        app_id=ANDROID_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    client, _ = _managed_client(
        additional_app_check_tokens={
            ANDROID_APP_CHECK_TOKEN: android_assertion,
        }
    )
    with client:
        requested = client.post(
            "/v1/managed/erasure",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "scope": "account",
                "confirmation_sha256": hashlib.sha256(
                    b"delete-noop-plus-managed-account-v1"
                ).hexdigest(),
            },
        )
        erasure_job_id = requested.json()["erasure"]["erasure_job_id"]
        receipt_headers = {
            "X-Firebase-AppCheck": APP_CHECK_TOKEN,
            "X-Noop-Installation-ID": "ios-test-1",
            "X-Noop-Installation-Token": INSTALLATION_TOKEN,
        }
        received = client.get(
            f"/v1/managed/erasure/{erasure_job_id}/receipt",
            headers=receipt_headers,
        )
        wrong_installation_secret = client.get(
            f"/v1/managed/erasure/{erasure_job_id}/receipt",
            headers={
                **receipt_headers,
                "X-Noop-Installation-Token": OTHER_INSTALLATION_TOKEN,
            },
        )
        wrong_platform_assertion = client.get(
            f"/v1/managed/erasure/{erasure_job_id}/receipt",
            headers={
                **receipt_headers,
                "X-Firebase-AppCheck": ANDROID_APP_CHECK_TOKEN,
            },
        )

    assert requested.status_code == 202
    assert received.status_code == 200
    assert received.json()["erasure"]["status"] == "cooling_off"
    assert wrong_installation_secret.status_code == 404
    assert wrong_platform_assertion.status_code == 403


def test_managed_erasure_cancel_does_not_require_fresh_destructive_auth() -> None:
    client, _ = _managed_client(auth_age=timedelta(hours=12))
    job_id = uuid4()
    with client:
        response = client.post(
            f"/v1/managed/erasure/{job_id}/cancel",
            headers=_managed_headers(),
        )

    assert response.status_code == 200
    assert response.json()["erasure"]["status"] == "canceled"


def test_managed_social_profile_lookup_and_invite_use_managed_identity() -> None:
    client, repository = _managed_client()
    capability = "noopinvite_" + ("c" * 43)
    with client:
        created = client.post(
            "/v1/managed/social/profile",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "display_name": "  Test person  ",
            },
        )
        found = client.get(
            "/v1/managed/social/lookup",
            headers=_managed_headers(),
            params={"noop_id": "noop-abcd-efgh-jklm-npqr"},
        )
        invite = client.post(
            "/v1/managed/social/invites",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "capability": capability,
                "expires_in_hours": 24,
            },
        )

    assert created.status_code == 201
    assert created.json()["profile"]["display_name"] == "Test person"
    assert repository.social_profile_requests[0].display_name == "Test person"
    assert found.status_code == 200
    assert found.json()["profile"]["noop_id"] == "NOOP-ABCD-EFGH-JKLM-NPQR"
    assert invite.status_code == 201
    assert invite.json()["invite"]["capability"] == capability
    assert (
        repository.social_invite_requests[0].capability.get_secret_value() == capability
    )


def test_managed_social_profile_delete_requires_exact_confirmation() -> None:
    client, repository = _managed_client()
    with client:
        missing = client.delete(
            "/v1/managed/social/profile",
            headers=_managed_headers(),
        )
        incorrect = client.delete(
            "/v1/managed/social/profile",
            headers={
                **_managed_headers(),
                "X-Noop-Confirm": "DELETE MY MANAGED ACCOUNT",
            },
        )
        deleted = client.delete(
            "/v1/managed/social/profile",
            headers={
                **_managed_headers(),
                "X-Noop-Confirm": "DELETE MANAGED FRIENDS",
            },
        )

    assert missing.status_code == 409
    assert incorrect.status_code == 409
    assert deleted.status_code == 204
    assert repository.social_profile_deletions == 1


def test_managed_social_validation_never_echoes_invite_or_extra_health_data() -> None:
    client, _ = _managed_client()
    leaked = "noopinvite_" + ("z" * 42) + "!"
    with client:
        invalid_invite = client.post(
            "/v1/managed/social/invites",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "capability": leaked,
                "expires_in_hours": 24,
            },
        )
        invalid_summary = client.put(
            "/v1/managed/social/summaries/2026-09-05",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "summary": {"spo2": 98.0},
            },
        )

    assert invalid_invite.status_code == 422
    assert leaked not in invalid_invite.text
    assert invalid_summary.status_code == 422
    assert "98.0" not in invalid_summary.text


def test_managed_social_poke_claim_is_installation_bound_and_acknowledged() -> None:
    client, repository = _managed_client()
    with client:
        sent = client.post(
            "/v1/managed/social/pokes",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "recipient_profile_id": str(repository.social_friend_id),
            },
        )
        claimed = client.post(
            "/v1/managed/social/pokes:claim",
            headers=_managed_headers(),
            params={"limit": 2},
        )
        acknowledged = client.post(
            f"/v1/managed/social/pokes/{repository.social_poke_id}:ack",
            headers=_managed_headers(),
            json={
                "claim_id": str(repository.social_claim_id),
                "notification_outcome": "scheduled",
                "haptic_outcome": "requested",
            },
        )

    assert sent.status_code == 202
    assert claimed.status_code == 200
    assert repository.social_claims == [("ios-test-1", 2)]
    assert acknowledged.status_code == 200
    assert repository.social_acknowledgements[0]["installation_id"] == "ios-test-1"


class FakeManagedSafetyRepository:
    def __init__(self) -> None:
        self.profile_id = uuid4()
        self.other_profile_id = uuid4()
        self.request_id = uuid4()
        self.invite_id = uuid4()
        self.incident_id = uuid4()
        self.calls: list[tuple[str, dict]] = []

    def _incident(self, *, role: str = "owner", status: str = "open") -> dict:
        now = datetime.now(UTC)
        return {
            "incident_id": str(self.incident_id),
            "role": role,
            "owner_profile_id": str(self.profile_id),
            "owner_display_name": "Owner",
            "trigger": "manual_sos",
            "status": status,
            "duration_hours": 8,
            "share_location": True,
            "created_at": now,
            "expires_at": now + timedelta(hours=8),
            "acknowledged_at": None,
            "ended_at": None,
            "participants": [
                {
                    "profile_id": str(self.other_profile_id),
                    "display_name": "Contact",
                    "status": "pending",
                    "paged_at": now,
                    "responded_at": None,
                    "push": {"configured": True, "reached": True},
                }
            ],
            "location": None,
            "delivery": {
                "contacts_targeted": 2,
                "contacts_reached": 1,
                "installations_targeted": 2,
                "installations_reached": 1,
            },
        }

    async def revoke_push_installation(self, **kwargs):
        self.calls.append(("revoke_push", kwargs))

    async def create_invite(self, **kwargs):
        self.calls.append(("create_invite", kwargs))
        now = datetime.now(UTC)
        return {
            "invite_id": str(self.invite_id),
            "capability": kwargs["request"].capability.get_secret_value(),
            "status": "active",
            "created_at": now,
            "expires_at": now + timedelta(hours=72),
            "duplicate": False,
        }

    async def revoke_invite(self, **kwargs):
        self.calls.append(("revoke_invite", kwargs))

    async def redeem_invite(self, **kwargs):
        self.calls.append(("redeem_invite", kwargs))
        return self._request(direction="incoming")

    async def create_request(self, **kwargs):
        self.calls.append(("create_request", kwargs))
        return self._request(direction="outgoing")

    def _request(self, *, direction: str) -> dict:
        now = datetime.now(UTC)
        return {
            "request_id": str(self.request_id),
            "profile_id": str(self.other_profile_id),
            "display_name": "Contact",
            "direction": direction,
            "source": "noop_id",
            "status": "pending",
            "created_at": now,
            "decided_at": None,
            "expires_at": now + timedelta(days=30),
            "duplicate": False,
        }

    async def list_requests(self, **kwargs):
        self.calls.append(("list_requests", kwargs))
        return [self._request(direction="incoming")]

    async def decide_request(self, **kwargs):
        self.calls.append(("decide_request", kwargs))
        value = self._request(direction="incoming")
        value["status"] = "accepted" if kwargs["decision"] == "accept" else "declined"
        value["decided_at"] = datetime.now(UTC)
        return value

    async def list_contacts(self, **kwargs):
        self.calls.append(("list_contacts", kwargs))
        return [
            {
                "profile_id": str(self.other_profile_id),
                "display_name": "Contact",
                "role": "contact",
                "accepted_at": datetime.now(UTC),
            }
        ]

    async def contact_snapshot(self, **kwargs):
        self.calls.append(("contact_snapshot", kwargs))
        return await self.list_contacts(**kwargs), 1

    async def remove_contact(self, **kwargs):
        self.calls.append(("remove_contact", kwargs))

    async def create_incident(self, **kwargs):
        self.calls.append(("create_incident", kwargs))
        return {**self._incident(), "duplicate": False}

    async def list_incidents(self, **kwargs):
        self.calls.append(("list_incidents", kwargs))
        return [self._incident()]

    async def get_incident(self, **kwargs):
        self.calls.append(("get_incident", kwargs))
        return self._incident()

    async def update_location(self, **kwargs):
        self.calls.append(("update_location", kwargs))
        update = kwargs["update"]
        return {
            "sequence": update.sequence,
            "latitude": update.latitude,
            "longitude": update.longitude,
            "horizontal_accuracy_m": update.horizontal_accuracy_m,
            "captured_at": update.captured_at,
            "received_at": datetime.now(UTC),
            "duplicate": False,
        }

    async def respond(self, **kwargs):
        self.calls.append(("respond", kwargs))
        return {
            **self._incident(role="contact", status="acknowledged"),
            "duplicate": False,
        }

    async def end_incident(self, **kwargs):
        self.calls.append(("end_incident", kwargs))
        return {
            **self._incident(status=kwargs["outcome"]),
            "duplicate": False,
        }


class RateLimitedManagedSafetyRepository(FakeManagedSafetyRepository):
    async def create_incident(self, **kwargs):
        self.calls.append(("create_incident", kwargs))
        raise ManagedRateLimitError(
            "Safety paging limit reached; wait before paging again",
            retry_after_seconds=45,
        )


class FakeManagedSafetyPushService:
    def __init__(
        self,
        repository: FakeManagedSafetyRepository,
        *,
        available: bool = True,
    ) -> None:
        self.repository = repository
        self.available = available
        self.registrations = []
        self.dispatches = []

    async def register(self, **kwargs):
        self.registrations.append(kwargs)
        registration = kwargs["registration"]
        return {
            "installation_id": kwargs["installation_id"],
            "platform": registration.platform,
            "environment": registration.environment,
            "target_kind": registration.target_kind,
            "status": "active",
            "updated_at": datetime.now(UTC),
            "duplicate": False,
        }

    async def dispatch(self, **kwargs):
        self.dispatches.append(kwargs)
        return {
            "contacts_targeted": 2,
            "contacts_reached": 1,
            "installations_targeted": 2,
            "installations_reached": 1,
        }


def test_managed_safety_routes_fail_closed_without_configured_repository() -> None:
    client, _ = _managed_client()
    with client:
        response = client.get(
            "/v1/managed/safety/contacts",
            headers=_managed_headers(),
        )
    assert response.status_code == 503
    assert response.json()["detail"] == "managed Safety is not configured"


def test_managed_safety_incident_fails_before_persistence_when_push_is_unavailable() -> (
    None
):
    safety = FakeManagedSafetyRepository()
    push = FakeManagedSafetyPushService(safety, available=False)
    client, _ = _managed_client(
        managed_safety_repository=safety,
        managed_safety_push_service=push,
    )
    with client:
        contacts = client.get(
            "/v1/managed/safety/contacts",
            headers=_managed_headers(),
        )
        incident = client.post(
            "/v1/managed/safety/incidents",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "trigger": "manual_sos",
                "duration_hours": 8,
                "share_location": False,
            },
        )
    assert contacts.status_code == 200
    assert contacts.json()["delivery_capable_count"] == 0
    assert incident.status_code == 503
    assert not any(call[0] == "create_incident" for call in safety.calls)


def test_managed_safety_push_registration_never_echoes_token() -> None:
    safety = FakeManagedSafetyRepository()
    push = FakeManagedSafetyPushService(safety)
    client, _ = _managed_client(
        managed_safety_repository=safety,
        managed_safety_push_service=push,
    )
    token = "fcm-token:ABC_def-1234567890"
    with client:
        response = client.put(
            "/v1/managed/push/installations/current",
            headers=_managed_headers(),
            json={
                "platform": "ios",
                "environment": "production",
                "target_kind": "token",
                "token": token,
            },
        )
        invalid = client.put(
            "/v1/managed/push/installations/current",
            headers=_managed_headers(),
            json={
                "platform": "ios",
                "environment": "production",
                "target_kind": "token",
                "token": "bad token value",
            },
        )
    assert response.status_code == 200
    assert token not in response.text
    assert push.registrations[0]["installation_id"] == "ios-test-1"
    assert invalid.status_code == 422
    assert "bad token value" not in invalid.text


def test_managed_safety_account_flow_is_identity_and_installation_bound() -> None:
    safety = FakeManagedSafetyRepository()
    push = FakeManagedSafetyPushService(safety)
    client, _ = _managed_client(
        managed_safety_repository=safety,
        managed_safety_push_service=push,
    )
    capability = "noopsafety_" + ("a" * 43)
    captured_at = datetime.now(UTC)
    with client:
        invite = client.post(
            "/v1/managed/safety/invites",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "capability": capability,
                "expires_in_hours": 72,
            },
        )
        request = client.post(
            "/v1/managed/safety/requests",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "noop_id": "noop-abcd-efgh-jklm-npqr",
            },
        )
        decided = client.post(
            f"/v1/managed/safety/requests/{safety.request_id}",
            headers=_managed_headers(),
            json={"decision": "accept"},
        )
        contacts = client.get(
            "/v1/managed/safety/contacts",
            headers=_managed_headers(),
        )
        incident = client.post(
            "/v1/managed/safety/incidents",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "trigger": "band_sos",
                "duration_hours": 8,
                "share_location": True,
            },
        )
        location = client.put(
            f"/v1/managed/safety/incidents/{safety.incident_id}/location",
            headers=_managed_headers(),
            json={
                "sequence": 1,
                "latitude": 17.385,
                "longitude": 78.4867,
                "horizontal_accuracy_m": 12.5,
                "captured_at": captured_at.isoformat(),
            },
        )
        response = client.post(
            f"/v1/managed/safety/incidents/{safety.incident_id}/response",
            headers=_managed_headers(),
            json={"decision": "responding"},
        )
        ended = client.post(
            f"/v1/managed/safety/incidents/{safety.incident_id}:end",
            headers=_managed_headers(),
            json={"outcome": "resolved"},
        )

    assert invite.status_code == 201
    assert capability in invite.json()["invite"]["capability"]
    assert request.status_code == 201
    assert decided.json()["request"]["status"] == "accepted"
    assert contacts.json()["minimum_required"] == 2
    assert contacts.json()["delivery_capable_count"] == 1
    assert incident.status_code == 202
    assert incident.json()["push_outcome"] == "attempted"
    create_call = next(call for call in safety.calls if call[0] == "create_incident")
    assert create_call[1]["request"].trigger == "band_sos"
    assert push.dispatches[0]["incident_id"] == safety.incident_id
    assert location.status_code == 200
    assert location.json()["location"]["sequence"] == 1
    assert response.json()["incident"]["status"] == "acknowledged"
    assert ended.json()["incident"]["status"] == "resolved"


def test_managed_safety_incident_quota_returns_retry_after() -> None:
    safety = RateLimitedManagedSafetyRepository()
    push = FakeManagedSafetyPushService(safety)
    client, _ = _managed_client(
        managed_safety_repository=safety,
        managed_safety_push_service=push,
    )

    with client:
        response = client.post(
            "/v1/managed/safety/incidents",
            headers=_managed_headers(),
            json={
                "request_id": str(uuid4()),
                "duration_hours": 8,
                "share_location": False,
            },
        )

    assert response.status_code == 429
    assert response.headers["retry-after"] == "45"
    assert response.json() == {
        "detail": "Safety paging limit reached; wait before paging again"
    }
