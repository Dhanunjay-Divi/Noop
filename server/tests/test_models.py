from __future__ import annotations

from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.models import InstallationCredentialBootstrap, SyncPayload


def minimal_payload() -> dict:
    return {
        "schema_version": 1,
        "batch_id": str(uuid4()),
        "source": {
            "device_id": "device-1",
            "sent_at": "2026-07-24T12:00:00Z",
            "platform": "other",
            "metadata": {
                "installation_id": "test-installation",
                "logical_source_id": "device-1",
                "namespace": "strap_measured",
                "paired_device_id": "device-1",
                "privacy": "explicit_opt_in",
                "score_provenance": "strap_measured",
            },
        },
        "streams": {},
        "daily_metrics": {},
        "sleep_sessions": [],
        "workouts": [],
        "journal": [],
    }


def test_timestamps_require_explicit_offset() -> None:
    payload = minimal_payload()
    payload["source"]["sent_at"] = "2026-07-24T12:00:00"
    with pytest.raises(ValidationError, match="UTC offset"):
        SyncPayload.model_validate(payload)


def test_control_characters_are_rejected_in_opaque_provenance() -> None:
    payload = minimal_payload()
    payload["streams"] = {
        "events": [
            {
                "event_id": "device-1:1:RTC_LOST(13)",
                "recorded_at": 1784917770,
                "kind": "RTC_LOST(13)\nforged",
            }
        ]
    }
    with pytest.raises(ValidationError, match="printable"):
        SyncPayload.model_validate(payload)


def test_stage_total_object_requires_integer_seconds() -> None:
    payload = minimal_payload()
    payload["sleep_sessions"] = [
        {
            "session_id": "s1",
            "start_ts": 1784870400,
            "end_ts": 1784899200,
            "stages": {"deep": 105.5},
        }
    ]
    with pytest.raises(ValidationError, match="integer seconds"):
        SyncPayload.model_validate(payload)


def test_sleep_session_rejects_unknown_hrv_method() -> None:
    payload = minimal_payload()
    payload["sleep_sessions"] = [
        {
            "session_id": "s1",
            "start_ts": 1784870400,
            "end_ts": 1784899200,
            "avg_hrv": 61,
            "metadata": {"hrv_method": "proprietary"},
        }
    ]
    with pytest.raises(ValidationError, match="hrv_method"):
        SyncPayload.model_validate(payload)


def test_epoch_legacy_rows_and_bounded_user_text_do_not_poison_batch() -> None:
    raw_payload = minimal_payload()
    raw_payload["source"]["sent_at"] = "1970-01-01T00:01:40Z"
    raw_payload["streams"] = {
        "hr": [{"recorded_at": 100, "value": 60}],
    }
    parsed_raw = SyncPayload.model_validate(raw_payload)

    workout_payload = minimal_payload()
    workout_payload["source"]["sent_at"] = "1970-01-01T00:01:40Z"
    workout_payload["source"]["metadata"].update(
        {
            "namespace": "activity_file_import",
            "score_provenance": "user_imported_activity_file",
        }
    )
    workout_payload["workouts"] = [
        {
            "workout_id": f"device-1:100:{'Custom sport ' * 20}",
            "start_ts": 100,
            "end_ts": 200,
            "sport": "Custom sport " * 20,
        }
    ]
    parsed_workout = SyncPayload.model_validate(workout_payload)

    journal_payload = minimal_payload()
    journal_payload["source"]["sent_at"] = "1970-01-01T00:01:40Z"
    journal_payload["source"]["metadata"].update(
        {
            "namespace": "noop_journal",
            "score_provenance": "user_entered_noop_journal",
        }
    )
    journal_payload["journal"] = [
        {
            "day": "1970-01-01",
            "question": "How did the session feel?",
            "answered_yes": True,
            "notes": "Detailed note. " * 1_000,
        }
    ]
    parsed_journal = SyncPayload.model_validate(journal_payload)

    assert parsed_raw.streams.hr[0].recorded_at.year == 1970
    assert parsed_workout.workouts[0].start_ts.year == 1970
    assert len(parsed_journal.journal[0].notes or "") > 10_000


def test_native_device_identity_must_match_platform_and_installation() -> None:
    payload = minimal_payload()
    payload["source"].update(
        {
            "device_id": "ios:another-installation:device-1",
            "platform": "ios",
        }
    )

    with pytest.raises(ValidationError, match="must be scoped"):
        SyncPayload.model_validate(payload)


