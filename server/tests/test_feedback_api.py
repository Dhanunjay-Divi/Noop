from __future__ import annotations

import asyncio
import hashlib
import io
import json
import re
import zipfile
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.feedback_archive import (
    FeedbackArchiveSummary,
    FeedbackArchiveValidating,
    FeedbackArchiveValidationUnavailableError,
)
from app.feedback_capability import FeedbackCapabilityCodec
from app.feedback_repository import (
    FeedbackConflictError,
    FeedbackReport,
    MemoryFeedbackRepository,
)
from app.main import create_app
from app.managed_app_check import (
    ManagedAppCheckClaims,
    StaticManagedAppCheckVerifier,
)
from app.managed_identity import ManagedIdentityClaims, StaticManagedTokenVerifier
from app.managed_identity_deletion import ManagedIdentityDeletionTicketCodec
from app.managed_object_store import (
    ManagedObjectCapability,
    ManagedObjectMetadata,
    ManagedObjectNotFoundError,
)
from app.repository import MemoryRepository


PROJECT_NUMBER = "123456789012"
APPLE_APP_ID = f"1:{PROJECT_NUMBER}:ios:0123456789abcdef"
ANDROID_APP_ID = f"1:{PROJECT_NUMBER}:android:fedcba9876543210"
APP_CHECK_TOKEN = "feedback-app-check"
OTHER_APP_CHECK_TOKEN = "feedback-other-app-check"
IDENTITY_TOKEN = "feedback-identity-token"
OTHER_IDENTITY_TOKEN = "feedback-other-identity-token"
OTHER_TENANT_IDENTITY_TOKEN = "feedback-other-tenant-identity-token"
PHONE_IDENTITY_TOKEN = "feedback-phone-identity-token"
PASSWORD_IDENTITY_TOKEN = "feedback-password-identity-token"
FEDERATED_IDENTITY_TOKEN = "feedback-federated-identity-token"
SECRET = "feedback-capability-secret-at-least-32-bytes"


class FakeFeedbackObjectStore:
    def __init__(self) -> None:
        self.object_key: str | None = None
        self.expected_sha256: str | None = None
        self.expected_size = 0
        self.payload: bytes | None = None
        self.generation = 42
        self.deleted = False
        self.capability_expires_at: datetime | None = None
        self.upload_capability_calls = 0
        self.metadata_calls = 0
        self.read_calls = 0
        self.read_admission_probe: Callable[[], bool] | None = None

    async def upload_capability(self, **kwargs):
        self.upload_capability_calls += 1
        self.object_key = kwargs["object_key"]
        self.expected_sha256 = kwargs["content_sha256"]
        self.expected_size = kwargs["content_length"]
        expires_at = self.capability_expires_at or datetime.now(UTC) + timedelta(
            minutes=5
        )
        if kwargs.get("not_after") is not None:
            expires_at = min(expires_at, kwargs["not_after"])
        return ManagedObjectCapability(
            method="PUT",
            url="https://storage.example/upload",
            headers={
                "content-length": str(self.expected_size),
                "content-type": "application/zip",
                "x-goog-content-sha256": self.expected_sha256,
            },
            expires_at=expires_at,
        )

    async def download_capability(self, **kwargs):  # pragma: no cover - unused seam
        raise AssertionError(kwargs)

    async def metadata(self, **kwargs):
        if kwargs["generation"] != self.generation:
            raise ManagedObjectNotFoundError("missing")
        return await self.latest_metadata(object_key=kwargs["object_key"])

    async def latest_metadata(self, *, object_key: str):
        self.metadata_calls += 1
        if self.payload is None or object_key != self.object_key or self.deleted:
            raise ManagedObjectNotFoundError("missing")
        return ManagedObjectMetadata(
            object_key=object_key,
            generation=self.generation,
            metageneration=1,
            crc32c="AAAAAA==",
            size=len(self.payload),
            content_type="application/zip",
            metadata={"noop-sha256": hashlib.sha256(self.payload).hexdigest()},
        )

    async def read(self, *, object_key: str, generation: int, maximum_bytes: int):
        self.read_calls += 1
        if self.read_admission_probe is not None:
            assert self.read_admission_probe()
        assert object_key == self.object_key
        assert generation == self.generation
        if self.payload is None or len(self.payload) > maximum_bytes:
            raise ManagedObjectNotFoundError("missing")
        return self.payload

    async def delete(self, **kwargs):
        assert kwargs["object_key"] == self.object_key
        if self.payload is None:
            raise ManagedObjectNotFoundError("missing")
        self.deleted = True


