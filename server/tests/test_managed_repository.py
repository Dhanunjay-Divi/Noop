from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.managed_identity import ManagedIdentityClaims
from app.managed_models import (
    ManagedChunkReservation,
    ManagedChunkStream,
    ManagedClientKeyRegistration,
    ManagedDocumentMutation,
    ManagedEnrollment,
    ManagedExportRequest,
    ManagedRestoreRequest,
    ManagedSourceRegistration,
)
from app.managed_object_store import ManagedObjectMetadata
from app.managed_repository import (
    ManagedConflictError,
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedQuotaExceededError,
    PostgresManagedRepository,
)
from app.repository import PostgresRepository

DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "timescaledb")
POLICY_SHA256 = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"


async def _wait_for_lock_waiters(pool, *, minimum: int) -> None:
    for _ in range(500):
        waiting = await pool.fetchval("SELECT count(*) FROM pg_locks WHERE NOT granted")
        if int(waiting) >= minimum:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"expected at least {minimum} lock waiters")


def _claims(subject: str, now: datetime) -> ManagedIdentityClaims:
    return ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-test-project",
        subject=subject,
        provider_tenant="noop-staging",
        issued_at=now,
        auth_time=now - timedelta(minutes=1),
        expires_at=now + timedelta(hours=1),
    )


def _enrollment(
    installation_id: str,
    request_id,
    *,
    installation_token: str | None = None,
) -> ManagedEnrollment:
    return ManagedEnrollment(
        installation_id=installation_id,
        platform="ios",
        installation_token=(installation_token or _installation_token(installation_id)),
        enrollment_request_id=request_id,
        policy_version="synthetic-v1",
        policy_sha256=POLICY_SHA256,
        data_classes=[
            "essential_timeseries",
            "encrypted_backup",
            "user_documents",
        ],
    )


def _installation_token(installation_id: str) -> str:
    encoded = (
        base64.urlsafe_b64encode(
            hashlib.sha256(installation_id.encode("utf-8")).digest()
        )
        .decode("ascii")
        .rstrip("=")
    )
    return f"noopm_{encoded}"


def _installation_token_hash(installation_id: str) -> str:
    return hashlib.sha256(
        _installation_token(installation_id).encode("ascii")
    ).hexdigest()


def _managed(primary: PostgresRepository) -> PostgresManagedRepository:
    return PostgresManagedRepository(
        primary,
        home_region="asia-south1",
        residency_policy_version="synthetic-v1",
        default_plan_code="noop_plus_staging",
        default_plan_revision=1,
        consent_policy_kind="managed_storage",
        entitlement_mode="open_beta",
        replay_secret="test-managed-replay-secret-at-least-32-bytes",
    )


def _essential_streams(
    *,
    event_at: datetime,
    heart_rate_samples: int,
) -> list[ManagedChunkStream]:
    streams = [
        "heart_rate",
        "rr_intervals",
        "battery",
        "derived_heart_rate",
        "device_events",
        "step_counter",
        "body_measurement",
    ]
    return [
        ManagedChunkStream(
            stream_key=stream,
            sample_count=(heart_rate_samples if stream == "heart_rate" else 0),
            first_event_at=(
                event_at if stream == "heart_rate" and heart_rate_samples > 0 else None
            ),
            last_event_at=(
                event_at if stream == "heart_rate" and heart_rate_samples > 0 else None
            ),
            encoded_bytes=0,
            schema_revision=1,
        )
        for stream in streams
    ]


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_control_retention_accepts_timestamp_parameters() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        counts = await _managed(primary).purge_expired_control_rows(
            now=datetime.now(UTC),
            batch_size=10,
        )
        assert {
            "access_grants",
            "upload_grants",
            "processing_attempts",
            "usage_ledger",
            "audit_events",
            "replay_tombstones",
            "daily_ingest_usage",
            "chunk_manifests",
        }.issubset(counts)
    finally:
        await primary.shutdown()


