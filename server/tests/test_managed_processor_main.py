from __future__ import annotations

import base64
import hashlib
import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.managed_processing import ManagedChunkProcessorResult
from app.managed_processor_main import (
    create_managed_processor_app,
    parse_storage_finalize_event,
)
from app.repository import PostgresRepository


def _envelope(*, bucket: str = "noop-private-bucket") -> tuple[dict, bytes]:
    payload = json.dumps(
        {
            "bucket": bucket,
            "name": f"v1/{uuid4()}/{uuid4()}",
            "generation": "42",
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return {
        "message": {
            "messageId": "event-1",
            "data": base64.b64encode(payload).decode(),
        },
        "subscription": "projects/test/subscriptions/processor",
    }, payload


def test_storage_finalize_event_is_bucket_and_generation_bound() -> None:
    envelope, payload = _envelope()

    event = parse_storage_finalize_event(
        envelope,
        expected_bucket="noop-private-bucket",
    )

    assert event.generation == 42
    assert event.event_hash == hashlib.sha256(payload).hexdigest()


def test_storage_finalize_event_rejects_another_bucket() -> None:
    envelope, _ = _envelope(bucket="another-bucket")

    with pytest.raises(ValueError):
        parse_storage_finalize_event(
            envelope,
            expected_bucket="noop-private-bucket",
        )


def test_storage_finalize_event_rejects_noncanonical_object_key() -> None:
    envelope, _ = _envelope()
    payload = json.loads(base64.b64decode(envelope["message"]["data"]))
    payload["name"] = "v1/readable-user/chunk"
    envelope["message"]["data"] = base64.b64encode(
        json.dumps(payload).encode()
    ).decode()

    with pytest.raises(ValueError):
        parse_storage_finalize_event(
            envelope,
            expected_bucket="noop-private-bucket",
        )


@pytest.mark.parametrize(
    ("processor_status", "severity"),
    [
        ("available", "INFO"),
        ("already_processed", "INFO"),
        ("quarantined", "WARNING"),
    ],
)
def test_storage_finalize_event_records_actual_processor_outcome(
    monkeypatch: pytest.MonkeyPatch,
    processor_status: str,
    severity: str,
) -> None:
    events: list[dict[str, object]] = []

    async def startup(_: PostgresRepository) -> None:
        return None

    async def shutdown(_: PostgresRepository) -> None:
        return None

    async def process(*_args, **_kwargs) -> ManagedChunkProcessorResult:
        return ManagedChunkProcessorResult(status=processor_status)

    def capture(event: str, **fields: object) -> None:
        events.append({"event": event, **fields})

    monkeypatch.setattr(PostgresRepository, "startup", startup)
    monkeypatch.setattr(PostgresRepository, "shutdown", shutdown)
    monkeypatch.setattr(
        "app.managed_processor_main.ManagedChunkProcessor.process",
        process,
    )
    monkeypatch.setattr(
        "app.managed_processor_main.emit_operational_event",
        capture,
    )
    settings = Settings(
        api_token=None,
        database_url="postgresql://unused",
        managed_raw_bucket="noop-private-bucket",
        managed_signer_email="processor@example.test",
    )
    app = create_managed_processor_app(settings=settings)

    with TestClient(app) as client:
        response = client.post("/v1/events/storage-finalized", json=_envelope()[0])

    assert response.status_code == 204
    processor_events = [
        event for event in events if event["event"] == "managed_processor.event"
    ]
    assert len(processor_events) == 1
    assert processor_events[0]["outcome"] == processor_status
    assert processor_events[0]["severity"] == severity
