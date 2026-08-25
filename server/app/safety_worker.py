from __future__ import annotations

import asyncio
import logging
import os
import random
import signal
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode
from uuid import uuid4

from app import __version__
from app.paging import (
    PagingOutcomeUnknownError,
    PagingProvider,
    PagingRateLimitedError,
)
from app.safety_capabilities import SafetyCapabilitySigner
from app.safety_repository import SafetyNotFoundError, SafetyRepository

logger = logging.getLogger("noop.safety")


def safety_incident_summary(
    trigger: str,
    evidence: dict[str, Any] | None = None,
) -> str:
    """Return provider-safe, non-diagnostic context with no arbitrary user text."""

    if trigger == "band_sos":
        return "Started after a repeated SOS gesture on their Noop Band."
    if trigger == "validated_fall":
        return (
            "Possible-fall motion evidence was recorded after the user did not "
            "respond to the on-device safety check. This is an observation, "
            "not a diagnosis."
        )
    return "Started from the NOOP app."


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
        max_concurrency: int = 10,
        maintenance_batch_size: int = 200,
        provider_max_requests_per_second: int = 5,
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
        self.max_concurrency = max_concurrency
        self.maintenance_batch_size = maintenance_batch_size
        self.provider_max_requests_per_second = provider_max_requests_per_second
        self.worker_id = f"safety-{uuid4()}"
        self._wake_event: asyncio.Event | None = None
        self._submission_limit: asyncio.Semaphore | None = None

    def wake(self) -> None:
        if self._wake_event is not None:
            self._wake_event.set()

    async def run(self, *, stop_event: asyncio.Event | None = None) -> None:
        self._wake_event = asyncio.Event()
        self._submission_limit = asyncio.Semaphore(self.max_concurrency)
        while stop_event is None or not stop_event.is_set():
            processed = 0
            try:
                processed = await self.process_once()
                self._record_local_liveness()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("safety delivery cycle failed")
            if stop_event is not None and stop_event.is_set():
                break
            if processed > 0:
                # A concurrency-sized wave may leave other due rows behind.
                # Recheck immediately; the first empty cycle returns to the
                # bounded idle wait below.
                continue
            try:
                await asyncio.wait_for(
                    self._wake_event.wait(),
                    timeout=self.poll_seconds,
                )
            except TimeoutError:
                pass
            finally:
                self._wake_event.clear()

    @staticmethod
    def _record_local_liveness() -> None:
        path = Path(
            os.getenv(
                "NOOP_SAFETY_WORKER_HEARTBEAT_FILE",
                "/tmp/noop-safety-worker-heartbeat",
            )
        )
        path.touch(mode=0o600, exist_ok=True)

    async def process_once(self) -> int:
        now = await self.repository.coordination_now()
        await self.repository.record_worker_heartbeat(
            worker_id=self.worker_id,
            now=now,
            worker_version=__version__,
        )
        await self.repository.expire_due_dispatches(now=now)
        await self.repository.mark_stale_provider_receipts(
            cutoff=now - timedelta(seconds=self.provider_receipt_timeout_seconds),
            now=now,
            limit=self.maintenance_batch_size,
        )
        deliveries = await self.repository.claim_due_deliveries(
            worker_id=self.worker_id,
            now=now,
            lease_until=now + timedelta(seconds=self.lease_seconds),
            limit=min(self.batch_size, self.max_concurrency),
        )
        if self._submission_limit is None:
            self._submission_limit = asyncio.Semaphore(self.max_concurrency)
        if deliveries:
            await asyncio.gather(
                *(self._submit_delivery_bounded(delivery) for delivery in deliveries)
            )
            return len(deliveries)

        invitations = await self.repository.claim_due_invitations(
            worker_id=self.worker_id,
            now=now,
            lease_until=now + timedelta(seconds=self.lease_seconds),
            limit=min(self.batch_size, self.max_concurrency),
        )
        if invitations:
            await asyncio.gather(
                *(
                    self._submit_invitation_bounded(invitation)
                    for invitation in invitations
                )
            )
        return len(invitations)

    async def _submit_delivery_bounded(self, delivery: dict[str, Any]) -> None:
        assert self._submission_limit is not None
        async with self._submission_limit:
            await self._submit_delivery(delivery)

    async def _submit_invitation_bounded(
        self,
        invitation: dict[str, Any],
    ) -> None:
        assert self._submission_limit is not None
        async with self._submission_limit:
            await self._submit_invitation(invitation)

    async def _submit_delivery(self, delivery: dict[str, Any]) -> None:
        response_url = self._response_url(delivery)
        incident_summary = safety_incident_summary(
            str(delivery.get("trigger", "manual_sos")),
            delivery.get("evidence"),
        )
        submission = None
        error: Exception | None = None
        outcome_unknown = False
        retry_after_seconds: int | None = None
        await self._wait_for_sender_slot()
        async with self.repository.paging_submission_permit(
            job_kind="delivery",
            job_id=str(delivery["delivery_id"]),
            attempt_id=str(delivery["attempt_id"]),
            worker_id=self.worker_id,
        ) as permitted:
            if permitted:
                try:
                    if delivery["channel"] == "sms":
                        submission = await self.provider.send_page_sms(
                            to_phone=str(delivery["phone_e164"]),
                            owner_name=str(delivery["owner_display_name"]),
                            incident_summary=incident_summary,
                            response_url=response_url,
                        )
                    else:
                        submission = await self.provider.send_page_voice(
                            to_phone=str(delivery["phone_e164"]),
                            owner_name=str(delivery["owner_display_name"]),
                            incident_summary=incident_summary,
                            response_url=response_url,
                        )
                except asyncio.CancelledError:
                    raise
                except PagingOutcomeUnknownError as exc:
                    error = exc
                    outcome_unknown = True
                except PagingRateLimitedError as exc:
                    error = exc
                    retry_after_seconds = exc.retry_after_seconds
                except Exception as exc:
                    error = exc

        if not permitted:
            released = await self.repository.release_delivery_attempt(
                delivery_id=str(delivery["delivery_id"]),
                attempt_id=str(delivery["attempt_id"]),
                worker_id=self.worker_id,
                now=await self.repository.coordination_now(),
            )
            if not released:
                logger.warning(
                    "safety delivery could not release its paused lease",
                    extra={"delivery_id": str(delivery["delivery_id"])},
                )
            return

        now = await self.repository.coordination_now()
        attempt_count = int(delivery["attempt_count"])
        delay = _retry_delay_seconds(
            base_seconds=self.retry_base_seconds,
            attempt_count=attempt_count,
            retry_after_seconds=retry_after_seconds,
        )
        try:
            await self.repository.complete_delivery_attempt(
                delivery_id=str(delivery["delivery_id"]),
                attempt_id=str(delivery["attempt_id"]),
                worker_id=self.worker_id,
                submission_status=(
                    submission.status
                    if submission
                    else ("unknown" if outcome_unknown else None)
                ),
                provider_reference=(
                    submission.provider_reference if submission else None
                ),
                error=_safe_error(error) if error else None,
                now=now,
                retry_at=now + timedelta(seconds=delay),
            )
        except SafetyNotFoundError:
            # Hard deletion may commit after the provider call drains but before
            # this post-submission bookkeeping obtains its lock.
            logger.info(
                "safety delivery was erased after provider submission",
                extra={"delivery_id": str(delivery["delivery_id"])},
            )
            return
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

    async def _submit_invitation(self, invitation: dict[str, Any]) -> None:
        expires_at = invitation["invite_expires_at"]
        if not isinstance(expires_at, datetime):
            raise TypeError("invitation expiry must be a datetime")
        token = self.capability_signer.invitation_token(
            contact_id=str(invitation["contact_id"]),
            invitation_nonce=str(invitation["invitation_nonce"]),
            expires_at_unix=int(expires_at.timestamp()),
        )
        acceptance_url = f"{self.public_base_url}/safety/accept/{quote(token, safe='')}"
        submission = None
        error: Exception | None = None
        outcome_unknown = False
        retry_after_seconds: int | None = None
        await self._wait_for_sender_slot()
        async with self.repository.paging_submission_permit(
            job_kind="invitation",
            job_id=str(invitation["contact_id"]),
            attempt_id=str(invitation["attempt_id"]),
            worker_id=self.worker_id,
        ) as permitted:
            if permitted:
                try:
                    submission = await self.provider.send_invitation(
                        to_phone=str(invitation["phone_e164"]),
                        contact_name=str(invitation["contact_display_name"]),
                        owner_name=str(invitation["owner_display_name"]),
                        acceptance_url=acceptance_url,
                    )
                except asyncio.CancelledError:
                    raise
                except PagingOutcomeUnknownError as exc:
                    error = exc
                    outcome_unknown = True
                except PagingRateLimitedError as exc:
                    error = exc
                    retry_after_seconds = exc.retry_after_seconds
                except Exception as exc:
                    error = exc

        if not permitted:
            released = await self.repository.release_invitation_attempt(
                contact_id=str(invitation["contact_id"]),
                attempt_id=str(invitation["attempt_id"]),
                worker_id=self.worker_id,
                now=await self.repository.coordination_now(),
            )
            if not released:
                logger.warning(
                    "safety invitation could not release its paused lease",
                    extra={"contact_id": str(invitation["contact_id"])},
                )
            return

        now = await self.repository.coordination_now()
        attempt_count = int(invitation["attempt_count"])
        delay = _retry_delay_seconds(
            base_seconds=self.retry_base_seconds,
            attempt_count=attempt_count,
            retry_after_seconds=retry_after_seconds,
        )
        try:
            await self.repository.complete_invitation_attempt(
                contact_id=str(invitation["contact_id"]),
                attempt_id=str(invitation["attempt_id"]),
                worker_id=self.worker_id,
                submission_status=(
                    submission.status
                    if submission
                    else ("unknown" if outcome_unknown else None)
                ),
                provider_reference=(
                    submission.provider_reference if submission else None
                ),
                error=_safe_error(error) if error else None,
                now=now,
                retry_at=now + timedelta(seconds=delay),
            )
        except SafetyNotFoundError:
            logger.info(
                "safety invitation was erased after provider submission",
                extra={"contact_id": str(invitation["contact_id"])},
            )
            return
        if error is not None:
            logger.warning(
                "safety invitation submission failed",
                extra={
                    "contact_id": str(invitation["contact_id"]),
                    "attempt": attempt_count,
                },
            )

    async def _wait_for_sender_slot(self) -> None:
        now = await self.repository.coordination_now()
        delay = await self.repository.reserve_provider_submission_slot(
            now=now,
            requests_per_second=self.provider_max_requests_per_second,
        )
        if delay > 0:
            await asyncio.sleep(delay)

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