class UnusedManagedRepository:
    pass


class CancellingReplayRepository(MemoryFeedbackRepository):
    def __init__(self) -> None:
        super().__init__()
        self.activation_count = 0

    async def activate_upload_capability(self, **kwargs):
        self.activation_count += 1
        if self.activation_count == 2:
            await self.request_delete(
                report_id=kwargs["report_id"],
                client_app_id=kwargs["client_app_id"],
                requested_at=kwargs["activated_at"],
                cleanup_after=kwargs["cleanup_after"],
            )
        return await super().activate_upload_capability(**kwargs)


class ConflictingActivationRepository(MemoryFeedbackRepository):
    async def activate_upload_capability(self, **kwargs):
        raise FeedbackConflictError("activation conflicted")


class UnavailableArchiveValidator:
    async def acquire(self):
        raise FeedbackArchiveValidationUnavailableError("busy")


class TrackingArchiveValidator:
    def __init__(self) -> None:
        self.acquired = False
        self.active = False
        self.validated = False

    async def acquire(self):
        self.acquired = True
        return _TrackingArchiveAdmission(self)


class _TrackingArchiveAdmission:
    def __init__(self, owner: TrackingArchiveValidator) -> None:
        self.owner = owner

    async def __aenter__(self):
        self.owner.active = True
        return self

    async def __aexit__(self, *_args) -> None:
        self.owner.active = False

    async def validate(self, *_args, **_kwargs) -> FeedbackArchiveSummary:
        assert self.owner.active
        self.owner.validated = True
        return FeedbackArchiveSummary(
            file_count=3,
            uncompressed_bytes=100,
            includes_user_note=False,
            includes_screenshot=False,
        )


