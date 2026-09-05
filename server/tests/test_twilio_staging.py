from __future__ import annotations

import os

import pytest

from app.paging import TwilioPagingProvider


pytestmark = pytest.mark.skipif(
    os.getenv("NOOP_RUN_TWILIO_STAGING") != "I_CONTROL_THIS_NUMBER",
    reason="real Twilio staging is explicitly opt-in",
)


@pytest.mark.asyncio
async def test_real_twilio_accepts_sms_and_voice_submissions() -> None:
    required = {
        name: os.environ[name]
        for name in (
            "NOOP_TWILIO_ACCOUNT_SID",
            "NOOP_TWILIO_AUTH_TOKEN",
            "NOOP_TWILIO_FROM_PHONE",
            "NOOP_TWILIO_STAGING_TO",
            "NOOP_TWILIO_STAGING_RESPONSE_URL",
        )
    }
    api_key_sid = os.getenv("NOOP_TWILIO_API_KEY_SID")
    api_key_secret = os.getenv("NOOP_TWILIO_API_KEY_SECRET")
    assert bool(api_key_sid) == bool(api_key_secret)
    assert required["NOOP_TWILIO_STAGING_RESPONSE_URL"].startswith("https://")
    provider = TwilioPagingProvider(
        account_sid=required["NOOP_TWILIO_ACCOUNT_SID"],
        auth_token=required["NOOP_TWILIO_AUTH_TOKEN"],
        api_key_sid=api_key_sid,
        api_key_secret=api_key_secret,
        from_phone=required["NOOP_TWILIO_FROM_PHONE"],
        status_callback_url=None,
    )

    sms = await provider.send_page_sms(
        to_phone=required["NOOP_TWILIO_STAGING_TO"],
        owner_name="NOOP staging test, no emergency",
        incident_summary="Staging test only. No emergency.",
        response_url=required["NOOP_TWILIO_STAGING_RESPONSE_URL"],
    )
    voice = await provider.send_page_voice(
        to_phone=required["NOOP_TWILIO_STAGING_TO"],
        owner_name="NOOP staging test, no emergency",
        incident_summary="Staging test only. No emergency.",
        response_url=required["NOOP_TWILIO_STAGING_RESPONSE_URL"],
    )

    assert sms.provider_reference.startswith("SM")
    assert voice.provider_reference.startswith("CA")
    assert sms.status in {"queued", "sent", "delivered"}
    assert voice.status in {"queued", "sent", "delivered"}
