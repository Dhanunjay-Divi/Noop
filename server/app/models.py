from __future__ import annotations

import json
import math
import re
from datetime import UTC, date, datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    field_validator,
    model_validator,
)

IDENTIFIER_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
INSTALLATION_ID_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
METRIC_PATTERN = r"^[a-z][a-z0-9_]{0,63}$"
MAX_STREAM_SAMPLES = 50_000
MAX_TOTAL_SAMPLES = 100_000
MAX_METADATA_BYTES = 16_384
MAX_METADATA_DEPTH = 6
MAX_STAGES_BYTES = 131_072
MAX_STAGE_SEGMENTS = 4_096
SOURCE_METADATA_KEYS = frozenset(
    {
        "installation_id",
        "logical_source_id",
        "namespace",
        "paired_device_id",
        "privacy",
        "score_provenance",
    }
)

NamespaceRole = Literal[
    "strap_measured",
    "official_reference",
    "noop_computed",
    "noop_journal",
    "apple_health_import",
    "health_connect_import",
    "activity_file_import",
    "wearable_import",
]

NAMESPACE_ROLES = frozenset(
    {
        "strap_measured",
        "official_reference",
        "noop_computed",
        "noop_journal",
        "apple_health_import",
        "health_connect_import",
        "activity_file_import",
        "wearable_import",
    }
)

NAMESPACE_SCORE_PROVENANCE: dict[str, frozenset[str]] = {
    "strap_measured": frozenset({"strap_measured"}),
    "official_reference": frozenset({"user_imported_whoop_export"}),
    "noop_computed": frozenset({"noop_transparent_algorithm"}),
    "noop_journal": frozenset({"user_entered_noop_journal"}),
    "apple_health_import": frozenset({"user_imported_apple_health"}),
    "health_connect_import": frozenset({"user_imported_health_connect"}),
    "activity_file_import": frozenset({"user_imported_activity_file"}),
    "wearable_import": frozenset({"user_imported_wearable"}),
}

StreamMetric = Literal[
    "hr",
    "rr",
    "battery",
    "spo2",
    "skin_temp",
    "respiration",
    "steps",
]

STREAM_RANGES: dict[str, tuple[float, float]] = {
    "hr": (20.0, 260.0),
    "rr": (200.0, 3_000.0),
    "battery": (0.0, 100.0),
    "spo2": (50.0, 100.0),
    "skin_temp": (10.0, 50.0),
    "respiration": (2.0, 80.0),
    "steps": (0.0, 10_000_000.0),
}

STREAM_UNITS: dict[str, str] = {
    "hr": "bpm",
    "rr": "ms",
    "battery": "percent",
    "spo2": "percent",
    "skin_temp": "celsius",
    "respiration": "breaths_per_minute",
    "steps": "count",
}

RAW_SENSOR_STREAMS = frozenset({"spo2", "skin_temp", "respiration"})


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        str_strip_whitespace=True,
        validate_default=True,
    )


def validate_display_name(value: str) -> str:
    if not value.isprintable() or any(ord(character) < 32 for character in value):
        raise ValueError("display name must contain printable characters only")
    return value


class FriendProfileCreate(StrictModel):
    display_name: str = Field(min_length=1, max_length=64)
    installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    daily_device_id: str = Field(
        min_length=1,
        max_length=128,
        pattern=IDENTIFIER_PATTERN,
        description="Producer whose daily summaries this profile may share.",
    )

    _display_name = field_validator("display_name")(validate_display_name)

    @model_validator(mode="after")
    def device_belongs_to_installation(self) -> "FriendProfileCreate":
        components = self.daily_device_id.split(":", 2)
        if (
            len(components) != 3
            or components[0] not in {"ios", "android", "macos"}
            or components[1] != self.installation_id
            or not components[2]
        ):
            raise ValueError("daily_device_id must be scoped to this installation_id")
        return self


class FriendProfileUpdate(StrictModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=64)
    daily_device_id: str | None = Field(
        default=None,
        min_length=1,
        max_length=128,
        pattern=IDENTIFIER_PATTERN,
    )

    _display_name = field_validator("display_name")(validate_display_name)

    @model_validator(mode="after")
    def require_change(self) -> "FriendProfileUpdate":
        if not self.model_fields_set:
            raise ValueError("at least one profile field is required")
        if any(
            field in self.model_fields_set and getattr(self, field) is None
            for field in ("display_name", "daily_device_id")
        ):
            raise ValueError("profile fields cannot be null")
        return self


