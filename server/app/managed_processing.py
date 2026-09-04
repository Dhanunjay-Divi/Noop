from __future__ import annotations

import gzip
import hashlib
import io
import json
import math
import re
import secrets
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

from app.managed_object_store import (
    ManagedObjectStoreError,
    ManagedObjectStoring,
)
from app.managed_repository import (
    PostgresManagedRepository,
)

STREAM_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
COLUMN_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


class ManagedChunkProcessingError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class ManagedDecodedChunk:
    uncompressed_bytes: int
    sample_count: int


@dataclass(frozen=True, slots=True)
class ManagedChunkProcessorResult:
    status: str
    chunk_id: str | None = None


class ManagedChunkProcessor:
    def __init__(
        self,
        repository: PostgresManagedRepository,
        object_store: ManagedObjectStoring,
        *,
        processor_revision: str,
        lease_seconds: int = 300,
    ) -> None:
        if (
            re.fullmatch(
                r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
                processor_revision,
            )
            is None
        ):
            raise ValueError("processor_revision is invalid")
        if not 10 <= lease_seconds <= 3_600:
            raise ValueError("lease_seconds must be between 10 and 3600")
        self.repository = repository
        self.object_store = object_store
        self.processor_revision = processor_revision
        self.lease_seconds = lease_seconds

    async def process(
        self,
        *,
        object_key: str,
        generation: int,
        queue_event_hash: str,
    ) -> ManagedChunkProcessorResult:
        metadata = await self.object_store.metadata(
            object_key=object_key,
            generation=generation,
        )
        await self.repository.complete_chunk_upload_for_object(metadata=metadata)
        now = await self.repository.coordination_now()
        lease_token_hash = secrets.token_hex(32)
        chunk = await self.repository.lease_chunk_processing(
            object_key=object_key,
            processor_revision=self.processor_revision,
            queue_event_hash=queue_event_hash,
            lease_token_hash=lease_token_hash,
            now=now,
            lease_seconds=self.lease_seconds,
        )
        if chunk is None:
            return ManagedChunkProcessorResult(status="already_processed")

        attempt_id = chunk["processing_attempt_id"]
        try:
            compressed = await self.object_store.read(
                object_key=object_key,
                generation=generation,
                maximum_bytes=int(chunk["expected_compressed_bytes"]),
            )
            verified_sha256 = hashlib.sha256(compressed).hexdigest()
            if len(compressed) != int(chunk["expected_compressed_bytes"]):
                raise ManagedChunkProcessingError(
                    "compressed_size_mismatch",
                    "managed object size changed during processing",
                )
            if verified_sha256 != str(chunk["expected_sha256"]).strip():
                raise ManagedChunkProcessingError(
                    "compressed_sha256_mismatch",
                    "managed object digest does not match its reservation",
                )

            decoded: ManagedDecodedChunk | None = None
            if chunk["content_mode"] == "server_readable":
                decoded = decode_server_readable_chunk(
                    compressed=compressed,
                    compression=str(chunk["compression"]),
                    content_type=str(chunk["content_type"]),
                    expected_uncompressed_bytes=int(
                        chunk["expected_uncompressed_bytes"]
                    ),
                    chunk_id=chunk["chunk_id"],
                    source_id=chunk["source_id"],
                    data_class=str(chunk["data_class"]),
                    schema_version=int(chunk["schema_version"]),
                    event_start=chunk["event_start"],
                    event_end=chunk["event_end"],
                    declared_streams=list(chunk["streams"]),
                )
            await self.repository.finish_chunk_processing(
                processing_attempt_id=attempt_id,
                lease_token_hash=lease_token_hash,
                now=await self.repository.coordination_now(),
                succeeded=True,
                verified_sha256=verified_sha256,
                decompressed_bytes=(
                    decoded.uncompressed_bytes if decoded is not None else None
                ),
                decoded_samples=(decoded.sample_count if decoded is not None else None),
            )
            return ManagedChunkProcessorResult(
                status="available",
                chunk_id=str(chunk["chunk_id"]),
            )
        except ManagedChunkProcessingError as error:
            await self.repository.finish_chunk_processing(
                processing_attempt_id=attempt_id,
                lease_token_hash=lease_token_hash,
                now=await self.repository.coordination_now(),
                succeeded=False,
                retryable=False,
                error_code=error.code,
                error_detail_sha256=_error_digest(error),
            )
            return ManagedChunkProcessorResult(
                status="quarantined",
                chunk_id=str(chunk["chunk_id"]),
            )
        except ManagedObjectStoreError as error:
            await self.repository.finish_chunk_processing(
                processing_attempt_id=attempt_id,
                lease_token_hash=lease_token_hash,
                now=await self.repository.coordination_now(),
                succeeded=False,
                retryable=True,
                error_code="object_store_unavailable",
                error_detail_sha256=_error_digest(error),
            )
            raise


