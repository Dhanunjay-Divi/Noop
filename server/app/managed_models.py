from __future__ import annotations

import re
import unicodedata
from datetime import UTC, date, datetime, timedelta
from typing import Any, Literal
from uuid import UUID

from pydantic import Field, SecretStr, field_validator, model_validator

from app.models import INSTALLATION_ID_PATTERN, StrictModel

SHA256_PATTERN = r"^[0-9a-f]{64}$"
MANAGED_KEY_PATTERN = r"^[a-z][a-z0-9_]{0,63}$"
MANAGED_INSTALLATION_TOKEN_PATTERN = r"^noopm_[A-Za-z0-9_-]{43}$"
MANAGED_SOCIAL_ALIAS_PATTERN = (
    r"^NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-"
    r"[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$"
)
MANAGED_SOCIAL_INVITE_PATTERN = r"^noopinvite_[A-Za-z0-9_-]{43}$"
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
MANAGED_SERVER_READABLE_DOCUMENT_KINDS = frozenset(
    {
        "day_ownership",
    }
)
MANAGED_CLIENT_ENCRYPTED_DOCUMENT_KINDS = (
    MANAGED_DOCUMENT_KINDS - MANAGED_SERVER_READABLE_DOCUMENT_KINDS
)
MANAGED_DOCUMENT_CONTENT_MODES = {
    kind: (
        "server_readable"
        if kind in MANAGED_SERVER_READABLE_DOCUMENT_KINDS
        else "client_encrypted"
    )
    for kind in MANAGED_DOCUMENT_KINDS
}


def validate_managed_server_readable_payload(
    document_kind: str,
    payload_json: dict[str, Any],
) -> None:
    invalid = ValueError(
        "server-readable document payload does not match its registered schema"
    )
    if (
        document_kind != "day_ownership"
        or not isinstance(payload_json, dict)
        or set(payload_json)
        != {
            "schema_version",
            "table",
            "key",
            "record",
        }
    ):
        raise invalid

    schema_version = payload_json.get("schema_version")
    key = payload_json.get("key")
    record = payload_json.get("record")
    if (
        type(schema_version) is not int
        or schema_version != 1
        or payload_json.get("table") != "dayOwnership"
        or not isinstance(key, dict)
        or set(key) != {"day"}
        or not isinstance(record, dict)
        or set(record) != {"day", "deviceId", "locked"}
    ):
        raise invalid

    key_day = key.get("day")
    record_day = record.get("day")
    if (
        not isinstance(key_day, str)
        or key_day != record_day
        or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", key_day) is None
    ):
        raise invalid
    try:
        parsed_day = date.fromisoformat(key_day)
    except ValueError:
        raise invalid from None
    if not 2000 <= parsed_day.year <= 2099 or parsed_day.isoformat() != key_day:
        raise invalid

    device_id = record.get("deviceId")
    try:
        device_id_bytes = (
            len(device_id.encode("utf-8")) if isinstance(device_id, str) else 0
        )
    except UnicodeEncodeError:
        raise invalid from None
    if (
        not isinstance(device_id, str)
        or not device_id
        or device_id.strip() != device_id
        or device_id_bytes > 256
        or any(unicodedata.category(character) == "Cc" for character in device_id)
    ):
        raise invalid

    locked = record.get("locked")
    if not (type(locked) is bool or (type(locked) is int and locked in {0, 1})):
        raise invalid


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
        expected_content_mode = MANAGED_DOCUMENT_CONTENT_MODES[self.document_kind]
        if self.content_mode != expected_content_mode:
            raise ValueError(
                f"{self.document_kind} documents require "
                f"{expected_content_mode} content"
            )
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
            validate_managed_server_readable_payload(
                self.document_kind,
                self.payload_json,
            )
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


class ManagedSocialProfileCreate(StrictModel):
    request_id: UUID
    display_name: str = Field(min_length=1, max_length=64)

    @field_validator("display_name")
    @classmethod
    def normalized_display_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized or any(
            not character.isprintable() for character in normalized
        ):
            raise ValueError("display_name contains unsupported characters")
        return normalized