def test_server_readable_reservation_accepts_only_deployed_wire_format() -> None:
    now = datetime.now(UTC)
    common = {
        "chunk_id": uuid4(),
        "request_id": uuid4(),
        "source_id": uuid4(),
        "data_class": "essential_timeseries",
        "schema_version": 1,
        "content_mode": "server_readable",
        "event_start": now - timedelta(minutes=5),
        "event_end": now,
        "expected_sha256": "a" * 64,
        "expected_compressed_bytes": 100,
        "expected_uncompressed_bytes": 200,
        "streams": [],
    }
    with pytest.raises(ValueError, match="enabled JSON/gzip wire format"):
        ManagedChunkReservation(
            **common,
            compression="zstd",
            content_type="application/vnd.noop.chunk+json",
        )
    with pytest.raises(ValueError, match="enabled JSON/gzip wire format"):
        ManagedChunkReservation(
            **common,
            compression="gzip",
            content_type="application/vnd.noop.chunk+cbor",
        )

    encrypted = ManagedChunkReservation(
        **{
            **common,
            "content_mode": "client_encrypted",
            "client_key_id": uuid4(),
        },
        compression="zstd",
        content_type="application/vnd.noop.backup",
    )
    assert encrypted.content_mode == "client_encrypted"


EXPECTED_ACTIVE_STREAMS = {
    "essential_timeseries": {
        "battery",
        "body_measurement",
        "derived_heart_rate",
        "device_events",
        "heart_rate",
        "rr_intervals",
        "step_counter",
    },
    "raw_auxiliary": {
        "respiration_adc",
        "skin_temperature_adc",
        "sleep_state",
    },
    "raw_ppg": {
        "ppg_waveform",
        "spo2_optical_adc",
    },
    "raw_motion": {
        "gravity",
        "raw_imu",
    },
    "derived_summaries": {
        "daily_metrics",
        "live_session",
        "metric_series",
        "sleep_summary",
        "workout_summary",
    },
}


