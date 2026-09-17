from __future__ import annotations

import base64
import hashlib
import io
import json
import struct
import zipfile
import zlib
from typing import Any

import pytest

from app.feedback_archive import (
    FeedbackArchiveRejectedError,
    validate_feedback_archive,
)


_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_METADATA_BEARING_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAACxlWElmTk9PUCBzeW50aGV0aWMgbWV0YWRhdGEgdGhhdCBtdXN0IGJlIHJlbW92ZWQJg4JOAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAHGlET1QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQhYJ0AAAABFJREFUeJxjUEhY8B+EGWAMAEa0CH0mQ0nfAAAAAElFTkSuQmCC"
)
_SANITIZED_MOBILE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAAlwSFlzAAALEwAACxMBAJqcGAAAABFJREFUeJxjUEhY8B+EGWAMAEa0CH0mQ0nfAAAAAElFTkSuQmCC"
)


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(data, checksum) & 0xFFFFFFFF
    return (
        struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", checksum)
    )


def _png(*, width: int = 2, height: int = 2) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    row = b"\x00" + bytes((32, 96, 160, 255)) * width
    pixels = row * height
    return (
        _PNG_SIGNATURE
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(pixels))
        + _png_chunk(b"IEND", b"")
    )


def _metadata(platform: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "schema": 1,
        "app_version": "9.2.0",
        "platform": platform,
        "os_version": "18.6" if platform == "iOS" else "16",
        "strap_model": "NOOP Band",
        "source": ["App runtime diagnostics"],
        "test_profile": "app-hang",
        "profile_started_at": None,
        "questionnaire": {},
        "build": {
            "channel": "TestFlight" if platform == "iOS" else "GitHub",
            "signed": platform == "iOS",
        },
        "storage": {
            "db_bytes": 42,
            "raw_capture_bytes": 0,
            "rows": {},
        },
        "redaction": "v2",
        "truncated": False,
        "capture_check": (
            []
            if platform == "iOS"
            else {
                "complete": True,
                "traces": {},
            }
        ),
    }
    if platform == "iOS":
        metadata.update(
            {
                "app_build": "920",
                "device_hardware": "iPhone17,2",
                "capture_started_at": None,
                "capture_ended_at": "2026-09-12T12:00:00Z",
                "capabilities": {
                    "healthkit_entitled": True,
                    "healthkit_background_delivery_entitled": True,
                    "app_group_identifier": "group.com.noopapp.noop",
                    "app_group_container_available": True,
                    "bluetooth_central_background_mode": True,
                    "location_background_mode": False,
                    "background_fetch_mode": True,
                    "protected_data_available": True,
                    "background_refresh": "Available",
                },
            }
        )
    return metadata