def test_motion_and_sleep_state_preserve_nonclinical_sensor_semantics() -> None:
    payload = minimal_payload()
    payload["streams"] = {
        "gravity": [
            {
                "recorded_at": 1_784_917_770,
                "value": 0.1,
                "metadata": {"unit": "g", "y": "-0.2", "z": "0.97"},
            }
        ],
        "sleep_state": [
            {
                "recorded_at": 1_784_917_771,
                "value": 2,
                "metadata": {"unit": "state_code"},
            }
        ],
    }

    parsed = SyncPayload.model_validate(payload)

    assert parsed.streams.gravity[0].metadata["z"] == "0.97"
    assert parsed.streams.sleep_state[0].value == 2


def test_ppg_products_preserve_derived_and_lossless_raw_semantics() -> None:
    payload = minimal_payload()
    payload["streams"] = {
        "ppg_hr": [
            {
                "recorded_at": 1_784_917_770,
                "value": 63.5,
                "quality": 0.87,
                "metadata": {"unit": "bpm", "derived": "true"},
            }
        ],
        "ppg_waveform": [
            {
                "recorded_at": 1_784_917_771,
                "value": 3,
                "metadata": {
                    "unit": "samples_per_record",
                    "encoding": "i16_le_base64",
                    "samples": "aPoHAAAI",
                    "sample_rate_hz": "24",
                    "uncalibrated": "true",
                },
            }
        ],
    }

    parsed = SyncPayload.model_validate(payload)

    assert parsed.streams.ppg_hr[0].quality == 0.87
    assert parsed.streams.ppg_waveform[0].metadata["samples"] == "aPoHAAAI"


@pytest.mark.parametrize(
    ("samples", "value", "message"),
    (
        ("not base64", 3, "canonical base64"),
        ("aPoHAAAI", 2, "packed sample count"),
        ("AQ==", 1, "packed i16"),
    ),
)
def test_ppg_waveform_rejects_malformed_payloads(
    samples: str, value: int, message: str
) -> None:
    payload = minimal_payload()
    payload["streams"] = {
        "ppg_waveform": [
            {
                "recorded_at": 1_784_917_771,
                "value": value,
                "metadata": {
                    "unit": "samples_per_record",
                    "encoding": "i16_le_base64",
                    "samples": samples,
                    "sample_rate_hz": "24",
                    "uncalibrated": "true",
                },
            }
        ]
    }

    with pytest.raises(ValidationError, match=message):
        SyncPayload.model_validate(payload)


@pytest.mark.parametrize(
    ("stream", "sample", "message"),
    (
        (
            "gravity",
            {
                "recorded_at": 1_784_917_770,
                "value": 0.1,
                "metadata": {"unit": "g", "y": "bad", "z": "0.97"},
            },
            "gravity metadata.y",
        ),
        (
            "sleep_state",
            {
                "recorded_at": 1_784_917_770,
                "value": 1.5,
                "metadata": {"unit": "state_code"},
            },
            "whole numbers",
        ),
    ),
)
def test_motion_and_sleep_state_reject_malformed_samples(
    stream: str, sample: dict, message: str
) -> None:
    payload = minimal_payload()
    payload["streams"] = {stream: [sample]}
    with pytest.raises(ValidationError, match=message):
        SyncPayload.model_validate(payload)


@pytest.mark.parametrize("installation_id", ("bad:scope", "a" * 65))
def test_installation_identifier_rejects_ambiguous_or_oversized_values(
    installation_id: str,
) -> None:
    with pytest.raises(ValidationError):
        InstallationCredentialBootstrap.model_validate(
            {
                "installation_id": installation_id,
                "enrollment_id": str(uuid4()),
                "installation_token": "noop_install_" + "a" * 43,
            }
        )


def test_maximum_installation_identifier_forms_a_valid_scoped_device() -> None:
    installation_id = "a" * 64
    enrollment = InstallationCredentialBootstrap.model_validate(
        {
            "installation_id": installation_id,
            "enrollment_id": str(uuid4()),
            "installation_token": "noop_install_" + "a" * 43,
        }
    )
    payload = minimal_payload()
    payload["source"]["platform"] = "ios"
    payload["source"]["metadata"]["installation_id"] = installation_id
    payload["source"]["device_id"] = f"ios:{installation_id}:strap"

    parsed = SyncPayload.model_validate(payload)

    assert enrollment.installation_id == installation_id
    assert parsed.source.device_id == f"ios:{installation_id}:strap"
