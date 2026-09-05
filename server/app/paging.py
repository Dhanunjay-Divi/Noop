from __future__ import annotations

import asyncio
import base64
import hashlib
import html
import hmac
import json
import math
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from http.client import HTTPException as HTTPClientException
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class PagingUnavailableError(RuntimeError):
    """Raised when an external paging provider is not configured or reachable."""


class PagingRejectedError(PagingUnavailableError):
    """The provider explicitly rejected the request before accepting it."""


class PagingOutcomeUnknownError(PagingUnavailableError):
    """The request may have reached the provider, so retrying could duplicate it."""


class PagingRateLimitedError(PagingRejectedError):
    """The provider rejected the request and supplied an optional retry delay."""

    def __init__(self, message: str, *, retry_after_seconds: int | None) -> None:
        super().__init__(message)
        self.retry_after_seconds = retry_after_seconds


@dataclass(frozen=True, slots=True)
class PagingSubmission:
    provider_reference: str
    status: str


class PagingProvider(Protocol):
    @property
    def available(self) -> bool: ...

    async def send_invitation(
        self,
        *,
        to_phone: str,
        contact_name: str,
        owner_name: str,
        acceptance_url: str,
    ) -> PagingSubmission: ...

    async def send_page_sms(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission: ...

    async def send_page_voice(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission: ...


class UnavailablePagingProvider:
    @property
    def available(self) -> bool:
        return False

    async def send_invitation(self, **_: str) -> PagingSubmission:
        raise PagingUnavailableError("SMS and voice paging are not configured")

    async def send_page_sms(self, **_: str) -> PagingSubmission:
        raise PagingUnavailableError("SMS and voice paging are not configured")

    async def send_page_voice(self, **_: str) -> PagingSubmission:
        raise PagingUnavailableError("SMS and voice paging are not configured")


class TwilioPagingProvider:
    """Small Twilio REST adapter with no SDK dependency or request logging."""

    def __init__(
        self,
        *,
        account_sid: str,
        auth_token: str,
        from_phone: str,
        status_callback_url: str | None,
        api_key_sid: str | None = None,
        api_key_secret: str | None = None,
        timeout_seconds: float = 15,
    ) -> None:
        self.account_sid = account_sid
        self.auth_token = auth_token
        self.api_key_sid = api_key_sid
        self.api_key_secret = api_key_secret
        self.from_phone = from_phone
        self.status_callback_url = status_callback_url
        self.timeout_seconds = timeout_seconds

    @property
    def available(self) -> bool:
        outbound_credential = bool(self.api_key_sid and self.api_key_secret) or bool(
            self.auth_token
        )
        return bool(self.account_sid and outbound_credential and self.from_phone)

    async def send_invitation(
        self,
        *,
        to_phone: str,
        contact_name: str,
        owner_name: str,
        acceptance_url: str,
    ) -> PagingSubmission:
        body = (
            f"{contact_name}, {owner_name} invited you to be an emergency "
            f"contact for NOOP. Review and accept: {acceptance_url}"
        )
        return await self._submit_message(to_phone=to_phone, body=body)

    async def send_page_sms(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission:
        body = (
            f"NOOP SAFETY PAGE: {owner_name} may need urgent help. Call them "
            f"now. {incident_summary} Acknowledge or decline here: "
            f"{response_url} If you believe they are in immediate danger, "
            "contact local emergency services. NOOP has not dispatched "
            "emergency services."
        )
        return await self._submit_message(to_phone=to_phone, body=body)

    async def send_page_voice(
        self,
        *,
        to_phone: str,
        owner_name: str,
        incident_summary: str,
        response_url: str,
    ) -> PagingSubmission:
        spoken_name = html.escape(owner_name, quote=True)
        spoken_summary = html.escape(incident_summary, quote=True)
        action = html.escape(response_url, quote=True)
        twiml = (
            "<Response>"
            f'<Gather input="dtmf" numDigits="1" timeout="10" '
            f'method="POST" action="{action}">'
            '<Say voice="alice">This is a NOOP safety page. '
            f"{spoken_name} may need urgent help. {spoken_summary} "
            "Press 1 if you are responding. "
            "Press 2 if you cannot respond.</Say>"
            "</Gather>"
            '<Say voice="alice">No response was recorded. Please call them '
            "directly. If you believe they are in immediate danger, contact "
            "local emergency services. NOOP has not dispatched emergency "
            "services.</Say>"
            "</Response>"
        )
        fields: dict[str, str | tuple[str, ...]] = {
            "To": to_phone,
            "From": self.from_phone,
            "Twiml": twiml,
        }
        if self.status_callback_url:
            fields["StatusCallback"] = self.status_callback_url
            fields["StatusCallbackEvent"] = (
                "initiated",
                "ringing",
                "answered",
                "completed",
            )
        return await self._post("Calls.json", fields)

    async def _submit_message(self, *, to_phone: str, body: str) -> PagingSubmission:
        fields = {"To": to_phone, "From": self.from_phone, "Body": body}
        if self.status_callback_url:
            fields["StatusCallback"] = self.status_callback_url
        return await self._post("Messages.json", fields)

    async def _post(
        self,
        endpoint: str,
        fields: dict[str, str | tuple[str, ...]],
    ) -> PagingSubmission:
        if not self.available:
            raise PagingUnavailableError("SMS and voice paging are not configured")
        return await asyncio.to_thread(self._post_sync, endpoint, fields)

    def _post_sync(
        self,
        endpoint: str,
        fields: dict[str, str | tuple[str, ...]],
    ) -> PagingSubmission:
        url = (
            f"https://api.twilio.com/2010-04-01/Accounts/{self.account_sid}/{endpoint}"
        )
        username = self.api_key_sid or self.account_sid
        password = self.api_key_secret or self.auth_token
        basic = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode(
            "ascii"
        )
        request = Request(
            url,
            data=urlencode(fields, doseq=True).encode("utf-8"),
            headers={
                "Authorization": f"Basic {basic}",
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "Noop-Safety-Paging/1",
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                raw = response.read(65_536)
        except HTTPError as exc:
            if exc.code == 408:
                raise PagingOutcomeUnknownError(
                    "paging provider outcome is unknown after HTTP 408"
                ) from exc
            if exc.code == 429:
                raise PagingRateLimitedError(
                    "paging provider rate limit was reached",
                    retry_after_seconds=_retry_after_seconds(exc.headers),
                ) from exc
            if 400 <= exc.code < 500:
                raise PagingRejectedError(
                    f"paging provider returned HTTP {exc.code}"
                ) from exc
            raise PagingOutcomeUnknownError(
                f"paging provider outcome is unknown after HTTP {exc.code}"
            ) from exc
        except (HTTPClientException, URLError, TimeoutError, OSError) as exc:
            raise PagingOutcomeUnknownError(
                "paging provider outcome is unknown"
            ) from exc
        try:
            payload = json.loads(raw)
            reference = str(payload["sid"])
            provider_status = str(payload.get("status", "queued"))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise PagingOutcomeUnknownError(
                "paging provider returned an unreadable response"
            ) from exc
        if not reference:
            raise PagingOutcomeUnknownError(
                "paging provider returned an unreadable response"
            )
        return PagingSubmission(
            provider_reference=reference,
            status=normalise_provider_status(provider_status),
        )


def _retry_after_seconds(
    headers: Any,
    *,
    now: datetime | None = None,
) -> int | None:
    if headers is None:
        return None
    raw = headers.get("Retry-After")
    if raw is None:
        return None
    value = str(raw).strip()
    try:
        seconds = int(value)
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(value)
        except (TypeError, ValueError, OverflowError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=UTC)
        reference = (now or datetime.now(UTC)).astimezone(UTC)
        seconds = math.ceil((retry_at.astimezone(UTC) - reference).total_seconds())
    if seconds <= 0:
        return 1
    return min(seconds, 3_600)


def normalise_provider_status(value: str) -> str:
    status = value.casefold()
    if status in {"delivered", "completed", "answered"}:
        return "delivered"
    if status in {"failed", "undelivered", "busy", "no-answer", "canceled"}:
        return "failed"
    if status in {"sent", "ringing", "in-progress"}:
        return "sent"
    return "queued"


def validate_twilio_webhook(
    *,
    url: str,
    parameters: dict[str, list[str]],
    signature: str,
    auth_token: str,
) -> bool:
    """Validate Twilio's form-webhook signature using its documented scheme."""

    if not signature or not auth_token:
        return False
    signed = url
    for name in sorted(parameters):
        for value in sorted(set(parameters[name])):
            signed += name + value
    digest = hmac.new(
        auth_token.encode("utf-8"),
        signed.encode("utf-8"),
        hashlib.sha1,
    ).digest()
    expected = base64.b64encode(digest).decode("ascii")
    return hmac.compare_digest(
        signature.encode("ascii", errors="ignore"),
        expected.encode("ascii"),
    )
