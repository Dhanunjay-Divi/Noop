from __future__ import annotations

import asyncio
from datetime import datetime
from typing import Any, Protocol
from uuid import UUID, uuid4


class SafetyNotFoundError(Exception):
    pass


class SafetyConflictError(Exception):
    pass


class SafetyNotReadyError(Exception):
    pass


class SafetyRepository(Protocol):
    async def create_profile(
        self,
        *,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        token_hash: str,
    ) -> dict[str, Any]: ...

    async def profile_for_token(self, token_hash: str) -> dict[str, Any] | None: ...

    async def create_contact(
        self,
        *,
        contact_id: str,
        profile_id: str,
        display_name: str,
        phone_e164: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]: ...

    async def list_contacts(self, profile_id: str) -> list[dict[str, Any]]: ...

    async def update_invitation_delivery(
        self,
        *,
        profile_id: str,
        contact_id: str,
        status: str,
        provider_reference: str | None,
        error: str | None,
    ) -> dict[str, Any]: ...

    async def renew_invitation(
        self,
        *,
        profile_id: str,
        contact_id: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]: ...

    async def revoke_contact(
        self, *, profile_id: str, contact_id: str, now: datetime
    ) -> None: ...

    async def invitation_preview(
        self, invite_token_hash: str
    ) -> dict[str, Any] | None: ...

    async def decide_invitation(
        self,
        *,
        invite_token_hash: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        trigger: str,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
    ) -> dict[str, Any]: ...

    async def claim_due_deliveries(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def complete_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        submission_status: str | None,
        provider_reference: str | None,
        error: str | None,
        now: datetime,
        retry_at: datetime,
    ) -> None: ...

    async def dispatch(
        self, *, profile_id: str, dispatch_id: str
    ) -> dict[str, Any]: ...

    async def list_dispatches(
        self, *, profile_id: str, limit: int
    ) -> list[dict[str, Any]]: ...

    async def update_incident_location(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        sequence: int,
        latitude: float,
        longitude: float,
        horizontal_accuracy_meters: float | None,
        captured_at: datetime,
        received_at: datetime,
    ) -> dict[str, Any]: ...

    async def update_provider_receipt(
        self,
        *,
        provider_reference: str,
        status: str,
        now: datetime,
        retry_at: datetime,
    ) -> bool: ...

    async def mark_stale_provider_receipts(
        self, *, cutoff: datetime, now: datetime
    ) -> int: ...

    async def expire_due_dispatches(self, *, now: datetime) -> int: ...

    async def responder_preview(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        now: datetime,
    ) -> dict[str, Any] | None: ...

    async def record_responder_decision(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        decision: str,
        source: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def transition_dispatch(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        action: str,
        note: str | None,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def monitoring_snapshot(self, *, now: datetime) -> dict[str, Any]: ...


def _public_profile(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in row.items()
        if key not in {"token_hash", "disabled_at"}
    }


def _public_contact(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in row.items()
        if key not in {"invite_token_hash", "profile_id"}
    }


class MemorySafetyRepository:
    """Deterministic safety store used by API tests and local experiments."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._profiles: dict[str, dict[str, Any]] = {}
        self._profile_tokens: dict[str, str] = {}
        self._contacts: dict[str, dict[str, Any]] = {}
        self._invitation_tokens: dict[str, str] = {}
        self._dispatches: dict[str, dict[str, Any]] = {}
        self._dispatch_keys: dict[tuple[str, str], str] = {}
        self._deliveries: dict[str, dict[str, Any]] = {}
        self._delivery_attempts: dict[str, dict[str, Any]] = {}
        self._responses: dict[tuple[str, str], dict[str, Any]] = {}
        self._locations: dict[str, dict[str, Any]] = {}

    async def create_profile(
        self,
        *,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        token_hash: str,
    ) -> dict[str, Any]:
        async with self._lock:
            existing = next(
                (
                    row
                    for row in self._profiles.values()
                    if row["enrollment_id"] == enrollment_id
                    or (
                        row["installation_id"] == installation_id
                        and row["disabled_at"] is None
                    )
                ),
                None,
            )
            if existing is not None:
                if (
                    existing["enrollment_id"] == enrollment_id
                    and existing["installation_id"] == installation_id
                    and existing["display_name"] == display_name
                    and existing["token_hash"] == token_hash
                    and existing["disabled_at"] is None
                ):
                    return _public_profile(existing)
                raise SafetyConflictError(
                    "this installation already has a safety profile"
                )
            if token_hash in self._profile_tokens:
                raise SafetyConflictError("safety credential is already enrolled")
            now = datetime.now().astimezone()
            profile = {
                "profile_id": profile_id,
                "enrollment_id": enrollment_id,
                "display_name": display_name,
                "installation_id": installation_id,
                "token_hash": token_hash,
                "created_at": now,
                "updated_at": now,
                "disabled_at": None,
            }
            self._profiles[profile_id] = profile
            self._profile_tokens[token_hash] = profile_id
            return _public_profile(profile)

    async def profile_for_token(self, token_hash: str) -> dict[str, Any] | None:
        async with self._lock:
            profile_id = self._profile_tokens.get(token_hash)
            profile = self._profiles.get(profile_id or "")
            if profile is None or profile["disabled_at"] is not None:
                return None
            return _public_profile(profile)

    async def create_contact(
        self,
        *,
        contact_id: str,
        profile_id: str,
        display_name: str,
        phone_e164: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            self._require_profile(profile_id)
            current = [
                row
                for row in self._contacts.values()
                if row["profile_id"] == profile_id and row["revoked_at"] is None
            ]
            if len(current) >= 5:
                raise SafetyConflictError(
                    "a safety profile can have at most five contacts"
                )
            if any(row["phone_e164"] == phone_e164 for row in current):
                raise SafetyConflictError("this phone number is already a contact")
            if invite_token_hash in self._invitation_tokens:
                raise SafetyConflictError("invitation token is already in use")
            contact = {
                "contact_id": contact_id,
                "profile_id": profile_id,
                "display_name": display_name,
                "phone_e164": phone_e164,
                "status": "pending",
                "invite_token_hash": invite_token_hash,
                "invited_at": invited_at,
                "invite_expires_at": invite_expires_at,
                "invitation_provider_reference": None,
                "invitation_delivery_status": "pending",
                "invitation_error": None,
                "accepted_at": None,
                "declined_at": None,
                "revoked_at": None,
                "created_at": invited_at,
                "updated_at": invited_at,
            }
            self._contacts[contact_id] = contact
            self._invitation_tokens[invite_token_hash] = contact_id
            return _public_contact(contact)

    async def list_contacts(self, profile_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            self._require_profile(profile_id)
            rows = [
                _public_contact(row)
                for row in self._contacts.values()
                if row["profile_id"] == profile_id and row["revoked_at"] is None
            ]
            return sorted(
                rows,
                key=lambda row: (
                    row["status"] != "accepted",
                    str(row["display_name"]).casefold(),
                    row["contact_id"],
                ),
            )

    async def update_invitation_delivery(
        self,
        *,
        profile_id: str,
        contact_id: str,
        status: str,
        provider_reference: str | None,
        error: str | None,
    ) -> dict[str, Any]:
        async with self._lock:
            contact = self._owned_contact(profile_id, contact_id)
            contact["invitation_delivery_status"] = status
            contact["invitation_provider_reference"] = provider_reference
            contact["invitation_error"] = error
            contact["updated_at"] = datetime.now().astimezone()
            return _public_contact(contact)

    async def renew_invitation(
        self,
        *,
        profile_id: str,
        contact_id: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            contact = self._owned_contact(profile_id, contact_id)
            if contact["status"] == "accepted":
                raise SafetyConflictError(
                    "an accepted contact does not need another invitation"
                )
            old_hash = contact["invite_token_hash"]
            if old_hash:
                self._invitation_tokens.pop(old_hash, None)
            contact.update(
                {
                    "status": "pending",
                    "invite_token_hash": invite_token_hash,
                    "invited_at": invited_at,
                    "invite_expires_at": invite_expires_at,
                    "invitation_provider_reference": None,
                    "invitation_delivery_status": "pending",
                    "invitation_error": None,
                    "accepted_at": None,
                    "declined_at": None,
                    "updated_at": invited_at,
                }
            )
            self._invitation_tokens[invite_token_hash] = contact_id
            return _public_contact(contact)

    async def revoke_contact(
        self, *, profile_id: str, contact_id: str, now: datetime
    ) -> None:
        async with self._lock:
            contact = self._owned_contact(profile_id, contact_id)
            token_hash = contact["invite_token_hash"]
            if token_hash:
                self._invitation_tokens.pop(token_hash, None)
            contact["status"] = "revoked"
            contact["invite_token_hash"] = None
            contact["revoked_at"] = now
            contact["updated_at"] = now

    async def invitation_preview(self, invite_token_hash: str) -> dict[str, Any] | None:
        async with self._lock:
            contact_id = self._invitation_tokens.get(invite_token_hash)
            contact = self._contacts.get(contact_id or "")
            if contact is None or contact["revoked_at"] is not None:
                return None
            profile = self._profiles.get(contact["profile_id"])
            if profile is None or profile["disabled_at"] is not None:
                return None
            return {
                "contact": _public_contact(contact),
                "owner_display_name": profile["display_name"],
            }

    async def decide_invitation(
        self,
        *,
        invite_token_hash: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            contact_id = self._invitation_tokens.get(invite_token_hash)
            contact = self._contacts.get(contact_id or "")
            if (
                contact is None
                or contact["revoked_at"] is not None
                or contact["status"] != "pending"
                or contact["invite_expires_at"] <= now
            ):
                raise SafetyNotFoundError(
                    "invitation is invalid, expired, or already used"
                )
            contact["status"] = "accepted" if decision == "accept" else "declined"
            contact["accepted_at"] = now if decision == "accept" else None
            contact["declined_at"] = now if decision == "decline" else None
            contact["updated_at"] = now
            contact["invite_token_hash"] = None
            self._invitation_tokens.pop(invite_token_hash, None)
            return _public_contact(contact)

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        trigger: str,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            self._require_profile(profile_id)
            existing_id = self._dispatch_keys.get((profile_id, idempotency_key))
            if existing_id is not None:
                existing = self._dispatches[existing_id]
                if existing["request_hash"] != request_hash:
                    raise SafetyConflictError(
                        "Idempotency-Key was already used for a different page"
                    )
                return self._dispatch_payload(existing_id, idempotent_replay=True)
            if any(
                row["profile_id"] == profile_id
                and row["status"] in {"open", "acknowledged"}
                for row in self._dispatches.values()
            ):
                raise SafetyConflictError(
                    "resolve or cancel the active safety incident first"
                )
            contacts = sorted(
                (
                    row
                    for row in self._contacts.values()
                    if row["profile_id"] == profile_id
                    and row["status"] == "accepted"
                    and row["revoked_at"] is None
                ),
                key=lambda row: row["contact_id"],
            )
            if len(contacts) < 2:
                raise SafetyNotReadyError(
                    "at least two accepted emergency contacts are required"
                )
            dispatch = {
                "dispatch_id": dispatch_id,
                "profile_id": profile_id,
                "idempotency_key": idempotency_key,
                "request_hash": request_hash,
                "trigger": trigger,
                "status": "open",
                "created_at": now,
                "updated_at": now,
                "expires_at": expires_at,
                "acknowledged_at": None,
                "resolved_at": None,
                "cancelled_at": None,
                "acknowledged_contact_id": None,
                "resolution_note": None,
                "completed_at": None,
            }
            self._dispatches[dispatch_id] = dispatch
            self._dispatch_keys[(profile_id, idempotency_key)] = dispatch_id
            for contact in contacts:
                for channel in ("sms", "voice"):
                    delivery_id = str(uuid4())
                    self._deliveries[delivery_id] = {
                        "delivery_id": delivery_id,
                        "dispatch_id": dispatch_id,
                        "contact_id": contact["contact_id"],
                        "contact_display_name": contact["display_name"],
                        "phone_e164": contact["phone_e164"],
                        "channel": channel,
                        "status": "pending",
                        "provider_reference": None,
                        "error": None,
                        "available_at": (
                            now if channel == "sms" else voice_fallback_at
                        ),
                        "lease_owner": None,
                        "lease_expires_at": None,
                        "attempt_count": 0,
                        "max_attempts": 3 if channel == "sms" else 2,
                        "last_attempt_at": None,
                        "delivered_at": None,
                        "terminal_at": None,
                        "created_at": now,
                        "updated_at": now,
                    }
            return self._dispatch_payload(dispatch_id, idempotent_replay=False)

    async def claim_due_deliveries(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            claimed: list[dict[str, Any]] = []
            candidates = sorted(
                self._deliveries.values(),
                key=lambda row: (
                    row["available_at"],
                    row["created_at"],
                    row["delivery_id"],
                ),
            )
            for delivery in candidates:
                if len(claimed) >= max(limit, 0):
                    break
                dispatch = self._dispatches[delivery["dispatch_id"]]
                if dispatch["status"] != "open" or dispatch["expires_at"] <= now:
                    continue
                due = (
                    delivery["status"] in {"pending", "retry_wait"}
                    and delivery["available_at"] <= now
                )
                stale = (
                    delivery["status"] == "leased"
                    and delivery["lease_expires_at"] is not None
                    and delivery["lease_expires_at"] <= now
                )
                if not (due or stale):
                    continue
                if stale:
                    self._finish_started_attempt(
                        delivery["delivery_id"],
                        status="unknown",
                        error="worker lease expired before outcome was recorded",
                        now=now,
                    )
                if delivery["attempt_count"] >= delivery["max_attempts"]:
                    delivery.update(
                        {
                            "status": "failed",
                            "error": "delivery retry limit reached",
                            "terminal_at": now,
                            "lease_owner": None,
                            "lease_expires_at": None,
                            "updated_at": now,
                        }
                    )
                    self._expedite_voice_fallback(delivery, now)
                    continue
                delivery["attempt_count"] += 1
                delivery.update(
                    {
                        "status": "leased",
                        "lease_owner": worker_id,
                        "lease_expires_at": lease_until,
                        "last_attempt_at": now,
                        "updated_at": now,
                    }
                )
                attempt_id = str(uuid4())
                self._delivery_attempts[attempt_id] = {
                    "attempt_id": attempt_id,
                    "delivery_id": delivery["delivery_id"],
                    "attempt_number": delivery["attempt_count"],
                    "status": "started",
                    "provider_reference": None,
                    "error": None,
                    "started_at": now,
                    "finished_at": None,
                }
                profile = self._profiles[dispatch["profile_id"]]
                claimed.append(
                    dict(delivery)
                    | {
                        "attempt_id": attempt_id,
                        "owner_display_name": profile["display_name"],
                        "expires_at": dispatch["expires_at"],
                    }
                )
            return claimed

    async def complete_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        submission_status: str | None,
        provider_reference: str | None,
        error: str | None,
        now: datetime,
        retry_at: datetime,
    ) -> None:
        async with self._lock:
            delivery = self._deliveries.get(delivery_id)
            attempt = self._delivery_attempts.get(attempt_id)
            if delivery is None or attempt is None:
                raise SafetyNotFoundError("delivery was not found")
            if attempt["delivery_id"] != delivery_id:
                raise SafetyConflictError("delivery attempt does not match its job")
            outcome = submission_status or "failed"
            attempt.update(
                {
                    "status": outcome,
                    "provider_reference": provider_reference,
                    "error": error,
                    "finished_at": now,
                }
            )
            dispatch = self._dispatches[delivery["dispatch_id"]]
            lease_is_current = (
                delivery["status"] == "leased" and delivery["lease_owner"] == worker_id
            )
            if not lease_is_current:
                return
            delivery.update(
                {
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "provider_reference": provider_reference,
                    "updated_at": now,
                }
            )
            submission_failed = submission_status == "failed"
            failure_error = error or (
                "paging provider reported delivery failure"
                if submission_failed
                else None
            )
            if submission_status is not None and not submission_failed:
                delivery.update(
                    {
                        "status": submission_status,
                        "error": None,
                        "delivered_at": (
                            now if submission_status == "delivered" else None
                        ),
                        "terminal_at": (
                            now if submission_status == "delivered" else None
                        ),
                    }
                )
            elif (
                delivery["attempt_count"] < delivery["max_attempts"]
                and dispatch["status"] == "open"
                and retry_at < dispatch["expires_at"]
            ):
                delivery.update(
                    {
                        "status": "retry_wait",
                        "available_at": retry_at,
                        "provider_reference": None,
                        "error": failure_error,
                    }
                )
            else:
                delivery.update(
                    {
                        "status": "failed",
                        "provider_reference": None,
                        "error": failure_error,
                        "terminal_at": now,
                    }
                )
                self._expedite_voice_fallback(delivery, now)
            dispatch["updated_at"] = now

    async def dispatch(self, *, profile_id: str, dispatch_id: str) -> dict[str, Any]:
        async with self._lock:
            dispatch = self._dispatches.get(dispatch_id)
            if dispatch is None or dispatch["profile_id"] != profile_id:
                raise SafetyNotFoundError("page was not found")
            return self._dispatch_payload(dispatch_id, idempotent_replay=True)

    async def list_dispatches(
        self, *, profile_id: str, limit: int
    ) -> list[dict[str, Any]]:
        async with self._lock:
            self._require_profile(profile_id)
            rows = sorted(
                (
                    row
                    for row in self._dispatches.values()
                    if row["profile_id"] == profile_id
                ),
                key=lambda row: (row["created_at"], row["dispatch_id"]),
                reverse=True,
            )[: max(0, limit)]
            return [
                self._dispatch_payload(
                    row["dispatch_id"],
                    idempotent_replay=True,
                )
                for row in rows
            ]

    async def update_incident_location(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        sequence: int,
        latitude: float,
        longitude: float,
        horizontal_accuracy_meters: float | None,
        captured_at: datetime,
        received_at: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            dispatch = self._dispatches.get(dispatch_id)
            if dispatch is None or dispatch["profile_id"] != profile_id:
                raise SafetyNotFoundError("safety incident was not found")
            if (
                dispatch["status"] not in {"open", "acknowledged"}
                or dispatch["expires_at"] <= received_at
            ):
                raise SafetyConflictError(
                    "this safety incident is no longer accepting location updates"
                )
            current = self._locations.get(dispatch_id)
            if current is not None and (
                sequence <= current["sequence"]
                or captured_at <= current["captured_at"]
            ):
                return dict(current) | {"idempotent_replay": True}
            location = {
                "sequence": sequence,
                "latitude": latitude,
                "longitude": longitude,
                "horizontal_accuracy_meters": horizontal_accuracy_meters,
                "captured_at": captured_at,
                "received_at": received_at,
            }
            self._locations[dispatch_id] = location
            dispatch["updated_at"] = received_at
            return dict(location) | {"idempotent_replay": False}

    async def update_provider_receipt(
        self,
        *,
        provider_reference: str,
        status: str,
        now: datetime,
        retry_at: datetime,
    ) -> bool:
        async with self._lock:
            contact = next(
                (
                    row
                    for row in self._contacts.values()
                    if row["invitation_provider_reference"] == provider_reference
                ),
                None,
            )
            if contact is not None:
                contact["invitation_delivery_status"] = status
                contact["updated_at"] = now
                return True
            attempt = next(
                (
                    row
                    for row in self._delivery_attempts.values()
                    if row["provider_reference"] == provider_reference
                ),
                None,
            )
            delivery = (
                self._deliveries.get(attempt["delivery_id"])
                if attempt is not None
                else None
            )
            if attempt is None or delivery is None:
                return False
            attempt["status"] = _advanced_provider_status(
                str(attempt["status"]),
                status,
            )
            attempt["finished_at"] = now
            dispatch = self._dispatches[delivery["dispatch_id"]]
            is_latest = delivery["provider_reference"] == provider_reference
            if status == "delivered":
                delivery.update(
                    {
                        "status": "delivered",
                        "error": None,
                        "delivered_at": now,
                        "terminal_at": now,
                        "updated_at": now,
                    }
                )
            elif status == "failed" and is_latest and delivery["status"] != "delivered":
                if (
                    delivery["attempt_count"] < delivery["max_attempts"]
                    and dispatch["status"] == "open"
                    and retry_at < dispatch["expires_at"]
                ):
                    delivery.update(
                        {
                            "status": "retry_wait",
                            "available_at": retry_at,
                            "error": "paging provider reported delivery failure",
                            "updated_at": now,
                        }
                    )
                else:
                    delivery.update(
                        {
                            "status": "failed",
                            "error": "paging provider reported delivery failure",
                            "terminal_at": now,
                            "updated_at": now,
                        }
                    )
                    self._expedite_voice_fallback(delivery, now)
            elif is_latest and delivery["status"] not in {
                "delivered",
                "failed",
                "cancelled",
            }:
                delivery["status"] = _advanced_provider_status(
                    str(delivery["status"]),
                    status,
                )
                delivery["updated_at"] = now
            dispatch["updated_at"] = now
            return True

    async def mark_stale_provider_receipts(
        self, *, cutoff: datetime, now: datetime
    ) -> int:
        async with self._lock:
            changed = 0
            for delivery in self._deliveries.values():
                dispatch = self._dispatches[delivery["dispatch_id"]]
                if (
                    dispatch["status"] == "open"
                    and delivery["status"] in {"queued", "sent"}
                    and delivery["updated_at"] <= cutoff
                ):
                    delivery.update(
                        {
                            "status": "unknown",
                            "error": "provider delivery receipt timed out",
                            "terminal_at": now,
                            "updated_at": now,
                        }
                    )
                    self._finish_attempt_for_reference(
                        delivery["provider_reference"],
                        status="unknown",
                        error="provider delivery receipt timed out",
                        now=now,
                    )
                    self._expedite_voice_fallback(delivery, now)
                    changed += 1
            return changed

    async def expire_due_dispatches(self, *, now: datetime) -> int:
        async with self._lock:
            changed = 0
            for dispatch in self._dispatches.values():
                if dispatch["status"] == "open" and dispatch["expires_at"] <= now:
                    dispatch.update(
                        {
                            "status": "expired",
                            "updated_at": now,
                            "completed_at": now,
                        }
                    )
                    self._cancel_pending_deliveries(
                        dispatch["dispatch_id"],
                        now=now,
                    )
                    changed += 1
            return changed

    async def responder_preview(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        now: datetime,
    ) -> dict[str, Any] | None:
        async with self._lock:
            dispatch = self._dispatches.get(dispatch_id)
            contact = self._contacts.get(contact_id)
            if (
                dispatch is None
                or contact is None
                or not self._is_dispatch_recipient(dispatch_id, contact_id)
            ):
                return None
            profile = self._profiles.get(dispatch["profile_id"])
            if profile is None:
                return None
            effective_status = (
                "expired"
                if dispatch["status"] == "open" and dispatch["expires_at"] <= now
                else dispatch["status"]
            )
            return {
                "dispatch_id": dispatch_id,
                "contact_id": contact_id,
                "contact_display_name": contact["display_name"],
                "owner_display_name": profile["display_name"],
                "status": effective_status,
                "expires_at": dispatch["expires_at"],
                "response": self._responses.get((dispatch_id, contact_id)),
                "latest_location": self._locations.get(dispatch_id),
            }

    async def record_responder_decision(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        decision: str,
        source: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            dispatch = self._dispatches.get(dispatch_id)
            if dispatch is None or not self._is_dispatch_recipient(
                dispatch_id, contact_id
            ):
                raise SafetyNotFoundError("safety incident was not found")
            if dispatch["status"] == "open" and dispatch["expires_at"] <= now:
                dispatch.update(
                    {
                        "status": "expired",
                        "updated_at": now,
                        "completed_at": now,
                    }
                )
                self._cancel_pending_deliveries(dispatch_id, now=now)
            if dispatch["status"] in {"resolved", "cancelled", "expired"}:
                raise SafetyConflictError(
                    "this safety incident is no longer accepting responses"
                )
            response = {
                "dispatch_id": dispatch_id,
                "contact_id": contact_id,
                "contact_display_name": self._contacts[contact_id]["display_name"],
                "decision": decision,
                "source": source,
                "responded_at": now,
            }
            self._responses[(dispatch_id, contact_id)] = response
            if decision == "responding" and dispatch["status"] == "open":
                dispatch.update(
                    {
                        "status": "acknowledged",
                        "acknowledged_at": now,
                        "acknowledged_contact_id": contact_id,
                        "updated_at": now,
                    }
                )
                self._cancel_pending_deliveries(dispatch_id, now=now)
            elif decision == "cannot_respond":
                self._cancel_pending_deliveries(
                    dispatch_id,
                    now=now,
                    contact_id=contact_id,
                )
                dispatch["updated_at"] = now
            return self._dispatch_payload(
                dispatch_id,
                idempotent_replay=False,
            )

    async def transition_dispatch(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        action: str,
        note: str | None,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            dispatch = self._dispatches.get(dispatch_id)
            if dispatch is None or dispatch["profile_id"] != profile_id:
                raise SafetyNotFoundError("safety incident was not found")
            target = "resolved" if action == "resolve" else "cancelled"
            if dispatch["status"] == target:
                return self._dispatch_payload(
                    dispatch_id,
                    idempotent_replay=True,
                )
            if dispatch["status"] in {"resolved", "cancelled", "expired"}:
                raise SafetyConflictError(
                    f"cannot {action} a {dispatch['status']} safety incident"
                )
            dispatch.update(
                {
                    "status": target,
                    "updated_at": now,
                    "completed_at": now,
                    "resolved_at": now if target == "resolved" else None,
                    "cancelled_at": now if target == "cancelled" else None,
                    "resolution_note": note,
                }
            )
            self._cancel_pending_deliveries(dispatch_id, now=now)
            return self._dispatch_payload(
                dispatch_id,
                idempotent_replay=False,
            )

    async def monitoring_snapshot(self, *, now: datetime) -> dict[str, Any]:
        async with self._lock:
            open_dispatches = sum(
                row["status"] == "open" for row in self._dispatches.values()
            )
            acknowledged = sum(
                row["status"] == "acknowledged" for row in self._dispatches.values()
            )
            queue: dict[str, int] = {}
            for delivery in self._deliveries.values():
                state = str(delivery["status"])
                queue[state] = queue.get(state, 0) + 1
            return {
                "incidents": {
                    "open": open_dispatches,
                    "acknowledged": acknowledged,
                    "overdue": sum(
                        row["status"] == "open" and row["expires_at"] <= now
                        for row in self._dispatches.values()
                    ),
                },
                "queue": queue,
                "stale_leases": sum(
                    row["status"] == "leased"
                    and row["lease_expires_at"] is not None
                    and row["lease_expires_at"] <= now
                    for row in self._deliveries.values()
                ),
            }

    def _require_profile(self, profile_id: str) -> dict[str, Any]:
        profile = self._profiles.get(profile_id)
        if profile is None or profile["disabled_at"] is not None:
            raise SafetyNotFoundError("safety profile was not found")
        return profile

    def _owned_contact(self, profile_id: str, contact_id: str) -> dict[str, Any]:
        contact = self._contacts.get(contact_id)
        if (
            contact is None
            or contact["profile_id"] != profile_id
            or contact["revoked_at"] is not None
        ):
            raise SafetyNotFoundError("emergency contact was not found")
        return contact

    def _is_dispatch_recipient(self, dispatch_id: str, contact_id: str) -> bool:
        return any(
            row["dispatch_id"] == dispatch_id and row["contact_id"] == contact_id
            for row in self._deliveries.values()
        )

    def _cancel_pending_deliveries(
        self,
        dispatch_id: str,
        *,
        now: datetime,
        contact_id: str | None = None,
    ) -> None:
        for delivery in self._deliveries.values():
            if (
                delivery["dispatch_id"] == dispatch_id
                and (contact_id is None or delivery["contact_id"] == contact_id)
                and delivery["status"] in {"pending", "retry_wait", "leased"}
            ):
                delivery.update(
                    {
                        "status": "cancelled",
                        "lease_owner": None,
                        "lease_expires_at": None,
                        "terminal_at": now,
                        "updated_at": now,
                    }
                )

    def _expedite_voice_fallback(
        self, source_delivery: dict[str, Any], now: datetime
    ) -> None:
        if source_delivery["channel"] != "sms":
            return
        for delivery in self._deliveries.values():
            if (
                delivery["dispatch_id"] == source_delivery["dispatch_id"]
                and delivery["contact_id"] == source_delivery["contact_id"]
                and delivery["channel"] == "voice"
                and delivery["status"] in {"pending", "retry_wait"}
            ):
                delivery["available_at"] = min(delivery["available_at"], now)
                delivery["updated_at"] = now

    def _finish_started_attempt(
        self,
        delivery_id: str,
        *,
        status: str,
        error: str,
        now: datetime,
    ) -> None:
        started = sorted(
            (
                row
                for row in self._delivery_attempts.values()
                if row["delivery_id"] == delivery_id and row["status"] == "started"
            ),
            key=lambda row: row["attempt_number"],
            reverse=True,
        )
        if started:
            started[0].update(
                {
                    "status": status,
                    "error": error,
                    "finished_at": now,
                }
            )

    def _finish_attempt_for_reference(
        self,
        provider_reference: str | None,
        *,
        status: str,
        error: str,
        now: datetime,
    ) -> None:
        if provider_reference is None:
            return
        attempt = next(
            (
                row
                for row in self._delivery_attempts.values()
                if row["provider_reference"] == provider_reference
            ),
            None,
        )
        if attempt is not None:
            attempt.update(
                {
                    "status": status,
                    "error": error,
                    "finished_at": now,
                }
            )

    def _dispatch_payload(
        self, dispatch_id: str, *, idempotent_replay: bool
    ) -> dict[str, Any]:
        dispatch = self._dispatches[dispatch_id]
        deliveries = sorted(
            (
                {
                    key: value
                    for key, value in row.items()
                    if key
                    not in {
                        "dispatch_id",
                        "lease_owner",
                        "lease_expires_at",
                    }
                }
                for row in self._deliveries.values()
                if row["dispatch_id"] == dispatch_id
            ),
            key=lambda row: (
                str(row["contact_display_name"]).casefold(),
                row["channel"],
            ),
        )
        responses = sorted(
            (
                {key: value for key, value in row.items() if key != "dispatch_id"}
                for row in self._responses.values()
                if row["dispatch_id"] == dispatch_id
            ),
            key=lambda row: (row["responded_at"], row["contact_id"]),
        )
        acknowledged_contact_id = dispatch["acknowledged_contact_id"]
        acknowledged_name = (
            self._contacts[acknowledged_contact_id]["display_name"]
            if acknowledged_contact_id in self._contacts
            else None
        )
        return {
            key: value
            for key, value in dispatch.items()
            if key not in {"profile_id", "request_hash"}
        } | {
            "idempotent_replay": idempotent_replay,
            "acknowledged_contact_display_name": acknowledged_name,
            "deliveries": deliveries,
            "responses": responses,
            "latest_location": self._locations.get(dispatch_id),
        }


class PostgresSafetyRepository:
    """Safety storage sharing the primary repository's migrated PostgreSQL pool."""

    def __init__(self, primary_repository: Any) -> None:
        self.primary_repository = primary_repository

    def _pool(self) -> Any:
        return self.primary_repository._require_pool()

    async def create_profile(
        self,
        *,
        profile_id: str,
        enrollment_id: str,
        display_name: str,
        installation_id: str,
        token_hash: str,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-profile:{installation_id}",
                )
                existing = await connection.fetchrow(
                    """
                    SELECT profile_id, enrollment_id, display_name,
                           installation_id, token_hash, created_at, updated_at,
                           disabled_at
                    FROM safety_profiles
                    WHERE enrollment_id = $1
                       OR (installation_id = $2 AND disabled_at IS NULL)
                    FOR UPDATE
                    """,
                    UUID(enrollment_id),
                    installation_id,
                )
                if existing is not None:
                    if (
                        str(existing["enrollment_id"]) == enrollment_id
                        and existing["installation_id"] == installation_id
                        and existing["display_name"] == display_name
                        and existing["token_hash"].strip() == token_hash
                        and existing["disabled_at"] is None
                    ):
                        return _public_profile(dict(existing))
                    raise SafetyConflictError(
                        "this installation already has a safety profile"
                    )
                try:
                    row = await connection.fetchrow(
                        """
                        INSERT INTO safety_profiles (
                            profile_id, enrollment_id, display_name,
                            installation_id, token_hash
                        ) VALUES ($1,$2,$3,$4,$5)
                        RETURNING profile_id, enrollment_id, display_name,
                                  installation_id, created_at, updated_at,
                                  disabled_at
                        """,
                        UUID(profile_id),
                        UUID(enrollment_id),
                        display_name,
                        installation_id,
                        token_hash,
                    )
                except Exception as exc:
                    if getattr(exc, "sqlstate", None) == "23505":
                        raise SafetyConflictError(
                            "safety credential is already enrolled"
                        ) from exc
                    raise
        return dict(row)

    async def profile_for_token(self, token_hash: str) -> dict[str, Any] | None:
        row = await self._pool().fetchrow(
            """
            SELECT profile_id, enrollment_id, display_name, installation_id,
                   created_at, updated_at
            FROM safety_profiles
            WHERE token_hash = $1 AND disabled_at IS NULL
            """,
            token_hash,
        )
        return dict(row) if row else None

    async def create_contact(
        self,
        *,
        contact_id: str,
        profile_id: str,
        display_name: str,
        phone_e164: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]:
        pool = self._pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-contacts:{profile_id}",
                )
                active = await connection.fetchval(
                    """
                    SELECT count(*)
                    FROM safety_contacts
                    WHERE profile_id = $1 AND revoked_at IS NULL
                    """,
                    profile_uuid,
                )
                if active >= 5:
                    raise SafetyConflictError(
                        "a safety profile can have at most five contacts"
                    )
                try:
                    row = await connection.fetchrow(
                        """
                        INSERT INTO safety_contacts (
                            contact_id, profile_id, display_name, phone_e164,
                            invite_token_hash, invited_at, invite_expires_at
                        )
                        SELECT $1, profile_id, $3, $4, $5, $6, $7
                        FROM safety_profiles
                        WHERE profile_id = $2 AND disabled_at IS NULL
                        RETURNING *
                        """,
                        UUID(contact_id),
                        profile_uuid,
                        display_name,
                        phone_e164,
                        invite_token_hash,
                        invited_at,
                        invite_expires_at,
                    )
                except Exception as exc:
                    if getattr(exc, "sqlstate", None) == "23505":
                        raise SafetyConflictError(
                            "this phone number is already a contact"
                        ) from exc
                    raise
                if row is None:
                    raise SafetyNotFoundError("safety profile was not found")
        return _public_contact(dict(row))

    async def list_contacts(self, profile_id: str) -> list[dict[str, Any]]:
        rows = await self._pool().fetch(
            """
            SELECT *
            FROM safety_contacts
            WHERE profile_id = $1 AND revoked_at IS NULL
            ORDER BY (status = 'accepted') DESC, lower(display_name), contact_id
            """,
            UUID(profile_id),
        )
        return [_public_contact(dict(row)) for row in rows]

    async def update_invitation_delivery(
        self,
        *,
        profile_id: str,
        contact_id: str,
        status: str,
        provider_reference: str | None,
        error: str | None,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            UPDATE safety_contacts
            SET invitation_delivery_status = $3,
                invitation_provider_reference = $4,
                invitation_error = $5,
                updated_at = now()
            WHERE contact_id = $1 AND profile_id = $2 AND revoked_at IS NULL
            RETURNING *
            """,
            UUID(contact_id),
            UUID(profile_id),
            status,
            provider_reference,
            error,
        )
        if row is None:
            raise SafetyNotFoundError("emergency contact was not found")
        return _public_contact(dict(row))

    async def renew_invitation(
        self,
        *,
        profile_id: str,
        contact_id: str,
        invite_token_hash: str,
        invited_at: datetime,
        invite_expires_at: datetime,
    ) -> dict[str, Any]:
        try:
            row = await self._pool().fetchrow(
                """
                UPDATE safety_contacts
                SET status = 'pending',
                    invite_token_hash = $3,
                    invited_at = $4,
                    invite_expires_at = $5,
                    invitation_provider_reference = NULL,
                    invitation_delivery_status = 'pending',
                    invitation_error = NULL,
                    accepted_at = NULL,
                    declined_at = NULL,
                    updated_at = $4
                WHERE contact_id = $1 AND profile_id = $2
                  AND revoked_at IS NULL AND status <> 'accepted'
                RETURNING *
                """,
                UUID(contact_id),
                UUID(profile_id),
                invite_token_hash,
                invited_at,
                invite_expires_at,
            )
        except Exception as exc:
            if getattr(exc, "sqlstate", None) == "23505":
                raise SafetyConflictError("invitation token is already in use") from exc
            raise
        if row is None:
            accepted = await self._pool().fetchval(
                """
                SELECT status = 'accepted'
                FROM safety_contacts
                WHERE contact_id = $1 AND profile_id = $2
                  AND revoked_at IS NULL
                """,
                UUID(contact_id),
                UUID(profile_id),
            )
            if accepted:
                raise SafetyConflictError(
                    "an accepted contact does not need another invitation"
                )
            raise SafetyNotFoundError("emergency contact was not found")
        return _public_contact(dict(row))

    async def revoke_contact(
        self, *, profile_id: str, contact_id: str, now: datetime
    ) -> None:
        row = await self._pool().fetchrow(
            """
            UPDATE safety_contacts
            SET status = 'revoked', revoked_at = $3,
                invite_token_hash = NULL, updated_at = $3
            WHERE contact_id = $1 AND profile_id = $2 AND revoked_at IS NULL
            RETURNING contact_id
            """,
            UUID(contact_id),
            UUID(profile_id),
            now,
        )
        if row is None:
            raise SafetyNotFoundError("emergency contact was not found")

    async def invitation_preview(self, invite_token_hash: str) -> dict[str, Any] | None:
        row = await self._pool().fetchrow(
            """
            SELECT c.*, p.display_name AS owner_display_name
            FROM safety_contacts c
            JOIN safety_profiles p ON p.profile_id = c.profile_id
            WHERE c.invite_token_hash = $1
              AND c.revoked_at IS NULL
              AND p.disabled_at IS NULL
            """,
            invite_token_hash,
        )
        if row is None:
            return None
        decoded = dict(row)
        owner = decoded.pop("owner_display_name")
        return {
            "contact": _public_contact(decoded),
            "owner_display_name": owner,
        }

    async def decide_invitation(
        self,
        *,
        invite_token_hash: str,
        decision: str,
        now: datetime,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            UPDATE safety_contacts
            SET status = $2,
                accepted_at = CASE WHEN $2 = 'accepted' THEN $3 ELSE NULL END,
                declined_at = CASE WHEN $2 = 'declined' THEN $3 ELSE NULL END,
                invite_token_hash = NULL,
                updated_at = $3
            WHERE invite_token_hash = $1
              AND status = 'pending'
              AND revoked_at IS NULL
              AND invite_expires_at > $3
            RETURNING *
            """,
            invite_token_hash,
            "accepted" if decision == "accept" else "declined",
            now,
        )
        if row is None:
            raise SafetyNotFoundError("invitation is invalid, expired, or already used")
        return _public_contact(dict(row))

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        trigger: str,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
    ) -> dict[str, Any]:
        pool = self._pool()
        profile_uuid = UUID(profile_id)
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-page:{profile_id}",
                )
                existing = await connection.fetchrow(
                    """
                    SELECT dispatch_id, request_hash
                    FROM safety_dispatches
                    WHERE profile_id = $1 AND idempotency_key = $2
                    """,
                    profile_uuid,
                    UUID(idempotency_key),
                )
                if existing is not None:
                    if existing["request_hash"].strip() != request_hash:
                        raise SafetyConflictError(
                            "Idempotency-Key was already used for a different page"
                        )
                    return await self._dispatch_payload(
                        connection,
                        str(existing["dispatch_id"]),
                        idempotent_replay=True,
                    )
                active = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM safety_dispatches
                        WHERE profile_id = $1
                          AND status IN ('open', 'acknowledged')
                    )
                    """,
                    profile_uuid,
                )
                if active:
                    raise SafetyConflictError(
                        "resolve or cancel the active safety incident first"
                    )
                contacts = await connection.fetch(
                    """
                    SELECT contact_id, display_name, phone_e164
                    FROM safety_contacts
                    WHERE profile_id = $1
                      AND status = 'accepted'
                      AND revoked_at IS NULL
                    ORDER BY contact_id
                    FOR SHARE
                    """,
                    profile_uuid,
                )
                if len(contacts) < 2:
                    raise SafetyNotReadyError(
                        "at least two accepted emergency contacts are required"
                    )
                await connection.execute(
                    """
                    INSERT INTO safety_dispatches (
                        dispatch_id, profile_id, idempotency_key,
                        request_hash, trigger, status, created_at, updated_at,
                        expires_at
                    ) VALUES ($1,$2,$3,$4,$5,'open',$6,$6,$7)
                    """,
                    UUID(dispatch_id),
                    profile_uuid,
                    UUID(idempotency_key),
                    request_hash,
                    trigger,
                    now,
                    expires_at,
                )
                for contact in contacts:
                    for channel in ("sms", "voice"):
                        await connection.execute(
                            """
                            INSERT INTO safety_deliveries (
                                delivery_id, dispatch_id, contact_id, channel,
                                available_at, max_attempts, created_at, updated_at
                            ) VALUES ($1,$2,$3,$4,$5,$6,$7,$7)
                            """,
                            uuid4(),
                            UUID(dispatch_id),
                            contact["contact_id"],
                            channel,
                            now if channel == "sms" else voice_fallback_at,
                            3 if channel == "sms" else 2,
                            now,
                        )
                return await self._dispatch_payload(
                    connection,
                    dispatch_id,
                    idempotent_replay=False,
                )

    async def claim_due_deliveries(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        pool = self._pool()
        claimed: list[dict[str, Any]] = []
        async with pool.acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    SELECT d.delivery_id, d.status, d.attempt_count,
                           d.max_attempts, d.channel, d.dispatch_id,
                           d.contact_id
                    FROM safety_deliveries d
                    JOIN safety_dispatches i
                      ON i.dispatch_id = d.dispatch_id
                    WHERE i.status = 'open'
                      AND i.expires_at > $1
                      AND (
                        (
                          d.status IN ('pending', 'retry_wait')
                          AND d.available_at <= $1
                        )
                        OR (
                          d.status = 'leased'
                          AND d.lease_expires_at <= $1
                        )
                      )
                    ORDER BY d.available_at, d.created_at, d.delivery_id
                    FOR UPDATE OF d SKIP LOCKED
                    LIMIT $2
                    """,
                    now,
                    max(0, limit),
                )
                for row in rows:
                    delivery_id = row["delivery_id"]
                    if row["status"] == "leased":
                        await connection.execute(
                            """
                            UPDATE safety_delivery_attempts
                            SET status = 'unknown',
                                error = 'worker lease expired before outcome was recorded',
                                finished_at = $2
                            WHERE attempt_id = (
                                SELECT attempt_id
                                FROM safety_delivery_attempts
                                WHERE delivery_id = $1 AND status = 'started'
                                ORDER BY attempt_number DESC
                                LIMIT 1
                            )
                            """,
                            delivery_id,
                            now,
                        )
                    if row["attempt_count"] >= row["max_attempts"]:
                        await connection.execute(
                            """
                            UPDATE safety_deliveries
                            SET status = 'failed',
                                error = 'delivery retry limit reached',
                                lease_owner = NULL,
                                lease_expires_at = NULL,
                                terminal_at = $2,
                                updated_at = $2
                            WHERE delivery_id = $1
                            """,
                            delivery_id,
                            now,
                        )
                        if row["channel"] == "sms":
                            await connection.execute(
                                """
                                UPDATE safety_deliveries
                                SET available_at = LEAST(available_at, $3),
                                    updated_at = $3
                                WHERE dispatch_id = $1
                                  AND contact_id = $2
                                  AND channel = 'voice'
                                  AND status IN ('pending', 'retry_wait')
                                """,
                                row["dispatch_id"],
                                row["contact_id"],
                                now,
                            )
                        await connection.execute(
                            """
                            UPDATE safety_dispatches
                            SET updated_at = $2
                            WHERE dispatch_id = $1
                            """,
                            row["dispatch_id"],
                            now,
                        )
                        continue
                    attempt_number = await connection.fetchval(
                        """
                        UPDATE safety_deliveries
                        SET status = 'leased',
                            lease_owner = $2,
                            lease_expires_at = $3,
                            attempt_count = attempt_count + 1,
                            last_attempt_at = $4,
                            updated_at = $4
                        WHERE delivery_id = $1
                        RETURNING attempt_count
                        """,
                        delivery_id,
                        worker_id,
                        lease_until,
                        now,
                    )
                    attempt_id = uuid4()
                    await connection.execute(
                        """
                        INSERT INTO safety_delivery_attempts (
                            attempt_id, delivery_id, attempt_number, status,
                            started_at
                        ) VALUES ($1,$2,$3,'started',$4)
                        """,
                        attempt_id,
                        delivery_id,
                        attempt_number,
                        now,
                    )
                    job = await connection.fetchrow(
                        """
                        SELECT d.*, i.expires_at,
                               p.display_name AS owner_display_name
                        FROM safety_deliveries d
                        JOIN safety_dispatches i
                          ON i.dispatch_id = d.dispatch_id
                        JOIN safety_profiles p
                          ON p.profile_id = i.profile_id
                        WHERE d.delivery_id = $1
                        """,
                        delivery_id,
                    )
                    claimed.append(dict(job) | {"attempt_id": attempt_id})
        return claimed

    async def complete_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        submission_status: str | None,
        provider_reference: str | None,
        error: str | None,
        now: datetime,
        retry_at: datetime,
    ) -> None:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT d.*, i.status AS dispatch_status,
                           i.expires_at AS dispatch_expires_at
                    FROM safety_deliveries d
                    JOIN safety_dispatches i
                      ON i.dispatch_id = d.dispatch_id
                    WHERE d.delivery_id = $1
                    FOR UPDATE OF d
                    """,
                    UUID(delivery_id),
                )
                if row is None:
                    raise SafetyNotFoundError("delivery was not found")
                attempt = await connection.fetchrow(
                    """
                    SELECT delivery_id
                    FROM safety_delivery_attempts
                    WHERE attempt_id = $1
                    """,
                    UUID(attempt_id),
                )
                if attempt is None or attempt["delivery_id"] != row["delivery_id"]:
                    raise SafetyConflictError("delivery attempt does not match its job")
                outcome = submission_status or "failed"
                await connection.execute(
                    """
                    UPDATE safety_delivery_attempts
                    SET status = $2, provider_reference = $3, error = $4,
                        finished_at = $5
                    WHERE attempt_id = $1
                    """,
                    UUID(attempt_id),
                    outcome,
                    provider_reference,
                    error,
                    now,
                )
                if row["status"] != "leased" or row["lease_owner"] != worker_id:
                    return
                submission_failed = submission_status == "failed"
                failure_error = error or (
                    "paging provider reported delivery failure"
                    if submission_failed
                    else None
                )
                if submission_status is not None and not submission_failed:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = $2,
                            provider_reference = $3,
                            error = NULL,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            delivered_at = CASE
                                WHEN $2 = 'delivered' THEN $4
                                ELSE delivered_at
                            END,
                            terminal_at = CASE
                                WHEN $2 = 'delivered' THEN $4
                                ELSE NULL
                            END,
                            updated_at = $4
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        submission_status,
                        provider_reference,
                        now,
                    )
                elif (
                    row["attempt_count"] < row["max_attempts"]
                    and row["dispatch_status"] == "open"
                    and retry_at < row["dispatch_expires_at"]
                ):
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = 'retry_wait',
                            available_at = $2,
                            provider_reference = NULL,
                            error = $3,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            updated_at = $4
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        retry_at,
                        failure_error,
                        now,
                    )
                else:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = 'failed',
                            provider_reference = NULL,
                            error = $2,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            terminal_at = $3,
                            updated_at = $3
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        failure_error,
                        now,
                    )
                    if row["channel"] == "sms":
                        await connection.execute(
                            """
                            UPDATE safety_deliveries
                            SET available_at = LEAST(available_at, $3),
                                updated_at = $3
                            WHERE dispatch_id = $1
                              AND contact_id = $2
                              AND channel = 'voice'
                              AND status IN ('pending', 'retry_wait')
                            """,
                            row["dispatch_id"],
                            row["contact_id"],
                            now,
                        )
                await connection.execute(
                    """
                    UPDATE safety_dispatches
                    SET updated_at = $2
                    WHERE dispatch_id = $1
                    """,
                    row["dispatch_id"],
                    now,
                )

    async def dispatch(self, *, profile_id: str, dispatch_id: str) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            owned = await connection.fetchval(
                """
                SELECT EXISTS (
                    SELECT 1 FROM safety_dispatches
                    WHERE dispatch_id = $1 AND profile_id = $2
                )
                """,
                UUID(dispatch_id),
                UUID(profile_id),
            )
            if not owned:
                raise SafetyNotFoundError("page was not found")
            return await self._dispatch_payload(
                connection,
                dispatch_id,
                idempotent_replay=True,
            )

    async def list_dispatches(
        self, *, profile_id: str, limit: int
    ) -> list[dict[str, Any]]:
        pool = self._pool()
        async with pool.acquire() as connection:
            dispatch_ids = await connection.fetch(
                """
                SELECT dispatch_id
                FROM safety_dispatches
                WHERE profile_id = $1
                ORDER BY created_at DESC, dispatch_id DESC
                LIMIT $2
                """,
                UUID(profile_id),
                max(0, limit),
            )
            return [
                await self._dispatch_payload(
                    connection,
                    str(row["dispatch_id"]),
                    idempotent_replay=True,
                )
                for row in dispatch_ids
            ]

    async def update_incident_location(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        sequence: int,
        latitude: float,
        longitude: float,
        horizontal_accuracy_meters: float | None,
        captured_at: datetime,
        received_at: datetime,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                incident = await connection.fetchrow(
                    """
                    SELECT status, expires_at
                    FROM safety_dispatches
                    WHERE dispatch_id = $1 AND profile_id = $2
                    FOR UPDATE
                    """,
                    UUID(dispatch_id),
                    UUID(profile_id),
                )
                if incident is None:
                    raise SafetyNotFoundError("safety incident was not found")
                if (
                    incident["status"] not in {"open", "acknowledged"}
                    or incident["expires_at"] <= received_at
                ):
                    raise SafetyConflictError(
                        "this safety incident is no longer accepting location updates"
                    )
                current = await connection.fetchrow(
                    """
                    SELECT sequence, latitude, longitude,
                           horizontal_accuracy_meters, captured_at, received_at
                    FROM safety_incident_locations
                    WHERE dispatch_id = $1
                    FOR UPDATE
                    """,
                    UUID(dispatch_id),
                )
                if current is not None and (
                    sequence <= current["sequence"]
                    or captured_at <= current["captured_at"]
                ):
                    return dict(current) | {"idempotent_replay": True}
                updated = await connection.fetchrow(
                    """
                    INSERT INTO safety_incident_locations (
                        dispatch_id, sequence, latitude, longitude,
                        horizontal_accuracy_meters, captured_at, received_at
                    )
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (dispatch_id) DO UPDATE
                    SET sequence = EXCLUDED.sequence,
                        latitude = EXCLUDED.latitude,
                        longitude = EXCLUDED.longitude,
                        horizontal_accuracy_meters =
                            EXCLUDED.horizontal_accuracy_meters,
                        captured_at = EXCLUDED.captured_at,
                        received_at = EXCLUDED.received_at
                    RETURNING sequence, latitude, longitude,
                              horizontal_accuracy_meters,
                              captured_at, received_at
                    """,
                    UUID(dispatch_id),
                    sequence,
                    latitude,
                    longitude,
                    horizontal_accuracy_meters,
                    captured_at,
                    received_at,
                )
                await connection.execute(
                    """
                    UPDATE safety_dispatches
                    SET updated_at = $2
                    WHERE dispatch_id = $1
                    """,
                    UUID(dispatch_id),
                    received_at,
                )
                return dict(updated) | {"idempotent_replay": False}

    async def update_provider_receipt(
        self,
        *,
        provider_reference: str,
        status: str,
        now: datetime,
        retry_at: datetime,
    ) -> bool:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                invitation = await connection.fetchval(
                    """
                    UPDATE safety_contacts
                    SET invitation_delivery_status = $2,
                        updated_at = $3
                    WHERE invitation_provider_reference = $1
                    RETURNING contact_id
                    """,
                    provider_reference,
                    status,
                    now,
                )
                if invitation is not None:
                    return True
                row = await connection.fetchrow(
                    """
                    SELECT a.attempt_id, a.status AS attempt_status,
                           d.*, i.status AS dispatch_status,
                           i.expires_at AS dispatch_expires_at
                    FROM safety_delivery_attempts a
                    JOIN safety_deliveries d
                      ON d.delivery_id = a.delivery_id
                    JOIN safety_dispatches i
                      ON i.dispatch_id = d.dispatch_id
                    WHERE a.provider_reference = $1
                    FOR UPDATE OF a, d
                    """,
                    provider_reference,
                )
                if row is None:
                    return False
                await connection.execute(
                    """
                    UPDATE safety_delivery_attempts
                    SET status = $2, finished_at = $3
                    WHERE attempt_id = $1
                    """,
                    row["attempt_id"],
                    _advanced_provider_status(row["attempt_status"], status),
                    now,
                )
                is_latest = row["provider_reference"] == provider_reference
                if status == "delivered":
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = 'delivered', error = NULL,
                            delivered_at = $2, terminal_at = $2,
                            updated_at = $2
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        now,
                    )
                elif status == "failed" and is_latest and row["status"] != "delivered":
                    if (
                        row["attempt_count"] < row["max_attempts"]
                        and row["dispatch_status"] == "open"
                        and retry_at < row["dispatch_expires_at"]
                    ):
                        await connection.execute(
                            """
                            UPDATE safety_deliveries
                            SET status = 'retry_wait',
                                available_at = $2,
                                error = 'paging provider reported delivery failure',
                                updated_at = $3
                            WHERE delivery_id = $1
                            """,
                            row["delivery_id"],
                            retry_at,
                            now,
                        )
                    else:
                        await connection.execute(
                            """
                            UPDATE safety_deliveries
                            SET status = 'failed',
                                error = 'paging provider reported delivery failure',
                                terminal_at = $2,
                                updated_at = $2
                            WHERE delivery_id = $1
                            """,
                            row["delivery_id"],
                            now,
                        )
                        if row["channel"] == "sms":
                            await connection.execute(
                                """
                                UPDATE safety_deliveries
                                SET available_at = LEAST(available_at, $3),
                                    updated_at = $3
                                WHERE dispatch_id = $1
                                  AND contact_id = $2
                                  AND channel = 'voice'
                                  AND status IN ('pending', 'retry_wait')
                                """,
                                row["dispatch_id"],
                                row["contact_id"],
                                now,
                            )
                elif is_latest and row["status"] not in {
                    "delivered",
                    "failed",
                    "cancelled",
                }:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = $2, updated_at = $3
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        _advanced_provider_status(row["status"], status),
                        now,
                    )
                await connection.execute(
                    """
                    UPDATE safety_dispatches
                    SET updated_at = $2
                    WHERE dispatch_id = $1
                    """,
                    row["dispatch_id"],
                    now,
                )
                return True

    async def mark_stale_provider_receipts(
        self, *, cutoff: datetime, now: datetime
    ) -> int:
        pool = self._pool()
        changed = 0
        async with pool.acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    SELECT d.delivery_id, d.dispatch_id, d.contact_id,
                           d.channel, d.provider_reference
                    FROM safety_deliveries d
                    JOIN safety_dispatches i
                      ON i.dispatch_id = d.dispatch_id
                    WHERE i.status = 'open'
                      AND d.status IN ('queued', 'sent')
                      AND d.updated_at <= $1
                    FOR UPDATE OF d SKIP LOCKED
                    """,
                    cutoff,
                )
                for row in rows:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = 'unknown',
                            error = 'provider delivery receipt timed out',
                            terminal_at = $2,
                            updated_at = $2
                        WHERE delivery_id = $1
                        """,
                        row["delivery_id"],
                        now,
                    )
                    if row["provider_reference"]:
                        await connection.execute(
                            """
                            UPDATE safety_delivery_attempts
                            SET status = 'unknown',
                                error = 'provider delivery receipt timed out',
                                finished_at = $2
                            WHERE provider_reference = $1
                            """,
                            row["provider_reference"],
                            now,
                        )
                    if row["channel"] == "sms":
                        await connection.execute(
                            """
                            UPDATE safety_deliveries
                            SET available_at = LEAST(available_at, $3),
                                updated_at = $3
                            WHERE dispatch_id = $1
                              AND contact_id = $2
                              AND channel = 'voice'
                              AND status IN ('pending', 'retry_wait')
                            """,
                            row["dispatch_id"],
                            row["contact_id"],
                            now,
                        )
                    changed += 1
        return changed

    async def expire_due_dispatches(self, *, now: datetime) -> int:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    UPDATE safety_dispatches
                    SET status = 'expired', updated_at = $1, completed_at = $1
                    WHERE status = 'open' AND expires_at <= $1
                    RETURNING dispatch_id
                    """,
                    now,
                )
                if rows:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries
                        SET status = 'cancelled',
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            terminal_at = $2,
                            updated_at = $2
                        WHERE dispatch_id = ANY($1::uuid[])
                          AND status IN ('pending', 'retry_wait', 'leased')
                        """,
                        [row["dispatch_id"] for row in rows],
                        now,
                    )
                return len(rows)

    async def responder_preview(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        now: datetime,
    ) -> dict[str, Any] | None:
        row = await self._pool().fetchrow(
            """
            SELECT i.dispatch_id, c.contact_id,
                   c.display_name AS contact_display_name,
                   p.display_name AS owner_display_name,
                   CASE
                     WHEN i.status = 'open' AND i.expires_at <= $3
                       THEN 'expired'
                     ELSE i.status
                   END AS status,
                   i.expires_at,
                   r.decision,
                   r.source,
                   r.responded_at,
                   l.sequence AS location_sequence,
                   l.latitude AS location_latitude,
                   l.longitude AS location_longitude,
                   l.horizontal_accuracy_meters AS location_accuracy,
                   l.captured_at AS location_captured_at,
                   l.received_at AS location_received_at
            FROM safety_dispatches i
            JOIN safety_profiles p ON p.profile_id = i.profile_id
            JOIN safety_contacts c ON c.contact_id = $2
            JOIN safety_deliveries d
              ON d.dispatch_id = i.dispatch_id
             AND d.contact_id = c.contact_id
            LEFT JOIN safety_responses r
              ON r.dispatch_id = i.dispatch_id
             AND r.contact_id = c.contact_id
            LEFT JOIN safety_incident_locations l
              ON l.dispatch_id = i.dispatch_id
            WHERE i.dispatch_id = $1
            LIMIT 1
            """,
            UUID(dispatch_id),
            UUID(contact_id),
            now,
        )
        if row is None:
            return None
        decoded = dict(row)
        if decoded["decision"] is None:
            decoded["response"] = None
        else:
            decoded["response"] = {
                "decision": decoded.pop("decision"),
                "source": decoded.pop("source"),
                "responded_at": decoded.pop("responded_at"),
            }
        decoded.pop("decision", None)
        decoded.pop("source", None)
        decoded.pop("responded_at", None)
        if decoded["location_sequence"] is None:
            decoded["latest_location"] = None
        else:
            decoded["latest_location"] = {
                "sequence": decoded.pop("location_sequence"),
                "latitude": decoded.pop("location_latitude"),
                "longitude": decoded.pop("location_longitude"),
                "horizontal_accuracy_meters": decoded.pop("location_accuracy"),
                "captured_at": decoded.pop("location_captured_at"),
                "received_at": decoded.pop("location_received_at"),
            }
        decoded.pop("location_sequence", None)
        decoded.pop("location_latitude", None)
        decoded.pop("location_longitude", None)
        decoded.pop("location_accuracy", None)
        decoded.pop("location_captured_at", None)
        decoded.pop("location_received_at", None)
        return decoded

    async def record_responder_decision(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        decision: str,
        source: str,
        now: datetime,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                incident = await connection.fetchrow(
                    """
                    SELECT *
                    FROM safety_dispatches
                    WHERE dispatch_id = $1
                    FOR UPDATE
                    """,
                    UUID(dispatch_id),
                )
                recipient = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM safety_deliveries
                        WHERE dispatch_id = $1 AND contact_id = $2
                    )
                    """,
                    UUID(dispatch_id),
                    UUID(contact_id),
                )
                if incident is None or not recipient:
                    raise SafetyNotFoundError("safety incident was not found")
                incident_status = incident["status"]
                if incident_status == "open" and incident["expires_at"] <= now:
                    incident_status = "expired"
                    await connection.execute(
                        """
                        UPDATE safety_dispatches
                        SET status = 'expired', updated_at = $2,
                            completed_at = $2
                        WHERE dispatch_id = $1
                        """,
                        UUID(dispatch_id),
                        now,
                    )
                if incident_status in {"resolved", "cancelled", "expired"}:
                    raise SafetyConflictError(
                        "this safety incident is no longer accepting responses"
                    )
                await connection.execute(
                    """
                    INSERT INTO safety_responses (
                        dispatch_id, contact_id, decision, source, responded_at
                    ) VALUES ($1,$2,$3,$4,$5)
                    ON CONFLICT (dispatch_id, contact_id) DO UPDATE
                    SET decision = EXCLUDED.decision,
                        source = EXCLUDED.source,
                        responded_at = EXCLUDED.responded_at
                    """,
                    UUID(dispatch_id),
                    UUID(contact_id),
                    decision,
                    source,
                    now,
                )
                if decision == "responding" and incident_status == "open":
                    await connection.execute(
                        """
                        UPDATE safety_dispatches
                        SET status = 'acknowledged',
                            acknowledged_at = $2,
                            acknowledged_contact_id = $3,
                            updated_at = $2
                        WHERE dispatch_id = $1
                        """,
                        UUID(dispatch_id),
                        now,
                        UUID(contact_id),
                    )
                    await self._cancel_pending_deliveries(
                        connection,
                        dispatch_id=dispatch_id,
                        now=now,
                    )
                elif decision == "cannot_respond":
                    await self._cancel_pending_deliveries(
                        connection,
                        dispatch_id=dispatch_id,
                        contact_id=contact_id,
                        now=now,
                    )
                    await connection.execute(
                        """
                        UPDATE safety_dispatches
                        SET updated_at = $2
                        WHERE dispatch_id = $1
                        """,
                        UUID(dispatch_id),
                        now,
                    )
                return await self._dispatch_payload(
                    connection,
                    dispatch_id,
                    idempotent_replay=False,
                )

    async def transition_dispatch(
        self,
        *,
        profile_id: str,
        dispatch_id: str,
        action: str,
        note: str | None,
        now: datetime,
    ) -> dict[str, Any]:
        pool = self._pool()
        target = "resolved" if action == "resolve" else "cancelled"
        async with pool.acquire() as connection:
            async with connection.transaction():
                incident = await connection.fetchrow(
                    """
                    SELECT status
                    FROM safety_dispatches
                    WHERE dispatch_id = $1 AND profile_id = $2
                    FOR UPDATE
                    """,
                    UUID(dispatch_id),
                    UUID(profile_id),
                )
                if incident is None:
                    raise SafetyNotFoundError("safety incident was not found")
                if incident["status"] == target:
                    return await self._dispatch_payload(
                        connection,
                        dispatch_id,
                        idempotent_replay=True,
                    )
                if incident["status"] in {"resolved", "cancelled", "expired"}:
                    raise SafetyConflictError(
                        f"cannot {action} a {incident['status']} safety incident"
                    )
                await connection.execute(
                    """
                    UPDATE safety_dispatches
                    SET status = $2,
                        updated_at = $3,
                        completed_at = $3,
                        resolved_at = CASE
                            WHEN $2 = 'resolved' THEN $3 ELSE NULL
                        END,
                        cancelled_at = CASE
                            WHEN $2 = 'cancelled' THEN $3 ELSE NULL
                        END,
                        resolution_note = $4
                    WHERE dispatch_id = $1
                    """,
                    UUID(dispatch_id),
                    target,
                    now,
                    note,
                )
                await self._cancel_pending_deliveries(
                    connection,
                    dispatch_id=dispatch_id,
                    now=now,
                )
                return await self._dispatch_payload(
                    connection,
                    dispatch_id,
                    idempotent_replay=False,
                )

    async def monitoring_snapshot(self, *, now: datetime) -> dict[str, Any]:
        pool = self._pool()
        incidents = await pool.fetchrow(
            """
            SELECT
              count(*) FILTER (WHERE status = 'open') AS open,
              count(*) FILTER (WHERE status = 'acknowledged') AS acknowledged,
              count(*) FILTER (
                WHERE status = 'open' AND expires_at <= $1
              ) AS overdue
            FROM safety_dispatches
            """,
            now,
        )
        states = await pool.fetch(
            """
            SELECT status, count(*) AS count
            FROM safety_deliveries
            GROUP BY status
            """
        )
        stale_leases = await pool.fetchval(
            """
            SELECT count(*)
            FROM safety_deliveries
            WHERE status = 'leased' AND lease_expires_at <= $1
            """,
            now,
        )
        return {
            "incidents": {
                key: int(value or 0) for key, value in dict(incidents).items()
            },
            "queue": {row["status"]: int(row["count"]) for row in states},
            "stale_leases": int(stale_leases or 0),
        }

    async def _cancel_pending_deliveries(
        self,
        connection: Any,
        *,
        dispatch_id: str,
        now: datetime,
        contact_id: str | None = None,
    ) -> None:
        await connection.execute(
            """
            UPDATE safety_deliveries
            SET status = 'cancelled',
                lease_owner = NULL,
                lease_expires_at = NULL,
                terminal_at = $3,
                updated_at = $3
            WHERE dispatch_id = $1
              AND ($2::uuid IS NULL OR contact_id = $2)
              AND status IN ('pending', 'retry_wait', 'leased')
            """,
            UUID(dispatch_id),
            UUID(contact_id) if contact_id else None,
            now,
        )

    async def _dispatch_payload(
        self,
        connection: Any,
        dispatch_id: str,
        *,
        idempotent_replay: bool,
    ) -> dict[str, Any]:
        dispatch = await connection.fetchrow(
            """
            SELECT i.dispatch_id, i.idempotency_key, i.trigger, i.status,
                   i.created_at, i.updated_at, i.expires_at,
                   i.acknowledged_at, i.resolved_at, i.cancelled_at,
                   i.acknowledged_contact_id, i.resolution_note,
                   i.completed_at,
                   c.display_name AS acknowledged_contact_display_name
            FROM safety_dispatches i
            LEFT JOIN safety_contacts c
              ON c.contact_id = i.acknowledged_contact_id
            WHERE i.dispatch_id = $1
            """,
            UUID(dispatch_id),
        )
        if dispatch is None:
            raise SafetyNotFoundError("page was not found")
        deliveries = await connection.fetch(
            """
            SELECT d.delivery_id, d.contact_id,
                   c.display_name AS contact_display_name,
                   c.phone_e164, d.channel, d.status,
                   d.provider_reference, d.error,
                   d.available_at, d.attempt_count, d.max_attempts,
                   d.last_attempt_at, d.delivered_at, d.terminal_at,
                   d.created_at, d.updated_at
            FROM safety_deliveries d
            JOIN safety_contacts c ON c.contact_id = d.contact_id
            WHERE d.dispatch_id = $1
            ORDER BY lower(c.display_name), d.channel
            """,
            UUID(dispatch_id),
        )
        responses = await connection.fetch(
            """
            SELECT r.contact_id,
                   c.display_name AS contact_display_name,
                   r.decision, r.source, r.responded_at
            FROM safety_responses r
            JOIN safety_contacts c ON c.contact_id = r.contact_id
            WHERE r.dispatch_id = $1
            ORDER BY r.responded_at, r.contact_id
            """,
            UUID(dispatch_id),
        )
        location = await connection.fetchrow(
            """
            SELECT sequence, latitude, longitude,
                   horizontal_accuracy_meters, captured_at, received_at
            FROM safety_incident_locations
            WHERE dispatch_id = $1
            """,
            UUID(dispatch_id),
        )
        return dict(dispatch) | {
            "idempotent_replay": idempotent_replay,
            "deliveries": [dict(row) for row in deliveries],
            "responses": [dict(row) for row in responses],
            "latest_location": dict(location) if location is not None else None,
        }


def _advanced_provider_status(current: str, incoming: str) -> str:
    if current == "delivered" or incoming == "delivered":
        return "delivered"
    if current == "failed" or incoming == "failed":
        return "failed"
    rank = {
        "started": 0,
        "pending": 0,
        "leased": 0,
        "retry_wait": 0,
        "queued": 1,
        "sent": 2,
        "unknown": 2,
    }
    return incoming if rank.get(incoming, 0) >= rank.get(current, 0) else current