def _error_digest(error: Exception) -> str:
    return hashlib.sha256(f"{type(error).__name__}:{error}".encode("utf-8")).hexdigest()


def decode_server_readable_chunk(
    *,
    compressed: bytes,
    compression: str,
    content_type: str,
    expected_uncompressed_bytes: int,
    chunk_id: UUID,
    source_id: UUID,
    data_class: str,
    schema_version: int,
    event_start: datetime,
    event_end: datetime,
    declared_streams: list[dict[str, Any]],
) -> ManagedDecodedChunk:
    payload = _decompress_bounded(
        compressed,
        compression=compression,
        expected_bytes=expected_uncompressed_bytes,
    )
    if content_type != "application/vnd.noop.chunk+json":
        raise ManagedChunkProcessingError(
            "unsupported_content_type",
            "server-readable chunk content type is not enabled",
        )
    sample_count = _validate_json_envelope(
        payload,
        chunk_id=chunk_id,
        source_id=source_id,
        data_class=data_class,
        schema_version=schema_version,
        event_start=event_start,
        event_end=event_end,
        declared_streams=declared_streams,
    )
    return ManagedDecodedChunk(
        uncompressed_bytes=len(payload),
        sample_count=sample_count,
    )


def _decompress_bounded(
    compressed: bytes,
    *,
    compression: str,
    expected_bytes: int,
) -> bytes:
    if expected_bytes <= 0:
        raise ManagedChunkProcessingError(
            "invalid_size_contract",
            "expected uncompressed size must be positive",
        )
    if compression == "none":
        payload = compressed
    elif compression == "gzip":
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as archive:
                payload = archive.read(expected_bytes + 1)
        except (EOFError, OSError):
            raise ManagedChunkProcessingError(
                "invalid_compression",
                "gzip payload could not be decoded",
            ) from None
    elif compression == "zstd":
        raise ManagedChunkProcessingError(
            "unsupported_compression",
            "zstd processing is not enabled in this runtime",
        )
    else:
        raise ManagedChunkProcessingError(
            "invalid_compression",
            "chunk compression is not recognized",
        )
    if len(payload) != expected_bytes:
        raise ManagedChunkProcessingError(
            "uncompressed_size_mismatch",
            "chunk does not match its uncompressed size contract",
        )
    return payload