def _retry_delay_seconds(
    *,
    base_seconds: int,
    attempt_count: int,
    retry_after_seconds: int | None,
) -> float:
    exponential = min(
        base_seconds * (2 ** max(attempt_count - 1, 0)),
        5 * 60,
    )
    minimum = max(exponential, retry_after_seconds or 0)
    jitter = random.uniform(0.0, max(1.0, exponential * 0.25))
    return min(minimum + jitter, 60 * 60)


async def _run_standalone() -> None:
    from app.config import Settings
    from app.paging import TwilioPagingProvider
    from app.repository import PostgresRepository
    from app.safety_repository import PostgresSafetyRepository

    settings = Settings.from_env()
    settings.validate_for_startup(needs_database=True, needs_api_token=False)
    repository = PostgresRepository(
        settings.database_url or "",
        pool_min_size=settings.pool_min_size,
        pool_max_size=settings.pool_max_size,
        statement_cache_size=settings.database_statement_cache_size,
        run_migrations=settings.run_migrations,
    )
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    worker: SafetyDeliveryWorker | None = None

    def request_stop() -> None:
        stop_event.set()
        if worker is not None:
            worker.wake()

    registered_signals: list[signal.Signals] = []
    for shutdown_signal in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(shutdown_signal, request_stop)
            registered_signals.append(shutdown_signal)
        except NotImplementedError:  # pragma: no cover - Linux container supports this
            pass

    await repository.startup()
    try:
        if not await repository.ready():
            raise RuntimeError(
                "database schema does not match this Safety worker build"
            )
        if not settings.paging_configured:
            logger.info("safety worker idle because paging is not configured")
            idle_interval = min(
                settings.safety_worker_poll_seconds,
                max(1, settings.safety_worker_heartbeat_timeout_seconds // 2),
            )
            while not stop_event.is_set():
                SafetyDeliveryWorker._record_local_liveness()
                try:
                    await asyncio.wait_for(
                        stop_event.wait(),
                        timeout=idle_interval,
                    )
                except TimeoutError:
                    pass
            return
        callback_secret = quote(
            settings.twilio_status_callback_secret or "",
            safe="",
        )
        callback_url = (
            f"{(settings.public_base_url or '').rstrip('/')}"
            "/v1/safety/provider/twilio/status"
            f"?token={callback_secret}"
        )
        provider = TwilioPagingProvider(
            account_sid=settings.twilio_account_sid or "",
            auth_token=settings.twilio_auth_token or "",
            from_phone=settings.twilio_from_phone or "",
            status_callback_url=callback_url,
            timeout_seconds=settings.safety_provider_request_timeout_seconds,
        )
        signer = SafetyCapabilitySigner(
            settings.safety_capability_secret or settings.api_token or "invalid"
        )
        worker = SafetyDeliveryWorker(
            repository=PostgresSafetyRepository(repository),
            provider=provider,
            public_base_url=settings.public_base_url or "",
            capability_signer=signer,
            poll_seconds=settings.safety_worker_poll_seconds,
            lease_seconds=settings.safety_delivery_lease_seconds,
            retry_base_seconds=settings.safety_retry_base_seconds,
            provider_receipt_timeout_seconds=(
                settings.safety_provider_receipt_timeout_seconds
            ),
            batch_size=settings.safety_worker_batch_size,
            max_concurrency=settings.safety_worker_max_concurrency,
            maintenance_batch_size=settings.safety_maintenance_batch_size,
            provider_max_requests_per_second=(
                settings.safety_provider_max_requests_per_second
            ),
        )
        await worker.run(stop_event=stop_event)
    finally:
        await repository.shutdown()
        for shutdown_signal in registered_signals:
            loop.remove_signal_handler(shutdown_signal)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(_run_standalone())
