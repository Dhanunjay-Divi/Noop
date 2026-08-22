import asyncio
import json
from urllib.parse import parse_qs

import app.paging as paging
from app.paging import TwilioPagingProvider, validate_twilio_webhook


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