async def _publish_test_chunk(
    repository: PostgresManagedRepository,
    *,
    principal,
    installation_id: str,
    reservation: ManagedChunkReservation,
    generation: int,
    sample_count: int,
) -> tuple[dict, datetime]:
    reserved = await repository.reserve_chunk(
        principal=principal,
        installation_id=installation_id,
        reservation=reservation,
    )
    await repository.complete_chunk_upload(
        principal=principal,
        installation_id=installation_id,
        chunk_id=reservation.chunk_id,
        metadata=ManagedObjectMetadata(
            object_key=reserved["object_key"],
            generation=generation,
            metageneration=1,
            crc32c="AAAAAA==",
            size=reservation.expected_compressed_bytes,
            content_type=reservation.content_type,
            metadata={"noop-sha256": reservation.expected_sha256},
        ),
    )
    validated_at = await repository.coordination_now()
    available = await repository.mark_chunk_validated(
        account_id=principal.account_id,
        chunk_id=reservation.chunk_id,
        verified_sha256=reservation.expected_sha256,
        uncompressed_bytes=reservation.expected_uncompressed_bytes,
        sample_count=sample_count,
        now=validated_at,
    )
    return available, validated_at


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_managed_repository_enrollment_chunk_retry_and_tenant_isolation() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        first_claims = _claims(f"first-{uuid4()}", now)
        second_claims = _claims(f"second-{uuid4()}", now)
        first_installation = str(uuid4())
        second_installation = str(uuid4())
        first_request = uuid4()

        with pytest.raises(ManagedNotFoundError):
            await repository.principal_for_identity(first_claims)

        enrolled = await repository.enroll(
            claims=first_claims,
            enrollment=_enrollment(first_installation, first_request),
        )
        repeated = await repository.enroll(
            claims=first_claims,
            enrollment=_enrollment(first_installation, first_request),
        )
        with pytest.raises(ManagedForbiddenError):
            await repository.enroll(
                claims=first_claims,
                enrollment=_enrollment(
                    first_installation,
                    first_request,
                    installation_token="noopm_" + ("z" * 43),
                ),
            )
        assert enrolled["created"] is True
        assert repeated["created"] is False
        assert enrolled["entitlements"]["feature_restrictions"] == []

        first_principal = await repository.principal_for_identity(first_claims)
        ensured = await repository.ensure_installation(
            principal=first_principal,
            installation_id=first_installation,
            installation_token_hash=_installation_token_hash(first_installation),
        )
        assert ensured["installation_id"] == first_installation
        with pytest.raises(ManagedForbiddenError):
            await repository.ensure_installation(
                principal=first_principal,
                installation_id=first_installation,
                installation_token_hash="0" * 64,
            )
        source_id = uuid4()
        await repository.register_source(
            principal=first_principal,
            installation_id=first_installation,
            registration=ManagedSourceRegistration(
                source_id=source_id,
                source_kind="band",
                platform="ios",
                logical_source_hash="b" * 64,
            ),
        )

        chunk_id = uuid4()
        chunk_request = uuid4()
        reservation = ManagedChunkReservation(
            chunk_id=chunk_id,
            request_id=chunk_request,
            source_id=source_id,
            data_class="essential_timeseries",
            schema_version=1,
            content_mode="server_readable",
            event_start=now - timedelta(hours=1),
            event_end=now,
            compression="gzip",
            content_type="application/vnd.noop.chunk+json",
            expected_sha256="c" * 64,
            expected_compressed_bytes=4096,
            expected_uncompressed_bytes=16_384,
            streams=[
                ManagedChunkStream(
                    stream_key="heart_rate",
                    sample_count=120,
                    first_event_at=now - timedelta(hours=1),
                    last_event_at=now,
                    encoded_bytes=2048,
                    schema_revision=1,
                )
            ],
        )
        reserved = await repository.reserve_chunk(
            principal=first_principal,
            installation_id=first_installation,
            reservation=reservation,
        )
        duplicate = await repository.reserve_chunk(
            principal=first_principal,
            installation_id=first_installation,
            reservation=reservation,
        )
        assert reserved["duplicate"] is False
        assert duplicate["duplicate"] is True
        assert reserved["object_key"].startswith("v1/")
        assert "essential_timeseries" not in reserved["object_key"]

        changed_retry = reservation.model_copy(
            update={"expected_compressed_bytes": 4097}
        )
        with pytest.raises(ManagedConflictError):
            await repository.reserve_chunk(
                principal=first_principal,
                installation_id=first_installation,
                reservation=changed_retry,
            )

        metadata = ManagedObjectMetadata(
            object_key=reserved["object_key"],
            generation=11,
            metageneration=1,
            crc32c="AAAAAA==",
            size=4096,
            content_type="application/vnd.noop.chunk+json",
            metadata={"noop-sha256": "c" * 64},
        )
        uploaded = await repository.complete_chunk_upload(
            principal=first_principal,
            installation_id=first_installation,
            chunk_id=chunk_id,
            metadata=metadata,
        )
        assert uploaded["state"] == "uploaded"
        reconciliation_candidates = (
            await repository.processing_reconciliation_candidates(
                now=(await repository.coordination_now()) + timedelta(minutes=3),
                batch_size=10,
            )
        )
        assert [
            (row["chunk_id"], row["object_generation"])
            for row in reconciliation_candidates
        ] == [(chunk_id, 11)]
        processing_now = await repository.coordination_now()
        processing = await repository.lease_chunk_processing(
            object_key=reserved["object_key"],
            processor_revision="managed-json-v1",
            queue_event_hash="e" * 64,
            lease_token_hash="f" * 64,
            now=processing_now,
            lease_seconds=300,
        )
        assert processing is not None
        assert isinstance(processing["streams"][0]["value_schema"], dict)
        assert processing["streams"][0]["value_schema"]["encoding"] == "tabular_v1"
        await repository.finish_chunk_processing(
            processing_attempt_id=processing["processing_attempt_id"],
            lease_token_hash="f" * 64,
            now=processing_now + timedelta(seconds=1),
            succeeded=True,
            verified_sha256="c" * 64,
            decompressed_bytes=16_384,
            decoded_samples=120,
        )
        available = await repository.available_chunk(
            principal=first_principal,
            chunk_id=chunk_id,
        )
        assert available["state"] == "available"

        changes = await repository.list_changes(
            principal=first_principal,
            after_sequence=0,
            limit=10,
        )
        assert changes["minimum_sequence"] == 1
        assert changes["high_watermark"] == 1
        assert changes["next_sequence"] == 1
        assert changes["has_more"] is False
        assert changes["changes"][0]["operation"] == "available"
        assert changes["changes"][0]["resource_id"] == str(chunk_id)
        assert changes["changes"][0]["chunk"]["state"] == "available"

        late_chunk_id = uuid4()
        late_reservation = reservation.model_copy(
            update={
                "chunk_id": late_chunk_id,
                "request_id": uuid4(),
                "event_start": now - timedelta(days=2, hours=1),
                "event_end": now - timedelta(days=2),
                "expected_sha256": "d" * 64,
            }
        )
        late_reserved = await repository.reserve_chunk(
            principal=first_principal,
            installation_id=first_installation,
            reservation=late_reservation,
        )
        late_metadata = ManagedObjectMetadata(
            object_key=late_reserved["object_key"],
            generation=12,
            metageneration=1,
            crc32c="BBBBBB==",
            size=4096,
            content_type="application/vnd.noop.chunk+json",
            metadata={"noop-sha256": "d" * 64},
        )
        await repository.complete_chunk_upload(
            principal=first_principal,
            installation_id=first_installation,
            chunk_id=late_chunk_id,
            metadata=late_metadata,
        )
        await repository.mark_chunk_validated(
            account_id=first_principal.account_id,
            chunk_id=late_chunk_id,
            verified_sha256="d" * 64,
            uncompressed_bytes=16_384,
            sample_count=120,
            now=now + timedelta(minutes=2),
        )
        late_changes = await repository.list_changes(
            principal=first_principal,
            after_sequence=1,
            limit=10,
        )
        assert late_changes["high_watermark"] == 2
        assert [change["resource_id"] for change in late_changes["changes"]] == [
            str(late_chunk_id)
        ]

        document_id = uuid4()
        document_request = ManagedDocumentMutation(
            request_id=uuid4(),
            document_kind="journal",
            document_id=document_id,
            base_revision=0,
            content_mode="server_readable",
            payload_json={
                "prompt": "How did today feel?",
                "answer": "Steady",
            },
            updated_at=now,
        )
        document = await repository.put_document(
            principal=first_principal,
            installation_id=first_installation,
            mutation=document_request,
        )
        duplicate_document = await repository.put_document(
            principal=first_principal,
            installation_id=first_installation,
            mutation=document_request,
        )
        assert document["revision"] == 1
        assert document["duplicate"] is False
        assert duplicate_document["duplicate"] is True
        assert (
            await repository.get_document(
                principal=first_principal,
                document_kind="journal",
                document_id=document_id,
            )
        )["payload_json"]["answer"] == "Steady"
        listed_documents = await repository.list_documents(
            principal=first_principal,
            document_kind="journal",
            include_deleted=False,
            after_updated_at=None,
            after_document_kind=None,
            after_document_id=None,
            snapshot_at=None,
            limit=10,
        )
        assert [row["document_id"] for row in listed_documents] == [str(document_id)]
        with pytest.raises(ManagedConflictError):
            await repository.put_document(
                principal=first_principal,
                installation_id=first_installation,
                mutation=document_request.model_copy(
                    update={
                        "request_id": uuid4(),
                        "payload_json": {"answer": "Changed without revision"},
                    }
                ),
            )

        restore_now = await repository.coordination_now()
        restore = await repository.create_restore(
            principal=first_principal,
            installation_id=first_installation,
            request=ManagedRestoreRequest(
                request_id=uuid4(),
                snapshot_at=restore_now,
                data_classes=[],
                document_kinds=["journal"],
            ),
        )
        assert restore["status"] == "running"
        assert restore["selected_objects"] >= 1
        assert restore["change_sequence"] == 3
        chunks_only_restore = await repository.create_restore(
            principal=first_principal,
            installation_id=first_installation,
            request=ManagedRestoreRequest(
                request_id=uuid4(),
                snapshot_at=restore_now,
                data_classes=[],
                document_kinds=[],
                include_documents=False,
            ),
        )
        assert chunks_only_restore["selected_objects"] == (
            restore["selected_objects"] - 1
        )
        assert chunks_only_restore["selected_bytes"] == restore["selected_bytes"]
        completed_restore = await repository.complete_restore(
            principal=first_principal,
            installation_id=first_installation,
            restore_job_id=UUID(restore["restore_job_id"]),
            delivered_objects=restore["selected_objects"],
            delivered_bytes=restore["selected_bytes"],
        )
        assert completed_restore["status"] == "completed"
        duplicate_completed_restore = await repository.complete_restore(
            principal=first_principal,
            installation_id=first_installation,
            restore_job_id=UUID(restore["restore_job_id"]),
            delivered_objects=restore["selected_objects"],
            delivered_bytes=restore["selected_bytes"],
        )
        assert duplicate_completed_restore["status"] == "completed"
        assert duplicate_completed_restore["duplicate"] is True

        key_id = uuid4()
        await repository.register_client_key(
            principal=first_principal,
            installation_id=first_installation,
            registration=ManagedClientKeyRegistration(
                client_key_id=key_id,
                purpose="recovery",
                algorithm="X25519-AESGCM",
                public_key_base64=None,
                key_fingerprint="e" * 64,
                recovery_method="recovery_key",
                hardware_backed=True,
            ),
        )
        export = await repository.create_export(
            principal=first_principal,
            installation_id=first_installation,
            request=ManagedExportRequest(
                request_id=uuid4(),
                format="noopbak",
                content_mode="client_encrypted",
                client_key_id=key_id,
                scope={"all": True},
                expected_sha256="f" * 64,
                expected_bytes=4096,
                content_type="application/vnd.noop.backup",
            ),
        )
        completed_export = await repository.complete_export(
            principal=first_principal,
            installation_id=first_installation,
            export_job_id=UUID(export["export_job_id"]),
            metadata=ManagedObjectMetadata(
                object_key=export["object_key"],
                generation=71,
                metageneration=1,
                crc32c="CCCCCC==",
                size=4096,
                content_type="application/vnd.noop.backup",
                metadata={"noop-sha256": "f" * 64},
            ),
        )
        assert completed_export["status"] == "completed"

        document_changes = await repository.list_changes(
            principal=first_principal,
            after_sequence=2,
            limit=10,
        )
        assert document_changes["changes"][0]["resource_kind"] == "document"
        assert document_changes["changes"][0]["document"]["document_kind"] == "journal"

        listed = await repository.list_available_chunks(
            principal=first_principal,
            start=now - timedelta(days=1),
            end=now + timedelta(days=1),
            data_class="essential_timeseries",
            after_event_start=None,
            after_chunk_id=None,
            limit=10,
        )
        assert [row["chunk_id"] for row in listed] == [str(chunk_id)]

        await repository.enroll(
            claims=second_claims,
            enrollment=_enrollment(second_installation, uuid4()),
        )
        second_principal = await repository.principal_for_identity(second_claims)
        with pytest.raises(ManagedNotFoundError):
            await repository.available_chunk(
                principal=second_principal,
                chunk_id=chunk_id,
            )
        with pytest.raises(ManagedForbiddenError):
            await repository.ensure_installation(
                principal=second_principal,
                installation_id=second_installation,
                installation_token_hash=_installation_token_hash(first_installation),
            )
        revoked_installation = str(uuid4())
        await repository.enroll(
            claims=first_claims,
            enrollment=_enrollment(revoked_installation, uuid4()),
        )
        await repository.revoke_installation(
            principal=first_principal,
            requesting_installation_id=first_installation,
            installation_id=revoked_installation,
        )
        with pytest.raises(ManagedForbiddenError):
            await repository.ensure_installation(
                principal=first_principal,
                installation_id=revoked_installation,
                installation_token_hash=_installation_token_hash(revoked_installation),
            )

        oversized = reservation.model_copy(
            update={
                "chunk_id": uuid4(),
                "request_id": uuid4(),
                "expected_compressed_bytes": 16_777_217,
                "expected_uncompressed_bytes": 16_777_217,
            }
        )
        with pytest.raises(ManagedQuotaExceededError):
            await repository.reserve_chunk(
                principal=first_principal,
                installation_id=first_installation,
                reservation=oversized,
            )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_account_erasure_blocks_reenrollment_until_identity_is_deleted() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"erasure-{uuid4()}", now)
        installation_id = str(uuid4())
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id, uuid4()),
        )
        principal = await repository.principal_for_identity(claims)
        request_id = uuid4()
        ticket = b"t" * 64

        requested = await repository.request_erasure(
            principal=principal,
            request_id=request_id,
            scope="account",
            confirmation_sha256="a" * 64,
            identity_deletion_ticket=ticket,
            cooling_off=timedelta(0),
        )
        erasure_job_id = UUID(requested["erasure_job_id"])
        lifecycle_now = await repository.coordination_now()
        await repository.claim_erasure_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        completed = await repository.finalize_erasure_jobs(
            now=lifecycle_now,
            batch_size=10,
        )

        assert completed == []
        with pytest.raises(ManagedForbiddenError):
            await repository.principal_for_identity(claims)
        with pytest.raises(ManagedForbiddenError):
            await repository.enroll(
                claims=claims,
                enrollment=_enrollment(str(uuid4()), uuid4()),
            )

        pending = await repository.pending_identity_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert len(pending) == 1
        assert bytes(pending[0]["identity_deletion_ticket"]) == ticket
        assert pending[0]["request_id"] == request_id

        await repository.mark_identity_deletion_failed(
            account_id=principal.account_id,
            erasure_job_id=erasure_job_id,
            error_detail_sha256="b" * 64,
            now=lifecycle_now,
        )
        retry = await repository.pending_identity_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert [row["erasure_job_id"] for row in retry] == [erasure_job_id]

        finished = await repository.mark_identity_deletion_succeeded(
            account_id=principal.account_id,
            erasure_job_id=erasure_job_id,
            now=lifecycle_now,
        )
        assert finished["status"] == "completed"
        assert finished["identity_deletion_ticket"] is None
        pool = primary._require_pool()
        assert (
            await pool.fetchval(
                """
                SELECT count(*)
                FROM managed_external_identities
                WHERE account_id = $1
                """,
                principal.account_id,
            )
            == 0
        )
        assert (
            await pool.fetchval(
                """
                SELECT status
                FROM managed_erasure_targets
                WHERE erasure_job_id = $1
                  AND target_kind = 'identity'
                  AND target_partition = 'firebase_auth'
                """,
                erasure_job_id,
            )
            == "completed"
        )
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_authoritative_empty_snapshot_supersedes_exact_window() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        active_rows = await primary._require_pool().fetch(
            """
            SELECT mapping.data_class, mapping.stream_key
            FROM managed_chunk_schema_streams mapping
            JOIN managed_stream_schemas stream
              ON stream.data_class = mapping.data_class
             AND stream.stream_key = mapping.stream_key
             AND stream.schema_revision = mapping.stream_schema_revision
            WHERE mapping.chunk_schema_version = 1
              AND stream.status = 'active'
            ORDER BY mapping.data_class, mapping.stream_key
            """
        )
        actual_active_streams: dict[str, set[str]] = {}
        for row in active_rows:
            actual_active_streams.setdefault(str(row["data_class"]), set()).add(
                str(row["stream_key"])
            )
        assert actual_active_streams == EXPECTED_ACTIVE_STREAMS

        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"snapshot-{uuid4()}", now)
        installation_id = str(uuid4())
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id, uuid4()),
        )
        principal = await repository.principal_for_identity(claims)
        source_id = uuid4()
        await repository.register_source(
            principal=principal,
            installation_id=installation_id,
            registration=ManagedSourceRegistration(
                source_id=source_id,
                source_kind="band",
                platform="ios",
                logical_source_hash="9" * 64,
            ),
        )

        event_start = now - timedelta(hours=2)
        event_end = event_start + timedelta(hours=1)

        def reservation(
            *,
            chunk_id: UUID,
            digest: str,
            streams: list[ManagedChunkStream],
        ) -> ManagedChunkReservation:
            return ManagedChunkReservation(
                chunk_id=chunk_id,
                request_id=uuid4(),
                source_id=source_id,
                data_class="essential_timeseries",
                schema_version=1,
                content_mode="server_readable",
                event_start=event_start,
                event_end=event_end,
                compression="gzip",
                content_type="application/vnd.noop.chunk+json",
                expected_sha256=digest,
                expected_compressed_bytes=4096,
                expected_uncompressed_bytes=16_384,
                streams=streams,
            )

        partial_id = uuid4()
        partial, _ = await _publish_test_chunk(
            repository,
            principal=principal,
            installation_id=installation_id,
            reservation=reservation(
                chunk_id=partial_id,
                digest="1" * 64,
                streams=[
                    ManagedChunkStream(
                        stream_key="heart_rate",
                        sample_count=1,
                        first_event_at=event_start,
                        last_event_at=event_start,
                        encoded_bytes=0,
                        schema_revision=1,
                    )
                ],
            ),
            generation=101,
            sample_count=1,
        )
        assert partial["authoritative_snapshot"] is False

        full_id = uuid4()
        full, full_snapshot_at = await _publish_test_chunk(
            repository,
            principal=principal,
            installation_id=installation_id,
            reservation=reservation(
                chunk_id=full_id,
                digest="2" * 64,
                streams=_essential_streams(
                    event_at=event_start,
                    heart_rate_samples=1,
                ),
            ),
            generation=102,
            sample_count=1,
        )
        assert full["authoritative_snapshot"] is True

        empty_id = uuid4()
        empty, empty_snapshot_at = await _publish_test_chunk(
            repository,
            principal=principal,
            installation_id=installation_id,
            reservation=reservation(
                chunk_id=empty_id,
                digest="3" * 64,
                streams=_essential_streams(
                    event_at=event_start,
                    heart_rate_samples=0,
                ),
            ),
            generation=103,
            sample_count=0,
        )
        assert empty["authoritative_snapshot"] is True

        current = await repository.list_available_chunks(
            principal=principal,
            start=event_start,
            end=event_end + timedelta(seconds=1),
            data_class="essential_timeseries",
            after_event_start=None,
            after_chunk_id=None,
            limit=10,
        )
        assert [chunk["chunk_id"] for chunk in current] == [str(empty_id)]
        at_full_snapshot = await repository.list_available_chunks(
            principal=principal,
            start=event_start,
            end=event_end + timedelta(seconds=1),
            data_class="essential_timeseries",
            after_event_start=None,
            after_chunk_id=None,
            limit=10,
            snapshot_at=full_snapshot_at,
        )
        assert [chunk["chunk_id"] for chunk in at_full_snapshot] == [str(full_id)]

        rows = await primary._require_pool().fetch(
            """
            SELECT chunk_id, superseded_by_chunk_id
            FROM managed_chunks
            WHERE account_id = $1 AND chunk_id = ANY($2::uuid[])
            """,
            principal.account_id,
            [partial_id, full_id, empty_id],
        )
        superseded = {row["chunk_id"]: row["superseded_by_chunk_id"] for row in rows}
        assert superseded == {
            partial_id: full_id,
            full_id: empty_id,
            empty_id: None,
        }

        full_restore = await repository.create_restore(
            principal=principal,
            installation_id=installation_id,
            request=ManagedRestoreRequest(
                request_id=uuid4(),
                snapshot_at=full_snapshot_at,
                data_classes=["essential_timeseries"],
                document_kinds=[],
            ),
        )
        empty_restore = await repository.create_restore(
            principal=principal,
            installation_id=installation_id,
            request=ManagedRestoreRequest(
                request_id=uuid4(),
                snapshot_at=empty_snapshot_at,
                data_classes=["essential_timeseries"],
                document_kinds=[],
            ),
        )
        assert full_restore["selected_objects"] == 1
        assert empty_restore["selected_objects"] == 1

        changes = await repository.list_changes(
            principal=principal,
            after_sequence=0,
            limit=10,
        )
        assert [change["resource_id"] for change in changes["changes"]] == [
            str(partial_id),
            str(full_id),
            str(empty_id),
        ]
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_restore_anchor_cannot_skip_concurrent_chunk_publication() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=4,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        installation_id = str(uuid4())
        claims = _claims(f"restore-race-{uuid4()}", now)
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id, uuid4()),
        )
        principal = await repository.principal_for_identity(claims)
        source_id = uuid4()
        await repository.register_source(
            principal=principal,
            installation_id=installation_id,
            registration=ManagedSourceRegistration(
                source_id=source_id,
                source_kind="band",
                platform="ios",
                logical_source_hash="b" * 64,
            ),
        )
        chunk_id = uuid4()
        reservation = ManagedChunkReservation(
            chunk_id=chunk_id,
            request_id=uuid4(),
            source_id=source_id,
            data_class="essential_timeseries",
            schema_version=1,
            content_mode="server_readable",
            event_start=now - timedelta(hours=1),
            event_end=now,
            compression="gzip",
            content_type="application/vnd.noop.chunk+json",
            expected_sha256="c" * 64,
            expected_compressed_bytes=4_096,
            expected_uncompressed_bytes=16_384,
            streams=_essential_streams(
                event_at=now,
                heart_rate_samples=1,
            ),
        )
        reserved = await repository.reserve_chunk(
            principal=principal,
            installation_id=installation_id,
            reservation=reservation,
        )
        await repository.complete_chunk_upload(
            principal=principal,
            installation_id=installation_id,
            chunk_id=chunk_id,
            metadata=ManagedObjectMetadata(
                object_key=reserved["object_key"],
                generation=1,
                metageneration=1,
                crc32c="AAAAAA==",
                size=4_096,
                content_type="application/vnd.noop.chunk+json",
                metadata={"noop-sha256": "c" * 64},
            ),
        )

        pool = primary._require_pool()
        async with pool.acquire() as blocker:
            transaction = blocker.transaction()
            await transaction.start()
            try:
                await blocker.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-change:{principal.account_id}",
                )
                publish_task = asyncio.create_task(
                    repository.mark_chunk_validated(
                        account_id=principal.account_id,
                        chunk_id=chunk_id,
                        verified_sha256="c" * 64,
                        uncompressed_bytes=16_384,
                        sample_count=1,
                        now=await repository.coordination_now(),
                    )
                )
                await _wait_for_lock_waiters(pool, minimum=1)
                restore_task = asyncio.create_task(
                    repository.create_restore(
                        principal=principal,
                        installation_id=installation_id,
                        request=ManagedRestoreRequest(
                            request_id=uuid4(),
                            data_classes=["essential_timeseries"],
                            document_kinds=[],
                            include_documents=False,
                        ),
                    )
                )
                await _wait_for_lock_waiters(pool, minimum=2)
                assert publish_task.done() is False
                assert restore_task.done() is False
            finally:
                await transaction.commit()

        await asyncio.wait_for(publish_task, timeout=5)
        restore = await asyncio.wait_for(restore_task, timeout=5)
        snapshot_chunks = await repository.list_available_chunks(
            principal=principal,
            start=None,
            end=None,
            data_class="essential_timeseries",
            after_event_start=None,
            after_chunk_id=None,
            limit=10,
            snapshot_at=restore["snapshot_at"],
        )
        following_changes = await repository.list_changes(
            principal=principal,
            after_sequence=restore["change_sequence"],
            limit=10,
        )
        visible_ids = {row["chunk_id"] for row in snapshot_chunks} | {
            change["resource_id"] for change in following_changes["changes"]
        }
        assert str(chunk_id) in visible_ids
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_active_restore_defers_retention_until_snapshot_completes() -> None:
    primary = PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=2,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )
    await primary.startup()
    try:
        repository = _managed(primary)
        now = datetime.now(UTC)
        claims = _claims(f"restore-retention-{uuid4()}", now)
        installation_id = str(uuid4())
        await repository.enroll(
            claims=claims,
            enrollment=_enrollment(installation_id, uuid4()),
        )
        principal = await repository.principal_for_identity(claims)
        source_id = uuid4()
        await repository.register_source(
            principal=principal,
            installation_id=installation_id,
            registration=ManagedSourceRegistration(
                source_id=source_id,
                source_kind="band",
                platform="ios",
                logical_source_hash="7" * 64,
            ),
        )
        chunk_id = uuid4()
        event_end = now - timedelta(days=30) + timedelta(hours=1)
        reservation = ManagedChunkReservation(
            chunk_id=chunk_id,
            request_id=uuid4(),
            source_id=source_id,
            data_class="essential_timeseries",
            schema_version=1,
            content_mode="server_readable",
            event_start=event_end - timedelta(hours=1),
            event_end=event_end,
            compression="gzip",
            content_type="application/vnd.noop.chunk+json",
            expected_sha256="8" * 64,
            expected_compressed_bytes=4_096,
            expected_uncompressed_bytes=16_384,
            streams=_essential_streams(
                event_at=event_end,
                heart_rate_samples=1,
            ),
        )
        await _publish_test_chunk(
            repository,
            principal=principal,
            installation_id=installation_id,
            reservation=reservation,
            generation=201,
            sample_count=1,
        )
        lifecycle_now = await repository.coordination_now() + timedelta(hours=2)
        restore = await repository.create_restore(
            principal=principal,
            installation_id=installation_id,
            request=ManagedRestoreRequest(
                request_id=uuid4(),
                data_classes=["essential_timeseries"],
                document_kinds=[],
                include_documents=False,
            ),
        )
        assert restore["selected_objects"] == 1

        protected = await repository.claim_retention_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert protected == []
        assert (
            await primary._require_pool().fetchval(
                """
                SELECT state
                FROM managed_chunks
                WHERE account_id = $1 AND chunk_id = $2
                """,
                principal.account_id,
                chunk_id,
            )
            == "available"
        )

        await repository.complete_restore(
            principal=principal,
            installation_id=installation_id,
            restore_job_id=UUID(restore["restore_job_id"]),
            delivered_objects=restore["selected_objects"],
            delivered_bytes=restore["selected_bytes"],
        )
        released = await repository.claim_retention_deletions(
            now=lifecycle_now,
            batch_size=10,
        )
        assert [row["chunk_id"] for row in released] == [chunk_id]
    finally:
        await primary.shutdown()