class FriendInviteCreate(StrictModel):
    expires_in_hours: int = Field(default=72, ge=1, le=168)


class FriendInviteRedeem(StrictModel):
    code: str = Field(min_length=8, max_length=64)

    @field_validator("code")
    @classmethod
    def normalise_code(cls, value: str) -> str:
        compact = "".join(
            character for character in value.upper() if character.isalnum()
        )
        if not 12 <= len(compact) <= 32 or not compact.isascii():
            raise ValueError("invite code is invalid")
        return compact


class FriendInviteJoin(FriendProfileCreate):
    code: str = Field(min_length=8, max_length=64)
    enrollment_id: UUID
    member_token: SecretStr

    @field_validator("code")
    @classmethod
    def normalise_code(cls, value: str) -> str:
        compact = "".join(
            character for character in value.upper() if character.isalnum()
        )
        if not 12 <= len(compact) <= 32 or not compact.isascii():
            raise ValueError("invite code is invalid")
        return compact

    @field_validator("member_token")
    @classmethod
    def valid_member_token(cls, value: SecretStr) -> SecretStr:
        plaintext = value.get_secret_value()
        suffix = plaintext.removeprefix("noop_member_")
        if (
            not plaintext.startswith("noop_member_")
            or not 43 <= len(suffix) <= 86
            or re.fullmatch(r"[A-Za-z0-9_-]+", suffix) is None
        ):
            raise ValueError(
                "member_token must be a 256-bit URL-safe Noop member token"
            )
        return value


class FriendRequestDecision(StrictModel):
    decision: Literal["accept", "decline"]


PHONE_E164_PATTERN = r"^\+[1-9][0-9]{7,14}$"


def validate_installation_token(value: SecretStr) -> SecretStr:
    plaintext = value.get_secret_value()
    suffix = plaintext.removeprefix("noop_install_")
    if (
        not plaintext.startswith("noop_install_")
        or not 43 <= len(suffix) <= 86
        or re.fullmatch(r"[A-Za-z0-9_-]+", suffix) is None
    ):
        raise ValueError(
            "installation_token must be a 256-bit URL-safe Noop installation token"
        )
    return value


class InstallationCredentialBootstrap(StrictModel):
    """Retry-safe operator-authorized enrollment for one app installation."""

    installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    enrollment_id: UUID
    installation_token: SecretStr

    _installation_token = field_validator("installation_token")(
        validate_installation_token
    )


class InstallationCredentialRotation(StrictModel):
    """Idempotent token rotation; the client retains the replacement plaintext."""

    rotation_id: UUID
    expected_version: int = Field(ge=1)
    installation_token: SecretStr

    _installation_token = field_validator("installation_token")(
        validate_installation_token
    )


def validate_safety_token(value: SecretStr) -> SecretStr:
    plaintext = value.get_secret_value()
    suffix = plaintext.removeprefix("noop_safety_")
    if (
        not plaintext.startswith("noop_safety_")
        or not 43 <= len(suffix) <= 86
        or re.fullmatch(r"[A-Za-z0-9_-]+", suffix) is None
    ):
        raise ValueError("safety_token must be a 256-bit URL-safe Noop safety token")
    return value


class SafetyProfileBootstrap(StrictModel):
    """Retry-safe enrollment for one app installation's safety credential."""

    display_name: str = Field(min_length=1, max_length=64)
    installation_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=INSTALLATION_ID_PATTERN,
    )
    enrollment_id: UUID
    safety_token: SecretStr

    _display_name = field_validator("display_name")(validate_display_name)
    _safety_token = field_validator("safety_token")(validate_safety_token)


class SafetyTokenRotation(StrictModel):
    rotation_id: UUID
    expected_version: int = Field(ge=1)
    safety_token: SecretStr

    _safety_token = field_validator("safety_token")(validate_safety_token)


class SafetyContactCreate(StrictModel):
    display_name: str = Field(min_length=1, max_length=64)
    phone_e164: str = Field(pattern=PHONE_E164_PATTERN)

    _display_name = field_validator("display_name")(validate_display_name)


