from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient

FIXTURES = Path(__file__).resolve().parent / "data"
INSTALLATION_ID = "11111111-1111-4111-8111-111111111111"
RAW_DEVICE_ID = f"ios:{INSTALLATION_ID}:strap-abc-strap"
OFFICIAL_DEVICE_ID = f"ios:{INSTALLATION_ID}:whoop-official-reference"


def client_payload(*, batch_id: str | None = None) -> dict:
    return {
        "schema_version": 1,
        "batch_id": batch_id or str(uuid4()),
        "source": {
            "device_id": RAW_DEVICE_ID,
            "sent_at": "2026-07-24T18:30:00Z",
            "app_version": "10.0",
            "platform": "ios",
            "device": {
                "display_name": "My strap",
                "model": "WHOOP 5.0",
            },
            "metadata": {
                "installation_id": INSTALLATION_ID,
                "logical_source_id": "strap-abc-strap",
                "namespace": "strap_measured",
                "paired_device_id": "strap-abc",
                "privacy": "explicit_opt_in",
                "score_provenance": "strap_measured",
            },
        },
        "streams": {
            "hr": [
                {
                    "recorded_at": 1784917770,
                    "value": 72,
                    "metadata": {
                        "unit": "bpm",
                        "provenance": "strap_measured",
                    },
                }
            ],
            "rr": [
                {
                    "recorded_at": 1784917770,
                    "value": 810,
                    "metadata": {"unit": "ms", "seq": "0"},
                },
                {
                    "recorded_at": 1784917770,
                    "value": 825,
                    "metadata": {"unit": "ms", "seq": "0"},
                },
                {
                    "recorded_at": 1784917770,
                    "value": 810,
                    "metadata": {"unit": "ms", "seq": "1"},
                },
            ],
            "battery": [
                {
                    "recorded_at": 1784917771,
                    "value": 4100,
                    "metadata": {"unit": "millivolts"},
                }
            ],
            "spo2": [
                {
                    "recorded_at": 1784917772,
                    "value": 18000,
                    "metadata": {
                        "unit": "raw_adc",
                        "infrared": "17000",
                        "uncalibrated": "true",
                        "provenance": "strap_raw_optical",
                    },
                }
            ],
            "skin_temp": [
                {
                    "recorded_at": 1784917772,
                    "value": -912.75,
                    "metadata": {
                        "unit": "raw_adc",
                        "uncalibrated": "true",
                    },
                }
            ],
            "respiration": [],
            "steps": [],
            "events": [
                {
                    "event_id": "strap-abc:1784917773:BLE_CONNECTION_DOWN(12)",
                    "recorded_at": 1784917773,
                    "kind": "BLE_CONNECTION_DOWN(12)",
                    "metadata": {"provenance": "strap_event"},
                }
            ],
        },
        "daily_metrics": {},
        "sleep_sessions": [],
        "workouts": [],
        "journal": [],
    }


def official_payload(*, batch_id: str | None = None) -> dict:
    payload = json.loads(
        (FIXTURES / "official_reference_sync_v1.json").read_text(encoding="utf-8")
    )
    payload["batch_id"] = batch_id or str(uuid4())
    return payload


def test_health_is_public_but_every_data_endpoint_requires_bearer(
    client: TestClient,
) -> None:
    assert client.get("/healthz").json() == {"status": "ok"}
    response = client.get("/v1/status")
    assert response.status_code == 401
    assert "token" in response.json()["detail"]
    assert response.headers["cache-control"] == "no-store"


