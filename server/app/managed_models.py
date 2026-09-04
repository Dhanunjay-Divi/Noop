from __future__ import annotations

import re
from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID

from pydantic import Field, SecretStr, field_validator, model_validator

from app.models import INSTALLATION_ID_PATTERN, StrictModel

SHA256_PATTERN = r"^[0-9a-f]{64}$"
MANAGED_KEY_PATTERN = r"^[a-z][a-z0-9_]{0,63}$"
MANAGED_INSTALLATION_TOKEN_PATTERN = r"^noopm_[A-Za-z0-9_-]{43}$"
MANAGED_CONTENT_TYPES = frozenset(
    {
        "application/vnd.noop.chunk+protobuf",
        "application/vnd.noop.chunk+cbor",
        "application/vnd.noop.chunk+json",
        "application/vnd.noop.backup",
    }
)


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must include a UTC offset")
    return value.astimezone(UTC)


class ManagedEnrollment(StrictModel):
    installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    platform: Literal["ios", "android"]
    installation_token: SecretStr
    enrollment_request_id: UUID
    policy_version: str = Field(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
    )
    policy_sha256: str = Field(pattern=SHA256_PATTERN)
    data_classes: list[str] = Field(min_length=1, max_length=32)
    device_key_fingerprint: str | None = Field(
        default=None,
        pattern=SHA256_PATTERN,
    )

    @field_validator("installation_token")
    @classmethod
    def valid_installation_token(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_INSTALLATION_TOKEN_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("installation_token is invalid")
        return value

    @field_validator("data_classes")
    @classmethod
    def valid_data_classes(cls, values: list[str]) -> list[str]:
        if len(set(values)) != len(values):
            raise ValueError("data_classes cannot contain duplicates")
        if any(re.fullmatch(MANAGED_KEY_PATTERN, value) is None for value in values):
            raise ValueError("data_classes contains an invalid identifier")
        return sorted(values)


class ManagedSourceRegistration(StrictModel):
    source_id: UUID
    source_kind: str = Field(
        min_length=2,
        max_length=64,
        pattern=r"^[a-z][a-z0-9_]{1,63}$",
    )
    platform: Literal["ios", "android", "macos", "import", "other"]
    logical_source_hash: str = Field(pattern=SHA256_PATTERN)


class ManagedChunkStream(StrictModel):
    stream_key: str = Field(
        min_length=1,
        max_length=64,
        pattern=MANAGED_KEY_PATTERN,
    )
    sample_count: int = Field(ge=0)
    first_event_at: datetime | None = None
    last_event_at: datetime | None = None
    encoded_bytes: int = Field(ge=0)
    schema_revision: int = Field(ge=1, le=10_000)

    @model_validator(mode="after")
    def ordered_window(self) -> "ManagedChunkStream":
        if (self.first_event_at is None) != (self.last_event_at is None):
            raise ValueError(
                "first_event_at and last_event_at must both be present or absent"
            )
        if self.first_event_at is not None and self.last_event_at is not None:
            first = _utc(self.first_event_at)
            last = _utc(self.last_event_at)
            if last < first:
                raise ValueError("last_event_at must not precede first_event_at")
            self.first_event_at = first
            self.last_event_at = last
        return self


class ManagedChunkReservation(StrictModel):
    chunk_id: UUID
    request_id: UUID
    source_id: UUID
    data_class: str = Field(
        min_length=2,
        max_length=64,
        pattern=r"^[a-z][a-z0-9_]{1,63}$",
    )
    schema_version: int = Field(ge=1, le=10_000)
    content_mode: Literal["server_readable", "client_encrypted"]
    client_key_id: UUID | None = None
    event_start: datetime
    event_end: datetime
    compression: Literal["zstd", "gzip", "none"]
    content_type: str
    expected_sha256: str = Field(pattern=SHA256_PATTERN)
    expected_compressed_bytes: int = Field(gt=0)
    expected_uncompressed_bytes: int = Field(gt=0)
    streams: list[ManagedChunkStream] = Field(default_factory=list, max_length=128)

    @field_validator("content_type")
    @classmethod
    def known_content_type(cls, value: str) -> str:
        if value not in MANAGED_CONTENT_TYPES:
            raise ValueError("unsupported managed chunk content_type")
        return value

    @model_validator(mode="after")
    def valid_contract(self) -> "ManagedChunkReservation":
        self.event_start = _utc(self.event_start)
        self.event_end = _utc(self.event_end)
        if self.event_end < self.event_start:
            raise ValueError("event_end must not precede event_start")
        if self.event_end - self.event_start > timedelta(days=7):
            raise ValueError("managed chunks cannot span more than seven days")
        if self.content_mode == "server_readable" and self.client_key_id is not None:
            raise ValueError("server-readable chunks cannot use a client key")
        if self.content_mode == "client_encrypted" and self.client_key_id is None:
            raise ValueError("client-encrypted chunks require a client key")
        if self.content_mode == "server_readable" and (
            self.compression not in {"gzip", "none"}
            or self.content_type != "application/vnd.noop.chunk+json"
        ):
            raise ValueError(
                "server-readable chunks require the enabled JSON/gzip wire format"
            )
        stream_keys = [stream.stream_key for stream in self.streams]
        if len(stream_keys) != len(set(stream_keys)):
            raise ValueError("streams cannot contain duplicate stream_key values")
        if any(
            stream.first_event_at is not None
            and (
                stream.first_event_at < self.event_start
                or stream.last_event_at is None
                or stream.last_event_at > self.event_end
            )
            for stream in self.streams
        ):
            raise ValueError("stream event windows must stay inside the chunk window")
        if sum(stream.encoded_bytes for stream in self.streams) > (
            self.expected_uncompressed_bytes
        ):
            raise ValueError("stream encoded bytes exceed expected uncompressed bytes")
        return self


class ManagedChunkCompletion(StrictModel):
    object_generation: int = Field(gt=0)
    object_metageneration: int = Field(gt=0)
    object_crc32c: str = Field(pattern=r"^[A-Za-z0-9+/]{6}==$")


class ManagedAccessRequest(StrictModel):
    request_id: UUID


class ManagedClientKeyRegistration(StrictModel):
    client_key_id: UUID
    purpose: Literal["backup", "sync", "recovery"]
    algorithm: str = Field(
        min_length=2,
        max_length=64,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._+-]{1,63}$",
    )
    public_key_base64: str | None = Field(default=None, max_length=16_384)
    key_fingerprint: str = Field(pattern=SHA256_PATTERN)
    recovery_method: Literal[
        "none",
        "device_transfer",
        "recovery_key",
        "platform_escrow",
    ]
    hardware_backed: bool | None = None