class SafetyInvitationDecision(StrictModel):
    decision: Literal["accept", "decline"]


class SafetyValidatedFallEvidence(StrictModel):
    """Bounded fields reserved for a future attested live-motion contract."""

    detector_id: str = Field(
        min_length=1,
        max_length=64,
        pattern=r"^[a-z][a-z0-9_.-]{0,63}$",
    )
    detector_version: int = Field(ge=1, le=10_000)
    event_id: UUID
    detected_at: datetime
    warning_haptic_confirmed_at: datetime
    response_deadline_at: datetime

    @field_validator(
        "detected_at",
        "warning_haptic_confirmed_at",
        "response_deadline_at",
        mode="before",
    )
    @classmethod
    def parse_timestamp(cls, value: Any) -> Any:
        return _rfc3339_input(value)

    @field_validator(
        "detected_at",
        "warning_haptic_confirmed_at",
        "response_deadline_at",
    )
    @classmethod
    def normalize_timestamp(cls, value: datetime) -> datetime:
        return _normalise_datetime(value)

    @model_validator(mode="after")
    def validate_response_sequence(self) -> "SafetyValidatedFallEvidence":
        if not (
            self.detected_at
            <= self.warning_haptic_confirmed_at
            <= self.response_deadline_at
        ):
            raise ValueError("fall evidence timestamps must be chronological")
        response_seconds = (
            self.response_deadline_at - self.warning_haptic_confirmed_at
        ).total_seconds()
        if not 30 <= response_seconds <= 120:
            raise ValueError("fall response window must be between 30 and 120 seconds")
        return self


class SafetyPageCreate(StrictModel):
    """An explicit SOS or a fail-closed, operator-approved fall escalation."""

    trigger: Literal["manual_sos", "band_sos", "validated_fall"] = "manual_sos"
    share_duration_hours: Literal[8, 12] = 8
    evidence: SafetyValidatedFallEvidence | None = None

    @model_validator(mode="after")
    def evidence_matches_trigger(self) -> "SafetyPageCreate":
        if self.trigger == "validated_fall":
            if self.evidence is None:
                raise ValueError("validated_fall requires live detector evidence")
        elif self.evidence is not None:
            raise ValueError("detector evidence is allowed only for validated_fall")
        return self


class SafetyIncidentTransition(StrictModel):
    note: str | None = Field(default=None, max_length=160)

    @field_validator("note")
    @classmethod
    def clean_note(cls, value: str | None) -> str | None:
        if value is None:
            return None
        compact = " ".join(value.split())
        return compact or None


class SafetyPagingControlUpdate(StrictModel):
    enabled: bool
    expected_revision: int = Field(ge=1)
    reason: str | None = Field(default=None, max_length=160)

    @field_validator("reason")
    @classmethod
    def clean_reason(cls, value: str | None) -> str | None:
        if value is None:
            return None
        compact = " ".join(value.split())
        return compact or None


class SafetyLocationUpdate(StrictModel):
    """One latest-only location fix for an active Safety incident."""

    sequence: int = Field(ge=1, le=9_223_372_036_854_775_807)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    horizontal_accuracy_meters: float | None = Field(
        default=None,
        ge=0,
        le=10_000,
    )
    captured_at: datetime

    @field_validator(
        "latitude",
        "longitude",
        "horizontal_accuracy_meters",
    )
    @classmethod
    def finite_number(cls, value: float | None) -> float | None:
        if value is not None and not math.isfinite(value):
            raise ValueError("location values must be finite")
        return value

    @field_validator("captured_at", mode="before")
    @classmethod
    def parse_captured_at(cls, value: Any) -> Any:
        return _rfc3339_input(value)

    @field_validator("captured_at")
    @classmethod
    def normalize_captured_at(cls, value: datetime) -> datetime:
        return _normalise_datetime(value)


class FriendVisibility(StrictModel):
    """Daily summary fields an owner exposes to one accepted friend.

    The core scores default on. More identifying physiological details remain
    off until the owner explicitly enables them for that individual.
    """

    charge: bool = True
    effort: bool = True
    rest: bool = True
    sleep_duration: bool = False
    hrv: bool = False
    rhr: bool = False


