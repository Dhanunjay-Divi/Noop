from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import quote, urlencode
from uuid import uuid4

from app.paging import PagingProvider
from app.safety_capabilities import SafetyCapabilitySigner
from app.safety_repository import SafetyRepository

logger = logging.getLogger("noop.safety")


class SafetyDeliveryWorker:
    """Leases and submits Safety deliveries independently of API requests."""

    def __init__(
        self,
        *,
        repository: SafetyRepository,
        provider: PagingProvider,
        public_base_url: str,
        capability_signer: SafetyCapabilitySigner,
        poll_seconds: int,
        lease_seconds: int,
        retry_base_seconds: int,
        provider_receipt_timeout_seconds: int,
        batch_size: int = 20,
    ) -> None:
        self.repository = repository
        self.provider = provider
        self.public_base_url = public_base_url.rstrip("/")
        self.capability_signer = capability_signer
        self.poll_seconds = poll_seconds
        self.lease_seconds = lease_seconds
        self.retry_base_seconds = retry_base_seconds
        self.provider_receipt_timeout_seconds = provider_receipt_timeout_seconds
        self.batch_size = batch_size
        self.worker_id = f"safety-{uuid4()}"
        self._wake_event: asyncio.Event | None = None

    def wake(self) -> None:
        if self._wake_event is not None:
            self._wake_event.set()

    async def run(self) -> None:
        self._wake_event = asyncio.Event()
        while True:
            try:
                await self.process_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("safety delivery cycle failed")
            try:
                await asyncio.wait_for(
                    self._wake_event.wait(),
                    timeout=self.poll_seconds,
                )
            except TimeoutError:
                pass
            finally:
                self._wake_event.clear()

    async def process_once(self) -> int:
        now = datetime.now(UTC)
        await self.repository.expire_due_dispatches(now=now)
        await self.repository.mark_stale_provider_receipts(
            cutoff=now - timedelta(seconds=self.provider_receipt_timeout_seconds),
            now=now,
        )
        deliveries = await self.repository.claim_due_deliveries(
            worker_id=self.worker_id,
            now=now,
            lease_until=now + timedelta(seconds=self.lease_seconds),
            limit=self.batch_size,
        )
        if not deliveries:
            return 0
        await asyncio.gather(*(self._submit(delivery) for delivery in deliveries))
        return len(deliveries)

    async def _submit(self, delivery: dict[str, Any]) -> None:
        response_url = self._response_url(delivery)
        submission = None
        error: Exception | None = None
        try:
            if delivery["channel"] == "sms":
                submission = await self.provider.send_page_sms(
                    to_phone=str(delivery["phone_e164"]),
                    owner_name=str(delivery["owner_display_name"]),
                    response_url=response_url,
                )
            else:
                submission = await self.provider.send_page_voice(
                    to_phone=str(delivery["phone_e164"]),
                    owner_name=str(delivery["owner_display_name"]),
                    response_url=response_url,
                )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            error = exc

        now = datetime.now(UTC)
        attempt_count = int(delivery["attempt_count"])
        delay = min(
            self.retry_base_seconds * (2 ** max(attempt_count - 1, 0)),
            5 * 60,
        )
        await self.repository.complete_delivery_attempt(
            delivery_id=str(delivery["delivery_id"]),
            attempt_id=str(delivery["attempt_id"]),
            worker_id=self.worker_id,
            submission_status=submission.status if submission else None,
            provider_reference=(submission.provider_reference if submission else None),
            error=_safe_error(error) if error else None,
            now=now,
            retry_at=now + timedelta(seconds=delay),
        )
        if error is not None:
            logger.warning(
                "safety delivery submission failed",
                extra={
                    "dispatch_id": str(delivery["dispatch_id"]),
                    "delivery_id": str(delivery["delivery_id"]),
                    "channel": str(delivery["channel"]),
                    "attempt": attempt_count,
                },
            )

    def _response_url(self, delivery: dict[str, Any]) -> str:
        dispatch_id = str(delivery["dispatch_id"])
        contact_id = str(delivery["contact_id"])
        expires_at = delivery["expires_at"]
        if not isinstance(expires_at, datetime):
            raise TypeError("incident expiry must be a datetime")
        expires_at_unix = int(expires_at.timestamp())
        signature = self.capability_signer.sign(
            dispatch_id=dispatch_id,
            contact_id=contact_id,
            expires_at_unix=expires_at_unix,
        )
        query = urlencode(
            {
                "expires": str(expires_at_unix),
                "signature": signature,
            }
        )
        if delivery["channel"] == "voice":
            path = (
                "/v1/safety/provider/twilio/respond/"
                f"{quote(dispatch_id, safe='')}/{quote(contact_id, safe='')}"
            )
        else:
            path = (
                f"/safety/respond/{quote(dispatch_id, safe='')}/"
                f"{quote(contact_id, safe='')}"
            )
        return f"{self.public_base_url}{path}?{query}"


def _safe_error(error: Exception) -> str:
    text = str(error).strip() or error.__class__.__name__
    return text[:240]