def test_client_shaped_batch_preserves_rr_and_raw_semantics(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    payload = client_payload()
    headers = {
        **auth_headers,
        "Idempotency-Key": payload["batch_id"],
    }
    accepted = client.post("/v1/sync", headers=headers, json=payload)
    assert accepted.status_code == 200, accepted.text
    result = accepted.json()
    assert result["status"] == "accepted"
    assert result["duplicate"] is False
    assert result["counts"]["metric_samples"] == 7

    rr = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/streams/rr",
        params={
            "start": "2026-07-24T00:00:00Z",
            "end": "2026-07-25T00:00:00Z",
        },
        headers=auth_headers,
    )
    assert rr.status_code == 200
    values = [
        (sample["value"], sample["metadata"]["seq"]) for sample in rr.json()["samples"]
    ]
    assert values == [(810.0, "0"), (825.0, "0"), (810.0, "1")]

    latest = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/latest",
        headers=auth_headers,
    ).json()["metrics"]
    assert latest["spo2"]["unit"] == "raw_adc"
    assert latest["spo2"]["measurement_class"] == "raw_sensor"
    assert latest["spo2"]["clinical_interpretation_allowed"] is False
    assert latest["skin_temp"]["value"] == -912.75
    assert latest["skin_temp"]["measurement_class"] == "raw_sensor"
    assert latest["battery"]["unit"] == "millivolts"
    assert latest["battery"]["measurement_class"] == "device_telemetry"
    assert latest["battery"]["source_platform"] == "ios"
    assert latest["battery"]["source_metadata"]["namespace"] == "strap_measured"
    assert latest["battery"]["sync_batch_id"] == payload["batch_id"]

    events = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/events",
        params={
            "start": "2026-07-24T00:00:00Z",
            "end": "2026-07-25T00:00:00Z",
        },
        headers=auth_headers,
    ).json()["events"]
    assert events[0]["kind"] == "BLE_CONNECTION_DOWN(12)"
    assert events[0]["event_id"].endswith("BLE_CONNECTION_DOWN(12)")


def test_checked_in_v1_fixtures_keep_raw_and_official_provenance_separate(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    raw_payload = json.loads((FIXTURES / "apple_sync_v1.json").read_text())
    raw_response = client.post(
        "/v1/sync",
        headers={**auth_headers, "Idempotency-Key": raw_payload["batch_id"]},
        json=raw_payload,
    )
    assert raw_response.status_code == 200, raw_response.text
    assert raw_response.json()["counts"]["metric_samples"] == 5
    rr = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/streams/rr",
        params={
            "start": "2026-07-24T00:00:00Z",
            "end": "2026-07-25T00:00:00Z",
        },
        headers=auth_headers,
    ).json()["samples"]
    assert [(row["value"], row["metadata"]["seq"]) for row in rr] == [
        (810.0, "0"),
        (825.0, "0"),
        (810.0, "1"),
    ]

    official_payload = json.loads(
        (FIXTURES / "official_reference_sync_v1.json").read_text()
    )
    official_response = client.post(
        "/v1/sync",
        headers={**auth_headers, "Idempotency-Key": official_payload["batch_id"]},
        json=official_payload,
    )
    assert official_response.status_code == 200, official_response.text
    assert official_response.json()["counts"]["metric_samples"] == 0
    official_sleep = client.get(
        f"/v1/devices/{OFFICIAL_DEVICE_ID}/sleep",
        params={
            "start": "2026-07-20T00:00:00Z",
            "end": "2026-07-26T00:00:00Z",
        },
        headers=auth_headers,
    ).json()["sessions"]
    assert official_sleep[0]["stages"]["deep"] == 6300
    assert official_sleep[0]["efficiency"] == 0.91