def _archive(*, platform: str = "iOS", raw: bool = False) -> bytes:
    metadata = {
        "schema": 1,
        "platform": platform,
        "test_profile": "app-hang",
        "redaction": "v2",
        "questionnaire": {},
        "storage": {
            "db_bytes": 123,
            "raw_capture_bytes": 0,
            "rows": {},
        },
    }
    entries: dict[str, bytes] = {
        "report.txt": b"NOOP app runtime report\n",
        "meta.json": json.dumps(metadata).encode("utf-8"),
        "app-session-current.jsonl": b'{"event":"app.launch"}\n',
    }
    if raw:
        entries["raw-capture.jsonl"] = b'{"hr":120}\n'
    if platform == "iOS":
        manifest = {
            "schema_version": 1,
            "platform": "ios",
            "app_version": "9.2.0",
            "created_at": "2026-09-12T12:00:00Z",
            "includes_user_note": False,
            "includes_screenshot": False,
            "entries": [
                {
                    "name": name,
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
                for name, data in sorted(entries.items())
            ],
        }
        entries["feedback-manifest.json"] = json.dumps(manifest).encode("utf-8")

    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return output.getvalue()


def _settings() -> Settings:
    return Settings(
        api_token="test-token-abcdefghijklmnopqrstuvwxyz-0123456789",
        database_url=None,
        dashboard_enabled=False,
        managed_storage_enabled=True,
        managed_project_id="noop-test-project",
        managed_project_number=PROJECT_NUMBER,
        managed_identity_api_key="identity-api-key",
        managed_apple_app_id=APPLE_APP_ID,
        managed_android_app_id=ANDROID_APP_ID,
        managed_raw_bucket="noop-private-bucket",
        managed_signer_email="noop-api@example.iam.gserviceaccount.com",
        managed_replay_secret="managed-replay-secret-at-least-32-bytes",
        managed_consent_policy_version="staging-v1",
        managed_consent_policy_sha256="a" * 64,
        feedback_enabled=True,
        feedback_accepting_reservations=True,
        feedback_bucket="noop-feedback-private",
        feedback_capability_secret=SECRET,
        feedback_retention_days=28,
        feedback_external_abuse_gate_approved=True,
    )


def _client(
    *,
    settings: Settings | None = None,
    feedback_repository: MemoryFeedbackRepository | None = None,
    feedback_archive_validator: FeedbackArchiveValidating | None = None,
    feedback_object_store: FakeFeedbackObjectStore | None = None,
) -> tuple[
    TestClient,
    FakeFeedbackObjectStore,
    MemoryFeedbackRepository,
]:
    now = datetime.now(UTC)
    verifier = StaticManagedAppCheckVerifier(
        {
            APP_CHECK_TOKEN: ManagedAppCheckClaims(
                app_id=APPLE_APP_ID,
                issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
                audience=(f"projects/{PROJECT_NUMBER}",),
                issued_at=now,
                expires_at=now + timedelta(hours=1),
            ),
            OTHER_APP_CHECK_TOKEN: ManagedAppCheckClaims(
                app_id=ANDROID_APP_ID,
                issuer=f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
                audience=(f"projects/{PROJECT_NUMBER}",),
                issued_at=now,
                expires_at=now + timedelta(hours=1),
            ),
        }
    )
    store = feedback_object_store or FakeFeedbackObjectStore()
    repository = feedback_repository or MemoryFeedbackRepository()
    app = create_app(
        settings=settings or _settings(),
        repository=MemoryRepository(),
        managed_repository=UnusedManagedRepository(),  # type: ignore[arg-type]
        managed_app_check_verifier=verifier,
        managed_token_verifier=StaticManagedTokenVerifier(
            {
                IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-test-user",
                    provider_tenant="noop-test-project",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    sign_in_provider="anonymous",
                ),
                OTHER_IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-other-user",
                    provider_tenant="noop-test-project",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    sign_in_provider="anonymous",
                ),
                OTHER_TENANT_IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-test-user",
                    provider_tenant="other-tenant",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    sign_in_provider="anonymous",
                ),
                PHONE_IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-phone-user",
                    provider_tenant="noop-test-project",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    phone_verified=True,
                    sign_in_provider="phone",
                ),
                PASSWORD_IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-password-user",
                    provider_tenant="noop-test-project",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    email_verified=True,
                    sign_in_provider="password",
                ),
                FEDERATED_IDENTITY_TOKEN: ManagedIdentityClaims(
                    issuer="https://securetoken.google.com/noop-test-project",
                    subject="feedback-federated-user",
                    provider_tenant="noop-test-project",
                    issued_at=now,
                    auth_time=now,
                    expires_at=now + timedelta(hours=1),
                    sign_in_provider="google.com",
                ),
            }
        ),
        managed_object_store=store,
        managed_identity_deletion_ticket_codec=ManagedIdentityDeletionTicketCodec(
            "managed-replay-secret-at-least-32-bytes"
        ),
        feedback_repository=repository,
        feedback_object_store=store,
        feedback_capability_codec=FeedbackCapabilityCodec(SECRET),
        feedback_archive_validator=feedback_archive_validator,
    )
    return TestClient(app), store, repository


def _reservation_payload(archive: bytes) -> dict[str, object]:
    return {
        "schema_version": 1,
        "platform": "ios",
        "app_version": "9.2.0",
        "archive_bytes": len(archive),
        "archive_sha256": hashlib.sha256(archive).hexdigest(),
        "includes_user_note": False,
        "includes_screenshot": False,
    }


def _headers(
    *,
    token: str = APP_CHECK_TOKEN,
    identity_token: str = IDENTITY_TOKEN,
) -> dict[str, str]:
    return {
        "X-Firebase-AppCheck": token,
        "Authorization": f"Bearer {identity_token}",
        "Idempotency-Key": str(uuid4()),
    }