def _session_event() -> bytes:
    return (
        json.dumps(
            {
                "schema": 1,
                "at": "2026-09-12T12:00:00.123Z",
                "uptime_ms": 12_345,
                "event": "process.launch",
                "fields": {
                    "app_version": "9.2.0",
                    "outcome": "completed",
                },
                "resources": {
                    "memory_mb": 128,
                    "database_bytes": 42,
                    "disk_available_bytes": 1_024,
                    "thermal_state": "nominal",
                    "low_power_mode": False,
                },
            },
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def _archive(
    *,
    platform: str = "iOS",
    note: bytes | None = None,
    screenshot: bytes | None = None,
    metadata: dict[str, Any] | None = None,
    report: bytes = b"NOOP app runtime report\n",
    additions: dict[str, bytes] | None = None,
) -> bytes:
    entries = {
        "report.txt": report,
        "meta.json": json.dumps(metadata or _metadata(platform)).encode("utf-8"),
        "app-session-current.jsonl": _session_event(),
    }
    if note is not None:
        entries["user-note.txt"] = note
    if screenshot is not None:
        entries["screenshot.png"] = screenshot
    entries.update(additions or {})
    if platform == "iOS":
        manifest = {
            "schema_version": 1,
            "platform": "ios",
            "app_version": "9.2.0",
            "created_at": "2026-09-12T12:00:00Z",
            "includes_user_note": note is not None,
            "includes_screenshot": screenshot is not None,
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


def _validate(
    payload: bytes,
    *,
    platform: str = "ios",
    note: bool = False,
    screenshot: bool = False,
):
    return validate_feedback_archive(
        payload,
        expected_platform=platform,
        expected_app_version="9.2.0",
        includes_user_note=note,
        includes_screenshot=screenshot,
    )


def test_feedback_archive_accepts_reviewed_app_report_with_decoded_png() -> None:
    summary = _validate(
        _archive(
            note=b"User-provided context (optional)\n\npaused once\n",
            screenshot=_png(),
        ),
        note=True,
        screenshot=True,
    )

    assert summary.file_count == 6
    assert summary.includes_user_note is True
    assert summary.includes_screenshot is True


def test_feedback_archive_accepts_sanitized_mobile_png_only() -> None:
    summary = _validate(
        _archive(screenshot=_SANITIZED_MOBILE_PNG),
        screenshot=True,
    )
    assert summary.includes_screenshot is True

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(screenshot=_METADATA_BEARING_PNG),
            screenshot=True,
        )


def test_feedback_archive_accepts_android_operational_diagnostics() -> None:
    exit_history = (
        b'{"schema":1,"at":"2026-09-12T11:00:00Z",'
        b'"event":"process.historical_exit",'
        b'"fields":{"reason":"low_memory","status":"0","rss_kb":"2048"}}\n'
    )
    crash = (
        b"schema: noop.android.crash.v2\n"
        b"captured_at: 2026-09-12T11:00:00Z\n"
        b"thread_kind: main\n"
        b"exception_0: java.lang.IllegalStateException\n"
        b"frame_count: 1\n"
    )

    summary = _validate(
        _archive(
            platform="Android",
            additions={
                "android-exit-history.jsonl": exit_history,
                "last-crash.txt": crash,
            },
        ),
        platform="android",
    )

    assert summary.file_count == 5


def test_feedback_archive_accepts_bounded_metrickit_payload() -> None:
    diagnostic = {
        "schema": 1,
        "at": "2026-09-12T12:00:00Z",
        "event": "metrickit.diagnostic",
        "payload": {
            "timeStampBegin": "2026-09-11T12:00:00Z",
            "callStackTree": {
                "binaryUUID": "123e4567-e89b-42d3-a456-426614174000",
                "offsetIntoBinaryTextSegment": 4096,
            },
        },
    }

    summary = _validate(
        _archive(
            additions={
                "apple-performance-diagnostics.jsonl": (
                    json.dumps(diagnostic).encode("utf-8") + b"\n"
                )
            }
        )
    )

    assert summary.file_count == 5


@pytest.mark.parametrize(
    "addition",
    [
        {"wearable.sqlite": b"database"},
        {"raw-capture.jsonl": b'{"hr":120}'},
        {"../report.txt": b"path traversal"},
    ],
)
def test_feedback_archive_rejects_unknown_raw_and_nested_attachments(
    addition: dict[str, bytes],
) -> None:
    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(_archive(additions=addition))


def test_feedback_archive_requires_consent_flags_to_match_frozen_files() -> None:
    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(
                note=b"User-provided context (optional)\n\npaused once\n",
            )
        )


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("debug_dump", {"anything": "unexpected"}),
        ("heart_rate", 187),
        ("latitude", 37.774929),
    ],
)
def test_feedback_archive_rejects_unknown_or_exact_meta_fields(
    key: str,
    value: Any,
) -> None:
    metadata = _metadata("iOS")
    metadata[key] = value

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(_archive(metadata=metadata))


def test_feedback_archive_rejects_exact_health_timestamp_in_storage() -> None:
    metadata = _metadata("Android")
    metadata["storage"]["latest_hr_unix"] = 1_789_200_000

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(platform="Android", metadata=metadata),
            platform="android",
        )