class ManagedErasureRequest(StrictModel):
    request_id: UUID
    scope: Literal[
        "all_managed_data",
        "raw_chunks",
        "derived_data",
        "account",
    ]
    confirmation_sha256: str = Field(pattern=SHA256_PATTERN)


MANAGED_DOCUMENT_KINDS = frozenset(
    {
        "automation",
        "caffeine",
        "coach_history",
        "coach_memory",
        "cycle",
        "day_ownership",
        "device_registry",
        "dismissal",
        "hydration",
        "journal",
        "lab_marker",
        "medication",
        "mood",
        "notification_settings",
        "nutrition",
        "nutrition_catalog",
        "preferences",
        "profile",
        "strength_log",
        "strength_plan",
        "user_marker",
        "workout_plan",
        "other",
    }
)

ManagedDocumentKind = Literal[
    "automation",
    "caffeine",
    "coach_history",
    "coach_memory",
    "hydration",
    "cycle",
    "day_ownership",
    "device_registry",
    "dismissal",
    "journal",
    "lab_marker",
    "medication",
    "mood",
    "notification_settings",
    "nutrition",
    "nutrition_catalog",
    "preferences",
    "profile",
    "strength_log",
    "strength_plan",
    "user_marker",
    "workout_plan",
    "other",
]


class ManagedDocumentMutation(StrictModel):
    request_id: UUID
    document_kind: ManagedDocumentKind
    document_id: UUID
    base_revision: int = Field(ge=0)
    content_mode: Literal["server_readable", "client_encrypted"]
    client_key_id: UUID | None = None
    payload_json: dict | None = None
    payload_ciphertext_base64: str | None = Field(
        default=None,
        max_length=1_398_104,
    )
    content_sha256: str | None = Field(default=None, pattern=SHA256_PATTERN)
    updated_at: datetime
    deleted: bool = False

    @model_validator(mode="after")
    def valid_payload(self) -> "ManagedDocumentMutation":
        self.updated_at = _utc(self.updated_at)
        if self.deleted:
            if (
                self.client_key_id is not None
                or self.payload_json is not None
                or self.payload_ciphertext_base64 is not None
            ):
                raise ValueError("deleted documents cannot contain payload data")
            return self
        if self.content_mode == "server_readable":
            if (
                self.client_key_id is not None
                or self.payload_json is None
                or self.payload_ciphertext_base64 is not None
            ):
                raise ValueError("server-readable documents require only payload_json")
        elif (
            self.client_key_id is None
            or self.payload_json is not None
            or self.payload_ciphertext_base64 is None
        ):
            raise ValueError("client-encrypted documents require a key and ciphertext")
        return self


class ManagedRestoreRequest(StrictModel):
    request_id: UUID
    snapshot_at: datetime | None = None
    data_classes: list[str] = Field(default_factory=list, max_length=32)
    document_kinds: list[ManagedDocumentKind] = Field(
        default_factory=list,
        max_length=16,
    )
    include_documents: bool = True
    start: datetime | None = None
    end: datetime | None = None

    @model_validator(mode="after")
    def valid_window(self) -> "ManagedRestoreRequest":
        if self.snapshot_at is not None:
            self.snapshot_at = _utc(self.snapshot_at)
        if len(set(self.data_classes)) != len(self.data_classes):
            raise ValueError("data_classes cannot contain duplicates")
        if any(
            re.fullmatch(MANAGED_KEY_PATTERN, value) is None
            for value in self.data_classes
        ):
            raise ValueError("data_classes contains an invalid identifier")
        if len(set(self.document_kinds)) != len(self.document_kinds):
            raise ValueError("document_kinds cannot contain duplicates")
        if self.start is not None:
            self.start = _utc(self.start)
        if self.end is not None:
            self.end = _utc(self.end)
        if self.start is not None and self.end is not None and self.start >= self.end:
            raise ValueError("start must be before end")
        return self


class ManagedRestoreCompletion(StrictModel):
    delivered_objects: int = Field(ge=0)
    delivered_bytes: int = Field(ge=0)


class ManagedExportRequest(StrictModel):
    request_id: UUID
    format: Literal["noopbak", "json", "csv_bundle"]
    content_mode: Literal["client_encrypted"]
    client_key_id: UUID
    scope: dict
    expected_sha256: str = Field(pattern=SHA256_PATTERN)
    expected_bytes: int = Field(gt=0, le=1_073_741_824)
    content_type: Literal[
        "application/vnd.noop.backup",
        "application/octet-stream",
    ]


class ManagedExportCompletion(StrictModel):
    object_generation: int = Field(gt=0)
    object_metageneration: int = Field(gt=0)
    object_crc32c: str = Field(pattern=r"^[A-Za-z0-9+/]{6}==$")