def _seed_legacy_v0_report(
    repository: MemoryFeedbackRepository,
    *,
    archive: bytes,
    idempotency_key: str,
) -> FeedbackReport:
    now = datetime.now(UTC)
    report_id = uuid4()
    subject_hash = hashlib.sha256(b"feedback-test-user").hexdigest()
    payload = _reservation_payload(archive)
    idempotency_hash = hashlib.sha256(
        (f"{APPLE_APP_ID}\0{subject_hash}\0{idempotency_key.lower()}").encode("utf-8")
    ).hexdigest()
    report = FeedbackReport(
        report_id=report_id,
        client_app_id=APPLE_APP_ID,
        subject_hash=subject_hash,
        principal_hash_version=0,
        principal_hash=subject_hash,
        idempotency_hash=idempotency_hash,
        request_hash=hashlib.sha256(
            json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest(),
        platform="ios",
        app_version="9.2.0",
        archive_bytes=len(archive),
        archive_sha256=hashlib.sha256(archive).hexdigest(),
        includes_user_note=False,
        includes_screenshot=False,
        receipt=FeedbackCapabilityCodec(SECRET).receipt(
            report_id=report_id,
            app_id=APPLE_APP_ID,
        ),
        object_key=f"v1/feedback/{now:%Y/%m/%d}/{report_id}.zip",
        status="reserved",
        object_generation=None,
        created_at=now,
        upload_expires_at=now + timedelta(minutes=15),
        completed_at=None,
        retained_until=now + timedelta(days=28),
        deleted_at=None,
        cleanup_after=now + timedelta(minutes=20),
        cleanup_phase="delete_pending",
    )
    repository._reports[report_id] = report
    repository._idempotency[(APPLE_APP_ID, 0, subject_hash, idempotency_hash)] = (
        report_id
    )
    return report


def test_feedback_reserve_complete_status_and_delete_are_capability_bound() -> None:
    archive = _archive()
    client, store, _ = _client()
    headers = _headers()
    with client:
        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        reservation = reserved.json()
        assert reservation["status"] == "reserved"
        assert reservation["upload"]["method"] == "PUT"
        assert "report_token" in reservation

        replay = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert replay.status_code == 201
        assert replay.json()["report_id"] == reservation["report_id"]
        assert replay.json()["report_token"] == reservation["report_token"]

        store.payload = archive
        capability_headers = {
            "X-Firebase-AppCheck": APP_CHECK_TOKEN,
            "Authorization": f"Bearer {IDENTITY_TOKEN}",
            "X-NOOP-Feedback-Token": reservation["report_token"],
        }
        completed = client.post(
            f"/v1/feedback/reports/{reservation['report_id']}/complete",
            headers=capability_headers,
            json={},
        )
        assert completed.status_code == 200
        assert completed.json()["status"] == "sent"
        assert re.fullmatch(
            r"NF-[A-Z2-7]{16}",
            completed.json()["receipt"],
        )

        status_response = client.get(
            f"/v1/feedback/reports/{reservation['report_id']}",
            headers=capability_headers,
        )
        assert status_response.status_code == 200
        assert status_response.json() == completed.json()

        rejected = client.get(
            f"/v1/feedback/reports/{reservation['report_id']}",
            headers={
                "X-Firebase-AppCheck": OTHER_APP_CHECK_TOKEN,
                "Authorization": f"Bearer {IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": reservation["report_token"],
            },
        )
        assert rejected.status_code == 404

        deleted = client.delete(
            f"/v1/feedback/reports/{reservation['report_id']}",
            headers=capability_headers,
        )
        assert deleted.status_code == 202
        assert deleted.json()["status"] == "deleting"
        assert deleted.json()["receipt"] is None
        assert store.deleted is True


def test_feedback_cancel_succeeds_before_an_object_exists() -> None:
    archive = _archive()
    client, _, _ = _client()
    with client:
        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        reservation = reserved.json()
        capability_headers = {
            "X-Firebase-AppCheck": APP_CHECK_TOKEN,
            "Authorization": f"Bearer {IDENTITY_TOKEN}",
            "X-NOOP-Feedback-Token": reservation["report_token"],
        }

        deleted = client.delete(
            f"/v1/feedback/reports/{reservation['report_id']}",
            headers=capability_headers,
        )
        assert deleted.status_code == 202
        assert deleted.json()["status"] == "deleting"

        status_response = client.get(
            f"/v1/feedback/reports/{reservation['report_id']}",
            headers=capability_headers,
        )
        assert status_response.status_code == 200
        assert status_response.json()["status"] == "deleting"
        assert status_response.json()["receipt"] is None


def test_feedback_rejects_platform_mismatch_and_raw_archive() -> None:
    archive = _archive(raw=True)
    client, store, _ = _client()
    with client:
        mismatch = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(token=OTHER_APP_CHECK_TOKEN),
            json=_reservation_payload(archive),
        )
        assert mismatch.status_code == 403

        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        body = reserved.json()
        store.payload = archive
        completed = client.post(
            f"/v1/feedback/reports/{body['report_id']}/complete",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
            json={},
        )
        assert completed.status_code == 422
        assert completed.json() == {"detail": "feedback archive failed validation"}
        assert store.deleted is True


