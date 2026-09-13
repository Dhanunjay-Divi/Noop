from __future__ import annotations

import asyncio
import hashlib
import io
import json
import math
import re
import struct
import zipfile
import zlib
from dataclasses import dataclass
from typing import Any, Callable, Protocol


class FeedbackArchiveRejectedError(ValueError):
    """The uploaded archive does not match the narrow app-report contract."""


class FeedbackArchiveValidationUnavailableError(RuntimeError):
    """Bounded archive validation could not start or finish in time."""


@dataclass(frozen=True, slots=True)
class FeedbackArchiveSummary:
    file_count: int
    uncompressed_bytes: int
    includes_user_note: bool
    includes_screenshot: bool


class FeedbackArchiveValidating(Protocol):
    async def acquire(self) -> FeedbackArchiveValidationAdmission: ...


class FeedbackArchiveValidationAdmission(Protocol):
    async def __aenter__(self) -> FeedbackArchiveValidationAdmission: ...

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: Any,
    ) -> None: ...

    async def validate(
        self,
        payload: bytes,
        *,
        expected_platform: str,
        expected_app_version: str,
        includes_user_note: bool,
        includes_screenshot: bool,
    ) -> FeedbackArchiveSummary: ...


class BoundedFeedbackArchiveValidator:
    def __init__(
        self,
        *,
        max_concurrency: int,
        timeout_seconds: float,
        validator: Callable[..., FeedbackArchiveSummary] | None = None,
    ) -> None:
        if not 1 <= max_concurrency <= 16:
            raise ValueError("max_concurrency must be between 1 and 16")
        if not 0 < timeout_seconds <= 120:
            raise ValueError(
                "timeout_seconds must be greater than zero and at most 120"
            )
        self._slots = asyncio.BoundedSemaphore(max_concurrency)
        self._timeout_seconds = timeout_seconds
        self._validator = validator or validate_feedback_archive

    async def acquire(self) -> FeedbackArchiveValidationAdmission:
        try:
            await asyncio.wait_for(
                self._slots.acquire(),
                timeout=self._timeout_seconds,
            )
        except TimeoutError:
            raise FeedbackArchiveValidationUnavailableError(
                "feedback archive validation capacity is unavailable"
            ) from None
        return _BoundedFeedbackArchiveValidationAdmission(self)

    async def validate(
        self,
        payload: bytes,
        *,
        expected_platform: str,
        expected_app_version: str,
        includes_user_note: bool,
        includes_screenshot: bool,
    ) -> FeedbackArchiveSummary:
        admission = await self.acquire()
        async with admission:
            return await admission.validate(
                payload,
                expected_platform=expected_platform,
                expected_app_version=expected_app_version,
                includes_user_note=includes_user_note,
                includes_screenshot=includes_screenshot,
            )

    def _release_slot(self, worker: asyncio.Task[FeedbackArchiveSummary]) -> None:
        try:
            worker.exception()
        except (asyncio.CancelledError, Exception):
            pass
        self._slots.release()


class _BoundedFeedbackArchiveValidationAdmission:
    def __init__(self, owner: BoundedFeedbackArchiveValidator) -> None:
        self._owner = owner
        self._entered = False
        self._release_on_exit = True

    async def __aenter__(self) -> _BoundedFeedbackArchiveValidationAdmission:
        if self._entered:
            raise RuntimeError("feedback archive admission cannot be reused")
        self._entered = True
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: Any,
    ) -> None:
        del exc_type, exc, traceback
        if self._release_on_exit:
            self._owner._slots.release()

    async def validate(
        self,
        payload: bytes,
        *,
        expected_platform: str,
        expected_app_version: str,
        includes_user_note: bool,
        includes_screenshot: bool,
    ) -> FeedbackArchiveSummary:
        if not self._entered:
            raise RuntimeError("feedback archive admission is not active")
        worker = asyncio.create_task(
            asyncio.to_thread(
                self._owner._validator,
                payload,
                expected_platform=expected_platform,
                expected_app_version=expected_app_version,
                includes_user_note=includes_user_note,
                includes_screenshot=includes_screenshot,
            )
        )
        try:
            return await asyncio.wait_for(
                asyncio.shield(worker),
                timeout=self._owner._timeout_seconds,
            )
        except TimeoutError:
            self._release_on_exit = False
            worker.add_done_callback(self._owner._release_slot)
            raise FeedbackArchiveValidationUnavailableError(
                "feedback archive validation timed out"
            ) from None
        except asyncio.CancelledError:
            self._release_on_exit = False
            worker.add_done_callback(self._owner._release_slot)
            raise