def _validate_json_envelope(
    payload: bytes,
    *,
    chunk_id: UUID,
    source_id: UUID,
    data_class: str,
    schema_version: int,
    event_start: datetime,
    event_end: datetime,
    declared_streams: list[dict[str, Any]],
) -> int:
    try:
        value = json.loads(
            payload,
            parse_constant=_reject_nonfinite_json,
        )
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ManagedChunkProcessingError(
            "invalid_json",
            "chunk JSON is invalid",
        ) from None
    if not isinstance(value, dict) or set(value) != {
        "chunk_id",
        "source_id",
        "data_class",
        "schema_version",
        "event_start_ms",
        "event_end_ms",
        "streams",
    }:
        raise ManagedChunkProcessingError(
            "invalid_envelope",
            "chunk JSON envelope has unexpected fields",
        )
    expected_start_ms = round(event_start.timestamp() * 1000)
    expected_end_ms = round(event_end.timestamp() * 1000)
    expected_header = {
        "chunk_id": str(chunk_id),
        "source_id": str(source_id),
        "data_class": data_class,
        "schema_version": schema_version,
        "event_start_ms": expected_start_ms,
        "event_end_ms": expected_end_ms,
    }
    for key, expected in expected_header.items():
        supplied = value.get(key)
        if type(supplied) is not type(expected) or supplied != expected:
            raise ManagedChunkProcessingError(
                "manifest_mismatch",
                f"chunk envelope {key} does not match its manifest",
            )
    streams = value["streams"]
    if not isinstance(streams, list) or len(streams) > 128:
        raise ManagedChunkProcessingError(
            "invalid_streams",
            "chunk streams must be a bounded list",
        )
    declared = {str(stream["stream_key"]): stream for stream in declared_streams}
    if len(declared) != len(declared_streams):
        raise ManagedChunkProcessingError(
            "invalid_manifest",
            "chunk manifest repeats a stream key",
        )
    seen: set[str] = set()
    total_samples = 0
    for stream in streams:
        if not isinstance(stream, dict) or set(stream) != {
            "stream_key",
            "schema_revision",
            "columns",
            "rows",
        }:
            raise ManagedChunkProcessingError(
                "invalid_stream",
                "chunk stream has unexpected fields",
            )
        stream_key = stream["stream_key"]
        if (
            not isinstance(stream_key, str)
            or STREAM_KEY_RE.fullmatch(stream_key) is None
            or stream_key in seen
            or stream_key not in declared
        ):
            raise ManagedChunkProcessingError(
                "manifest_mismatch",
                "chunk stream key does not match its manifest",
            )
        seen.add(stream_key)
        manifest = declared[stream_key]
        if (
            isinstance(stream["schema_revision"], bool)
            or not isinstance(stream["schema_revision"], int)
            or stream["schema_revision"] != manifest["schema_revision"]
        ):
            raise ManagedChunkProcessingError(
                "manifest_mismatch",
                "chunk stream schema revision does not match its manifest",
            )
        columns = stream["columns"]
        rows = stream["rows"]
        value_schema = manifest.get("value_schema")
        schema_columns = _validated_schema_columns(value_schema)
        valid_columns = isinstance(columns, list) and all(
            isinstance(column, str) and COLUMN_KEY_RE.fullmatch(column) is not None
            for column in columns
        )
        if (
            not isinstance(columns, list)
            or not 1 <= len(columns) <= 32
            or not valid_columns
            or len(set(columns)) != len(columns)
            or "event_at_ms" not in columns
            or columns != [column["name"] for column in schema_columns]
        ):
            raise ManagedChunkProcessingError(
                "invalid_columns",
                "chunk stream columns do not match the registered schema",
            )
        if not isinstance(rows, list) or len(rows) != manifest["sample_count"]:
            raise ManagedChunkProcessingError(
                "sample_count_mismatch",
                "chunk stream row count does not match its manifest",
            )
        event_index = columns.index("event_at_ms")
        first_event_ms: int | None = None
        last_event_ms: int | None = None
        for row in rows:
            if not isinstance(row, list) or len(row) != len(columns):
                raise ManagedChunkProcessingError(
                    "invalid_row",
                    "chunk stream row shape is invalid",
                )
            for cell, column_schema in zip(row, schema_columns, strict=True):
                _validate_cell(cell, column_schema=column_schema)
            event_ms = row[event_index]
            if (
                isinstance(event_ms, bool)
                or not isinstance(event_ms, int)
                or not expected_start_ms <= event_ms <= expected_end_ms
            ):
                raise ManagedChunkProcessingError(
                    "event_time_out_of_range",
                    "chunk sample time is outside its manifest window",
                )
            first_event_ms = (
                event_ms if first_event_ms is None else min(first_event_ms, event_ms)
            )
            last_event_ms = (
                event_ms if last_event_ms is None else max(last_event_ms, event_ms)
            )
        _validate_stream_window(
            manifest,
            first_event_ms=first_event_ms,
            last_event_ms=last_event_ms,
        )
        total_samples += len(rows)
    if seen != set(declared):
        raise ManagedChunkProcessingError(
            "manifest_mismatch",
            "chunk payload omitted a declared stream",
        )
    return total_samples


def _validate_stream_window(
    manifest: dict[str, Any],
    *,
    first_event_ms: int | None,
    last_event_ms: int | None,
) -> None:
    expected_first = manifest["first_event_at"]
    expected_last = manifest["last_event_at"]
    if first_event_ms is None:
        if expected_first is not None or expected_last is not None:
            raise ManagedChunkProcessingError(
                "manifest_mismatch",
                "empty stream has a non-empty manifest window",
            )
        return
    if expected_first is None or expected_last is None:
        raise ManagedChunkProcessingError(
            "manifest_mismatch",
            "stream payload has no manifest window",
        )
    expected_first_ms = round(expected_first.timestamp() * 1000)
    expected_last_ms = round(expected_last.timestamp() * 1000)
    if first_event_ms != expected_first_ms or last_event_ms != expected_last_ms:
        raise ManagedChunkProcessingError(
            "manifest_mismatch",
            "stream event window does not match its manifest",
        )