class ManagedSocialProfilePatch(StrictModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=64)
    poke_opt_in: bool | None = None
    quiet_start_minute: int | None = Field(default=None, ge=0, le=1439)
    quiet_end_minute: int | None = Field(default=None, ge=0, le=1439)
    time_zone: str | None = Field(
        default=None,
        min_length=1,
        max_length=64,
        pattern=(
            r"^(?:[A-Za-z0-9][A-Za-z0-9_+./:-]{0,63}"
            r"|[+-][0-9]{2}:[0-9]{2})$"
        ),
    )

    @field_validator("display_name")
    @classmethod
    def normalized_optional_display_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        if not normalized or any(
            not character.isprintable() for character in normalized
        ):
            raise ValueError("display_name contains unsupported characters")
        return normalized

    @model_validator(mode="after")
    def has_change(self) -> "ManagedSocialProfilePatch":
        if not self.model_fields_set:
            raise ValueError("profile patch must include at least one field")
        if any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("profile patch fields cannot be null")
        return self


class ManagedSocialInviteCreate(StrictModel):
    request_id: UUID
    capability: SecretStr
    expires_in_hours: int = Field(default=72, ge=1, le=168)

    @field_validator("capability")
    @classmethod
    def valid_capability(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_SOCIAL_INVITE_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("managed social invite is invalid")
        return value


class ManagedSocialInviteRedeem(StrictModel):
    request_id: UUID
    capability: SecretStr

    @field_validator("capability")
    @classmethod
    def valid_capability(cls, value: SecretStr) -> SecretStr:
        if (
            re.fullmatch(
                MANAGED_SOCIAL_INVITE_PATTERN,
                value.get_secret_value(),
            )
            is None
        ):
            raise ValueError("managed social invite is invalid")
        return value


class ManagedSocialRequestCreate(StrictModel):
    request_id: UUID
    noop_id: str = Field(pattern=MANAGED_SOCIAL_ALIAS_PATTERN)

    @field_validator("noop_id", mode="before")
    @classmethod
    def canonical_noop_id(cls, value: object) -> object:
        return value.upper() if isinstance(value, str) else value


class ManagedSocialRequestDecision(StrictModel):
    decision: Literal["accept", "decline"]


class ManagedSocialVisibilityPatch(StrictModel):
    charge: bool | None = None
    effort: bool | None = None
    rest: bool | None = None
    sleep_duration: bool | None = None
    hrv: bool | None = None
    rhr: bool | None = None
    poke_allowed: bool | None = None

    @model_validator(mode="after")
    def has_change(self) -> "ManagedSocialVisibilityPatch":
        if not self.model_fields_set:
            raise ValueError("visibility patch must include at least one field")
        if any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("visibility patch fields cannot be null")
        return self


MANAGED_SOCIAL_SUMMARY_RANGES: dict[str, tuple[float, float]] = {
    "charge": (0.0, 100.0),
    "effort": (0.0, 100.0),
    "rest": (0.0, 100.0),
    "sleep_duration": (0.0, 2_880.0),
    "hrv": (0.0, 1_000.0),
    "rhr": (20.0, 260.0),
}


class ManagedSocialSummaryMutation(StrictModel):
    request_id: UUID
    summary: dict[str, float | None] = Field(max_length=6)

    @field_validator("summary")
    @classmethod
    def valid_summary(cls, values: dict[str, float | None]) -> dict[str, float | None]:
        unknown = set(values) - set(MANAGED_SOCIAL_SUMMARY_RANGES)
        if unknown:
            raise ValueError("summary contains an unsupported field")
        for key, value in values.items():
            if value is None:
                continue
            lower, upper = MANAGED_SOCIAL_SUMMARY_RANGES[key]
            if not lower <= value <= upper:
                raise ValueError(f"summary field {key} is out of range")
        return dict(sorted(values.items()))


class ManagedSocialPokeCreate(StrictModel):
    request_id: UUID
    recipient_profile_id: UUID


class ManagedSocialPokeAcknowledgement(StrictModel):
    claim_id: UUID
    notification_outcome: Literal[
        "scheduled",
        "not_authorized",
        "failed",
    ]
    haptic_outcome: Literal[
        "requested",
        "band_unavailable",
        "not_eligible",
        "failed",
    ]