_REQUIRED_NAMES = frozenset({"report.txt", "meta.json"})
_COMMON_OPTIONAL_NAMES = frozenset(
    {
        "user-note.txt",
        "screenshot.png",
        "app-session-current.jsonl",
        "app-session-previous.jsonl",
    }
)
_PLATFORM_OPTIONAL_NAMES = {
    "ios": frozenset(
        {
            "feedback-manifest.json",
            "apple-performance-diagnostics.jsonl",
        }
    ),
    "android": frozenset(
        {
            "android-exit-history.jsonl",
            "last-crash.txt",
        }
    ),
}
_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_ISO8601_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"
)
_SAFE_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$")
_SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .,_+()/:'-]{0,127}$")
_MAX_FILES = 12
_MAX_UNCOMPRESSED_BYTES = 32 * 1024 * 1024
_MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024
_MAX_META_BYTES = 256 * 1024
_MAX_JSONL_LINES = 4_096
_MAX_JSONL_LINE_BYTES = 2 * 1024 * 1024
_MAX_JSON_DEPTH = 16
_MAX_JSON_NODES = 65_536
_MAX_JSON_STRING_BYTES = 16 * 1024
_MAX_PNG_DIMENSION = 8_192
_MAX_PNG_PIXELS = 8_388_608
_MAX_PNG_DECODED_BYTES = 36 * 1024 * 1024
_MAX_PNG_CHUNK_BYTES = 8 * 1024 * 1024

_ENTRY_LIMITS = {
    "report.txt": 1024 * 1024,
    "meta.json": _MAX_META_BYTES,
    "user-note.txt": 8 * 1024,
    "screenshot.png": _MAX_SCREENSHOT_BYTES,
    "app-session-current.jsonl": 512 * 1024,
    "app-session-previous.jsonl": 512 * 1024,
    "feedback-manifest.json": _MAX_META_BYTES,
    "apple-performance-diagnostics.jsonl": 2 * 1024 * 1024,
    "android-exit-history.jsonl": 512 * 1024,
    "last-crash.txt": 64 * 1024,
}
_JSONL_NAMES = frozenset(
    {
        "app-session-current.jsonl",
        "app-session-previous.jsonl",
        "apple-performance-diagnostics.jsonl",
        "android-exit-history.jsonl",
    }
)
_META_REQUIRED_KEYS = frozenset(
    {
        "schema",
        "platform",
        "test_profile",
        "questionnaire",
        "storage",
        "redaction",
    }
)
_META_ALLOWED_KEYS = _META_REQUIRED_KEYS | frozenset(
    {
        "app_version",
        "app_build",
        "os_version",
        "device_hardware",
        "strap_model",
        "strap_firmware",
        "device_family",
        "device_variant",
        "source",
        "profile_started_at",
        "capture_started_at",
        "capture_ended_at",
        "build",
        "capabilities",
        "truncated",
        "capture_check",
    }
)
_STORAGE_KEYS = frozenset({"db_bytes", "raw_capture_bytes", "rows"})
_BUILD_KEYS = frozenset({"channel", "signed"})
_CAPABILITY_KEYS = frozenset(
    {
        "healthkit_entitled",
        "healthkit_background_delivery_entitled",
        "app_group_identifier",
        "app_group_container_available",
        "bluetooth_central_background_mode",
        "location_background_mode",
        "background_fetch_mode",
        "protected_data_available",
        "background_refresh",
    }
)
_RESOURCE_KEYS = frozenset(
    {
        "memory_mb",
        "memory_pss_mb",
        "java_heap_bytes",
        "native_heap_bytes",
        "database_bytes",
        "disk_available_bytes",
        "physical_memory_bytes",
        "memory_class_bytes",
        "thermal_state",
        "thermal_status",
        "low_power_mode",
    }
)
_RESOURCE_LABEL_KEYS = frozenset({"thermal_state", "thermal_status"})

_FORBIDDEN_KEY_PARTS = frozenset(
    {
        "access_token",
        "account_id",
        "api_key",
        "authorization",
        "biometric_value",
        "blood_oxygen",
        "client_secret",
        "contact_id",
        "cookie",
        "coordinates",
        "credential",
        "device_id",
        "email",
        "endpoint",
        "gps",
        "heart_rate",
        "health_timestamp",
        "health_value",
        "hrv",
        "latitude",
        "latest_hr",
        "location",
        "longitude",
        "network_body",
        "network_payload",
        "object_key",
        "otp",
        "password",
        "phone",
        "private_key",
        "query",
        "refresh_token",
        "request_body",
        "response_body",
        "respiratory_rate",
        "secret",
        "sensor_value",
        "signed_url",
        "skin_temp",
        "spo2",
        "token",
        "url",
        "user_id",
        "vo2",
    }
)
_EXACT_HEALTH_KEY_NAMES = frozenset(
    {
        "bpm",
        "hr",
        "oxygen_saturation",
        "temperature",
    }
)