def test_feedback_routes_remain_absent_when_disabled() -> None:
    app = create_app(
        settings=Settings(
            api_token="test-token-abcdefghijklmnopqrstuvwxyz-0123456789",
            database_url=None,
            dashboard_enabled=False,
        ),
        repository=MemoryRepository(),
    )
    with TestClient(app) as client:
        response = client.post(
            "/v1/feedback/reports/reservations",
            json={},
        )
    assert response.status_code == 404


def test_feedback_requires_identity_and_binds_capability_to_account() -> None:
    archive = _archive()
    client, _, _ = _client()
    with client:
        missing_identity = client.post(
            "/v1/feedback/reports/reservations",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Idempotency-Key": str(uuid4()),
            },
            json=_reservation_payload(archive),
        )
        assert missing_identity.status_code == 401

        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        body = reserved.json()

        wrong_account = client.get(
            f"/v1/feedback/reports/{body['report_id']}",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {OTHER_IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
        )
        assert wrong_account.status_code == 404


@pytest.mark.parametrize(
    "identity_token",
    [
        PHONE_IDENTITY_TOKEN,
        PASSWORD_IDENTITY_TOKEN,
        FEDERATED_IDENTITY_TOKEN,
    ],
    ids=["phone", "password", "federated"],
)
def test_feedback_rejects_non_anonymous_firebase_identities(
    identity_token: str,
) -> None:
    archive = _archive()
    client, store, repository = _client()

    with client:
        response = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(identity_token=identity_token),
            json=_reservation_payload(archive),
        )

    assert response.status_code == 403
    assert response.json() == {
        "detail": "feedback requires an anonymous Firebase identity"
    }
    assert store.upload_capability_calls == 0
    assert repository._reports == {}


def test_feedback_reservation_dual_writes_legacy_and_tenant_principal_hashes() -> None:
    archive = _archive()
    client, _, repository = _client()

    with client:
        response = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )

    assert response.status_code == 201
    report = asyncio.run(
        repository.get(
            report_id=UUID(response.json()["report_id"]),
            client_app_id=APPLE_APP_ID,
        )
    )
    assert report.subject_hash == hashlib.sha256(b"feedback-test-user").hexdigest()
    assert report.principal_hash_version == 1
    assert report.principal_hash != report.subject_hash


