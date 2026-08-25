import asyncio
import json
from datetime import UTC, datetime
from email.utils import format_datetime
from http.client import IncompleteRead
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs

import pytest

import app.paging as paging
from app.paging import (
    PagingOutcomeUnknownError,
    PagingRateLimitedError,
    PagingRejectedError,
    TwilioPagingProvider,
    validate_twilio_webhook,
)
from app.safety_worker import _retry_delay_seconds


def test_twilio_form_signature_is_constant_time_and_covers_url_and_values() -> None:
    url = "https://safety.example.test/v1/safety/provider/twilio/status?token=abc"
    parameters = {
        "MessageSid": ["SM123"],
        "MessageStatus": ["delivered"],
        "To": ["+14155550123"],
    }
    signature = "tScL/PLOahhMNt0ZB2tIjUCbIIc="

    # Fixed HMAC-SHA1 fixture produced independently from the documented
    # Twilio URL + lexicographically sorted form-value construction.
    assert validate_twilio_webhook(
        url=url,
        parameters=parameters,
        signature=signature,
        auth_token="twilio-test-auth-token",
    )
    assert not validate_twilio_webhook(
        url=url,
        parameters=parameters | {"MessageStatus": ["failed"]},
        signature=signature,
        auth_token="twilio-test-auth-token",
    )


def test_twilio_voice_callback_events_are_repeated_form_values(monkeypatch) -> None:
    captured: dict[str, object] = {}

    class ProviderResponse:
        def __enter__(self):
            return self

        def __exit__(self, *_: object) -> None:
            return None

        @staticmethod
        def read(_: int) -> bytes:
            return json.dumps({"sid": "CA123", "status": "queued"}).encode()

    def fake_urlopen(request, *, timeout):
        captured["request"] = request
        captured["timeout"] = timeout
        return ProviderResponse()

    monkeypatch.setattr(paging, "urlopen", fake_urlopen)
    provider = TwilioPagingProvider(
        account_sid="AC123",
        auth_token="secret",
        from_phone="+14155550100",
        status_callback_url="https://safety.example.test/twilio/status",
    )

    submission = asyncio.run(
        provider.send_page_voice(
            to_phone="+14155550101",
            owner_name="Jordan",
            incident_summary="Started from the NOOP app.",
            response_url="https://safety.example.test/respond",
        )
    )

    request = captured["request"]
    values = parse_qs(request.data.decode("utf-8"))
    assert submission.provider_reference == "CA123"
    assert values["StatusCallbackEvent"] == [
        "initiated",
        "ringing",
        "answered",
        "completed",
    ]


@pytest.mark.parametrize(
    ("provider_error", "expected_type"),
    [
        (URLError("connection reset"), PagingOutcomeUnknownError),
        (
            HTTPError("https://api.twilio.test", 503, "down", {}, None),
            PagingOutcomeUnknownError,
        ),
        (
            HTTPError("https://api.twilio.test", 408, "timeout", {}, None),
            PagingOutcomeUnknownError,
        ),
        (
            HTTPError("https://api.twilio.test", 400, "bad request", {}, None),
            PagingRejectedError,
        ),
        (IncompleteRead(b'{"sid":', 32), PagingOutcomeUnknownError),
    ],
)
def test_twilio_distinguishes_ambiguous_outcomes_from_explicit_rejection(
    monkeypatch,
    provider_error,
    expected_type,
) -> None:
    def fake_urlopen(*_: object, **__: object):
        raise provider_error

    monkeypatch.setattr(paging, "urlopen", fake_urlopen)
    provider = TwilioPagingProvider(
        account_sid="AC123",
        auth_token="secret",
        from_phone="+14155550100",
        status_callback_url=None,
    )

    with pytest.raises(expected_type):
        asyncio.run(
            provider.send_page_sms(
                to_phone="+14155550101",
                owner_name="Jordan",
                incident_summary="Started from the NOOP app.",
                response_url="https://safety.example.test/respond",
            )
        )


def test_twilio_rate_limit_preserves_bounded_retry_after(monkeypatch) -> None:
    def fake_urlopen(*_: object, **__: object):
        raise HTTPError(
            "https://api.twilio.test",
            429,
            "rate limited",
            {"Retry-After": "120"},
            None,
        )

    monkeypatch.setattr(paging, "urlopen", fake_urlopen)
    provider = TwilioPagingProvider(
        account_sid="AC123",
        auth_token="secret",
        from_phone="+14155550100",
        status_callback_url=None,
    )

    with pytest.raises(PagingRateLimitedError) as error:
        asyncio.run(
            provider.send_page_sms(
                to_phone="+14155550101",
                owner_name="Jordan",
                incident_summary="Started from the NOOP app.",
                response_url="https://safety.example.test/respond",
            )
        )

    assert error.value.retry_after_seconds == 120
    assert paging._retry_after_seconds({"Retry-After": "999999"}) == 3_600


def test_retry_after_http_date_rounds_up_and_retry_jitter_keeps_floor(
    monkeypatch,
) -> None:
    now = datetime(2026, 8, 24, 12, 0, 0, 500_000, tzinfo=UTC)
    retry_at = datetime(2026, 8, 24, 12, 0, 2, tzinfo=UTC)

    assert (
        paging._retry_after_seconds(
            {"Retry-After": format_datetime(retry_at, usegmt=True)},
            now=now,
        )
        == 2
    )

    monkeypatch.setattr(
        "app.safety_worker.random.uniform",
        lambda _lower, upper: upper,
    )
    assert (
        _retry_delay_seconds(
            base_seconds=5,
            attempt_count=2,
            retry_after_seconds=30,
        )
        == 32.5
    )
    assert (
        _retry_delay_seconds(
            base_seconds=5,
            attempt_count=2,
            retry_after_seconds=3_600,
        )
        == 3_600
    )