_CREDENTIAL_PATTERNS = (
    re.compile(
        r"\b(?:authorization|proxy-authorization)\s*[:=]\s*"
        r"(?:bearer|basic)\s+\S+",
        re.IGNORECASE,
    ),
    re.compile(r"\bbearer\s+[A-Za-z0-9._~+/=-]{8,}", re.IGNORECASE),
    re.compile(
        r"\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|"
        r"passwd|secret|cookie|set-cookie|client[_-]?secret|private[_-]?key|"
        r"otp)\b\s*[:=]\s*\S+",
        re.IGNORECASE,
    ),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(
        r"[?&](?:X-Amz-|X-Goog-|Signature=|sig=|token=|key=)",
        re.IGNORECASE,
    ),
)
_HEALTH_VALUE_PATTERNS = (
    re.compile(
        r"\b(?:heart[\s_-]*rate|hrv|spo2|blood[\s_-]*oxygen|"
        r"oxygen[\s_-]*saturation|respiratory[\s_-]*rate|"
        r"skin[\s_-]*temp(?:erature)?|vo2(?:max)?|bpm|hr)\b"
        r"\s*(?::|=|is)?\s*-?\d+(?:\.\d+)?",
        re.IGNORECASE,
    ),
    re.compile(r"\b\d+(?:\.\d+)?\s*bpm\b", re.IGNORECASE),
)
_LOCATION_VALUE_PATTERNS = (
    re.compile(
        r"\b(?:lat(?:itude)?|lon(?:gitude)?|lng|gps)\b\s*[:=]\s*"
        r"[+-]?\d{1,3}\.\d{3,}",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?<![\d.])[+-]?\d{1,3}\.\d{3,}\s*[,/]\s*"
        r"[+-]?\d{1,3}\.\d{3,}(?![\d.])"
    ),
)
_CONTACT_PATTERNS = (
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    re.compile(r"(?<![\w+])\+\d{8,15}\b"),
    re.compile(
        r"(?<!\d)(?:\+?1[\s.-]?)?"
        r"(?:\([2-9]\d{2}\)|[2-9]\d{2})"
        r"[\s.-][2-9]\d{2}[\s.-]\d{4}(?!\d)"
    ),
)
_DYNAMIC_PATH_PATTERNS = (
    re.compile(
        r"(?<![A-Za-z0-9._-])/(?:Users|home|private/var|var/mobile|"
        r"data/user|storage/emulated|tmp)/\S+",
        re.IGNORECASE,
    ),
    re.compile(r"\b[A-Za-z]:\\(?:Users|Documents and Settings)\\\S+"),
    re.compile(r"\b(?:file|content)://\S+", re.IGNORECASE),
    re.compile(r"\bhttps?://\S+", re.IGNORECASE),
)
_IDENTIFIER_PATTERNS = (
    re.compile(
        r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", re.IGNORECASE),
)


class _DuplicateJSONKeyError(ValueError):
    pass


def validate_feedback_archive(
    payload: bytes,
    *,
    expected_platform: str,
    expected_app_version: str,
    includes_user_note: bool,
    includes_screenshot: bool,
) -> FeedbackArchiveSummary:
    if not payload:
        raise FeedbackArchiveRejectedError("feedback archive is empty")
    try:
        archive = zipfile.ZipFile(io.BytesIO(payload))
    except (OSError, zipfile.BadZipFile):
        raise FeedbackArchiveRejectedError(
            "feedback archive is not a valid ZIP"
        ) from None

    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        platform_optional = _PLATFORM_OPTIONAL_NAMES.get(expected_platform)
        if platform_optional is None:
            raise FeedbackArchiveRejectedError("feedback archive platform is invalid")
        allowed_names = _REQUIRED_NAMES | _COMMON_OPTIONAL_NAMES | platform_optional
        if not 1 <= len(infos) <= _MAX_FILES:
            raise FeedbackArchiveRejectedError("feedback archive file count is invalid")
        if len(names) != len(set(names)):
            raise FeedbackArchiveRejectedError(
                "feedback archive contains duplicate files"
            )
        if any(
            info.is_dir()
            or info.filename not in allowed_names
            or "/" in info.filename
            or "\\" in info.filename
            or not _is_regular_zip_entry(info)
            or info.flag_bits & 0x1
            or info.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
            for info in infos
        ):
            raise FeedbackArchiveRejectedError(
                "feedback archive contains an invalid file"
            )
        if not _REQUIRED_NAMES.issubset(names):
            raise FeedbackArchiveRejectedError(
                "feedback archive is missing required files"
            )
        if expected_platform == "ios" and "feedback-manifest.json" not in names:
            raise FeedbackArchiveRejectedError(
                "feedback archive is missing its manifest"
            )
        if ("user-note.txt" in names) != includes_user_note:
            raise FeedbackArchiveRejectedError("feedback note consent does not match")
        if ("screenshot.png" in names) != includes_screenshot:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot consent does not match"
            )

        uncompressed_bytes = sum(info.file_size for info in infos)
        if uncompressed_bytes > _MAX_UNCOMPRESSED_BYTES:
            raise FeedbackArchiveRejectedError(
                "feedback archive expands beyond its limit"
            )

        contents: dict[str, bytes] = {}
        for info in infos:
            entry_limit = _ENTRY_LIMITS[info.filename]
            if (
                info.file_size <= 0
                or info.compress_size < 0
                or info.file_size > entry_limit
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback archive contains an oversized file"
                )
            try:
                with archive.open(info) as source:
                    data = source.read(entry_limit + 1)
            except (EOFError, OSError, RuntimeError, zipfile.BadZipFile, zlib.error):
                raise FeedbackArchiveRejectedError(
                    "feedback archive file cannot be decoded"
                ) from None
            if len(data) != info.file_size or len(data) > entry_limit:
                raise FeedbackArchiveRejectedError(
                    "feedback archive file length is invalid"
                )
            contents[info.filename] = data

    screenshot = contents.get("screenshot.png")
    if screenshot is not None:
        _validate_png(screenshot)

    text_contents: dict[str, str] = {}
    for name, data in contents.items():
        if name == "screenshot.png":
            continue
        text_contents[name] = _decode_text(data)

    _validate_metadata(
        text_contents["meta.json"],
        expected_platform=expected_platform,
        expected_app_version=expected_app_version,
    )
    _validate_plain_generated_text(
        "report.txt",
        text_contents["report.txt"],
    )
    for name in _JSONL_NAMES & text_contents.keys():
        _validate_jsonl(name, text_contents[name])
    if "last-crash.txt" in text_contents:
        _validate_plain_generated_text(
            "last-crash.txt",
            text_contents["last-crash.txt"],
        )
    if "user-note.txt" in text_contents and not text_contents[
        "user-note.txt"
    ].startswith("User-provided context (optional)\n\n"):
        raise FeedbackArchiveRejectedError("feedback user note is invalid")

    manifest_data = contents.get("feedback-manifest.json")
    if manifest_data is not None:
        _validate_apple_manifest(
            text_contents["feedback-manifest.json"],
            contents=contents,
            expected_app_version=expected_app_version,
            includes_user_note=includes_user_note,
            includes_screenshot=includes_screenshot,
        )

    return FeedbackArchiveSummary(
        file_count=len(contents),
        uncompressed_bytes=uncompressed_bytes,
        includes_user_note=includes_user_note,
        includes_screenshot=includes_screenshot,
    )


