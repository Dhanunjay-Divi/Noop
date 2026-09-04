from __future__ import annotations

import gzip
import hashlib
import json
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.managed_processing import (
    ManagedChunkProcessor,
    ManagedChunkProcessingError,
    decode_server_readable_chunk,
)
from app.managed_object_store import (
    ManagedObjectMetadata,
    ManagedObjectStoreError,
)


def _fixture() -> tuple[dict, dict]:
    start = datetime(2026, 9, 3, 12, tzinfo=UTC)
    end = start + timedelta(minutes=1)
    chunk_id = uuid4()
    source_id = uuid4()
    body = {
        "chunk_id": str(chunk_id),
        "source_id": str(source_id),
        "data_class": "essential_timeseries",
        "schema_version": 1,
        "event_start_ms": round(start.timestamp() * 1000),
        "event_end_ms": round(end.timestamp() * 1000),
        "streams": [
            {
                "stream_key": "heart_rate",
                "schema_revision": 1,
                "columns": [
                    "event_at_ms",
                    "bpm",
                    "quality",
                    "provenance",
                ],
                "rows": [
                    [
                        round(start.timestamp() * 1000),
                        68.0,
                        0.98,
                        "sensor",
                    ],
                    [
                        round(end.timestamp() * 1000),
                        72.0,
                        0.97,
                        "sensor",
                    ],
                ],
            }
        ],
    }
    contract = {
        "chunk_id": chunk_id,
        "source_id": source_id,
        "data_class": "essential_timeseries",
        "schema_version": 1,
        "event_start": start,
        "event_end": end,
        "declared_streams": [
            {
                "stream_key": "heart_rate",
                "sample_count": 2,
                "first_event_at": start,
                "last_event_at": end,
                "encoded_bytes": 64,
                "schema_revision": 1,
                "value_schema": {
                    "encoding": "tabular_v1",
                    "timestamp_column": "event_at_ms",
                    "columns": [
                        {"name": "event_at_ms", "type": "integer"},
                        {
                            "name": "bpm",
                            "type": "number",
                            "minimum": 20,
                            "maximum": 260,
                        },
                        {
                            "name": "quality",
                            "type": "number",
                            "nullable": True,
                            "minimum": 0,
                            "maximum": 1,
                        },
                        {
                            "name": "provenance",
                            "type": "string",
                            "max_length": 64,
                        },
                    ],
                },
            }
        ],
    }
    return body, contract


def _encode(body: dict) -> bytes:
    return json.dumps(
        body,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def test_json_gzip_chunk_is_bounded_and_manifest_bound() -> None:
    body, contract = _fixture()
    payload = _encode(body)

    decoded = decode_server_readable_chunk(
        compressed=gzip.compress(payload),
        compression="gzip",
        content_type="application/vnd.noop.chunk+json",
        expected_uncompressed_bytes=len(payload),
        **contract,
    )

    assert decoded.uncompressed_bytes == len(payload)
    assert decoded.sample_count == 2


def test_empty_stream_snapshot_is_manifest_bound() -> None:
    body, contract = _fixture()
    body["streams"][0]["rows"] = []
    contract["declared_streams"][0].update(
        {
            "sample_count": 0,
            "first_event_at": None,
            "last_event_at": None,
        }
    )
    payload = _encode(body)

    decoded = decode_server_readable_chunk(
        compressed=payload,
        compression="none",
        content_type="application/vnd.noop.chunk+json",
        expected_uncompressed_bytes=len(payload),
        **contract,
    )

    assert decoded.sample_count == 0


def test_chunk_rejects_uncompressed_size_mismatch_before_json_parse() -> None:
    body, contract = _fixture()
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=gzip.compress(payload),
            compression="gzip",
            content_type="application/vnd.noop.chunk+json",
            expected_uncompressed_bytes=len(payload) - 1,
            **contract,
        )

    assert failure.value.code == "uncompressed_size_mismatch"


def test_chunk_rejects_payload_stream_not_declared_by_manifest() -> None:
    body, contract = _fixture()
    body["streams"][0]["stream_key"] = "raw_ppg"
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=payload,
            compression="none",
            content_type="application/vnd.noop.chunk+json",
            expected_uncompressed_bytes=len(payload),
            **contract,
        )

    assert failure.value.code == "manifest_mismatch"


def test_chunk_rejects_sample_time_outside_reserved_window() -> None:
    body, contract = _fixture()
    body["streams"][0]["rows"][1][0] = body["event_end_ms"] + 1
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=payload,
            compression="none",
            content_type="application/vnd.noop.chunk+json",
            expected_uncompressed_bytes=len(payload),
            **contract,
        )

    assert failure.value.code == "event_time_out_of_range"


def test_chunk_rejects_columns_not_registered_for_stream() -> None:
    body, contract = _fixture()
    body["streams"][0]["columns"][1] = "value"
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=payload,
            compression="none",
            content_type="application/vnd.noop.chunk+json",
            expected_uncompressed_bytes=len(payload),
            **contract,
        )

    assert failure.value.code == "invalid_columns"