class FriendVisibilityPatch(StrictModel):
    charge: bool | None = None
    effort: bool | None = None
    rest: bool | None = None
    sleep_duration: bool | None = None
    hrv: bool | None = None
    rhr: bool | None = None

    @model_validator(mode="after")
    def require_change(self) -> "FriendVisibilityPatch":
        if not self.model_fields_set:
            raise ValueError("at least one visibility field is required")
        if any(
            field in self.model_fields_set and getattr(self, field) is None
            for field in (
                "charge",
                "effort",
                "rest",
                "sleep_duration",
                "hrv",
                "rhr",
            )
        ):
            raise ValueError("visibility fields cannot be null")
        return self


def _normalise_datetime(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must include a UTC offset")
    normalised = value.astimezone(UTC)
    # Accept epoch-era legacy rows so one old local outbox record cannot poison
    # every later atomic batch. The upper guard still catches unit mistakes such
    # as milliseconds accidentally supplied as seconds.
    if not 1970 <= normalised.year <= 2100:
        raise ValueError("timestamp must be between years 1970 and 2100")
    return normalised


def _rfc3339_input(value: Any) -> Any:
    if not isinstance(value, (str, datetime)):
        raise ValueError("timestamp must be an RFC 3339 string")
    return value


def _stream_timestamp_input(value: Any) -> Any:
    if isinstance(value, bool) or not isinstance(value, (str, int, datetime)):
        raise ValueError("timestamp must be Unix integer seconds or an RFC 3339 string")
    return value


def _json_depth(value: Any, depth: int = 0) -> int:
    if depth > MAX_METADATA_DEPTH:
        return depth
    if isinstance(value, dict):
        return max(
            (_json_depth(item, depth + 1) for item in value.values()),
            default=depth,
        )
    if isinstance(value, list):
        return max((_json_depth(item, depth + 1) for item in value), default=depth)
    return depth


def validate_json_object(value: dict[str, Any]) -> dict[str, Any]:
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError("metadata must contain only finite JSON values") from exc
    if len(encoded) > MAX_METADATA_BYTES:
        raise ValueError(f"metadata cannot exceed {MAX_METADATA_BYTES} bytes")
    if _json_depth(value) > MAX_METADATA_DEPTH:
        raise ValueError(f"metadata cannot exceed {MAX_METADATA_DEPTH} levels")
    return value


def validate_finite_map(
    values: dict[str, float], *, maximum_items: int = 256
) -> dict[str, float]:
    if len(values) > maximum_items:
        raise ValueError(f"metric map cannot exceed {maximum_items} entries")
    checked: dict[str, float] = {}
    for key, value in values.items():
        if re.fullmatch(METRIC_PATTERN, key) is None:
            raise ValueError(f"invalid metric name: {key!r}")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"metric {key!r} must be numeric")
        numeric = float(value)
        if not math.isfinite(numeric):
            raise ValueError(f"metric {key!r} must be finite")
        if abs(numeric) > 1_000_000_000:
            raise ValueError(f"metric {key!r} is outside the accepted range")
        checked[key] = numeric
    return checked


def validate_opaque_identifier(value: str) -> str:
    """Validate client-generated natural keys without rewriting provenance."""

    if not value.isprintable() or any(ord(character) < 32 for character in value):
        raise ValueError("identifier must contain printable characters only")
    if len(value.encode("utf-8")) > 2_000:
        raise ValueError("identifier cannot exceed 2000 UTF-8 bytes")
    return value


class DeviceMetadata(StrictModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=128)
    model: str | None = Field(default=None, min_length=1, max_length=128)
    firmware_version: str | None = Field(default=None, min_length=1, max_length=64)
    hardware_revision: str | None = Field(default=None, min_length=1, max_length=64)


class SyncSource(StrictModel):
    device_id: str = Field(min_length=1, max_length=128, pattern=IDENTIFIER_PATTERN)
    sent_at: datetime
    app_version: str | None = Field(default=None, min_length=1, max_length=64)
    platform: Literal["ios", "android", "macos", "import", "other"] | None = None
    device: DeviceMetadata = Field(default_factory=DeviceMetadata)
    metadata: dict[str, Any] = Field(default_factory=dict)

    _sent_at_input = field_validator("sent_at", mode="before")(_rfc3339_input)
    _sent_at = field_validator("sent_at")(_normalise_datetime)
    _metadata = field_validator("metadata")(validate_json_object)


