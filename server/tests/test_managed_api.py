from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi.testclient import TestClient

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
from app.managed_object_store import ManagedObjectCapability, ManagedObjectMetadata
from app.managed_repository import ManagedForbiddenError, ManagedPrincipal
from app.repository import MemoryRepository

TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"
MANAGED_TOKEN = "managed-test-token"
APP_CHECK_TOKEN = "managed-app-check-token"
INSTALLATION_TOKEN = "noopm_" + ("a" * 43)
OTHER_INSTALLATION_TOKEN = "noopm_" + ("b" * 43)
POLICY_SHA256 = "a" * 64
PROJECT_NUMBER = "123456789012"
APPLE_APP_ID = f"1:{PROJECT_NUMBER}:ios:0123456789abcdef"
ANDROID_APP_ID = f"1:{PROJECT_NUMBER}:android:fedcba9876543210"


class FakeManagedRepository:
    def __init__(self, claims: ManagedIdentityClaims) -> None:
        self.principal = ManagedPrincipal(
            account_id=uuid4(),
            identity_id=uuid4(),
            subject_hash=claims.subject_hash,
            account_status="active",
            auth_valid_after=claims.auth_time,
        )
        self.enrollments = []
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
        self.available_chunk_row: dict | None = None
        self.chunk_list_calls: list[dict] = []
        self.chunk_reservations = []
        self.upload_grants = []
        self.restore_requests = []
        self.export_row: dict | None = None
        self.completed_exports: list[dict] = []
        self.erasure_requests: list[dict] = []
        self.installation_token_hashes = {
            "ios-test-1": hashlib.sha256(
                INSTALLATION_TOKEN.encode("ascii")
            ).hexdigest(),
            "android-test-2": hashlib.sha256(
                OTHER_INSTALLATION_TOKEN.encode("ascii")
            ).hexdigest(),
        }

    async def principal_for_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> ManagedPrincipal:
        assert claims.subject_hash == self.principal.subject_hash
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
    ) -> dict:
        assert principal == self.principal
        assert after_sequence == 4
        assert limit == 20
        return {
            "changes": [],
            "minimum_sequence": 1,
            "high_watermark": 4,
            "next_sequence": 4,
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
        assert installation_id == "ios-test-1"
        self.restore_requests.append(request)
        now = datetime.now(UTC)
        return {
            "restore_job_id": str(uuid4()),
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
        return {
            "erasure_job_id": str(uuid4()),
            "scope": kwargs["scope"],
            "status": "cooling_off",
            "not_before": datetime.now(UTC) + timedelta(hours=24),
        }


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


def _settings(*, enabled: bool) -> Settings:
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
        managed_raw_bucket="noop-private-bucket",
        managed_signer_email="noop-api@example.iam.gserviceaccount.com",
        managed_replay_secret="managed-replay-secret-at-least-32-bytes",
        managed_consent_policy_version="staging-v1",
        managed_consent_policy_sha256=POLICY_SHA256,
    )


def _managed_client(
    *,
    auth_age: timedelta = timedelta(minutes=1),
    object_store=None,
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
    app_check_claims = ManagedAppCheckClaims(
        app_id=APPLE_APP_ID,
        issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
        audience=(f"projects/{PROJECT_NUMBER}",),
        issued_at=now,
        expires_at=now + timedelta(hours=1),
    )
    app = create_app(
        settings=_settings(enabled=True),
        repository=MemoryRepository(),
        managed_repository=managed_repository,  # type: ignore[arg-type]
        managed_app_check_verifier=StaticManagedAppCheckVerifier(
            {APP_CHECK_TOKEN: app_check_claims}
        ),
        managed_token_verifier=StaticManagedTokenVerifier({MANAGED_TOKEN: claims}),
        managed_object_store=object_store or UnusedObjectStore(),
    )
    return TestClient(app), managed_repository


def _managed_headers(
    *,
    installation_id: str = "ios-test-1",
    installation_token: str = INSTALLATION_TOKEN,
) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {MANAGED_TOKEN}",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
        "X-Noop-Installation-ID": installation_id,
        "X-Noop-Installation-Token": installation_token,
    }


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
    }
    assert len(repository.enrollments) == 1
    assert (
        repository.enrollments[0][1].installation_token.get_secret_value()
        == INSTALLATION_TOKEN
    )


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

    assert chunks.status_code == 200
    assert repository.chunk_list_calls[-1]["snapshot_at"] == datetime(
        2026, 9, 1, 2, tzinfo=UTC
    )
    assert restore.status_code == 201
    assert restore.json()["restore"]["change_sequence"] == 4
    assert repository.restore_requests[-1].include_documents is False


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