def test_chunk_rejects_value_outside_registered_range() -> None:
    body, contract = _fixture()
    body["streams"][0]["rows"][0][1] = 400
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=payload,
            compression="none",
            content_type="application/vnd.noop.chunk+json",
            expected_uncompressed_bytes=len(payload),
            **contract,
        )

    assert failure.value.code == "invalid_value"


def test_chunk_rejects_unimplemented_wire_format() -> None:
    body, contract = _fixture()
    payload = _encode(body)

    with pytest.raises(ManagedChunkProcessingError) as failure:
        decode_server_readable_chunk(
            compressed=payload,
            compression="none",
            content_type="application/vnd.noop.chunk+protobuf",
            expected_uncompressed_bytes=len(payload),
            **contract,
        )

    assert failure.value.code == "unsupported_content_type"


class FakeProcessorRepository:
    def __init__(self, chunk: dict) -> None:
        self.chunk = chunk
        self.finished: list[dict] = []
        self.completed: list[ManagedObjectMetadata] = []
        self.now = datetime(2026, 9, 3, 13, tzinfo=UTC)

    async def complete_chunk_upload_for_object(self, *, metadata):
        self.completed.append(metadata)

    async def coordination_now(self):
        return self.now

    async def lease_chunk_processing(self, **kwargs):
        return self.chunk

    async def finish_chunk_processing(self, **kwargs):
        self.finished.append(kwargs)


class FakeProcessorObjectStore:
    def __init__(
        self,
        payload: bytes,
        *,
        read_error: bool = False,
    ) -> None:
        self.payload = payload
        self.read_error = read_error

    async def metadata(self, *, object_key: str, generation: int):
        return ManagedObjectMetadata(
            object_key=object_key,
            generation=generation,
            metageneration=1,
            crc32c="AAAAAA==",
            size=len(self.payload),
            content_type="application/vnd.noop.chunk+json",
            metadata={"noop-sha256": hashlib.sha256(self.payload).hexdigest()},
        )

    async def read(self, **kwargs):
        if self.read_error:
            raise ManagedObjectStoreError("temporary read failure")
        return self.payload


def _processor_fixture(*, expected_sha256: str | None = None):
    body, contract = _fixture()
    payload = _encode(body)
    chunk = {
        **contract,
        "processing_attempt_id": uuid4(),
        "content_mode": "server_readable",
        "compression": "none",
        "content_type": "application/vnd.noop.chunk+json",
        "expected_sha256": expected_sha256 or hashlib.sha256(payload).hexdigest(),
        "expected_compressed_bytes": len(payload),
        "expected_uncompressed_bytes": len(payload),
        "streams": contract["declared_streams"],
    }
    return payload, chunk


@pytest.mark.asyncio
async def test_processor_atomically_publishes_valid_chunk() -> None:
    payload, chunk = _processor_fixture()
    repository = FakeProcessorRepository(chunk)
    store = FakeProcessorObjectStore(payload)

    result = await ManagedChunkProcessor(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        processor_revision="managed-json-v1",
    ).process(
        object_key="v1/tenant/chunk",
        generation=7,
        queue_event_hash="a" * 64,
    )

    assert result.status == "available"
    assert repository.finished[0]["succeeded"] is True
    assert (
        repository.finished[0]["verified_sha256"] == hashlib.sha256(payload).hexdigest()
    )
    assert repository.finished[0]["decoded_samples"] == 2


@pytest.mark.asyncio
async def test_processor_quarantines_digest_mismatch_without_retry() -> None:
    payload, chunk = _processor_fixture(expected_sha256="0" * 64)
    repository = FakeProcessorRepository(chunk)
    store = FakeProcessorObjectStore(payload)

    result = await ManagedChunkProcessor(
        repository,  # type: ignore[arg-type]
        store,  # type: ignore[arg-type]
        processor_revision="managed-json-v1",
    ).process(
        object_key="v1/tenant/chunk",
        generation=7,
        queue_event_hash="b" * 64,
    )

    assert result.status == "quarantined"
    assert repository.finished[0]["succeeded"] is False
    assert repository.finished[0]["retryable"] is False
    assert repository.finished[0]["error_code"] == ("compressed_sha256_mismatch")


@pytest.mark.asyncio
async def test_processor_records_retryable_object_store_failure() -> None:
    payload, chunk = _processor_fixture()
    repository = FakeProcessorRepository(chunk)
    store = FakeProcessorObjectStore(payload, read_error=True)

    with pytest.raises(ManagedObjectStoreError):
        await ManagedChunkProcessor(
            repository,  # type: ignore[arg-type]
            store,  # type: ignore[arg-type]
            processor_revision="managed-json-v1",
        ).process(
            object_key="v1/tenant/chunk",
            generation=7,
            queue_event_hash="c" * 64,
        )

    assert repository.finished[0]["succeeded"] is False
    assert repository.finished[0]["retryable"] is True
    assert repository.finished[0]["error_code"] == "object_store_unavailable"