def _validated_schema_columns(value_schema: Any) -> list[dict[str, Any]]:
    if (
        not isinstance(value_schema, dict)
        or value_schema.get("encoding") != "tabular_v1"
        or value_schema.get("timestamp_column") != "event_at_ms"
    ):
        raise ManagedChunkProcessingError(
            "invalid_schema_contract",
            "registered stream schema is not a tabular_v1 contract",
        )
    columns = value_schema.get("columns")
    if not isinstance(columns, list) or not 1 <= len(columns) <= 32:
        raise ManagedChunkProcessingError(
            "invalid_schema_contract",
            "registered stream schema has invalid columns",
        )
    names: list[str] = []
    allowed_keys = {
        "name",
        "type",
        "nullable",
        "minimum",
        "maximum",
        "max_length",
        "enum",
    }
    for column in columns:
        if (
            not isinstance(column, dict)
            or not set(column).issubset(allowed_keys)
            or not {"name", "type"}.issubset(column)
            or not isinstance(column["name"], str)
            or COLUMN_KEY_RE.fullmatch(column["name"]) is None
            or column["type"] not in {"integer", "number", "string", "boolean"}
            or not isinstance(column.get("nullable", False), bool)
        ):
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream column contract is invalid",
            )
        if "max_length" in column and (
            isinstance(column["max_length"], bool)
            or not isinstance(column["max_length"], int)
            or not 1 <= column["max_length"] <= 1_048_576
        ):
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream string bound is invalid",
            )
        if "max_length" in column and column["type"] != "string":
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream length bound applies only to strings",
            )
        if "enum" in column and (
            not isinstance(column["enum"], list)
            or not 1 <= len(column["enum"]) <= 128
            or len({json.dumps(item, sort_keys=True) for item in column["enum"]})
            != len(column["enum"])
        ):
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream enum is invalid",
            )
        if "enum" in column and any(
            not _schema_type_matches(item, column["type"]) for item in column["enum"]
        ):
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream enum value has the wrong type",
            )
        for bound in ("minimum", "maximum"):
            if bound in column and (
                isinstance(column[bound], bool)
                or not isinstance(column[bound], (int, float))
                or not math.isfinite(column[bound])
            ):
                raise ManagedChunkProcessingError(
                    "invalid_schema_contract",
                    "registered stream numeric bound is invalid",
                )
        if ("minimum" in column or "maximum" in column) and column["type"] not in {
            "integer",
            "number",
        }:
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered numeric bound applies only to numeric columns",
            )
        if (
            "minimum" in column
            and "maximum" in column
            and column["minimum"] > column["maximum"]
        ):
            raise ManagedChunkProcessingError(
                "invalid_schema_contract",
                "registered stream numeric bounds are reversed",
            )
        names.append(column["name"])
    if (
        len(names) != len(set(names))
        or names[0] != "event_at_ms"
        or value_schema["columns"][0]["type"] != "integer"
        or value_schema["columns"][0].get("nullable", False)
    ):
        raise ManagedChunkProcessingError(
            "invalid_schema_contract",
            "registered stream timestamp contract is invalid",
        )
    return columns


def _schema_type_matches(value: Any, expected_type: str) -> bool:
    return (
        (expected_type == "boolean" and isinstance(value, bool))
        or (
            expected_type == "integer"
            and isinstance(value, int)
            and not isinstance(value, bool)
        )
        or (
            expected_type == "number"
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
        )
        or (expected_type == "string" and isinstance(value, str))
    )


def _validate_cell(value: Any, *, column_schema: dict[str, Any]) -> None:
    if value is None:
        if column_schema.get("nullable", False):
            return
        raise ManagedChunkProcessingError(
            "invalid_value",
            f"{column_schema['name']} cannot be null",
        )

    expected_type = column_schema["type"]
    valid_type = _schema_type_matches(value, expected_type)
    if not valid_type:
        raise ManagedChunkProcessingError(
            "invalid_value",
            f"{column_schema['name']} has the wrong value type",
        )

    if expected_type == "integer" and not -(2**63) <= value < 2**63:
        raise ManagedChunkProcessingError(
            "invalid_value",
            f"{column_schema['name']} is outside signed 64-bit range",
        )
    if expected_type == "number":
        try:
            finite = math.isfinite(value)
        except OverflowError:
            finite = False
        if not finite:
            raise ManagedChunkProcessingError(
                "invalid_value",
                f"{column_schema['name']} must be finite",
            )
    if expected_type in {"integer", "number"}:
        minimum = column_schema.get("minimum")
        maximum = column_schema.get("maximum")
        if minimum is not None and value < minimum:
            raise ManagedChunkProcessingError(
                "invalid_value",
                f"{column_schema['name']} is below its registered minimum",
            )
        if maximum is not None and value > maximum:
            raise ManagedChunkProcessingError(
                "invalid_value",
                f"{column_schema['name']} exceeds its registered maximum",
            )
    if expected_type == "string":
        maximum_length = column_schema.get("max_length", 1_048_576)
        if len(value.encode("utf-8")) > maximum_length:
            raise ManagedChunkProcessingError(
                "invalid_value",
                f"{column_schema['name']} exceeds its registered length",
            )
    if "enum" in column_schema and value not in column_schema["enum"]:
        raise ManagedChunkProcessingError(
            "invalid_value",
            f"{column_schema['name']} is outside its registered vocabulary",
        )


def _reject_nonfinite_json(value: str) -> None:
    raise ManagedChunkProcessingError(
        "invalid_value",
        f"non-finite JSON value {value} is not allowed",
    )