def test_namespace_contract_rejects_missing_unknown_and_mixed_provenance(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    missing = client_payload()
    del missing["source"]["metadata"]["logical_source_id"]

    unknown = client_payload()
    unknown["source"]["metadata"]["namespace"] = "whoop_cloud"

    raw_with_derived = client_payload()
    raw_with_derived["daily_metrics"] = {"2026-07-24": {"effort": 42}}

    official_with_raw = client_payload()
    official_with_raw["source"]["metadata"].update(
        {
            "namespace": "official_reference",
            "logical_source_id": "whoop-official-reference",
            "score_provenance": "user_imported_whoop_export",
        }
    )

    computed_with_official_score = official_payload()
    computed_with_official_score["source"]["metadata"].update(
        {
            "namespace": "noop_computed",
            "logical_source_id": "strap-abc-noop",
            "score_provenance": "noop_transparent_algorithm",
            "algorithm_revision": "noop-charge-v1+noop-effort-v1+noop-rest-v1",
        }
    )

    for invalid in (
        missing,
        unknown,
        raw_with_derived,
        official_with_raw,
        computed_with_official_score,
    ):
        invalid["batch_id"] = str(uuid4())
        response = client.post("/v1/sync", headers=auth_headers, json=invalid)
        assert response.status_code == 422, response.text


def test_batch_retry_is_idempotent_and_uuid_reuse_conflicts(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    payload = client_payload()
    headers = {**auth_headers, "Idempotency-Key": payload["batch_id"]}
    first = client.post("/v1/sync", headers=headers, json=payload)
    second = client.post("/v1/sync", headers=headers, json=payload)
    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["duplicate"] is True
    assert second.json()["counts"]["metric_samples"] == 0

    changed = deepcopy(payload)
    changed["streams"]["hr"][0]["value"] = 73
    conflict = client.post("/v1/sync", headers=headers, json=changed)
    assert conflict.status_code == 409


def test_idempotency_header_must_match_body(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    payload = client_payload()
    response = client.post(
        "/v1/sync",
        headers={**auth_headers, "Idempotency-Key": str(uuid4())},
        json=payload,
    )
    assert response.status_code == 409


def test_clinical_range_only_applies_to_explicit_clinical_unit(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    raw_payload = client_payload()
    raw_payload["streams"]["spo2"][0]["value"] = 9.87654321e200
    assert (
        client.post("/v1/sync", headers=auth_headers, json=raw_payload).status_code
        == 200
    )

    clinical = client_payload()
    clinical["streams"]["spo2"][0] = {
        "recorded_at": 1784917772,
        "value": 18000,
        "metadata": {"unit": "percent"},
    }
    rejected = client.post("/v1/sync", headers=auth_headers, json=clinical)
    assert rejected.status_code == 422
    assert "spo2 value" in rejected.text


def test_wrapping_step_stream_is_not_relabelled_as_daily_steps(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    payload = client_payload()
    payload["streams"]["steps"] = [
        {
            "recorded_at": 1784917774,
            "value": 4_000_000_000,
            "metadata": {
                "unit": "cumulative_counter",
                "approximate": "true",
                "provenance": "strap_counter",
            },
        }
    ]
    response = client.post("/v1/sync", headers=auth_headers, json=payload)
    assert response.status_code == 200, response.text
    latest = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/latest", headers=auth_headers
    ).json()["metrics"]["steps"]
    assert latest["unit"] == "cumulative_counter"
    assert latest["measurement_class"] == "device_counter"
    assert latest["clinical_interpretation_allowed"] is False


def test_efficiency_is_a_fraction_and_stages_support_legacy_arrays(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    legacy = official_payload()
    legacy["sleep_sessions"][0]["stages"] = (
        '[{"stage":"light","start_ts":1784870400,"end_ts":1784874000}]'
    )
    assert client.post("/v1/sync", headers=auth_headers, json=legacy).status_code == 200

    invalid = official_payload()
    invalid["sleep_sessions"][0]["efficiency"] = 91
    invalid["daily_metrics"]["2026-07-24"]["efficiency"] = 91
    response = client.post("/v1/sync", headers=auth_headers, json=invalid)
    assert response.status_code == 422
    assert "efficiency" in response.text


def test_export_delete_and_retention_are_authenticated_and_confirmed(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    payload = client_payload()
    assert (
        client.post("/v1/sync", headers=auth_headers, json=payload).status_code == 200
    )

    export = client.get(
        f"/v1/devices/{RAW_DEVICE_ID}/export",
        headers=auth_headers,
    )
    assert export.status_code == 200
    assert "attachment" in export.headers["content-disposition"]
    exported = export.json()
    assert len(exported["metric_samples"]) == 7
    assert exported["metric_samples"][0]["source_metadata"]["logical_source_id"] == (
        "strap-abc-strap"
    )
    assert "Raw ADC" in exported["notice"]

    no_confirmation = client.delete(
        f"/v1/devices/{RAW_DEVICE_ID}", headers=auth_headers
    )
    assert no_confirmation.status_code == 412

    deleted = client.delete(
        f"/v1/devices/{RAW_DEVICE_ID}",
        headers={**auth_headers, "X-Noop-Confirm": f"DELETE {RAW_DEVICE_ID}"},
    )
    assert deleted.status_code == 200
    assert deleted.json()["counts"]["metric_samples"] == 7

    retention = client.post(
        "/v1/admin/retention/run",
        headers={**auth_headers, "X-Noop-Confirm": "PURGE"},
        json={},
    )
    assert retention.status_code == 200
    assert retention.json()["retention_days"] == 30


def test_dashboard_is_static_and_never_embeds_a_secret(client: TestClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert "self-hosted biometric vault" in response.text.casefold()
    assert "content-security-policy" in response.headers
    assert response.headers["x-frame-options"] == "DENY"
    assert "camera=()" in response.headers["permissions-policy"]
    assert "test-token" not in response.text