def _decode_text(payload: bytes) -> str:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        raise FeedbackArchiveRejectedError(
            "feedback text attachment is not UTF-8"
        ) from None
    if any(
        (ord(character) < 0x20 and character not in "\n\r\t") or ord(character) == 0x7F
        for character in text
    ):
        raise FeedbackArchiveRejectedError(
            "feedback text attachment contains control data"
        )
    return text


def _load_json(payload: str, error_message: str) -> Any:
    try:
        return json.loads(
            payload,
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, _DuplicateJSONKeyError, ValueError):
        raise FeedbackArchiveRejectedError(error_message) from None


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateJSONKeyError(key)
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise ValueError(value)


def _validate_metadata(
    payload: str,
    *,
    expected_platform: str,
    expected_app_version: str,
) -> None:
    metadata = _load_json(payload, "feedback metadata is invalid")
    if not isinstance(metadata, dict):
        raise FeedbackArchiveRejectedError("feedback metadata is invalid")
    keys = set(metadata)
    if keys - _META_ALLOWED_KEYS:
        raise FeedbackArchiveRejectedError(
            "feedback metadata contains an unknown field"
        )
    if not _META_REQUIRED_KEYS.issubset(keys):
        raise FeedbackArchiveRejectedError(
            "feedback metadata is missing a required field"
        )

    expected_metadata_platform = {
        "ios": "iOS",
        "android": "Android",
    }[expected_platform]
    if (
        not _is_exact_int(metadata["schema"], 1)
        or metadata["platform"] != expected_metadata_platform
        or metadata["test_profile"] != "app-hang"
        or metadata["redaction"] != "v2"
        or metadata["questionnaire"] != {}
    ):
        raise FeedbackArchiveRejectedError(
            "feedback metadata does not match an app report"
        )

    app_version = metadata.get("app_version")
    if app_version is not None and (
        app_version != expected_app_version
        or _SAFE_TOKEN_RE.fullmatch(app_version) is None
    ):
        raise FeedbackArchiveRejectedError(
            "feedback metadata app version does not match"
        )

    _validate_optional_token(metadata, "app_build")
    for key in (
        "os_version",
        "device_hardware",
        "strap_model",
        "strap_firmware",
        "device_family",
        "device_variant",
    ):
        _validate_optional_label(metadata, key)

    source = metadata.get("source")
    if source is not None and source != ["App runtime diagnostics"]:
        raise FeedbackArchiveRejectedError("feedback metadata source is invalid")
    for key in ("profile_started_at", "capture_started_at"):
        if key in metadata and metadata[key] is not None:
            raise FeedbackArchiveRejectedError(
                "feedback metadata contains an unrelated capture timestamp"
            )
    capture_ended_at = metadata.get("capture_ended_at")
    if capture_ended_at is not None and not _is_timestamp(capture_ended_at):
        raise FeedbackArchiveRejectedError(
            "feedback metadata capture timestamp is invalid"
        )

    storage = metadata["storage"]
    if not isinstance(storage, dict) or set(storage) != _STORAGE_KEYS:
        raise FeedbackArchiveRejectedError("feedback metadata storage shape is invalid")
    if storage["rows"] != {}:
        raise FeedbackArchiveRejectedError(
            "feedback metadata contains row-level storage detail"
        )
    for key in ("db_bytes", "raw_capture_bytes"):
        if not _is_bounded_int(storage[key], minimum=0):
            raise FeedbackArchiveRejectedError(
                "feedback metadata storage value is invalid"
            )

    if "build" in metadata:
        _validate_build_metadata(metadata["build"])
    if "capabilities" in metadata:
        _validate_capability_metadata(metadata["capabilities"])
    if "truncated" in metadata and not isinstance(metadata["truncated"], bool):
        raise FeedbackArchiveRejectedError(
            "feedback metadata truncation flag is invalid"
        )
    if "capture_check" in metadata:
        _validate_capture_check(metadata["capture_check"])


