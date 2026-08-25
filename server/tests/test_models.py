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
