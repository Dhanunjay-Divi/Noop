from __future__ import annotations

import base64
import hashlib
import json
from uuid import uuid4

import pytest

from app.managed_processor_main import parse_storage_finalize_event


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