def test_feedback_same_subject_in_another_tenant_is_isolated() -> None:
    archive = _archive()
    client, _, _ = _client(settings=replace(_settings(), feedback_daily_report_limit=1))
    shared_key = str(uuid4())
    with client:
        owner = client.post(
            "/v1/feedback/reports/reservations",
            headers={
                **_headers(identity_token=IDENTITY_TOKEN),
                "Idempotency-Key": shared_key,
            },
            json=_reservation_payload(archive),
        )
        assert owner.status_code == 201
        body = owner.json()

        cross_tenant_read = client.get(
            f"/v1/feedback/reports/{body['report_id']}",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {OTHER_TENANT_IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
        )
        assert cross_tenant_read.status_code == 404

        other_tenant = client.post(
            "/v1/feedback/reports/reservations",
            headers={
                **_headers(identity_token=OTHER_TENANT_IDENTITY_TOKEN),
                "Idempotency-Key": shared_key,
            },
            json=_reservation_payload(archive),
        )
        assert other_tenant.status_code == 201
        assert other_tenant.json()["report_id"] != body["report_id"]


def test_feedback_legacy_v0_row_fails_closed_across_tenants() -> None:
    archive = _archive()
    shared_key = str(uuid4())
    repository = MemoryFeedbackRepository()
    legacy = _seed_legacy_v0_report(
        repository,
        archive=archive,
        idempotency_key=shared_key,
    )
    client, store, _ = _client(
        settings=replace(
            _settings(),
            feedback_daily_report_limit=1,
            feedback_max_archive_bytes=len(archive),
            feedback_pending_byte_limit=len(archive),
        ),
        feedback_repository=repository,
    )
    legacy_token = FeedbackCapabilityCodec(SECRET).issue(
        report_id=legacy.report_id,
        app_id=legacy.client_app_id,
    )
    owner_headers = {
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
        "Authorization": f"Bearer {IDENTITY_TOKEN}",
        "X-NOOP-Feedback-Token": legacy_token,
    }
    cross_tenant_headers = {
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
        "Authorization": f"Bearer {OTHER_TENANT_IDENTITY_TOKEN}",
        "X-NOOP-Feedback-Token": legacy_token,
    }

    with client:
        owner_read = client.get(
            f"/v1/feedback/reports/{legacy.report_id}",
            headers=owner_headers,
        )
        cross_tenant_read = client.get(
            f"/v1/feedback/reports/{legacy.report_id}",
            headers=cross_tenant_headers,
        )
        cross_tenant_complete = client.post(
            f"/v1/feedback/reports/{legacy.report_id}/complete",
            headers=cross_tenant_headers,
            json={},
        )
        cross_tenant_delete = client.delete(
            f"/v1/feedback/reports/{legacy.report_id}",
            headers=cross_tenant_headers,
        )
        replacement = client.post(
            "/v1/feedback/reports/reservations",
            headers={
                **_headers(identity_token=OTHER_TENANT_IDENTITY_TOKEN),
                "Idempotency-Key": shared_key,
            },
            json=_reservation_payload(archive),
        )

    assert owner_read.status_code == 404
    assert cross_tenant_read.status_code == 404
    assert cross_tenant_complete.status_code == 404
    assert cross_tenant_delete.status_code == 404
    assert replacement.status_code == 201
    assert replacement.json()["report_id"] != str(legacy.report_id)
    replacement_report = asyncio.run(
        repository.get(
            report_id=UUID(replacement.json()["report_id"]),
            client_app_id=APPLE_APP_ID,
        )
    )
    assert replacement_report.principal_hash_version == 1
    assert replacement_report.principal_hash != legacy.principal_hash
    assert repository._reports[legacy.report_id].status == "reserved"
    assert store.upload_capability_calls == 1
    assert store.metadata_calls == 0
    assert store.read_calls == 0
    assert store.deleted is False


def test_feedback_daily_quota_is_durable_but_replay_is_allowed() -> None:
    archive = _archive()
    client, _, _ = _client(
        settings=replace(
            _settings(),
            feedback_daily_report_limit=1,
        )
    )
    headers = _headers()
    with client:
        first = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert first.status_code == 201

        replay = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert replay.status_code == 201
        assert replay.json()["report_id"] == first.json()["report_id"]

        exceeded = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert exceeded.status_code == 429
        assert exceeded.headers["Retry-After"] == "3600"


def test_feedback_persists_returned_capability_expiry_before_cancel() -> None:
    archive = _archive()
    capability_expiry = datetime.now(UTC) + timedelta(hours=2)
    client, store, repository = _client()
    store.capability_expires_at = capability_expiry
    with client:
        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        body = reserved.json()
        returned_expiry = datetime.fromisoformat(body["upload"]["expires_at"])
        deleted = client.delete(
            f"/v1/feedback/reports/{body['report_id']}",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
        )
        assert deleted.status_code == 202

    report = asyncio.run(
        repository.get(
            report_id=UUID(body["report_id"]),
            client_app_id=APPLE_APP_ID,
        )
    )
    assert report.upload_expires_at >= returned_expiry
    assert report.cleanup_after is not None
    assert report.cleanup_after >= returned_expiry


def test_feedback_replay_returns_deleting_when_cancellation_wins_activation() -> None:
    archive = _archive()
    repository = CancellingReplayRepository()
    client, _, _ = _client(feedback_repository=repository)
    headers = _headers()
    with client:
        first = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert first.status_code == 201
        assert first.json()["status"] == "reserved"
        assert first.json()["upload"] is not None

        replay = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )

    assert replay.status_code == 201
    assert replay.json()["status"] == "deleting"
    assert replay.json()["upload"] is None