def _validate_optional_token(metadata: dict[str, Any], key: str) -> None:
    if key not in metadata or metadata[key] is None:
        return
    value = metadata[key]
    if not isinstance(value, str) or _SAFE_TOKEN_RE.fullmatch(value) is None:
        raise FeedbackArchiveRejectedError(
            "feedback metadata contains an invalid build value"
        )
    _reject_sensitive_text(value)


def _validate_optional_label(metadata: dict[str, Any], key: str) -> None:
    if key not in metadata or metadata[key] is None:
        return
    value = metadata[key]
    if not isinstance(value, str) or _SAFE_LABEL_RE.fullmatch(value) is None:
        raise FeedbackArchiveRejectedError(
            "feedback metadata contains an invalid device value"
        )
    _reject_sensitive_text(value)


def _validate_build_metadata(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != _BUILD_KEYS:
        raise FeedbackArchiveRejectedError("feedback metadata build shape is invalid")
    channel = value["channel"]
    if (
        not isinstance(channel, str)
        or _SAFE_LABEL_RE.fullmatch(channel) is None
        or not isinstance(value["signed"], bool)
    ):
        raise FeedbackArchiveRejectedError("feedback metadata build value is invalid")
    _reject_sensitive_text(channel)


def _validate_capability_metadata(value: Any) -> None:
    if not isinstance(value, dict) or set(value) - _CAPABILITY_KEYS:
        raise FeedbackArchiveRejectedError(
            "feedback metadata capabilities shape is invalid"
        )
    for key, capability in value.items():
        if key == "app_group_identifier":
            if capability is not None and (
                not isinstance(capability, str)
                or _SAFE_TOKEN_RE.fullmatch(capability) is None
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback metadata capability value is invalid"
                )
            if capability is not None:
                _reject_sensitive_text(capability)
            continue
        if key == "background_refresh":
            if capability is not None and (
                not isinstance(capability, str)
                or _SAFE_LABEL_RE.fullmatch(capability) is None
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback metadata capability value is invalid"
                )
            if capability is not None:
                _reject_sensitive_text(capability)
            continue
        if capability is not None and not isinstance(capability, bool):
            raise FeedbackArchiveRejectedError(
                "feedback metadata capability value is invalid"
            )


def _validate_capture_check(value: Any) -> None:
    if value == []:
        return
    if not isinstance(value, dict) or set(value) != {"complete", "traces"}:
        raise FeedbackArchiveRejectedError("feedback metadata capture check is invalid")
    traces = value["traces"]
    if (
        not isinstance(value["complete"], bool)
        or not isinstance(traces, dict)
        or traces
    ):
        raise FeedbackArchiveRejectedError("feedback metadata capture check is invalid")


def _validate_plain_generated_text(name: str, text: str) -> None:
    expected_prefix = {
        "report.txt": "NOOP app runtime report\n",
        "last-crash.txt": "schema: noop.android.crash.v2\n",
    }[name]
    if not text.startswith(expected_prefix):
        raise FeedbackArchiveRejectedError(
            "feedback generated text has an invalid schema"
        )
    _reject_sensitive_text(text)


def _validate_jsonl(name: str, text: str) -> None:
    lines = text.splitlines()
    if not lines or len(lines) > _MAX_JSONL_LINES:
        raise FeedbackArchiveRejectedError("feedback diagnostic event count is invalid")
    for line in lines:
        if not line or len(line.encode("utf-8")) > _MAX_JSONL_LINE_BYTES:
            raise FeedbackArchiveRejectedError(
                "feedback diagnostic event length is invalid"
            )
        record = _load_json(line, "feedback diagnostic event is invalid")
        if not isinstance(record, dict):
            raise FeedbackArchiveRejectedError("feedback diagnostic event is invalid")
        event = record.get("event")
        if (
            name == "apple-performance-diagnostics.jsonl"
            and isinstance(event, str)
            and event.startswith("metrickit.")
        ):
            _validate_metrickit_record(record)
        else:
            _validate_operational_record(record)


def _validate_operational_record(record: dict[str, Any]) -> None:
    allowed_keys = {"schema", "at", "uptime_ms", "event", "fields", "resources"}
    if set(record) - allowed_keys:
        raise FeedbackArchiveRejectedError(
            "feedback diagnostic event contains an unknown field"
        )
    if "schema" in record and not _is_exact_int(record["schema"], 1):
        raise FeedbackArchiveRejectedError(
            "feedback diagnostic event schema is invalid"
        )
    event = record.get("event")
    if not isinstance(event, str) or _SAFE_TOKEN_RE.fullmatch(event) is None:
        raise FeedbackArchiveRejectedError("feedback diagnostic event name is invalid")
    if "at" in record and not _is_timestamp(record["at"]):
        raise FeedbackArchiveRejectedError(
            "feedback diagnostic event timestamp is invalid"
        )
    if "uptime_ms" in record and not _is_bounded_int(
        record["uptime_ms"],
        minimum=0,
    ):
        raise FeedbackArchiveRejectedError(
            "feedback diagnostic event uptime is invalid"
        )
    if "fields" in record:
        _validate_diagnostic_fields(record["fields"])
    if "resources" in record:
        _validate_resource_snapshot(record["resources"])


def _validate_metrickit_record(record: dict[str, Any]) -> None:
    if set(record) != {"schema", "at", "event", "payload"}:
        raise FeedbackArchiveRejectedError(
            "feedback performance diagnostic shape is invalid"
        )
    if (
        not _is_exact_int(record["schema"], 1)
        or record["event"] not in {"metrickit.metric", "metrickit.diagnostic"}
        or not _is_timestamp(record["at"])
    ):
        raise FeedbackArchiveRejectedError(
            "feedback performance diagnostic wrapper is invalid"
        )
    node_count = [0]
    _validate_json_value(
        record["payload"],
        depth=0,
        node_count=node_count,
        allow_binary_identifiers=True,
    )


def _validate_diagnostic_fields(value: Any) -> None:
    if not isinstance(value, dict) or len(value) > 24:
        raise FeedbackArchiveRejectedError("feedback diagnostic fields are invalid")
    for key, field_value in value.items():
        if (
            not isinstance(key, str)
            or _SAFE_TOKEN_RE.fullmatch(key) is None
            or _is_forbidden_key(key)
            or not isinstance(field_value, str)
            or len(field_value.encode("utf-8")) > 512
        ):
            raise FeedbackArchiveRejectedError("feedback diagnostic fields are invalid")
        _reject_sensitive_text(field_value)


def _validate_resource_snapshot(value: Any) -> None:
    if not isinstance(value, dict) or set(value) - _RESOURCE_KEYS:
        raise FeedbackArchiveRejectedError("feedback diagnostic resources are invalid")
    for key, resource_value in value.items():
        if key == "low_power_mode":
            valid = isinstance(resource_value, bool)
        elif key in _RESOURCE_LABEL_KEYS:
            valid = (
                isinstance(resource_value, str)
                and _SAFE_TOKEN_RE.fullmatch(resource_value) is not None
            )
        else:
            valid = _is_bounded_int(resource_value, minimum=-1)
        if not valid:
            raise FeedbackArchiveRejectedError(
                "feedback diagnostic resources are invalid"
            )


def _validate_json_value(
    value: Any,
    *,
    depth: int,
    node_count: list[int],
    allow_binary_identifiers: bool,
) -> None:
    node_count[0] += 1
    if depth > _MAX_JSON_DEPTH or node_count[0] > _MAX_JSON_NODES:
        raise FeedbackArchiveRejectedError(
            "feedback performance diagnostic is too complex"
        )
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if not -(2**63) <= value <= 2**63 - 1:
            raise FeedbackArchiveRejectedError(
                "feedback performance diagnostic number is invalid"
            )
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise FeedbackArchiveRejectedError(
                "feedback performance diagnostic number is invalid"
            )
        return
    if isinstance(value, str):
        if len(value.encode("utf-8")) > _MAX_JSON_STRING_BYTES:
            raise FeedbackArchiveRejectedError(
                "feedback performance diagnostic string is too large"
            )
        _reject_sensitive_text(
            value,
            allow_binary_identifiers=allow_binary_identifiers,
        )
        return
    if isinstance(value, list):
        if len(value) > 4_096:
            raise FeedbackArchiveRejectedError(
                "feedback performance diagnostic list is too large"
            )
        for item in value:
            _validate_json_value(
                item,
                depth=depth + 1,
                node_count=node_count,
                allow_binary_identifiers=allow_binary_identifiers,
            )
        return
    if isinstance(value, dict):
        if len(value) > 512:
            raise FeedbackArchiveRejectedError(
                "feedback performance diagnostic object is too large"
            )
        for key, item in value.items():
            if (
                not isinstance(key, str)
                or not 1 <= len(key.encode("utf-8")) <= 128
                or _is_forbidden_key(key)
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback performance diagnostic field is invalid"
                )
            _validate_json_value(
                item,
                depth=depth + 1,
                node_count=node_count,
                allow_binary_identifiers=allow_binary_identifiers,
            )
        return
    raise FeedbackArchiveRejectedError(
        "feedback performance diagnostic value is invalid"
    )


def _is_forbidden_key(key: str) -> bool:
    normalized = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", key)
    normalized = normalized.lower().replace("-", "_").replace(".", "_")
    return normalized in _EXACT_HEALTH_KEY_NAMES or any(
        fragment in normalized for fragment in _FORBIDDEN_KEY_PARTS
    )


def _reject_sensitive_text(
    text: str,
    *,
    allow_binary_identifiers: bool = False,
) -> None:
    pattern_groups = (
        _CREDENTIAL_PATTERNS,
        _HEALTH_VALUE_PATTERNS,
        _LOCATION_VALUE_PATTERNS,
        _CONTACT_PATTERNS,
        _DYNAMIC_PATH_PATTERNS,
    )
    if any(pattern.search(text) for group in pattern_groups for pattern in group):
        raise FeedbackArchiveRejectedError(
            "feedback generated diagnostics contain prohibited private data"
        )
    if not allow_binary_identifiers and any(
        pattern.search(text) for pattern in _IDENTIFIER_PATTERNS
    ):
        raise FeedbackArchiveRejectedError(
            "feedback generated diagnostics contain prohibited private data"
        )


def _is_exact_int(value: Any, expected: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value == expected


def _is_bounded_int(
    value: Any,
    *,
    minimum: int,
    maximum: int = 2**63 - 1,
) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and minimum <= value <= maximum
    )


def _is_timestamp(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= 64
        and _ISO8601_RE.fullmatch(value) is not None
    )


def _is_regular_zip_entry(info: zipfile.ZipInfo) -> bool:
    unix_mode = (info.external_attr >> 16) & 0o170000
    return unix_mode in {0, 0o100000}


def _validate_png(payload: bytes) -> None:
    if not payload.startswith(_PNG_SIGNATURE):
        raise FeedbackArchiveRejectedError("feedback screenshot is not a PNG")

    position = len(_PNG_SIGNATURE)
    ihdr: tuple[int, int, int, int] | None = None
    palette_entries: int | None = None
    transparency_bytes: int | None = None
    compressed = bytearray()
    seen_chunks: set[bytes] = set()
    idat_started = False
    idat_closed = False
    found_iend = False

    while position < len(payload):
        if len(payload) - position < 12:
            raise FeedbackArchiveRejectedError("feedback screenshot is truncated")
        chunk_length = struct.unpack_from(">I", payload, position)[0]
        chunk_type = payload[position + 4 : position + 8]
        chunk_end = position + 12 + chunk_length
        if (
            chunk_length > _MAX_PNG_CHUNK_BYTES
            or chunk_end > len(payload)
            or not _is_png_chunk_type(chunk_type)
        ):
            raise FeedbackArchiveRejectedError(
                "feedback screenshot has an invalid PNG chunk"
            )
        chunk_data = payload[position + 8 : position + 8 + chunk_length]
        expected_crc = struct.unpack_from(">I", payload, position + 8 + chunk_length)[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(chunk_data, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot has an invalid PNG checksum"
            )
        position = chunk_end

        if idat_started and chunk_type != b"IDAT":
            idat_closed = True

        if chunk_type == b"IHDR":
            if seen_chunks or chunk_length != 13:
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot has an invalid PNG header"
                )
            width, height, bit_depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", chunk_data)
            )
            if (
                width <= 0
                or height <= 0
                or width > _MAX_PNG_DIMENSION
                or height > _MAX_PNG_DIMENSION
                or width * height > _MAX_PNG_PIXELS
                or bit_depth != 8
                or color_type not in {0, 2, 3, 4, 6}
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot dimensions or format are invalid"
                )
            ihdr = (width, height, bit_depth, color_type)
        elif chunk_type == b"PLTE":
            if (
                ihdr is None
                or idat_started
                or chunk_type in seen_chunks
                or chunk_length == 0
                or chunk_length % 3 != 0
                or chunk_length > 768
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot palette is invalid"
                )
            palette_entries = chunk_length // 3
        elif chunk_type == b"tRNS":
            if ihdr is None or idat_started or chunk_type in seen_chunks:
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot transparency is invalid"
                )
            transparency_bytes = chunk_length
        elif chunk_type in {b"gAMA", b"cHRM", b"sRGB", b"pHYs"}:
            if (
                ihdr is None
                or idat_started
                or chunk_type in seen_chunks
                or not _valid_png_ancillary_chunk(chunk_type, chunk_data)
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot metadata is invalid"
                )
        elif chunk_type == b"IDAT":
            if ihdr is None or idat_closed:
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot image data is invalid"
                )
            idat_started = True
            compressed.extend(chunk_data)
            if len(compressed) > _MAX_SCREENSHOT_BYTES:
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot image data is oversized"
                )
        elif chunk_type == b"IEND":
            if (
                ihdr is None
                or not idat_started
                or chunk_length != 0
                or chunk_type in seen_chunks
                or position != len(payload)
            ):
                raise FeedbackArchiveRejectedError(
                    "feedback screenshot ending is invalid"
                )
            found_iend = True
            seen_chunks.add(chunk_type)
            break
        else:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot contains an unsupported PNG chunk"
            )
        seen_chunks.add(chunk_type)

    if not found_iend or ihdr is None:
        raise FeedbackArchiveRejectedError("feedback screenshot is truncated")

    width, height, _, color_type = ihdr
    if color_type == 3 and palette_entries is None:
        raise FeedbackArchiveRejectedError("feedback screenshot palette is missing")
    if color_type in {0, 4} and palette_entries is not None:
        raise FeedbackArchiveRejectedError("feedback screenshot palette is invalid")
    if transparency_bytes is not None:
        valid_transparency = (
            (color_type == 0 and transparency_bytes == 2)
            or (color_type == 2 and transparency_bytes == 6)
            or (
                color_type == 3
                and palette_entries is not None
                and 1 <= transparency_bytes <= palette_entries
            )
        )
        if not valid_transparency:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot transparency is invalid"
            )

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    row_bytes = width * channels
    expected_bytes = height * (row_bytes + 1)
    if expected_bytes > _MAX_PNG_DECODED_BYTES:
        raise FeedbackArchiveRejectedError(
            "feedback screenshot decoded size is oversized"
        )
    try:
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(bytes(compressed), expected_bytes + 1)
        if decoder.unconsumed_tail or len(decoded) > expected_bytes:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot decoded size is invalid"
            )
        decoded += decoder.flush(expected_bytes + 1 - len(decoded))
    except zlib.error:
        raise FeedbackArchiveRejectedError(
            "feedback screenshot image data cannot be decoded"
        ) from None
    if (
        len(decoded) != expected_bytes
        or not decoder.eof
        or decoder.unused_data
        or decoder.unconsumed_tail
    ):
        raise FeedbackArchiveRejectedError(
            "feedback screenshot image data is truncated"
        )

    offset = 0
    previous = bytearray(row_bytes) if color_type == 3 else None
    for _ in range(height):
        filter_type = decoded[offset]
        offset += 1
        source = decoded[offset : offset + row_bytes]
        offset += row_bytes
        if filter_type > 4:
            raise FeedbackArchiveRejectedError(
                "feedback screenshot uses an invalid PNG filter"
            )
        if color_type != 3:
            continue

        assert previous is not None
        current = bytearray(row_bytes)
        for index, byte in enumerate(source):
            left = current[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                value = byte
            elif filter_type == 1:
                value = byte + left
            elif filter_type == 2:
                value = byte + above
            elif filter_type == 3:
                value = byte + ((left + above) // 2)
            elif filter_type == 4:
                value = byte + _paeth_predictor(left, above, upper_left)
            current[index] = value & 0xFF
        if palette_entries is not None and any(
            index >= palette_entries for index in current
        ):
            raise FeedbackArchiveRejectedError(
                "feedback screenshot contains an invalid palette index"
            )
        previous = current


def _is_png_chunk_type(value: bytes) -> bool:
    return (
        len(value) == 4
        and all(
            ord("A") <= byte <= ord("Z") or ord("a") <= byte <= ord("z")
            for byte in value
        )
        and not (value[2] & 0x20)
    )


def _valid_png_ancillary_chunk(chunk_type: bytes, data: bytes) -> bool:
    if chunk_type == b"gAMA":
        return len(data) == 4 and struct.unpack(">I", data)[0] != 0
    if chunk_type == b"cHRM":
        return len(data) == 32
    if chunk_type == b"sRGB":
        return len(data) == 1 and data[0] <= 3
    if chunk_type == b"pHYs":
        return (
            len(data) == 9
            and struct.unpack(">I", data[:4])[0] > 0
            and struct.unpack(">I", data[4:8])[0] > 0
            and data[8] in {0, 1}
        )
    return False


def _paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _validate_apple_manifest(
    payload: str,
    *,
    contents: dict[str, bytes],
    expected_app_version: str,
    includes_user_note: bool,
    includes_screenshot: bool,
) -> None:
    manifest = _load_json(payload, "feedback manifest is invalid")
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema_version",
        "platform",
        "app_version",
        "created_at",
        "includes_user_note",
        "includes_screenshot",
        "entries",
    }:
        raise FeedbackArchiveRejectedError("feedback manifest is invalid")
    created_at = manifest.get("created_at")
    if (
        manifest.get("schema_version") != 1
        or manifest.get("platform") != "ios"
        or manifest.get("app_version") != expected_app_version
        or manifest.get("includes_user_note") is not includes_user_note
        or manifest.get("includes_screenshot") is not includes_screenshot
        or not _is_timestamp(created_at)
    ):
        raise FeedbackArchiveRejectedError(
            "feedback manifest does not match its reservation"
        )

    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise FeedbackArchiveRejectedError("feedback manifest is invalid")
    expected_names = set(contents) - {"feedback-manifest.json"}
    if len(entries) != len(expected_names):
        raise FeedbackArchiveRejectedError(
            "feedback manifest entry count does not match"
        )
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "name",
            "bytes",
            "sha256",
        }:
            raise FeedbackArchiveRejectedError("feedback manifest entry is invalid")
        name = entry.get("name")
        size = entry.get("bytes")
        digest = entry.get("sha256")
        if (
            not isinstance(name, str)
            or name not in expected_names
            or name in seen
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size != len(contents[name])
            or not isinstance(digest, str)
            or _SHA256_RE.fullmatch(digest) is None
            or digest != hashlib.sha256(contents[name]).hexdigest()
        ):
            raise FeedbackArchiveRejectedError("feedback manifest entry does not match")
        seen.add(name)
    if seen != expected_names:
        raise FeedbackArchiveRejectedError("feedback manifest entries do not match")