class NumericSample(StrictModel):
    recorded_at: datetime
    value: float
    quality: float | None = Field(default=None, ge=0.0, le=1.0)
    metadata: dict[str, Any] = Field(default_factory=dict)

    _recorded_at_input = field_validator("recorded_at", mode="before")(
        _stream_timestamp_input
    )
    _recorded_at = field_validator("recorded_at")(_normalise_datetime)
    _metadata = field_validator("metadata")(validate_json_object)

    @field_validator("value")
    @classmethod
    def finite_value(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("value must be finite")
        return value


def _metadata_truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.casefold() in {"1", "true", "yes"}
    return False


def sample_semantics(stream_name: str, sample: NumericSample) -> tuple[str, str, bool]:
    """Return (unit, measurement class, safe-for-health-interpretation).

    BLE decoders currently preserve some sensor channels as raw ADC counts. A
    column named ``spo2`` must never turn those counts into a percentage merely
    because of its name. Both ingestion and reads use this helper so the
    distinction survives storage and export.
    """

    declared_unit = str(sample.metadata.get("unit", "")).casefold()
    uncalibrated = _metadata_truthy(sample.metadata.get("uncalibrated"))
    if (
        stream_name in RAW_SENSOR_STREAMS
        and declared_unit == "raw_adc"
        and uncalibrated
    ):
        return ("raw_adc", "raw_sensor", False)
    if stream_name in RAW_SENSOR_STREAMS:
        if uncalibrated:
            return (declared_unit or "unknown", "unclassified_sensor", False)
        expected_unit = STREAM_UNITS[stream_name]
        if declared_unit == expected_unit:
            return (expected_unit, "decoded_biometric", False)
        # Legacy/experimental decoders may not yet know a channel's scale.
        # Store it without inventing clinical semantics or applying clinical
        # range gates.
        return (declared_unit or "unknown", "unclassified_sensor", False)
    if stream_name == "battery" and declared_unit == "millivolts":
        return ("millivolts", "device_telemetry", False)
    if stream_name == "battery":
        if declared_unit in {"", "percent"}:
            return ("percent", "device_telemetry", False)
        return (declared_unit, "unclassified_telemetry", False)
    if stream_name == "steps":
        if declared_unit in {"cumulative_counter", "device_counter"}:
            # The decoded WHOOP stream is a wrapping device register, not a daily step total.
            return ("cumulative_counter", "device_counter", False)
        return ("count", "estimated_counter", False)
    return (STREAM_UNITS[stream_name], "decoded_biometric", False)


class EventSample(StrictModel):
    event_id: str = Field(min_length=1, max_length=256)
    recorded_at: datetime
    kind: str = Field(min_length=1, max_length=128)
    value: Any = None
    metadata: dict[str, Any] = Field(default_factory=dict)

    _recorded_at_input = field_validator("recorded_at", mode="before")(
        _stream_timestamp_input
    )
    _recorded_at = field_validator("recorded_at")(_normalise_datetime)
    _metadata = field_validator("metadata")(validate_json_object)
    _event_id = field_validator("event_id")(validate_opaque_identifier)

    @field_validator("kind")
    @classmethod
    def printable_kind(cls, value: str) -> str:
        # Event labels are raw protocol provenance and may legitimately contain
        # capitals, spaces, colons, slashes, and parenthesised numeric codes.
        if not value.isprintable() or any(ord(character) < 32 for character in value):
            raise ValueError("kind must contain printable characters only")
        return value

    @field_validator("value")
    @classmethod
    def json_value(cls, value: Any) -> Any:
        validate_json_object({"value": value})
        return value


class DecodedStreams(StrictModel):
    hr: list[NumericSample] = Field(default_factory=list, max_length=MAX_STREAM_SAMPLES)
    rr: list[NumericSample] = Field(default_factory=list, max_length=MAX_STREAM_SAMPLES)
    battery: list[NumericSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )
    spo2: list[NumericSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )
    skin_temp: list[NumericSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )
    respiration: list[NumericSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )
    steps: list[NumericSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )
    events: list[EventSample] = Field(
        default_factory=list, max_length=MAX_STREAM_SAMPLES
    )

    @model_validator(mode="after")
    def validate_stream_values(self) -> "DecodedStreams":
        total = len(self.events)
        for stream_name, accepted_range in STREAM_RANGES.items():
            samples: list[NumericSample] = getattr(self, stream_name)
            total += len(samples)
            minimum, maximum = accepted_range
            for sample in samples:
                if stream_name == "rr":
                    sequence = sample.metadata.get("seq")
                    if isinstance(sequence, bool):
                        sequence_number = -1
                    elif isinstance(sequence, int):
                        sequence_number = sequence
                    elif (
                        isinstance(sequence, str)
                        and sequence.isascii()
                        and sequence.isdigit()
                    ):
                        sequence_number = int(sequence)
                    else:
                        sequence_number = -1
                    if not 0 <= sequence_number <= 4_294_967_295:
                        raise ValueError(
                            "rr metadata.seq must be an integer from 0 to 4294967295"
                        )
                unit, measurement_class, _ = sample_semantics(stream_name, sample)
                if measurement_class in {
                    "raw_sensor",
                    "unclassified_sensor",
                    "unclassified_telemetry",
                }:
                    # NumericSample already guarantees finite IEEE values.
                    value_is_valid = True
                elif stream_name == "battery" and unit == "millivolts":
                    value_is_valid = 0 <= sample.value <= 10_000
                elif stream_name == "steps" and unit == "cumulative_counter":
                    value_is_valid = 0 <= sample.value <= 4_294_967_295
                else:
                    value_is_valid = minimum <= sample.value <= maximum
                if not value_is_valid:
                    accepted = (
                        "a finite raw sensor value"
                        if measurement_class
                        in {
                            "raw_sensor",
                            "unclassified_sensor",
                            "unclassified_telemetry",
                        }
                        else (
                            "0 and 10000 millivolts"
                            if stream_name == "battery" and unit == "millivolts"
                            else (
                                "0 and 4294967295 for a wrapping device counter"
                                if stream_name == "steps"
                                and unit == "cumulative_counter"
                                else f"{minimum:g} and {maximum:g}"
                            )
                        )
                    )
                    raise ValueError(f"{stream_name} value must be between {accepted}")
                if stream_name == "steps" and not sample.value.is_integer():
                    raise ValueError("steps values must be whole numbers")
        if total > MAX_TOTAL_SAMPLES:
            raise ValueError(
                f"a sync batch cannot exceed {MAX_TOTAL_SAMPLES} stream records"
            )
        return self

    def numeric_items(self) -> list[tuple[str, list[NumericSample]]]:
        return [
            (stream_name, getattr(self, stream_name)) for stream_name in STREAM_RANGES
        ]


class SleepSession(StrictModel):
    session_id: str = Field(min_length=1, max_length=512)
    start_ts: datetime
    end_ts: datetime
    # Noop stores efficiency as a fraction: 0.87 means 87%.
    efficiency: float | None = Field(default=None, ge=0.0, le=1.0)
    resting_hr: float | None = Field(default=None, ge=20.0, le=260.0)
    avg_hrv: float | None = Field(default=None, ge=0.0, le=1_000.0)
    stages: Any = Field(default_factory=list)
    metadata: dict[str, Any] = Field(default_factory=dict)

    _timestamp_input = field_validator("start_ts", "end_ts", mode="before")(
        _stream_timestamp_input
    )
    _timestamps = field_validator("start_ts", "end_ts")(_normalise_datetime)
    _metadata = field_validator("metadata")(validate_json_object)
    _session_id = field_validator("session_id")(validate_opaque_identifier)

    @model_validator(mode="after")
    def validate_hrv_method(self) -> SleepSession:
        method = self.metadata.get("hrv_method")
        if method is not None and method not in {"RMSSD", "SDNN"}:
            raise ValueError("sleep-session hrv_method must be RMSSD or SDNN")
        return self

    @field_validator("stages", mode="before")
    @classmethod
    def decode_stages(cls, value: Any) -> Any:
        # The Apple store currently exposes its stage breakdown as canonical
        # JSON text. It is commonly an array of timestamped stage segments, not
        # a stage->seconds object, so preserve either representation losslessly.
        if value is None or value == "":
            return []
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except json.JSONDecodeError as exc:
                raise ValueError("stages must contain valid JSON") from exc
        if not isinstance(value, (dict, list)):
            raise ValueError("stages must be a JSON array or object")
        if isinstance(value, list) and len(value) > MAX_STAGE_SEGMENTS:
            raise ValueError(f"stages cannot exceed {MAX_STAGE_SEGMENTS} segments")
        try:
            encoded = json.dumps(
                value,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
        except (TypeError, ValueError) as exc:
            raise ValueError("stages must contain finite JSON values") from exc
        if len(encoded) > MAX_STAGES_BYTES:
            raise ValueError(f"stages cannot exceed {MAX_STAGES_BYTES} bytes")
        if _json_depth(value) > MAX_METADATA_DEPTH + 2:
            raise ValueError("stages JSON is nested too deeply")
        if isinstance(value, dict):
            if len(value) > 32:
                raise ValueError("stage totals cannot exceed 32 entries")
            for stage, seconds in value.items():
                if re.fullmatch(METRIC_PATTERN, stage) is None:
                    raise ValueError(f"invalid sleep stage name: {stage!r}")
                if isinstance(seconds, bool) or not isinstance(seconds, int):
                    raise ValueError(f"sleep stage {stage!r} must be integer seconds")
                if not 0 <= seconds <= 172_800:
                    raise ValueError(
                        f"sleep stage {stage!r} is outside the accepted range"
                    )
        return value

    @model_validator(mode="after")
    def ordered_times(self) -> "SleepSession":
        if self.end_ts <= self.start_ts:
            raise ValueError("sleep end_ts must be after start_ts")
        if self.end_ts - self.start_ts > timedelta_days(2):
            raise ValueError("sleep session cannot exceed 48 hours")
        return self


class Workout(StrictModel):
    workout_id: str = Field(min_length=1, max_length=1_024)
    start_ts: datetime
    end_ts: datetime
    sport: str = Field(min_length=1, max_length=512)
    source: str | None = Field(default=None, min_length=1, max_length=256)
    metrics: dict[str, float] = Field(default_factory=dict)
    metadata: dict[str, Any] = Field(default_factory=dict)

    _timestamp_input = field_validator("start_ts", "end_ts", mode="before")(
        _stream_timestamp_input
    )
    _timestamps = field_validator("start_ts", "end_ts")(_normalise_datetime)
    _metrics = field_validator("metrics")(validate_finite_map)
    _metadata = field_validator("metadata")(validate_json_object)
    _workout_id = field_validator("workout_id")(validate_opaque_identifier)

    @model_validator(mode="after")
    def validate_workout(self) -> "Workout":
        if self.end_ts <= self.start_ts:
            raise ValueError("workout end_ts must be after start_ts")
        if self.end_ts - self.start_ts > timedelta_days(2):
            raise ValueError("workout cannot exceed 48 hours")
        return self


class JournalEntry(StrictModel):
    day: date
    question: str = Field(min_length=1, max_length=512)
    answered_yes: bool
    notes: str | None = Field(default=None, max_length=100_000)
    numeric_value: float | None = Field(
        default=None, ge=-1_000_000_000, le=1_000_000_000
    )

    @field_validator("numeric_value")
    @classmethod
    def finite_numeric_value(cls, value: float | None) -> float | None:
        if value is not None and not math.isfinite(value):
            raise ValueError("numeric_value must be finite")
        return value


class SyncPayload(StrictModel):
    schema_version: Literal[1]
    batch_id: UUID
    source: SyncSource
    streams: DecodedStreams = Field(default_factory=DecodedStreams)
    daily_metrics: dict[date, dict[str, float]] = Field(default_factory=dict)
    sleep_sessions: list[SleepSession] = Field(default_factory=list, max_length=5_000)
    workouts: list[Workout] = Field(default_factory=list, max_length=5_000)
    journal: list[JournalEntry] = Field(default_factory=list, max_length=5_000)

    @field_validator("daily_metrics")
    @classmethod
    def validate_daily_metrics(
        cls, value: dict[date, dict[str, float]]
    ) -> dict[date, dict[str, float]]:
        if len(value) > 3_660:
            raise ValueError("daily_metrics cannot exceed 3660 dates")
        checked = {day: validate_finite_map(metrics) for day, metrics in value.items()}
        for day, metrics in checked.items():
            efficiency = metrics.get("efficiency")
            if efficiency is not None and not 0.0 <= efficiency <= 1.0:
                raise ValueError(
                    f"daily efficiency for {day.isoformat()} must be a 0...1 fraction"
                )
        return checked

    @model_validator(mode="after")
    def reject_duplicate_ids(self) -> "SyncPayload":
        groups = (
            ("event_id", self.streams.events),
            ("session_id", self.sleep_sessions),
            ("workout_id", self.workouts),
        )
        for field_name, records in groups:
            identifiers = [getattr(record, field_name) for record in records]
            if len(identifiers) != len(set(identifiers)):
                raise ValueError(f"duplicate {field_name} in sync batch")
        journal_keys = [
            (entry.day, entry.question.casefold()) for entry in self.journal
        ]
        if len(journal_keys) != len(set(journal_keys)):
            raise ValueError("duplicate journal day/question in sync batch")
        return self

    @model_validator(mode="after")
    def validate_source_namespace(self) -> "SyncPayload":
        metadata = self.source.metadata
        missing = sorted(
            key
            for key in SOURCE_METADATA_KEYS
            if not isinstance(metadata.get(key), str) or not metadata[key].strip()
        )
        if missing:
            raise ValueError(
                "source.metadata requires non-empty string values for: "
                + ", ".join(missing)
            )

        role = metadata["namespace"]
        if role not in NAMESPACE_ROLES:
            raise ValueError(
                f"source.metadata.namespace must be one of: "
                f"{', '.join(sorted(NAMESPACE_ROLES))}"
            )
        if metadata["privacy"] != "explicit_opt_in":
            raise ValueError(
                "source.metadata.privacy must be explicit_opt_in for remote sync"
            )
        if self.source.platform in {"ios", "android", "macos"}:
            scoped_prefix = f"{self.source.platform}:{metadata['installation_id']}:"
            if not self.source.device_id.startswith(scoped_prefix):
                raise ValueError(
                    "native source.device_id must be scoped as "
                    "<platform>:<installation_id>:<producer>"
                )
        expected_provenance = NAMESPACE_SCORE_PROVENANCE[role]
        if metadata["score_provenance"] not in expected_provenance:
            raise ValueError(
                f"source.metadata.score_provenance is inconsistent with {role}"
            )
        if role == "noop_computed":
            revision = metadata.get("algorithm_revision")
            if not isinstance(revision, str) or not revision.strip():
                raise ValueError(
                    "noop_computed requires source.metadata.algorithm_revision"
                )

        has_raw = bool(self.streams.events) or any(
            samples for _, samples in self.streams.numeric_items()
        )
        has_derived = bool(self.daily_metrics or self.sleep_sessions or self.workouts)
        has_journal = bool(self.journal)

        if role != "strap_measured" and has_raw:
            raise ValueError(f"{role} cannot contain decoded strap streams or events")
        if role == "strap_measured" and (has_derived or has_journal):
            raise ValueError(
                "strap_measured can contain only decoded strap streams and events"
            )
        if role == "noop_journal" and (has_raw or has_derived):
            raise ValueError("noop_journal can contain only journal entries")
        if role != "noop_journal" and has_journal:
            raise ValueError(f"{role} cannot contain journal entries")

        if role != "official_reference":
            daily_official = any(
                "whoop_strain" in metrics for metrics in self.daily_metrics.values()
            )
            workout_official = any(
                "whoop_strain" in workout.metrics for workout in self.workouts
            )
            if daily_official or workout_official:
                raise ValueError(
                    "whoop_strain is reserved for official_reference imports"
                )
        return self


class SyncCounts(StrictModel):
    metric_samples: int = 0
    events: int = 0
    daily_metrics: int = 0
    sleep_sessions: int = 0
    workouts: int = 0
    journal_entries: int = 0


class SyncResult(StrictModel):
    batch_id: UUID
    status: Literal["accepted"] = "accepted"
    duplicate: bool
    counts: SyncCounts


def timedelta_days(days: int):
    # Kept as a helper to make the two duration limits read as domain rules.
    from datetime import timedelta

    return timedelta(days=days)