def test_feedback_activation_conflict_never_exposes_unpersisted_capability() -> None:
    archive = _archive()
    client, _, _ = _client(feedback_repository=ConflictingActivationRepository())
    with client:
        response = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )

    assert response.status_code == 409
    assert response.json() == {
        "detail": "feedback upload capability could not be activated"
    }


def test_feedback_validation_capacity_defers_without_rejecting_upload() -> None:
    archive = _archive()
    client, store, repository = _client(
        feedback_archive_validator=UnavailableArchiveValidator()
    )
    with client:
        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        body = reserved.json()
        store.payload = archive
        response = client.post(
            f"/v1/feedback/reports/{body['report_id']}/complete",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
            json={},
        )

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "5"
    assert store.deleted is False
    assert store.metadata_calls == 0
    assert store.read_calls == 0
    report = asyncio.run(
        repository.get(
            report_id=UUID(body["report_id"]),
            client_app_id=APPLE_APP_ID,
        )
    )
    assert report.status == "reserved"


def test_feedback_capability_rotation_accepts_current_and_previous_only() -> None:
    report_id = uuid4()
    previous = "previous-feedback-capability-secret-at-least-32-bytes"
    current = "current-feedback-capability-secret-at-least-32-bytes"
    retired = "retired-feedback-capability-secret-at-least-32-bytes"
    previous_token = FeedbackCapabilityCodec(previous).issue(
        report_id=report_id,
        app_id=APPLE_APP_ID,
    )
    retired_token = FeedbackCapabilityCodec(retired).issue(
        report_id=report_id,
        app_id=APPLE_APP_ID,
    )
    rotated = FeedbackCapabilityCodec(
        current,
        previous_secrets=(previous,),
    )

    assert rotated.verify(
        previous_token,
        report_id=report_id,
        app_id=APPLE_APP_ID,
    )
    assert not rotated.verify(
        retired_token,
        report_id=report_id,
        app_id=APPLE_APP_ID,
    )


def test_feedback_capability_mixed_revisions_cross_verify_versioned_tokens() -> None:
    report_id = uuid4()
    first_key = "first-feedback-capability-secret-at-least-32-bytes"
    second_key = "second-feedback-capability-secret-at-least-32-bytes"
    old_revision = FeedbackCapabilityCodec(
        first_key,
        secret_version="v1",
        previous_secrets=(second_key,),
        previous_secret_versions=("v2",),
        write_version="v1",
    )
    new_revision = FeedbackCapabilityCodec(
        second_key,
        secret_version="v2",
        previous_secrets=(first_key,),
        previous_secret_versions=("v1",),
        write_version="v2",
    )
    old_token = old_revision.issue(report_id=report_id, app_id=APPLE_APP_ID)
    new_token = new_revision.issue(report_id=report_id, app_id=APPLE_APP_ID)
    legacy_token = FeedbackCapabilityCodec(first_key).issue(
        report_id=report_id,
        app_id=APPLE_APP_ID,
    )

    assert old_token.startswith("v1.")
    assert new_token.startswith("v2.")
    for codec in (old_revision, new_revision):
        assert codec.verify(old_token, report_id=report_id, app_id=APPLE_APP_ID)
        assert codec.verify(new_token, report_id=report_id, app_id=APPLE_APP_ID)
        assert codec.verify(legacy_token, report_id=report_id, app_id=APPLE_APP_ID)