@pytest.mark.parametrize(
    "fields",
    [
        {"outcome": "Authorization: Bearer abcdefghijklmnop"},
        {"heart_rate": "187"},
        {"outcome": "latitude=37.774929 longitude=-122.419416"},
    ],
)
def test_feedback_archive_rejects_private_diagnostic_fields(
    fields: dict[str, str],
) -> None:
    event = {
        "schema": 1,
        "at": "2026-09-12T12:00:00Z",
        "uptime_ms": 123,
        "event": "operation.end",
        "fields": fields,
    }

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(
                additions={
                    "app-session-current.jsonl": (
                        json.dumps(event).encode("utf-8") + b"\n"
                    )
                }
            )
        )


def test_feedback_archive_rejects_credential_in_plain_report() -> None:
    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(
                report=(
                    b"NOOP app runtime report\nclient_secret=do-not-upload-this-value\n"
                )
            )
        )


@pytest.mark.parametrize(
    "phone_number",
    ["415-555-0100", "(415) 555-0100"],
)
@pytest.mark.parametrize("evidence_name", ["report", "jsonl"])
def test_feedback_archive_rejects_formatted_phone_in_generated_evidence(
    phone_number: str,
    evidence_name: str,
) -> None:
    if evidence_name == "report":
        payload = _archive(
            report=(
                f"NOOP app runtime report\ncallback target: {phone_number}\n"
            ).encode("utf-8")
        )
    else:
        event = {
            "schema": 1,
            "at": "2026-09-12T12:00:00Z",
            "event": "operation.end",
            "fields": {"outcome": f"callback target {phone_number}"},
        }
        payload = _archive(
            additions={
                "app-session-current.jsonl": (json.dumps(event).encode("utf-8") + b"\n")
            }
        )

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(payload)


@pytest.mark.parametrize(
    "phone_number",
    ["415-555-0100", "(415) 555-0100"],
)
def test_feedback_archive_keeps_intentional_user_note_exempt_from_phone_scan(
    phone_number: str,
) -> None:
    summary = _validate(
        _archive(
            note=(
                f"User-provided context (optional)\n\nPlease call {phone_number}.\n"
            ).encode("utf-8")
        ),
        note=True,
    )

    assert summary.includes_user_note is True


@pytest.mark.parametrize(
    "screenshot",
    [
        _PNG_SIGNATURE + b"\x00" * 32,
        _png()[:-5],
        _png() + b"trailing",
        _png(width=8_193, height=1),
    ],
    ids=["signature-only", "truncated", "trailing-data", "oversized-dimension"],
)
def test_feedback_archive_rejects_invalid_png_content(screenshot: bytes) -> None:
    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(screenshot=screenshot),
            screenshot=True,
        )


def test_feedback_archive_rejects_png_with_invalid_decompressed_rows() -> None:
    header = struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)
    payload = (
        _PNG_SIGNATURE
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(b"\x00too short"))
        + _png_chunk(b"IEND", b"")
    )

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(_archive(screenshot=payload), screenshot=True)


def test_feedback_archive_rejects_cross_platform_diagnostics() -> None:
    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(
            _archive(
                additions={
                    "android-exit-history.jsonl": (
                        b'{"schema":1,"event":"process.historical_exit"}\n'
                    ),
                },
            )
        )


def test_feedback_archive_rejects_tampered_apple_manifest() -> None:
    payload = _archive()
    source = zipfile.ZipFile(io.BytesIO(payload))
    output = io.BytesIO()
    with source, zipfile.ZipFile(output, "w") as archive:
        for info in source.infolist():
            data = source.read(info)
            if info.filename == "feedback-manifest.json":
                manifest = json.loads(data)
                manifest["entries"][0]["sha256"] = "0" * 64
                data = json.dumps(manifest).encode("utf-8")
            archive.writestr(info.filename, data)

    with pytest.raises(FeedbackArchiveRejectedError):
        _validate(output.getvalue())