def test_feedback_drain_mode_rejects_new_reservations_but_keeps_control() -> None:
    archive = _archive()
    active_client, store, repository = _client()
    headers = _headers()
    with active_client:
        reserved = active_client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert reserved.status_code == 201
        body = reserved.json()

    drain_client, _, _ = _client(
        settings=replace(_settings(), feedback_accepting_reservations=False),
        feedback_repository=repository,
        feedback_object_store=store,
    )
    capability_headers = {
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
        "Authorization": f"Bearer {IDENTITY_TOKEN}",
        "X-NOOP-Feedback-Token": body["report_token"],
    }
    with drain_client:
        rejected = drain_client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        current = drain_client.get(
            f"/v1/feedback/reports/{body['report_id']}",
            headers=capability_headers,
        )
        deleted = drain_client.delete(
            f"/v1/feedback/reports/{body['report_id']}",
            headers=capability_headers,
        )

    assert rejected.status_code == 503
    assert rejected.headers["Retry-After"] == "300"
    assert current.status_code == 200
    assert current.json()["status"] == "reserved"
    assert deleted.status_code == 202
    assert deleted.json()["status"] == "deleting"


def test_feedback_validation_admission_precedes_object_access() -> None:
    archive = _archive()
    validator = TrackingArchiveValidator()
    client, store, _ = _client(feedback_archive_validator=validator)
    store.read_admission_probe = lambda: validator.active
    with client:
        reserved = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(),
            json=_reservation_payload(archive),
        )
        body = reserved.json()
        store.payload = archive
        completed = client.post(
            f"/v1/feedback/reports/{body['report_id']}/complete",
            headers={
                "X-Firebase-AppCheck": APP_CHECK_TOKEN,
                "Authorization": f"Bearer {IDENTITY_TOKEN}",
                "X-NOOP-Feedback-Token": body["report_token"],
            },
            json={},
        )

    assert completed.status_code == 200
    assert validator.acquired
    assert validator.validated
    assert store.metadata_calls == 1
    assert store.read_calls == 1
    assert not validator.active


def test_feedback_app_quota_limits_anonymous_identity_churn() -> None:
    archive = _archive()
    client, _, _ = _client(
        settings=replace(
            _settings(),
            feedback_daily_report_limit=1,
            feedback_app_daily_report_limit=1,
        )
    )
    with client:
        first = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(identity_token=IDENTITY_TOKEN),
            json=_reservation_payload(archive),
        )
        second = client.post(
            "/v1/feedback/reports/reservations",
            headers=_headers(identity_token=OTHER_IDENTITY_TOKEN),
            json=_reservation_payload(archive),
        )

    assert first.status_code == 201
    assert second.status_code == 429
    assert second.headers["Retry-After"] == "3600"


def test_feedback_replay_near_retention_does_not_mint_fresh_upload() -> None:
    archive = _archive()
    client, store, repository = _client()
    headers = _headers()
    with client:
        first = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )
        assert first.status_code == 201
        report_id = UUID(first.json()["report_id"])
        report = asyncio.run(
            repository.get(report_id=report_id, client_app_id=APPLE_APP_ID)
        )
        near_retention = datetime.now(UTC) + timedelta(minutes=5)
        repository._reports[report_id] = replace(
            report,
            upload_expires_at=datetime.now(UTC) + timedelta(seconds=30),
            retained_until=near_retention,
            cleanup_after=near_retention,
        )

        replay = client.post(
            "/v1/feedback/reports/reservations",
            headers=headers,
            json=_reservation_payload(archive),
        )

    assert replay.status_code == 201
    assert replay.json()["status"] == "deleting"
    assert replay.json()["upload"] is None
    assert store.upload_capability_calls == 1
    updated = asyncio.run(
        repository.get(report_id=report_id, client_app_id=APPLE_APP_ID)
    )
    assert updated.upload_expires_at <= updated.retained_until
    assert updated.cleanup_after is not None
    assert updated.cleanup_after <= updated.retained_until
