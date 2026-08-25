from __future__ import annotations

import asyncio
import json
import math
from collections import Counter
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from typing import Any, AsyncContextManager, Literal, Protocol
from uuid import UUID, uuid4

from app.repository import ExportLimitExceededError


class SafetyNotFoundError(Exception):
    pass


class SafetyConflictError(Exception):
    pass


class SafetyNotReadyError(Exception):
    pass


class SafetyRepository(Protocol):
    async def coordination_now(self) -> datetime: ...

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

    async def rotate_profile_token(
        self,
        *,
        profile_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def export_profile(
        self,
        profile_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        max_rows: int = 100_000,
    ) -> dict[str, Any]: ...

    async def delete_profile(self, profile_id: str) -> dict[str, int]: ...

    async def delete_profiles_for_installation(
        self, installation_id: str
    ) -> dict[str, int]: ...

    async def purge_retained_data(
        self,
        *,
        incident_cutoff: datetime | None,
        contact_cutoff: datetime | None,
        replay_guard_until: datetime,
        now: datetime,
        limit: int,
    ) -> dict[str, int]: ...

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
        invitation_nonce: str | None = None,
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
        invitation_nonce: str | None = None,
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

    async def paging_control(self) -> dict[str, Any]: ...

    async def set_paging_control(
        self,
        *,
        enabled: bool,
        reason: str | None,
        expected_revision: int,
        now: datetime,
        actor: str = "system",
        request_id: str | None = None,
    ) -> dict[str, Any]: ...

    def paging_submission_permit(
        self,
        *,
        job_kind: Literal["delivery", "invitation"],
        job_id: str,
        attempt_id: str,
        worker_id: str,
    ) -> AsyncContextManager[bool]: ...

    async def record_worker_heartbeat(
        self,
        *,
        worker_id: str,
        now: datetime,
        worker_version: str = "unknown",
    ) -> None: ...

    async def worker_is_active(self, *, cutoff: datetime) -> bool: ...

    async def reserve_provider_submission_slot(
        self,
        *,
        now: datetime,
        requests_per_second: int,
    ) -> float: ...

    async def claim_due_invitations(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]: ...

    async def complete_invitation_attempt(
        self,
        *,
        contact_id: str,
        attempt_id: str,
        worker_id: str,
        submission_status: str | None,
        provider_reference: str | None,
        error: str | None,
        now: datetime,
        retry_at: datetime,
    ) -> None: ...

    async def release_invitation_attempt(
        self,
        *,
        contact_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool: ...

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        accepted_request_hashes: frozenset[str] = frozenset(),
        trigger: str,
        share_duration_hours: int = 8,
        evidence: dict[str, Any] | None = None,
        escalation_rounds: int = 1,
        escalation_interval_seconds: int = 15 * 60,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
        delivery_ready: bool = True,
    ) -> dict[str, Any]: ...

    async def dispatch_for_idempotency_key(
        self,
        *,
        profile_id: str,
        idempotency_key: str,
        accepted_request_hashes: frozenset[str],
    ) -> dict[str, Any] | None: ...

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

    async def release_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool: ...

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
        self, *, cutoff: datetime, now: datetime, limit: int = 200
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

    async def monitoring_snapshot(
        self,
        *,
        now: datetime,
        worker_cutoff: datetime | None = None,
        window_seconds: int = 24 * 60 * 60,
    ) -> dict[str, Any]: ...


def _public_profile(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in row.items()
        if key
        not in {
            "token_hash",
            "last_rotation_token_hash",
            "disabled_at",
        }
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
        self._submission_condition = asyncio.Condition(self._lock)
        self._active_submission_permits = 0
        self._active_submission_profiles: Counter[str] = Counter()
        self._profiles_pending_deletion: set[str] = set()
        self._profiles: dict[str, dict[str, Any]] = {}
        self._profile_tokens: dict[str, str] = {}
        self._contacts: dict[str, dict[str, Any]] = {}
        self._invitation_tokens: dict[str, str] = {}
        self._invitation_jobs: dict[str, dict[str, Any]] = {}
        self._invitation_attempts: dict[str, dict[str, Any]] = {}
        self._dispatches: dict[str, dict[str, Any]] = {}
        self._dispatch_keys: dict[tuple[str, str], str] = {}
        self._dispatch_tombstones: dict[tuple[str, str], dict[str, Any]] = {}
        self._deliveries: dict[str, dict[str, Any]] = {}
        self._delivery_attempts: dict[str, dict[str, Any]] = {}
        self._responses: dict[tuple[str, str], dict[str, Any]] = {}
        self._locations: dict[str, dict[str, Any]] = {}
        self._paging_control = {
            "enabled": True,
            "reason": None,
            "revision": 1,
            "updated_at": None,
        }
        self._paging_control_audit: list[dict[str, Any]] = []
        self._worker_heartbeats: dict[str, dict[str, Any]] = {}
        self._provider_next_slot_at: datetime | None = None

    async def coordination_now(self) -> datetime:
        return datetime.now(UTC)

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
                "token_version": 1,
                "last_rotation_id": None,
                "last_rotation_token_hash": None,
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

    async def rotate_profile_token(
        self,
        *,
        profile_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            profile = self._profiles.get(profile_id)
            if profile is None or profile["disabled_at"] is not None:
                raise SafetyNotFoundError("safety profile is not active")
            if (
                profile["last_rotation_id"] == rotation_id
                and profile["last_rotation_token_hash"] == token_hash
            ):
                return _public_profile(profile)
            if profile["token_version"] != expected_version:
                raise SafetyConflictError("safety token version has changed")
            token_owner = self._profile_tokens.get(token_hash)
            if token_owner is not None and token_owner != profile_id:
                raise SafetyConflictError("safety credential is already enrolled")
            self._profile_tokens.pop(profile["token_hash"], None)
            profile["token_hash"] = token_hash
            profile["token_version"] += 1
            profile["last_rotation_id"] = rotation_id
            profile["last_rotation_token_hash"] = token_hash
            profile["updated_at"] = now
            self._profile_tokens[token_hash] = profile_id
            return _public_profile(profile)

    async def export_profile(
        self,
        profile_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        max_rows: int = 100_000,
    ) -> dict[str, Any]:
        def in_window(value: datetime) -> bool:
            return (start is None or value >= start) and (end is None or value < end)

        async with self._lock:
            profile = self._require_profile(profile_id)
            contact_rows = sorted(
                (
                    row
                    for row in self._contacts.values()
                    if row["profile_id"] == profile_id and in_window(row["created_at"])
                ),
                key=lambda row: (row["created_at"], row["contact_id"]),
            )
            contact_ids = {row["contact_id"] for row in contact_rows}
            dispatch_rows = sorted(
                (
                    row
                    for row in self._dispatches.values()
                    if row["profile_id"] == profile_id and in_window(row["created_at"])
                ),
                key=lambda row: (row["created_at"], row["dispatch_id"]),
            )
            dispatch_ids = {row["dispatch_id"] for row in dispatch_rows}
            delivery_ids = {
                row["delivery_id"]
                for row in self._deliveries.values()
                if row["dispatch_id"] in dispatch_ids
            }
            row_count = 1 + len(contact_rows) + len(dispatch_rows)
            row_count += sum(
                contact_id in self._invitation_jobs for contact_id in contact_ids
            )
            row_count += sum(
                row["contact_id"] in contact_ids
                for row in self._invitation_attempts.values()
            )
            row_count += len(delivery_ids)
            row_count += sum(
                row["delivery_id"] in delivery_ids
                for row in self._delivery_attempts.values()
            )
            row_count += sum(
                row["dispatch_id"] in dispatch_ids for row in self._responses.values()
            )
            row_count += sum(
                dispatch_id in self._locations for dispatch_id in dispatch_ids
            )
            if row_count > max_rows:
                raise ExportLimitExceededError(max_rows)

            contacts = []
            for contact in contact_rows:
                public = _public_contact(contact)
                job = self._invitation_jobs.get(contact["contact_id"])
                if job is not None:
                    public["invitation_job"] = {
                        key: value
                        for key, value in job.items()
                        if key
                        not in {
                            "invitation_nonce",
                            "lease_owner",
                            "lease_expires_at",
                            "active_attempt_id",
                        }
                    }
                    public["invitation_attempts"] = sorted(
                        (
                            {
                                key: value
                                for key, value in attempt.items()
                                if key
                                not in {
                                    "contact_id",
                                    "invitation_nonce",
                                }
                            }
                            for attempt in self._invitation_attempts.values()
                            if attempt["contact_id"] == contact["contact_id"]
                        ),
                        key=lambda row: (row["started_at"], row["attempt_id"]),
                    )
                contacts.append(public)

            incidents = []
            for dispatch in dispatch_rows:
                payload = self._dispatch_payload(
                    dispatch["dispatch_id"],
                    idempotent_replay=False,
                )
                for delivery in payload["deliveries"]:
                    delivery["attempts"] = sorted(
                        (
                            {
                                key: value
                                for key, value in attempt.items()
                                if key != "delivery_id"
                            }
                            for attempt in self._delivery_attempts.values()
                            if attempt["delivery_id"] == delivery["delivery_id"]
                        ),
                        key=lambda row: (row["started_at"], row["attempt_id"]),
                    )
                incidents.append(payload)
            return {
                "schema_version": 1,
                "exported_at": datetime.now(UTC),
                "row_count": row_count,
                "window": {"start": start, "end": end},
                "profile": _public_profile(profile),
                "contacts": contacts,
                "incidents": incidents,
            }

    async def delete_profile(self, profile_id: str) -> dict[str, int]:
        async with self._submission_condition:
            self._require_profile(profile_id)
            return await self._delete_profiles_after_submission_drain({profile_id})

    async def delete_profiles_for_installation(
        self, installation_id: str
    ) -> dict[str, int]:
        async with self._submission_condition:
            profile_ids = {
                profile_id
                for profile_id, row in self._profiles.items()
                if row["installation_id"] == installation_id
            }
            return await self._delete_profiles_after_submission_drain(profile_ids)

    async def _delete_profiles_after_submission_drain(
        self,
        profile_ids: set[str],
    ) -> dict[str, int]:
        if not profile_ids:
            return {}
        if profile_ids & self._profiles_pending_deletion:
            raise SafetyConflictError("safety profile deletion is already in progress")
        self._profiles_pending_deletion.update(profile_ids)
        try:
            while any(
                self._active_submission_profiles.get(profile_id, 0) > 0
                for profile_id in profile_ids
            ):
                await self._submission_condition.wait()
            return self._delete_profiles_locked(profile_ids)
        finally:
            self._profiles_pending_deletion.difference_update(profile_ids)
            self._submission_condition.notify_all()

    async def purge_retained_data(
        self,
        *,
        incident_cutoff: datetime | None,
        contact_cutoff: datetime | None,
        replay_guard_until: datetime,
        now: datetime,
        limit: int,
    ) -> dict[str, int]:
        async with self._lock:
            expired_tombstones = [
                key
                for key, row in self._dispatch_tombstones.items()
                if row["expires_at"] <= now
            ][:limit]
            for key in expired_tombstones:
                del self._dispatch_tombstones[key]

            retired_incidents = 0
            if incident_cutoff is not None:
                candidates = sorted(
                    (
                        row
                        for row in self._dispatches.values()
                        if row["status"]
                        in {"resolved", "cancelled", "expired", "failed"}
                        and row["completed_at"] is not None
                        and row["completed_at"] < incident_cutoff
                    ),
                    key=lambda row: (row["completed_at"], row["dispatch_id"]),
                )[:limit]
                for dispatch in candidates:
                    key = (
                        dispatch["profile_id"],
                        dispatch["idempotency_key"],
                    )
                    self._dispatch_tombstones[key] = {
                        "profile_id": dispatch["profile_id"],
                        "idempotency_key": dispatch["idempotency_key"],
                        "request_hash": dispatch["request_hash"],
                        "retired_at": now,
                        "expires_at": replay_guard_until,
                    }
                    self._delete_dispatch_locked(dispatch["dispatch_id"])
                    retired_incidents += 1

            retired_contacts = 0
            if contact_cutoff is not None:
                candidates = []
                for contact in self._contacts.values():
                    anchor = {
                        "pending": contact["invite_expires_at"],
                        "declined": contact["declined_at"],
                        "revoked": contact["revoked_at"],
                    }.get(contact["status"])
                    if anchor is None or anchor >= contact_cutoff:
                        continue
                    contact_id = contact["contact_id"]
                    if (
                        any(
                            row["contact_id"] == contact_id
                            for row in self._deliveries.values()
                        )
                        or any(
                            row["contact_id"] == contact_id
                            for row in self._responses.values()
                        )
                        or any(
                            row["acknowledged_contact_id"] == contact_id
                            for row in self._dispatches.values()
                        )
                    ):
                        continue
                    candidates.append(contact)
                for contact in sorted(
                    candidates,
                    key=lambda row: (
                        row["revoked_at"]
                        or row["declined_at"]
                        or row["invite_expires_at"],
                        row["contact_id"],
                    ),
                )[:limit]:
                    self._delete_contact_locked(contact["contact_id"])
                    retired_contacts += 1

            return {
                "incidents": retired_incidents,
                "contacts": retired_contacts,
                "tombstones": len(expired_tombstones),
            }

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
        invitation_nonce: str | None = None,
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
            if invitation_nonce is not None:
                self._invitation_jobs[contact_id] = {
                    "contact_id": contact_id,
                    "invitation_nonce": invitation_nonce,
                    "status": "pending",
                    "available_at": invited_at,
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "active_attempt_id": None,
                    "attempt_count": 0,
                    "max_attempts": 3,
                    "provider_reference": None,
                    "error": None,
                    "last_attempt_at": None,
                    "terminal_at": None,
                    "created_at": invited_at,
                    "updated_at": invited_at,
                }
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
        invitation_nonce: str | None = None,
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
            if invitation_nonce is not None:
                self._invitation_jobs[contact_id] = {
                    "contact_id": contact_id,
                    "invitation_nonce": invitation_nonce,
                    "status": "pending",
                    "available_at": invited_at,
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "active_attempt_id": None,
                    "attempt_count": 0,
                    "max_attempts": 3,
                    "provider_reference": None,
                    "error": None,
                    "last_attempt_at": None,
                    "terminal_at": None,
                    "created_at": invited_at,
                    "updated_at": invited_at,
                }
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
            invitation = self._invitation_jobs.get(contact_id)
            if invitation is not None and invitation["status"] in {
                "pending",
                "retry_wait",
                "leased",
                "queued",
                "sent",
                "unknown",
            }:
                invitation.update(
                    {
                        "status": "cancelled",
                        "lease_owner": None,
                        "lease_expires_at": None,
                        "active_attempt_id": None,
                        "terminal_at": now,
                        "updated_at": now,
                    }
                )

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
            invitation = self._invitation_jobs.get(contact_id)
            if invitation is not None and invitation["status"] in {
                "pending",
                "retry_wait",
                "leased",
                "queued",
                "sent",
                "unknown",
            }:
                invitation.update(
                    {
                        "status": "cancelled",
                        "lease_owner": None,
                        "lease_expires_at": None,
                        "active_attempt_id": None,
                        "terminal_at": now,
                        "updated_at": now,
                    }
                )
            return _public_contact(contact)

    async def paging_control(self) -> dict[str, Any]:
        async with self._lock:
            return dict(self._paging_control)

    async def set_paging_control(
        self,
        *,
        enabled: bool,
        reason: str | None,
        expected_revision: int,
        now: datetime,
        actor: str = "system",
        request_id: str | None = None,
    ) -> dict[str, Any]:
        async with self._submission_condition:
            if int(self._paging_control["revision"]) != expected_revision:
                raise SafetyConflictError(
                    "paging control changed; refresh its revision and retry"
                )
            self._paging_control.update(
                {
                    "enabled": enabled,
                    "reason": reason,
                    "revision": int(self._paging_control["revision"]) + 1,
                    "updated_at": now,
                }
            )
            self._paging_control_audit.append(
                {
                    **self._paging_control,
                    "actor": actor,
                    "request_id": request_id,
                }
            )
            while not enabled and self._active_submission_permits > 0:
                await self._submission_condition.wait()
            return dict(self._paging_control)

    @asynccontextmanager
    async def paging_submission_permit(
        self,
        *,
        job_kind: Literal["delivery", "invitation"],
        job_id: str,
        attempt_id: str,
        worker_id: str,
    ) -> AsyncIterator[bool]:
        profile_id: str | None = None
        async with self._submission_condition:
            profile_id = self._submission_profile_id(
                job_kind=job_kind,
                job_id=job_id,
                attempt_id=attempt_id,
                worker_id=worker_id,
            )
            allowed = (
                bool(self._paging_control["enabled"])
                and profile_id is not None
                and profile_id not in self._profiles_pending_deletion
            )
            if allowed:
                self._active_submission_permits += 1
                self._active_submission_profiles[profile_id] += 1
        try:
            yield allowed
        finally:
            if allowed:
                async with self._submission_condition:
                    self._active_submission_permits -= 1
                    self._active_submission_profiles[profile_id] -= 1
                    if self._active_submission_profiles[profile_id] == 0:
                        del self._active_submission_profiles[profile_id]
                    self._submission_condition.notify_all()

    def _submission_profile_id(
        self,
        *,
        job_kind: Literal["delivery", "invitation"],
        job_id: str,
        attempt_id: str,
        worker_id: str,
    ) -> str | None:
        if job_kind == "delivery":
            delivery = self._deliveries.get(job_id)
            attempt = self._delivery_attempts.get(attempt_id)
            if (
                delivery is None
                or attempt is None
                or attempt["delivery_id"] != job_id
                or attempt["status"] != "started"
                or delivery["status"] != "leased"
                or delivery["lease_owner"] != worker_id
            ):
                return None
            dispatch = self._dispatches.get(str(delivery["dispatch_id"]))
            if dispatch is None or dispatch["status"] != "open":
                return None
            profile_id = str(dispatch["profile_id"])
        else:
            job = self._invitation_jobs.get(job_id)
            attempt = self._invitation_attempts.get(attempt_id)
            contact = self._contacts.get(job_id)
            if (
                job is None
                or attempt is None
                or contact is None
                or attempt["contact_id"] != job_id
                or attempt["status"] != "started"
                or job["status"] != "leased"
                or job["lease_owner"] != worker_id
                or job["active_attempt_id"] != attempt_id
                or contact["status"] != "pending"
                or contact["revoked_at"] is not None
            ):
                return None
            profile_id = str(contact["profile_id"])
        profile = self._profiles.get(profile_id)
        if profile is None or profile["disabled_at"] is not None:
            return None
        return profile_id

    async def record_worker_heartbeat(
        self,
        *,
        worker_id: str,
        now: datetime,
        worker_version: str = "unknown",
    ) -> None:
        async with self._lock:
            heartbeat = self._worker_heartbeats.setdefault(
                worker_id,
                {
                    "started_at": now,
                    "last_seen_at": now,
                    "worker_version": worker_version,
                },
            )
            heartbeat["last_seen_at"] = now
            heartbeat["worker_version"] = worker_version

    async def worker_is_active(self, *, cutoff: datetime) -> bool:
        async with self._lock:
            return any(
                heartbeat["last_seen_at"] >= cutoff
                for heartbeat in self._worker_heartbeats.values()
            )

    async def reserve_provider_submission_slot(
        self,
        *,
        now: datetime,
        requests_per_second: int,
    ) -> float:
        async with self._lock:
            interval = timedelta(seconds=1 / max(requests_per_second, 1))
            reserved_at = max(self._provider_next_slot_at or now, now)
            self._provider_next_slot_at = reserved_at + interval
            return max(0.0, (reserved_at - now).total_seconds())

    async def claim_due_invitations(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            if not self._paging_control["enabled"]:
                return []
            claimed: list[dict[str, Any]] = []
            jobs = sorted(
                self._invitation_jobs.values(),
                key=lambda row: (
                    row["available_at"],
                    row["created_at"],
                    row["contact_id"],
                ),
            )
            for job in jobs:
                if len(claimed) >= max(0, limit):
                    break
                contact = self._contacts[job["contact_id"]]
                profile = self._profiles[contact["profile_id"]]
                if (
                    contact["status"] != "pending"
                    or contact["revoked_at"] is not None
                    or profile["disabled_at"] is not None
                    or contact["invite_expires_at"] <= now
                ):
                    if job["status"] in {"pending", "retry_wait", "leased"}:
                        job.update(
                            {
                                "status": "cancelled",
                                "lease_owner": None,
                                "lease_expires_at": None,
                                "active_attempt_id": None,
                                "terminal_at": now,
                                "updated_at": now,
                            }
                        )
                    continue
                due = (
                    job["status"] in {"pending", "retry_wait"}
                    and job["available_at"] <= now
                )
                stale = (
                    job["status"] == "leased"
                    and job["lease_expires_at"] is not None
                    and job["lease_expires_at"] <= now
                )
                if not (due or stale):
                    continue
                if stale and job["active_attempt_id"] is not None:
                    attempt = self._invitation_attempts.get(job["active_attempt_id"])
                    if attempt is not None and attempt["status"] == "started":
                        attempt.update(
                            {
                                "status": "unknown",
                                "error": (
                                    "worker lease expired before invitation "
                                    "outcome was recorded"
                                ),
                                "finished_at": now,
                            }
                        )
                if job["attempt_count"] >= job["max_attempts"]:
                    job.update(
                        {
                            "status": "failed",
                            "error": "invitation retry limit reached",
                            "lease_owner": None,
                            "lease_expires_at": None,
                            "active_attempt_id": None,
                            "terminal_at": now,
                            "updated_at": now,
                        }
                    )
                    contact["invitation_delivery_status"] = "failed"
                    contact["invitation_error"] = job["error"]
                    contact["updated_at"] = now
                    continue
                job["attempt_count"] += 1
                attempt_id = str(uuid4())
                job.update(
                    {
                        "status": "leased",
                        "lease_owner": worker_id,
                        "lease_expires_at": lease_until,
                        "active_attempt_id": attempt_id,
                        "last_attempt_at": now,
                        "updated_at": now,
                    }
                )
                self._invitation_attempts[attempt_id] = {
                    "attempt_id": attempt_id,
                    "contact_id": job["contact_id"],
                    "invitation_nonce": job["invitation_nonce"],
                    "attempt_number": job["attempt_count"],
                    "status": "started",
                    "provider_reference": None,
                    "error": None,
                    "started_at": now,
                    "finished_at": None,
                }
                claimed.append(
                    dict(job)
                    | {
                        "attempt_id": attempt_id,
                        "phone_e164": contact["phone_e164"],
                        "contact_display_name": contact["display_name"],
                        "owner_display_name": profile["display_name"],
                        "invite_expires_at": contact["invite_expires_at"],
                    }
                )
            return claimed

    async def complete_invitation_attempt(
        self,
        *,
        contact_id: str,
        attempt_id: str,
        worker_id: str,
        submission_status: str | None,
        provider_reference: str | None,
        error: str | None,
        now: datetime,
        retry_at: datetime,
    ) -> None:
        async with self._lock:
            job = self._invitation_jobs.get(contact_id)
            attempt = self._invitation_attempts.get(attempt_id)
            contact = self._contacts.get(contact_id)
            if job is None or attempt is None or contact is None:
                raise SafetyNotFoundError("invitation job was not found")
            if attempt["contact_id"] != contact_id:
                raise SafetyConflictError("invitation attempt does not match its job")
            outcome = submission_status or "failed"
            attempt.update(
                {
                    "status": outcome,
                    "provider_reference": provider_reference,
                    "error": error,
                    "finished_at": now,
                }
            )
            if (
                job["status"] != "leased"
                or job["lease_owner"] != worker_id
                or job["active_attempt_id"] != attempt_id
                or job["invitation_nonce"] != attempt["invitation_nonce"]
            ):
                return
            job.update(
                {
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "active_attempt_id": None,
                    "provider_reference": provider_reference,
                    "updated_at": now,
                }
            )
            submission_failed = submission_status == "failed"
            if submission_status is not None and not submission_failed:
                job["status"] = submission_status
                job["error"] = None
                job["terminal_at"] = (
                    now if submission_status in {"delivered", "unknown"} else None
                )
                contact["invitation_delivery_status"] = submission_status
                contact["invitation_provider_reference"] = provider_reference
                contact["invitation_error"] = None
            elif (
                job["attempt_count"] < job["max_attempts"]
                and contact["status"] == "pending"
                and retry_at < contact["invite_expires_at"]
            ):
                job.update(
                    {
                        "status": "retry_wait",
                        "available_at": retry_at,
                        "provider_reference": None,
                        "error": error or "invitation provider rejected submission",
                    }
                )
                contact["invitation_delivery_status"] = "pending"
                contact["invitation_provider_reference"] = None
                contact["invitation_error"] = job["error"]
            else:
                job.update(
                    {
                        "status": "failed",
                        "provider_reference": None,
                        "error": error or "invitation provider rejected submission",
                        "terminal_at": now,
                    }
                )
                contact["invitation_delivery_status"] = "failed"
                contact["invitation_provider_reference"] = None
                contact["invitation_error"] = job["error"]
            contact["updated_at"] = now

    async def release_invitation_attempt(
        self,
        *,
        contact_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool:
        async with self._lock:
            job = self._invitation_jobs.get(contact_id)
            attempt = self._invitation_attempts.get(attempt_id)
            if (
                job is None
                or attempt is None
                or attempt["contact_id"] != contact_id
                or attempt["status"] != "started"
                or job["status"] != "leased"
                or job["lease_owner"] != worker_id
                or job["active_attempt_id"] != attempt_id
            ):
                return False
            del self._invitation_attempts[attempt_id]
            job.update(
                {
                    "status": "retry_wait",
                    "available_at": now,
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "active_attempt_id": None,
                    "attempt_count": max(int(job["attempt_count"]) - 1, 0),
                    "last_attempt_at": max(
                        (
                            row["started_at"]
                            for row in self._invitation_attempts.values()
                            if row["contact_id"] == contact_id
                        ),
                        default=None,
                    ),
                    "updated_at": now,
                }
            )
            return True

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        accepted_request_hashes: frozenset[str] = frozenset(),
        trigger: str,
        share_duration_hours: int = 8,
        evidence: dict[str, Any] | None = None,
        escalation_rounds: int = 1,
        escalation_interval_seconds: int = 15 * 60,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
        delivery_ready: bool = True,
    ) -> dict[str, Any]:
        async with self._lock:
            self._require_profile(profile_id)
            existing_id = self._dispatch_keys.get((profile_id, idempotency_key))
            if existing_id is not None:
                existing = self._dispatches[existing_id]
                if existing["request_hash"] not in (
                    accepted_request_hashes | {request_hash}
                ):
                    raise SafetyConflictError(
                        "Idempotency-Key was already used for a different page"
                    )
                return self._dispatch_payload(existing_id, idempotent_replay=True)
            tombstone_key = (profile_id, idempotency_key)
            tombstone = self._dispatch_tombstones.get(tombstone_key)
            if tombstone is not None:
                if tombstone["expires_at"] <= now:
                    del self._dispatch_tombstones[tombstone_key]
                else:
                    if tombstone["request_hash"] not in (
                        accepted_request_hashes | {request_hash}
                    ):
                        raise SafetyConflictError(
                            "Idempotency-Key was already used for a different page"
                        )
                    raise SafetyConflictError(
                        "this safety page was retired and cannot be replayed"
                    )
            if not delivery_ready:
                raise SafetyNotReadyError("safety delivery is temporarily unavailable")
            if not self._paging_control["enabled"]:
                raise SafetyNotReadyError("safety paging is temporarily paused")
            for row in self._dispatches.values():
                if (
                    row["profile_id"] == profile_id
                    and row["status"] in {"open", "acknowledged"}
                    and row["expires_at"] <= now
                ):
                    row.update(
                        {
                            "status": "expired",
                            "updated_at": now,
                            "completed_at": now,
                        }
                    )
                    self._cancel_pending_deliveries(
                        row["dispatch_id"],
                        now=now,
                    )
            if any(
                row["profile_id"] == profile_id
                and row["status"] in {"open", "acknowledged"}
                for row in self._dispatches.values()
            ):
                raise SafetyConflictError(
                    "resolve or cancel the active safety incident first"
                )
            if trigger == "validated_fall" and evidence is not None:
                event_id = str(evidence.get("event_id", ""))
                if any(
                    row["profile_id"] == profile_id
                    and row["trigger"] == "validated_fall"
                    and str((row.get("evidence") or {}).get("event_id", "")) == event_id
                    for row in self._dispatches.values()
                ):
                    raise SafetyConflictError(
                        "this validated fall event was already used"
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
                "share_duration_hours": share_duration_hours,
                "evidence": evidence,
                "escalation_rounds": escalation_rounds,
                "escalation_interval_seconds": escalation_interval_seconds,
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
            voice_delay = voice_fallback_at - now
            for contact in contacts:
                for escalation_round in range(escalation_rounds):
                    round_start = now + timedelta(
                        seconds=escalation_round * escalation_interval_seconds
                    )
                    for channel in ("sms", "voice"):
                        delivery_id = str(uuid4())
                        self._deliveries[delivery_id] = {
                            "delivery_id": delivery_id,
                            "dispatch_id": dispatch_id,
                            "contact_id": contact["contact_id"],
                            "contact_display_name": contact["display_name"],
                            "phone_e164": contact["phone_e164"],
                            "channel": channel,
                            "escalation_round": escalation_round,
                            "status": "pending",
                            "provider_reference": None,
                            "error": None,
                            "available_at": (
                                round_start
                                if channel == "sms"
                                else round_start + voice_delay
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

    async def dispatch_for_idempotency_key(
        self,
        *,
        profile_id: str,
        idempotency_key: str,
        accepted_request_hashes: frozenset[str],
    ) -> dict[str, Any] | None:
        async with self._lock:
            self._require_profile(profile_id)
            existing_id = self._dispatch_keys.get((profile_id, idempotency_key))
            if existing_id is None:
                return None
            existing = self._dispatches[existing_id]
            if existing["request_hash"] not in accepted_request_hashes:
                raise SafetyConflictError(
                    "Idempotency-Key was already used for a different page"
                )
            return self._dispatch_payload(existing_id, idempotent_replay=True)

    async def claim_due_deliveries(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        async with self._lock:
            if not self._paging_control["enabled"]:
                return []
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
                    self._finalize_failed_dispatch(
                        str(delivery["dispatch_id"]),
                        now=now,
                    )
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
                        "trigger": dispatch["trigger"],
                        "evidence": dispatch["evidence"],
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
            self._finalize_failed_dispatch(
                str(delivery["dispatch_id"]),
                now=now,
            )

    async def release_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool:
        async with self._lock:
            delivery = self._deliveries.get(delivery_id)
            attempt = self._delivery_attempts.get(attempt_id)
            if (
                delivery is None
                or attempt is None
                or attempt["delivery_id"] != delivery_id
                or attempt["status"] != "started"
                or delivery["status"] != "leased"
                or delivery["lease_owner"] != worker_id
            ):
                return False
            del self._delivery_attempts[attempt_id]
            previous_attempts = [
                row
                for row in self._delivery_attempts.values()
                if row["delivery_id"] == delivery_id
            ]
            delivery.update(
                {
                    "status": "retry_wait",
                    "available_at": now,
                    "lease_owner": None,
                    "lease_expires_at": None,
                    "attempt_count": max(int(delivery["attempt_count"]) - 1, 0),
                    "last_attempt_at": max(
                        (row["started_at"] for row in previous_attempts),
                        default=None,
                    ),
                    "updated_at": now,
                }
            )
            return True

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
                sequence <= current["sequence"] or captured_at <= current["captured_at"]
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
            invitation_attempt = next(
                (
                    row
                    for row in self._invitation_attempts.values()
                    if row["provider_reference"] == provider_reference
                ),
                None,
            )
            if invitation_attempt is not None:
                invitation_attempt["status"] = _advanced_provider_status(
                    str(invitation_attempt["status"]),
                    status,
                )
                invitation_attempt["finished_at"] = now
                contact_id = str(invitation_attempt["contact_id"])
                job = self._invitation_jobs.get(contact_id)
                contact = self._contacts.get(contact_id)
                if (
                    job is None
                    or contact is None
                    or job["invitation_nonce"] != invitation_attempt["invitation_nonce"]
                    or job["status"] == "cancelled"
                    or contact["status"] != "pending"
                ):
                    return True
                is_latest = job["provider_reference"] == provider_reference
                if status == "delivered":
                    job.update(
                        {
                            "status": "delivered",
                            "error": None,
                            "terminal_at": now,
                            "updated_at": now,
                        }
                    )
                    contact.update(
                        {
                            "invitation_delivery_status": "delivered",
                            "invitation_provider_reference": provider_reference,
                            "invitation_error": None,
                            "updated_at": now,
                        }
                    )
                elif status == "failed" and is_latest and job["status"] != "delivered":
                    if (
                        int(job["attempt_count"]) < int(job["max_attempts"])
                        and contact["status"] == "pending"
                        and retry_at < contact["invite_expires_at"]
                    ):
                        job.update(
                            {
                                "status": "retry_wait",
                                "available_at": retry_at,
                                "provider_reference": None,
                                "error": (
                                    "paging provider reported invitation failure"
                                ),
                                "terminal_at": None,
                                "updated_at": now,
                            }
                        )
                        contact.update(
                            {
                                "invitation_delivery_status": "pending",
                                "invitation_provider_reference": None,
                                "invitation_error": job["error"],
                                "updated_at": now,
                            }
                        )
                    else:
                        job.update(
                            {
                                "status": "failed",
                                "error": (
                                    "paging provider reported invitation failure"
                                ),
                                "terminal_at": now,
                                "updated_at": now,
                            }
                        )
                        contact.update(
                            {
                                "invitation_delivery_status": "failed",
                                "invitation_error": job["error"],
                                "updated_at": now,
                            }
                        )
                elif is_latest and job["status"] not in {
                    "delivered",
                    "failed",
                    "cancelled",
                }:
                    advanced = _advanced_provider_status(str(job["status"]), status)
                    job["status"] = advanced
                    job["updated_at"] = now
                    contact["invitation_delivery_status"] = advanced
                    contact["updated_at"] = now
                return True
            # Backward compatibility for invitations sent before durable jobs
            # were introduced.
            legacy_contact = next(
                (
                    row
                    for row in self._contacts.values()
                    if row["invitation_provider_reference"] == provider_reference
                ),
                None,
            )
            if legacy_contact is not None:
                legacy_contact["invitation_delivery_status"] = status
                legacy_contact["updated_at"] = now
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
            self._finalize_failed_dispatch(
                str(delivery["dispatch_id"]),
                now=now,
            )
            return True

    async def mark_stale_provider_receipts(
        self,
        *,
        cutoff: datetime,
        now: datetime,
        limit: int = 200,
    ) -> int:
        async with self._lock:
            changed = 0
            candidates = sorted(
                [
                    (
                        delivery["updated_at"],
                        "delivery",
                        str(delivery["delivery_id"]),
                    )
                    for delivery in self._deliveries.values()
                    if delivery["status"] in {"queued", "sent"}
                    and delivery["updated_at"] <= cutoff
                ]
                + [
                    (
                        job["updated_at"],
                        "invitation",
                        str(job["contact_id"]),
                    )
                    for job in self._invitation_jobs.values()
                    if job["status"] in {"queued", "sent"}
                    and job["updated_at"] <= cutoff
                ],
                key=lambda candidate: (candidate[0], candidate[1], candidate[2]),
            )[: max(limit, 0)]
            for _, kind, identifier in candidates:
                if kind == "invitation":
                    job = self._invitation_jobs[identifier]
                    job.update(
                        {
                            "status": "unknown",
                            "error": "provider delivery receipt timed out",
                            "terminal_at": now,
                            "updated_at": now,
                        }
                    )
                    self._finish_invitation_attempt_for_reference(
                        job["provider_reference"],
                        status="unknown",
                        error="provider delivery receipt timed out",
                        now=now,
                    )
                    contact = self._contacts[identifier]
                    if (
                        contact["status"] == "pending"
                        and contact["invitation_provider_reference"]
                        == job["provider_reference"]
                    ):
                        contact.update(
                            {
                                "invitation_delivery_status": "unknown",
                                "invitation_error": (
                                    "provider delivery receipt timed out"
                                ),
                                "updated_at": now,
                            }
                        )
                    changed += 1
                    continue
                delivery = self._deliveries[identifier]
                dispatch = self._dispatches[delivery["dispatch_id"]]
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
                if dispatch["status"] == "open":
                    self._expedite_voice_fallback(delivery, now)
                changed += 1
            return changed

    async def expire_due_dispatches(self, *, now: datetime) -> int:
        async with self._lock:
            changed = 0
            for dispatch in self._dispatches.values():
                if (
                    dispatch["status"] in {"open", "acknowledged"}
                    and dispatch["expires_at"] <= now
                ):
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
                if dispatch["status"] in {"open", "acknowledged"}
                and dispatch["expires_at"] <= now
                else dispatch["status"]
            )
            return {
                "dispatch_id": dispatch_id,
                "contact_id": contact_id,
                "contact_display_name": contact["display_name"],
                "owner_display_name": profile["display_name"],
                "status": effective_status,
                "expires_at": dispatch["expires_at"],
                "trigger": dispatch["trigger"],
                "share_duration_hours": dispatch["share_duration_hours"],
                "evidence": dispatch["evidence"],
                "response": self._responses.get((dispatch_id, contact_id)),
                "latest_location": (
                    self._locations.get(dispatch_id)
                    if effective_status in {"open", "acknowledged"}
                    else None
                ),
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
            if (
                dispatch["status"] in {"open", "acknowledged"}
                and dispatch["expires_at"] <= now
            ):
                dispatch.update(
                    {
                        "status": "expired",
                        "updated_at": now,
                        "completed_at": now,
                    }
                )
                self._cancel_pending_deliveries(dispatch_id, now=now)
            if dispatch["status"] in {"resolved", "cancelled", "expired", "failed"}:
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
            if dispatch["status"] in {"resolved", "cancelled", "expired", "failed"}:
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

    async def monitoring_snapshot(
        self,
        *,
        now: datetime,
        worker_cutoff: datetime | None = None,
        window_seconds: int = 24 * 60 * 60,
    ) -> dict[str, Any]:
        async with self._lock:
            active_cutoff = worker_cutoff or now - timedelta(seconds=30)
            window_start = now - timedelta(seconds=max(window_seconds, 1))
            active_states = {"pending", "retry_wait", "leased", "queued", "sent"}
            open_dispatches = sum(
                row["status"] == "open" for row in self._dispatches.values()
            )
            acknowledged = sum(
                row["status"] == "acknowledged" for row in self._dispatches.values()
            )
            queue: dict[str, int] = {}
            due_ages: list[float] = []
            delivery_latencies: list[float] = []
            for delivery in self._deliveries.values():
                state = str(delivery["status"])
                if state in active_states or delivery["updated_at"] >= window_start:
                    queue[state] = queue.get(state, 0) + 1
                if state in {"pending", "retry_wait"}:
                    due_ages.append(
                        max(0.0, (now - delivery["available_at"]).total_seconds())
                    )
                if (
                    delivery["delivered_at"] is not None
                    and delivery["delivered_at"] >= window_start
                ):
                    delivery_latencies.append(
                        max(
                            0.0,
                            (
                                delivery["delivered_at"] - delivery["created_at"]
                            ).total_seconds(),
                        )
                    )
            delivery_latencies.sort()
            p95_index = max(
                0,
                math.ceil(len(delivery_latencies) * 0.95) - 1,
            )
            heartbeat_ages = [
                max(0.0, (now - row["last_seen_at"]).total_seconds())
                for row in self._worker_heartbeats.values()
            ]
            invitation_queue: dict[str, int] = {}
            invitation_due_ages: list[float] = []
            for job in self._invitation_jobs.values():
                state = str(job["status"])
                if state in active_states or job["updated_at"] >= window_start:
                    invitation_queue[state] = invitation_queue.get(state, 0) + 1
                if state in {"pending", "retry_wait"}:
                    invitation_due_ages.append(
                        max(0.0, (now - job["available_at"]).total_seconds())
                    )
            unknown_delivery_attempts = sum(
                row["status"] == "unknown"
                and (row["finished_at"] or row["started_at"]) >= window_start
                for row in self._delivery_attempts.values()
            )
            unknown_invitation_attempts = sum(
                row["status"] == "unknown"
                and (row["finished_at"] or row["started_at"]) >= window_start
                for row in self._invitation_attempts.values()
            )
            return {
                "telemetry_window": {
                    "seconds": max(window_seconds, 1),
                    "started_at": window_start,
                    "ended_at": now,
                },
                "paging_control": dict(self._paging_control),
                "workers": {
                    "active": sum(
                        row["last_seen_at"] >= active_cutoff
                        for row in self._worker_heartbeats.values()
                    ),
                    "stale": sum(
                        row["last_seen_at"] < active_cutoff
                        for row in self._worker_heartbeats.values()
                    ),
                    "oldest_heartbeat_age_seconds": (
                        int(max(heartbeat_ages)) if heartbeat_ages else None
                    ),
                },
                "incidents": {
                    "open": open_dispatches,
                    "acknowledged": acknowledged,
                    "failed": sum(
                        row["status"] == "failed"
                        and row["completed_at"] is not None
                        and row["completed_at"] >= window_start
                        for row in self._dispatches.values()
                    ),
                    "overdue": sum(
                        row["status"] in {"open", "acknowledged"}
                        and row["expires_at"] <= now
                        for row in self._dispatches.values()
                    ),
                },
                "queue": queue,
                "invitation_queue": invitation_queue,
                "oldest_due_seconds": int(max(due_ages, default=0)),
                "oldest_invitation_due_seconds": int(
                    max(invitation_due_ages, default=0)
                ),
                "retrying_deliveries": sum(
                    int(row["attempt_count"]) > 1 and row["updated_at"] >= window_start
                    for row in self._deliveries.values()
                ),
                "unknown_receipts": sum(
                    row["status"] == "unknown" and row["updated_at"] >= window_start
                    for row in self._deliveries.values()
                ),
                "unknown_invitation_receipts": sum(
                    row["status"] == "unknown" and row["updated_at"] >= window_start
                    for row in self._invitation_jobs.values()
                ),
                "unknown_attempts": (
                    unknown_delivery_attempts + unknown_invitation_attempts
                ),
                "unknown_delivery_attempts": unknown_delivery_attempts,
                "unknown_invitation_attempts": unknown_invitation_attempts,
                "total_delivery_failures": sum(
                    row["status"] == "failed" and row["updated_at"] >= window_start
                    for row in self._deliveries.values()
                ),
                "total_invitation_failures": sum(
                    row["status"] == "failed" and row["updated_at"] >= window_start
                    for row in self._invitation_jobs.values()
                ),
                "provider_delivery_latency_p95_seconds": (
                    round(delivery_latencies[p95_index], 3)
                    if delivery_latencies
                    else None
                ),
                "stale_leases": sum(
                    row["status"] == "leased"
                    and row["lease_expires_at"] is not None
                    and row["lease_expires_at"] <= now
                    for row in self._deliveries.values()
                ),
                "stale_invitation_leases": sum(
                    row["status"] == "leased"
                    and row["lease_expires_at"] is not None
                    and row["lease_expires_at"] <= now
                    for row in self._invitation_jobs.values()
                ),
            }

    def _delete_profiles_locked(self, profile_ids: set[str]) -> dict[str, int]:
        counts: Counter[str] = Counter()
        for dispatch_id in [
            dispatch_id
            for dispatch_id, row in self._dispatches.items()
            if row["profile_id"] in profile_ids
        ]:
            child_counts = self._delete_dispatch_locked(dispatch_id)
            counts.update(child_counts)
        for contact_id in [
            contact_id
            for contact_id, row in self._contacts.items()
            if row["profile_id"] in profile_ids
        ]:
            child_counts = self._delete_contact_locked(contact_id)
            counts.update(child_counts)
        for key in [key for key in self._dispatch_tombstones if key[0] in profile_ids]:
            del self._dispatch_tombstones[key]
            counts["dispatch_tombstones"] += 1
        for profile_id in profile_ids:
            profile = self._profiles.pop(profile_id, None)
            if profile is None:
                continue
            self._profile_tokens.pop(profile["token_hash"], None)
            counts["profiles"] += 1
        return dict(counts)

    def _delete_dispatch_locked(self, dispatch_id: str) -> dict[str, int]:
        counts: Counter[str] = Counter()
        dispatch = self._dispatches.pop(dispatch_id, None)
        if dispatch is None:
            return {}
        self._dispatch_keys.pop(
            (dispatch["profile_id"], dispatch["idempotency_key"]),
            None,
        )
        delivery_ids = [
            delivery_id
            for delivery_id, row in self._deliveries.items()
            if row["dispatch_id"] == dispatch_id
        ]
        for delivery_id in delivery_ids:
            attempt_ids = [
                attempt_id
                for attempt_id, row in self._delivery_attempts.items()
                if row["delivery_id"] == delivery_id
            ]
            for attempt_id in attempt_ids:
                del self._delivery_attempts[attempt_id]
            counts["delivery_attempts"] += len(attempt_ids)
            del self._deliveries[delivery_id]
        counts["deliveries"] += len(delivery_ids)
        response_keys = [
            key
            for key, row in self._responses.items()
            if row["dispatch_id"] == dispatch_id
        ]
        for key in response_keys:
            del self._responses[key]
        counts["responses"] += len(response_keys)
        if self._locations.pop(dispatch_id, None) is not None:
            counts["locations"] += 1
        counts["incidents"] += 1
        return dict(counts)

    def _delete_contact_locked(self, contact_id: str) -> dict[str, int]:
        counts: Counter[str] = Counter()
        contact = self._contacts.pop(contact_id, None)
        if contact is None:
            return {}
        token_hash = contact.get("invite_token_hash")
        if token_hash:
            self._invitation_tokens.pop(token_hash, None)
        if self._invitation_jobs.pop(contact_id, None) is not None:
            counts["invitation_jobs"] += 1
        attempt_ids = [
            attempt_id
            for attempt_id, row in self._invitation_attempts.items()
            if row["contact_id"] == contact_id
        ]
        for attempt_id in attempt_ids:
            del self._invitation_attempts[attempt_id]
        counts["invitation_attempts"] += len(attempt_ids)
        counts["contacts"] += 1
        return dict(counts)

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
                and delivery["escalation_round"] == source_delivery["escalation_round"]
                and delivery["status"] in {"pending", "retry_wait"}
            ):
                delivery["available_at"] = min(delivery["available_at"], now)
                delivery["updated_at"] = now

    def _finalize_failed_dispatch(self, dispatch_id: str, *, now: datetime) -> None:
        dispatch = self._dispatches[dispatch_id]
        deliveries = [
            row
            for row in self._deliveries.values()
            if row["dispatch_id"] == dispatch_id
        ]
        if (
            dispatch["status"] == "open"
            and deliveries
            and all(row["status"] == "failed" for row in deliveries)
            and not any(
                attempt["status"] in {"started", "queued", "sent", "unknown"}
                and any(
                    row["delivery_id"] == attempt["delivery_id"] for row in deliveries
                )
                for attempt in self._delivery_attempts.values()
            )
        ):
            dispatch.update(
                {
                    "status": "failed",
                    "updated_at": now,
                    "completed_at": now,
                }
            )

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

    def _finish_invitation_attempt_for_reference(
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
                for row in self._invitation_attempts.values()
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
        deliveries = []
        for row in self._deliveries.values():
            if row["dispatch_id"] != dispatch_id:
                continue
            public = {
                key: value
                for key, value in row.items()
                if key
                not in {
                    "dispatch_id",
                    "lease_owner",
                    "lease_expires_at",
                }
            }
            public["has_unconfirmed_attempt"] = any(
                attempt["delivery_id"] == row["delivery_id"]
                and attempt["status"] in {"started", "queued", "sent", "unknown"}
                for attempt in self._delivery_attempts.values()
            )
            deliveries.append(public)
        deliveries.sort(
            key=lambda row: (
                str(row["contact_display_name"]).casefold(),
                row["escalation_round"],
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

    async def coordination_now(self) -> datetime:
        return await self._pool().fetchval("SELECT clock_timestamp()")

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
                           installation_id, token_hash, token_version,
                           last_rotation_id, last_rotation_token_hash,
                           created_at, updated_at, disabled_at
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
                                  installation_id, token_version,
                                  last_rotation_id, created_at, updated_at,
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
                   token_version, last_rotation_id, created_at, updated_at
            FROM safety_profiles
            WHERE token_hash = $1 AND disabled_at IS NULL
            """,
            token_hash,
        )
        return dict(row) if row else None

    async def rotate_profile_token(
        self,
        *,
        profile_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT profile_id, enrollment_id, display_name,
                           installation_id, token_hash, token_version,
                           last_rotation_id, last_rotation_token_hash,
                           created_at, updated_at, disabled_at
                    FROM safety_profiles
                    WHERE profile_id = $1
                    FOR UPDATE
                    """,
                    UUID(profile_id),
                )
                if row is None or row["disabled_at"] is not None:
                    raise SafetyNotFoundError("safety profile is not active")
                if (
                    str(row["last_rotation_id"]) == rotation_id
                    and (row["last_rotation_token_hash"] or "").strip() == token_hash
                ):
                    return _public_profile(dict(row))
                if row["token_version"] != expected_version:
                    raise SafetyConflictError("safety token version has changed")
                try:
                    updated = await connection.fetchrow(
                        """
                        UPDATE safety_profiles
                        SET token_hash = $2,
                            token_version = token_version + 1,
                            last_rotation_id = $3,
                            last_rotation_token_hash = $2,
                            updated_at = $4
                        WHERE profile_id = $1
                        RETURNING profile_id, enrollment_id, display_name,
                                  installation_id, token_version,
                                  last_rotation_id, created_at, updated_at,
                                  disabled_at
                        """,
                        UUID(profile_id),
                        token_hash,
                        UUID(rotation_id),
                        now,
                    )
                except Exception as exc:
                    if getattr(exc, "sqlstate", None) == "23505":
                        raise SafetyConflictError(
                            "safety credential is already enrolled"
                        ) from exc
                    raise
        return _public_profile(dict(updated))

    async def export_profile(
        self,
        profile_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        max_rows: int = 100_000,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction(
                isolation="repeatable_read",
                readonly=True,
            ):
                profile = await connection.fetchrow(
                    """
                    SELECT profile_id, enrollment_id, display_name,
                           installation_id, token_version, last_rotation_id,
                           created_at, updated_at
                    FROM safety_profiles
                    WHERE profile_id = $1 AND disabled_at IS NULL
                    """,
                    UUID(profile_id),
                )
                if profile is None:
                    raise SafetyNotFoundError("safety profile is not active")
                row_count = int(
                    await connection.fetchval(
                        """
                        WITH selected_contacts AS MATERIALIZED (
                          SELECT contact_id
                          FROM safety_contacts
                          WHERE profile_id = $1
                            AND (
                              $2::timestamptz IS NULL OR created_at >= $2
                            )
                            AND (
                              $3::timestamptz IS NULL OR created_at < $3
                            )
                        ),
                        selected_dispatches AS MATERIALIZED (
                          SELECT dispatch_id
                          FROM safety_dispatches
                          WHERE profile_id = $1
                            AND (
                              $2::timestamptz IS NULL OR created_at >= $2
                            )
                            AND (
                              $3::timestamptz IS NULL OR created_at < $3
                            )
                        ),
                        selected_deliveries AS MATERIALIZED (
                          SELECT delivery_id
                          FROM safety_deliveries
                          WHERE dispatch_id IN (
                            SELECT dispatch_id FROM selected_dispatches
                          )
                        )
                        SELECT count(*)::bigint
                        FROM (
                          SELECT 1 AS export_row
                          FROM safety_profiles
                          WHERE profile_id = $1 AND disabled_at IS NULL
                          UNION ALL
                          SELECT 1 FROM selected_contacts
                          UNION ALL
                          SELECT 1
                          FROM safety_invitation_jobs
                          WHERE contact_id IN (
                            SELECT contact_id FROM selected_contacts
                          )
                          UNION ALL
                          SELECT 1
                          FROM safety_invitation_attempts
                          WHERE contact_id IN (
                            SELECT contact_id FROM selected_contacts
                          )
                          UNION ALL
                          SELECT 1 FROM selected_dispatches
                          UNION ALL
                          SELECT 1 FROM selected_deliveries
                          UNION ALL
                          SELECT 1
                          FROM safety_delivery_attempts
                          WHERE delivery_id IN (
                            SELECT delivery_id FROM selected_deliveries
                          )
                          UNION ALL
                          SELECT 1
                          FROM safety_responses
                          WHERE dispatch_id IN (
                            SELECT dispatch_id FROM selected_dispatches
                          )
                          UNION ALL
                          SELECT 1
                          FROM safety_incident_locations
                          WHERE dispatch_id IN (
                            SELECT dispatch_id FROM selected_dispatches
                          )
                          LIMIT $4
                        ) AS bounded_export
                        """,
                        UUID(profile_id),
                        start,
                        end,
                        max_rows + 1,
                    )
                )
                if row_count > max_rows:
                    raise ExportLimitExceededError(max_rows)
                contacts = [
                    dict(row)
                    for row in await connection.fetch(
                        """
                        SELECT contact_id, display_name, phone_e164, status,
                               invited_at, invite_expires_at,
                               invitation_provider_reference,
                               invitation_delivery_status, invitation_error,
                               accepted_at, declined_at, revoked_at,
                               created_at, updated_at
                        FROM safety_contacts
                        WHERE profile_id = $1
                          AND (
                            $2::timestamptz IS NULL OR created_at >= $2
                          )
                          AND (
                            $3::timestamptz IS NULL OR created_at < $3
                          )
                        ORDER BY created_at, contact_id
                        """,
                        UUID(profile_id),
                        start,
                        end,
                    )
                ]
                contact_ids = [row["contact_id"] for row in contacts]
                if contact_ids:
                    invitation_jobs = await connection.fetch(
                        """
                        SELECT contact_id, status, available_at, attempt_count,
                               max_attempts, provider_reference, error,
                               last_attempt_at, terminal_at, created_at, updated_at
                        FROM safety_invitation_jobs
                        WHERE contact_id = ANY($1::uuid[])
                        """,
                        contact_ids,
                    )
                    invitation_attempts = await connection.fetch(
                        """
                        SELECT attempt_id, contact_id, attempt_number, status,
                               provider_reference, error, started_at, finished_at
                        FROM safety_invitation_attempts
                        WHERE contact_id = ANY($1::uuid[])
                        ORDER BY started_at, attempt_id
                        """,
                        contact_ids,
                    )
                else:
                    invitation_jobs = []
                    invitation_attempts = []
                jobs_by_contact = {
                    str(row["contact_id"]): {
                        key: value
                        for key, value in dict(row).items()
                        if key != "contact_id"
                    }
                    for row in invitation_jobs
                }
                attempts_by_contact: dict[str, list[dict[str, Any]]] = {}
                for row in invitation_attempts:
                    decoded = dict(row)
                    contact_key = str(decoded.pop("contact_id"))
                    attempts_by_contact.setdefault(contact_key, []).append(decoded)
                for contact in contacts:
                    contact_key = str(contact["contact_id"])
                    if contact_key in jobs_by_contact:
                        contact["invitation_job"] = jobs_by_contact[contact_key]
                        contact["invitation_attempts"] = attempts_by_contact.get(
                            contact_key,
                            [],
                        )

                dispatches = await connection.fetch(
                    """
                    SELECT i.dispatch_id, i.idempotency_key, i.trigger, i.status,
                           i.created_at, i.updated_at, i.expires_at,
                           i.acknowledged_at, i.resolved_at, i.cancelled_at,
                           i.acknowledged_contact_id, i.resolution_note,
                           i.completed_at,
                           c.display_name
                             AS acknowledged_contact_display_name
                    FROM safety_dispatches i
                    LEFT JOIN safety_contacts c
                      ON c.contact_id = i.acknowledged_contact_id
                    WHERE i.profile_id = $1
                      AND ($2::timestamptz IS NULL OR i.created_at >= $2)
                      AND ($3::timestamptz IS NULL OR i.created_at < $3)
                    ORDER BY i.created_at, i.dispatch_id
                    """,
                    UUID(profile_id),
                    start,
                    end,
                )
                dispatch_ids = [row["dispatch_id"] for row in dispatches]
                if dispatch_ids:
                    deliveries = await connection.fetch(
                        """
                        SELECT d.dispatch_id, d.delivery_id, d.contact_id,
                               c.display_name AS contact_display_name,
                               c.phone_e164, d.channel, d.status,
                               d.provider_reference, d.error,
                               d.available_at, d.attempt_count, d.max_attempts,
                               d.last_attempt_at, d.delivered_at, d.terminal_at,
                               d.created_at, d.updated_at,
                               EXISTS (
                                 SELECT 1
                                 FROM safety_delivery_attempts a
                                 WHERE a.delivery_id = d.delivery_id
                                   AND a.status IN (
                                     'started', 'queued', 'sent', 'unknown'
                                   )
                               ) AS has_unconfirmed_attempt
                        FROM safety_deliveries d
                        JOIN safety_contacts c
                          ON c.contact_id = d.contact_id
                        WHERE d.dispatch_id = ANY($1::uuid[])
                        ORDER BY d.dispatch_id, lower(c.display_name), d.channel
                        """,
                        dispatch_ids,
                    )
                    delivery_attempts = await connection.fetch(
                        """
                        SELECT a.attempt_id, a.delivery_id, a.attempt_number,
                               a.status, a.provider_reference, a.error,
                               a.started_at, a.finished_at
                        FROM safety_delivery_attempts a
                        JOIN safety_deliveries d
                          ON d.delivery_id = a.delivery_id
                        WHERE d.dispatch_id = ANY($1::uuid[])
                        ORDER BY a.started_at, a.attempt_id
                        """,
                        dispatch_ids,
                    )
                    responses = await connection.fetch(
                        """
                        SELECT r.dispatch_id, r.contact_id,
                               c.display_name AS contact_display_name,
                               r.decision, r.source, r.responded_at
                        FROM safety_responses r
                        JOIN safety_contacts c
                          ON c.contact_id = r.contact_id
                        WHERE r.dispatch_id = ANY($1::uuid[])
                        ORDER BY r.dispatch_id, r.responded_at, r.contact_id
                        """,
                        dispatch_ids,
                    )
                    locations = await connection.fetch(
                        """
                        SELECT dispatch_id, sequence, latitude, longitude,
                               horizontal_accuracy_meters, captured_at,
                               received_at
                        FROM safety_incident_locations
                        WHERE dispatch_id = ANY($1::uuid[])
                        """,
                        dispatch_ids,
                    )
                else:
                    deliveries = []
                    delivery_attempts = []
                    responses = []
                    locations = []
                attempts_by_delivery: dict[str, list[dict[str, Any]]] = {}
                for row in delivery_attempts:
                    decoded = dict(row)
                    delivery_key = str(decoded.pop("delivery_id"))
                    attempts_by_delivery.setdefault(delivery_key, []).append(decoded)
                deliveries_by_dispatch: dict[str, list[dict[str, Any]]] = {}
                for row in deliveries:
                    decoded = dict(row)
                    dispatch_key = str(decoded.pop("dispatch_id"))
                    decoded["attempts"] = attempts_by_delivery.get(
                        str(decoded["delivery_id"]),
                        [],
                    )
                    deliveries_by_dispatch.setdefault(dispatch_key, []).append(decoded)
                responses_by_dispatch: dict[str, list[dict[str, Any]]] = {}
                for row in responses:
                    decoded = dict(row)
                    dispatch_key = str(decoded.pop("dispatch_id"))
                    responses_by_dispatch.setdefault(dispatch_key, []).append(decoded)
                locations_by_dispatch: dict[str, dict[str, Any]] = {}
                for row in locations:
                    decoded = dict(row)
                    dispatch_key = str(decoded.pop("dispatch_id"))
                    locations_by_dispatch[dispatch_key] = decoded
                incidents = []
                for row in dispatches:
                    incident = dict(row)
                    dispatch_key = str(incident["dispatch_id"])
                    incident.update(
                        {
                            "idempotent_replay": False,
                            "deliveries": deliveries_by_dispatch.get(
                                dispatch_key,
                                [],
                            ),
                            "responses": responses_by_dispatch.get(
                                dispatch_key,
                                [],
                            ),
                            "latest_location": locations_by_dispatch.get(dispatch_key),
                        }
                    )
                    incidents.append(incident)
                exported_at = await connection.fetchval("SELECT clock_timestamp()")
        return {
            "schema_version": 1,
            "exported_at": exported_at,
            "row_count": row_count,
            "window": {"start": start, "end": end},
            "profile": dict(profile),
            "contacts": contacts,
            "incidents": incidents,
        }

    async def delete_profile(self, profile_id: str) -> dict[str, int]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT profile_id
                    FROM safety_profiles
                    WHERE profile_id = $1 AND disabled_at IS NULL
                    FOR UPDATE
                    """,
                    UUID(profile_id),
                )
                if row is None:
                    raise SafetyNotFoundError("safety profile is not active")
                return await self._delete_profiles(connection, [UUID(profile_id)])

    async def delete_profiles_for_installation(
        self, installation_id: str
    ) -> dict[str, int]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    SELECT profile_id
                    FROM safety_profiles
                    WHERE installation_id = $1
                    FOR UPDATE
                    """,
                    installation_id,
                )
                return await self._delete_profiles(
                    connection,
                    [row["profile_id"] for row in rows],
                )

    async def _delete_profiles(
        self,
        connection: Any,
        profile_ids: list[UUID],
    ) -> dict[str, int]:
        if not profile_ids:
            return {}
        # Provider submissions hold a shared lock on this row for the duration
        # of the external request. The exclusive lock drains those calls and
        # keeps cached leases from starting after profile deletion commits.
        control = await connection.fetchval(
            """
            SELECT enabled
            FROM safety_runtime_controls
            WHERE control_name = 'paging'
            FOR UPDATE
            """
        )
        if control is None:
            raise RuntimeError("safety paging control is missing")
        counts = await connection.fetchrow(
            """
            SELECT
              (SELECT count(*) FROM safety_profiles
               WHERE profile_id = ANY($1::uuid[])) AS profiles,
              (SELECT count(*) FROM safety_contacts
               WHERE profile_id = ANY($1::uuid[])) AS contacts,
              (SELECT count(*) FROM safety_invitation_jobs j
               JOIN safety_contacts c USING (contact_id)
               WHERE c.profile_id = ANY($1::uuid[])) AS invitation_jobs,
              (SELECT count(*) FROM safety_invitation_attempts a
               JOIN safety_contacts c USING (contact_id)
               WHERE c.profile_id = ANY($1::uuid[])) AS invitation_attempts,
              (SELECT count(*) FROM safety_dispatches
               WHERE profile_id = ANY($1::uuid[])) AS incidents,
              (SELECT count(*) FROM safety_deliveries d
               JOIN safety_dispatches i USING (dispatch_id)
               WHERE i.profile_id = ANY($1::uuid[])) AS deliveries,
              (SELECT count(*) FROM safety_delivery_attempts a
               JOIN safety_deliveries d USING (delivery_id)
               JOIN safety_dispatches i USING (dispatch_id)
               WHERE i.profile_id = ANY($1::uuid[])) AS delivery_attempts,
              (SELECT count(*) FROM safety_responses r
               JOIN safety_dispatches i USING (dispatch_id)
               WHERE i.profile_id = ANY($1::uuid[])) AS responses,
              (SELECT count(*) FROM safety_incident_locations l
               JOIN safety_dispatches i USING (dispatch_id)
               WHERE i.profile_id = ANY($1::uuid[])) AS locations,
              (SELECT count(*) FROM safety_dispatch_tombstones
               WHERE profile_id = ANY($1::uuid[])) AS dispatch_tombstones
            """,
            profile_ids,
        )
        await connection.execute(
            """
            DELETE FROM safety_dispatches
            WHERE profile_id = ANY($1::uuid[])
            """,
            profile_ids,
        )
        await connection.execute(
            """
            DELETE FROM safety_profiles
            WHERE profile_id = ANY($1::uuid[])
            """,
            profile_ids,
        )
        return {key: int(value) for key, value in dict(counts).items()}

    async def purge_retained_data(
        self,
        *,
        incident_cutoff: datetime | None,
        contact_cutoff: datetime | None,
        replay_guard_until: datetime,
        now: datetime,
        limit: int,
    ) -> dict[str, int]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    "noop-safety-retention",
                )
                expired_tombstones = await connection.fetch(
                    """
                    WITH candidates AS (
                      SELECT profile_id, idempotency_key
                      FROM safety_dispatch_tombstones
                      WHERE expires_at <= $1
                      ORDER BY expires_at, profile_id, idempotency_key
                      FOR UPDATE SKIP LOCKED
                      LIMIT $2
                    )
                    DELETE FROM safety_dispatch_tombstones t
                    USING candidates c
                    WHERE t.profile_id = c.profile_id
                      AND t.idempotency_key = c.idempotency_key
                    RETURNING t.idempotency_key
                    """,
                    now,
                    limit,
                )

                retired_incidents = 0
                if incident_cutoff is not None:
                    candidates = await connection.fetch(
                        """
                        SELECT dispatch_id, profile_id, idempotency_key,
                               request_hash
                        FROM safety_dispatches
                        WHERE status IN (
                            'resolved', 'cancelled', 'expired', 'failed'
                        )
                          AND completed_at IS NOT NULL
                          AND completed_at < $1
                        ORDER BY completed_at, dispatch_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                        """,
                        incident_cutoff,
                        limit,
                    )
                    if candidates:
                        await connection.executemany(
                            """
                            INSERT INTO safety_dispatch_tombstones (
                                profile_id, idempotency_key, request_hash,
                                retired_at, expires_at
                            ) VALUES ($1, $2, $3, $4, $5)
                            ON CONFLICT (profile_id, idempotency_key)
                            DO UPDATE SET
                                request_hash = EXCLUDED.request_hash,
                                retired_at = EXCLUDED.retired_at,
                                expires_at = GREATEST(
                                    safety_dispatch_tombstones.expires_at,
                                    EXCLUDED.expires_at
                                )
                            """,
                            [
                                (
                                    row["profile_id"],
                                    row["idempotency_key"],
                                    row["request_hash"],
                                    now,
                                    replay_guard_until,
                                )
                                for row in candidates
                            ],
                        )
                        status = await connection.execute(
                            """
                            DELETE FROM safety_dispatches
                            WHERE dispatch_id = ANY($1::uuid[])
                            """,
                            [row["dispatch_id"] for row in candidates],
                        )
                        retired_incidents = int(status.rsplit(" ", 1)[-1])

                retired_contacts = 0
                if contact_cutoff is not None:
                    status = await connection.execute(
                        """
                        WITH candidates AS (
                          SELECT c.contact_id
                          FROM safety_contacts c
                          WHERE c.status IN ('pending', 'declined', 'revoked')
                            AND COALESCE(
                                c.revoked_at,
                                c.declined_at,
                                c.invite_expires_at
                            ) < $1
                            AND NOT EXISTS (
                              SELECT 1 FROM safety_deliveries d
                              WHERE d.contact_id = c.contact_id
                            )
                            AND NOT EXISTS (
                              SELECT 1 FROM safety_responses r
                              WHERE r.contact_id = c.contact_id
                            )
                            AND NOT EXISTS (
                              SELECT 1 FROM safety_dispatches i
                              WHERE i.acknowledged_contact_id = c.contact_id
                            )
                          ORDER BY COALESCE(
                              c.revoked_at,
                              c.declined_at,
                              c.invite_expires_at
                          ), c.contact_id
                          FOR UPDATE SKIP LOCKED
                          LIMIT $2
                        )
                        DELETE FROM safety_contacts c
                        USING candidates old
                        WHERE c.contact_id = old.contact_id
                        """,
                        contact_cutoff,
                        limit,
                    )
                    retired_contacts = int(status.rsplit(" ", 1)[-1])
        return {
            "incidents": retired_incidents,
            "contacts": retired_contacts,
            "tombstones": len(expired_tombstones),
        }

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
        invitation_nonce: str | None = None,
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
                if invitation_nonce is not None:
                    await connection.execute(
                        """
                        INSERT INTO safety_invitation_jobs (
                            contact_id, invitation_nonce, status, available_at,
                            attempt_count, max_attempts, created_at, updated_at
                        )
                        VALUES ($1, $2, 'pending', $3, 0, 3, $3, $3)
                        """,
                        UUID(contact_id),
                        UUID(invitation_nonce),
                        invited_at,
                    )
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
        invitation_nonce: str | None = None,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-invitation:{contact_id}",
                )
                try:
                    row = await connection.fetchrow(
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
                        raise SafetyConflictError(
                            "invitation token is already in use"
                        ) from exc
                    raise
                if row is None:
                    accepted = await connection.fetchval(
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
                if invitation_nonce is not None:
                    await connection.execute(
                        """
                        INSERT INTO safety_invitation_jobs (
                            contact_id, invitation_nonce, status, available_at,
                            lease_owner, lease_expires_at, active_attempt_id,
                            attempt_count, max_attempts, provider_reference,
                            error, last_attempt_at, terminal_at,
                            created_at, updated_at
                        )
                        VALUES (
                            $1, $2, 'pending', $3,
                            NULL, NULL, NULL, 0, 3, NULL,
                            NULL, NULL, NULL, $3, $3
                        )
                        ON CONFLICT (contact_id) DO UPDATE
                        SET invitation_nonce = EXCLUDED.invitation_nonce,
                            status = 'pending',
                            available_at = EXCLUDED.available_at,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            active_attempt_id = NULL,
                            attempt_count = 0,
                            max_attempts = 3,
                            provider_reference = NULL,
                            error = NULL,
                            last_attempt_at = NULL,
                            terminal_at = NULL,
                            created_at = EXCLUDED.created_at,
                            updated_at = EXCLUDED.updated_at
                        """,
                        UUID(contact_id),
                        UUID(invitation_nonce),
                        invited_at,
                    )
                return _public_contact(dict(row))

    async def revoke_contact(
        self, *, profile_id: str, contact_id: str, now: datetime
    ) -> None:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-invitation:{contact_id}",
                )
                row = await connection.fetchrow(
                    """
                    UPDATE safety_contacts
                    SET status = 'revoked', revoked_at = $3,
                        invite_token_hash = NULL, updated_at = $3
                    WHERE contact_id = $1 AND profile_id = $2
                      AND revoked_at IS NULL
                    RETURNING contact_id
                    """,
                    UUID(contact_id),
                    UUID(profile_id),
                    now,
                )
                if row is None:
                    raise SafetyNotFoundError("emergency contact was not found")
                await connection.execute(
                    """
                    UPDATE safety_invitation_jobs
                    SET status = 'cancelled',
                        lease_owner = NULL,
                        lease_expires_at = NULL,
                        active_attempt_id = NULL,
                        terminal_at = $2,
                        updated_at = $2
                    WHERE contact_id = $1
                      AND status IN (
                        'pending', 'retry_wait', 'leased', 'queued', 'sent',
                        'unknown'
                      )
                    """,
                    UUID(contact_id),
                    now,
                )

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
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                contact_id = await connection.fetchval(
                    """
                    SELECT contact_id
                    FROM safety_contacts
                    WHERE invite_token_hash = $1
                    """,
                    invite_token_hash,
                )
                if contact_id is None:
                    raise SafetyNotFoundError(
                        "invitation is invalid, expired, or already used"
                    )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-invitation:{contact_id}",
                )
                row = await connection.fetchrow(
                    """
                    UPDATE safety_contacts
                    SET status = $2,
                        accepted_at = CASE
                            WHEN $2 = 'accepted' THEN $3 ELSE NULL
                        END,
                        declined_at = CASE
                            WHEN $2 = 'declined' THEN $3 ELSE NULL
                        END,
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
                    raise SafetyNotFoundError(
                        "invitation is invalid, expired, or already used"
                    )
                await connection.execute(
                    """
                    UPDATE safety_invitation_jobs
                    SET status = 'cancelled',
                        lease_owner = NULL,
                        lease_expires_at = NULL,
                        active_attempt_id = NULL,
                        terminal_at = $2,
                        updated_at = $2
                    WHERE contact_id = $1
                      AND status IN (
                        'pending', 'retry_wait', 'leased', 'queued', 'sent',
                        'unknown'
                      )
                    """,
                    row["contact_id"],
                    now,
                )
                return _public_contact(dict(row))

    async def paging_control(self) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT enabled, reason, revision, updated_at
            FROM safety_runtime_controls
            WHERE control_name = 'paging'
            """
        )
        if row is None:
            raise RuntimeError("safety paging control is missing")
        return dict(row)

    async def set_paging_control(
        self,
        *,
        enabled: bool,
        reason: str | None,
        expected_revision: int,
        now: datetime,
        actor: str = "system",
        request_id: str | None = None,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    UPDATE safety_runtime_controls
                    SET enabled = $1,
                        reason = $2,
                        revision = revision + 1,
                        updated_at = clock_timestamp()
                    WHERE control_name = 'paging'
                      AND revision = $3
                    RETURNING enabled, reason, revision, updated_at
                    """,
                    enabled,
                    reason,
                    expected_revision,
                )
                if row is None:
                    current = await connection.fetchval(
                        """
                        SELECT revision
                        FROM safety_runtime_controls
                        WHERE control_name = 'paging'
                        """
                    )
                    if current is None:
                        raise RuntimeError("safety paging control is missing")
                    raise SafetyConflictError(
                        "paging control changed; refresh its revision and retry"
                    )
                await connection.execute(
                    """
                    INSERT INTO safety_runtime_control_audit (
                        control_name, revision, enabled, reason, changed_at,
                        actor, request_id
                    ) VALUES ('paging', $1, $2, $3, $4, $5, $6)
                    """,
                    row["revision"],
                    row["enabled"],
                    row["reason"],
                    row["updated_at"],
                    actor,
                    UUID(request_id) if request_id else None,
                )
                return dict(row)

    @asynccontextmanager
    async def paging_submission_permit(
        self,
        *,
        job_kind: Literal["delivery", "invitation"],
        job_id: str,
        attempt_id: str,
        worker_id: str,
    ) -> AsyncIterator[bool]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                enabled = await connection.fetchval(
                    """
                    SELECT enabled
                    FROM safety_runtime_controls
                    WHERE control_name = 'paging'
                    FOR SHARE
                    """
                )
                valid = False
                if enabled is True and job_kind == "delivery":
                    valid = bool(
                        await connection.fetchval(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM safety_deliveries delivery
                                JOIN safety_delivery_attempts attempt
                                  ON attempt.delivery_id = delivery.delivery_id
                                JOIN safety_dispatches incident
                                  ON incident.dispatch_id = delivery.dispatch_id
                                JOIN safety_profiles profile
                                  ON profile.profile_id = incident.profile_id
                                WHERE delivery.delivery_id = $1
                                  AND attempt.attempt_id = $2
                                  AND attempt.status = 'started'
                                  AND delivery.status = 'leased'
                                  AND delivery.lease_owner = $3
                                  AND incident.status = 'open'
                                  AND incident.expires_at > clock_timestamp()
                                  AND profile.disabled_at IS NULL
                            )
                            """,
                            UUID(job_id),
                            UUID(attempt_id),
                            worker_id,
                        )
                    )
                elif enabled is True:
                    valid = bool(
                        await connection.fetchval(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM safety_invitation_jobs job
                                JOIN safety_invitation_attempts attempt
                                  ON attempt.contact_id = job.contact_id
                                JOIN safety_contacts contact
                                  ON contact.contact_id = job.contact_id
                                JOIN safety_profiles profile
                                  ON profile.profile_id = contact.profile_id
                                WHERE job.contact_id = $1
                                  AND attempt.attempt_id = $2
                                  AND attempt.status = 'started'
                                  AND job.status = 'leased'
                                  AND job.lease_owner = $3
                                  AND job.active_attempt_id = attempt.attempt_id
                                  AND job.invitation_nonce =
                                      attempt.invitation_nonce
                                  AND contact.status = 'pending'
                                  AND contact.revoked_at IS NULL
                                  AND contact.invite_expires_at >
                                      clock_timestamp()
                                  AND profile.disabled_at IS NULL
                            )
                            """,
                            UUID(job_id),
                            UUID(attempt_id),
                            worker_id,
                        )
                    )
                yield valid

    async def record_worker_heartbeat(
        self,
        *,
        worker_id: str,
        now: datetime,
        worker_version: str = "unknown",
    ) -> None:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    """
                    INSERT INTO safety_worker_heartbeats (
                        worker_id, started_at, last_seen_at, worker_version
                    )
                    VALUES ($1, clock_timestamp(), clock_timestamp(), $2)
                    ON CONFLICT (worker_id) DO UPDATE
                    SET last_seen_at = clock_timestamp(),
                        worker_version = EXCLUDED.worker_version
                    """,
                    worker_id,
                    worker_version,
                )
                await connection.execute(
                    """
                    DELETE FROM safety_worker_heartbeats
                    WHERE last_seen_at < clock_timestamp() - interval '7 days'
                    """
                )

    async def worker_is_active(self, *, cutoff: datetime) -> bool:
        return bool(
            await self._pool().fetchval(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM safety_worker_heartbeats
                    WHERE last_seen_at >= $1
                )
                """,
                cutoff,
            )
        )

    async def reserve_provider_submission_slot(
        self,
        *,
        now: datetime,
        requests_per_second: int,
    ) -> float:
        interval_seconds = 1.0 / max(requests_per_second, 1)
        row = await self._pool().fetchrow(
            """
            WITH current AS (
                SELECT next_slot_at, clock_timestamp() AS database_now
                FROM safety_provider_rate_state
                WHERE provider_name = 'twilio'
                FOR UPDATE
            ),
            reserved AS (
                UPDATE safety_provider_rate_state state
                SET next_slot_at = GREATEST(
                    current.next_slot_at,
                    current.database_now
                ) + make_interval(secs => $1::double precision)
                FROM current
                WHERE state.provider_name = 'twilio'
                RETURNING
                    GREATEST(
                        current.next_slot_at,
                        current.database_now
                    ) AS reserved_at,
                    current.database_now
            )
            SELECT GREATEST(
                EXTRACT(epoch FROM reserved_at - database_now),
                0
            ) AS delay_seconds
            FROM reserved
            """,
            interval_seconds,
        )
        if row is None:
            raise RuntimeError("safety provider rate state is missing")
        return float(row["delay_seconds"])

    async def claim_due_invitations(
        self,
        *,
        worker_id: str,
        now: datetime,
        lease_until: datetime,
        limit: int,
    ) -> list[dict[str, Any]]:
        if limit <= 0:
            return []
        pool = self._pool()
        claimed: list[dict[str, Any]] = []
        async with pool.acquire() as connection:
            async with connection.transaction():
                paging_enabled = await connection.fetchval(
                    """
                    SELECT enabled
                    FROM safety_runtime_controls
                    WHERE control_name = 'paging'
                    FOR SHARE
                    """
                )
                if paging_enabled is not True:
                    return []
                candidates = await connection.fetch(
                    """
                    SELECT contact_id
                    FROM safety_invitation_jobs
                    WHERE (
                        status IN ('pending', 'retry_wait')
                        AND available_at <= $1
                    ) OR (
                        status = 'leased'
                        AND lease_expires_at <= $1
                    )
                    ORDER BY available_at, created_at, contact_id
                    LIMIT $2
                    """,
                    now,
                    limit * 2,
                )
                for candidate in candidates:
                    if len(claimed) >= limit:
                        break
                    contact_id = candidate["contact_id"]
                    locked = await connection.fetchval(
                        """
                        SELECT pg_try_advisory_xact_lock(
                            hashtextextended($1, 0)
                        )
                        """,
                        f"noop-safety-invitation:{contact_id}",
                    )
                    if locked is not True:
                        continue
                    row = await connection.fetchrow(
                        """
                        SELECT j.*, c.status AS contact_status,
                               c.revoked_at, c.phone_e164,
                               c.display_name AS contact_display_name,
                               c.invite_expires_at,
                               p.display_name AS owner_display_name,
                               p.disabled_at AS profile_disabled_at
                        FROM safety_invitation_jobs j
                        JOIN safety_contacts c
                          ON c.contact_id = j.contact_id
                        JOIN safety_profiles p
                          ON p.profile_id = c.profile_id
                        WHERE j.contact_id = $1
                        FOR UPDATE OF j, c
                        """,
                        contact_id,
                    )
                    if row is None:
                        continue
                    due = (
                        row["status"] in {"pending", "retry_wait"}
                        and row["available_at"] <= now
                    )
                    stale = (
                        row["status"] == "leased"
                        and row["lease_expires_at"] is not None
                        and row["lease_expires_at"] <= now
                    )
                    if not (due or stale):
                        continue
                    if stale and row["active_attempt_id"] is not None:
                        await connection.execute(
                            """
                            UPDATE safety_invitation_attempts
                            SET status = 'unknown',
                                error = (
                                  'worker lease expired before invitation '
                                  'outcome was recorded'
                                ),
                                finished_at = $2
                            WHERE attempt_id = $1
                              AND status = 'started'
                            """,
                            row["active_attempt_id"],
                            now,
                        )
                    invalid = (
                        row["contact_status"] != "pending"
                        or row["revoked_at"] is not None
                        or row["profile_disabled_at"] is not None
                        or row["invite_expires_at"] <= now
                    )
                    if invalid:
                        await connection.execute(
                            """
                            UPDATE safety_invitation_jobs
                            SET status = 'cancelled',
                                lease_owner = NULL,
                                lease_expires_at = NULL,
                                active_attempt_id = NULL,
                                terminal_at = $2,
                                updated_at = $2
                            WHERE contact_id = $1
                            """,
                            contact_id,
                            now,
                        )
                        continue
                    if row["attempt_count"] >= row["max_attempts"]:
                        error = "invitation retry limit reached"
                        await connection.execute(
                            """
                            UPDATE safety_invitation_jobs
                            SET status = 'failed',
                                error = $2,
                                lease_owner = NULL,
                                lease_expires_at = NULL,
                                active_attempt_id = NULL,
                                terminal_at = $3,
                                updated_at = $3
                            WHERE contact_id = $1
                            """,
                            contact_id,
                            error,
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE safety_contacts
                            SET invitation_delivery_status = 'failed',
                                invitation_error = $2,
                                updated_at = $3
                            WHERE contact_id = $1
                              AND status = 'pending'
                            """,
                            contact_id,
                            error,
                            now,
                        )
                        continue
                    attempt_id = uuid4()
                    updated = await connection.fetchrow(
                        """
                        UPDATE safety_invitation_jobs
                        SET status = 'leased',
                            lease_owner = $2,
                            lease_expires_at = $3,
                            active_attempt_id = $4,
                            attempt_count = attempt_count + 1,
                            last_attempt_at = $5,
                            updated_at = $5
                        WHERE contact_id = $1
                        RETURNING *
                        """,
                        contact_id,
                        worker_id,
                        lease_until,
                        attempt_id,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO safety_invitation_attempts (
                            attempt_id, contact_id, invitation_nonce,
                            attempt_number, status, started_at
                        )
                        VALUES (
                            $1, $2, $3, $4, 'started', $5
                        )
                        """,
                        attempt_id,
                        contact_id,
                        updated["invitation_nonce"],
                        updated["attempt_count"],
                        now,
                    )
                    claimed.append(
                        dict(updated)
                        | {
                            "attempt_id": attempt_id,
                            "phone_e164": row["phone_e164"],
                            "contact_display_name": row["contact_display_name"],
                            "owner_display_name": row["owner_display_name"],
                            "invite_expires_at": row["invite_expires_at"],
                        }
                    )
        return claimed

    async def complete_invitation_attempt(
        self,
        *,
        contact_id: str,
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
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-invitation:{contact_id}",
                )
                row = await connection.fetchrow(
                    """
                    SELECT j.*, c.status AS contact_status,
                           c.invite_expires_at,
                           a.contact_id AS attempt_contact_id,
                           a.invitation_nonce AS attempt_invitation_nonce
                    FROM safety_invitation_jobs j
                    JOIN safety_contacts c
                      ON c.contact_id = j.contact_id
                    JOIN safety_invitation_attempts a
                      ON a.attempt_id = $2
                    WHERE j.contact_id = $1
                    FOR UPDATE OF j, c, a
                    """,
                    UUID(contact_id),
                    UUID(attempt_id),
                )
                if row is None:
                    raise SafetyNotFoundError("invitation job was not found")
                if row["attempt_contact_id"] != row["contact_id"]:
                    raise SafetyConflictError(
                        "invitation attempt does not match its job"
                    )
                outcome = submission_status or "failed"
                await connection.execute(
                    """
                    UPDATE safety_invitation_attempts
                    SET status = $2,
                        provider_reference = $3,
                        error = $4,
                        finished_at = $5
                    WHERE attempt_id = $1
                    """,
                    UUID(attempt_id),
                    outcome,
                    provider_reference,
                    error,
                    now,
                )
                lease_is_current = (
                    row["status"] == "leased"
                    and row["lease_owner"] == worker_id
                    and row["active_attempt_id"] == UUID(attempt_id)
                    and row["invitation_nonce"] == row["attempt_invitation_nonce"]
                )
                if not lease_is_current:
                    return
                submission_failed = submission_status == "failed"
                if submission_status is not None and not submission_failed:
                    await connection.execute(
                        """
                        UPDATE safety_invitation_jobs
                        SET status = $2,
                            provider_reference = $3,
                            error = NULL,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            active_attempt_id = NULL,
                            terminal_at = CASE
                              WHEN $2 IN ('delivered', 'unknown') THEN $4
                              ELSE NULL
                            END,
                            updated_at = $4
                        WHERE contact_id = $1
                        """,
                        row["contact_id"],
                        submission_status,
                        provider_reference,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE safety_contacts
                        SET invitation_delivery_status = $2,
                            invitation_provider_reference = $3,
                            invitation_error = NULL,
                            updated_at = $4
                        WHERE contact_id = $1
                          AND status = 'pending'
                        """,
                        row["contact_id"],
                        submission_status,
                        provider_reference,
                        now,
                    )
                elif (
                    row["attempt_count"] < row["max_attempts"]
                    and row["contact_status"] == "pending"
                    and retry_at < row["invite_expires_at"]
                ):
                    failure_error = error or "invitation provider rejected submission"
                    await connection.execute(
                        """
                        UPDATE safety_invitation_jobs
                        SET status = 'retry_wait',
                            available_at = $2,
                            provider_reference = NULL,
                            error = $3,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            active_attempt_id = NULL,
                            terminal_at = NULL,
                            updated_at = $4
                        WHERE contact_id = $1
                        """,
                        row["contact_id"],
                        retry_at,
                        failure_error,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE safety_contacts
                        SET invitation_delivery_status = 'pending',
                            invitation_provider_reference = NULL,
                            invitation_error = $2,
                            updated_at = $3
                        WHERE contact_id = $1
                          AND status = 'pending'
                        """,
                        row["contact_id"],
                        failure_error,
                        now,
                    )
                else:
                    failure_error = error or "invitation provider rejected submission"
                    await connection.execute(
                        """
                        UPDATE safety_invitation_jobs
                        SET status = 'failed',
                            provider_reference = NULL,
                            error = $2,
                            lease_owner = NULL,
                            lease_expires_at = NULL,
                            active_attempt_id = NULL,
                            terminal_at = $3,
                            updated_at = $3
                        WHERE contact_id = $1
                        """,
                        row["contact_id"],
                        failure_error,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE safety_contacts
                        SET invitation_delivery_status = 'failed',
                            invitation_provider_reference = NULL,
                            invitation_error = $2,
                            updated_at = $3
                        WHERE contact_id = $1
                          AND status = 'pending'
                        """,
                        row["contact_id"],
                        failure_error,
                        now,
                    )

    async def release_invitation_attempt(
        self,
        *,
        contact_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-safety-invitation:{contact_id}",
                )
                row = await connection.fetchrow(
                    """
                    SELECT j.*, a.status AS attempt_status,
                           a.contact_id AS attempt_contact_id,
                           a.invitation_nonce AS attempt_invitation_nonce
                    FROM safety_invitation_jobs j
                    JOIN safety_invitation_attempts a
                      ON a.attempt_id = $2
                    WHERE j.contact_id = $1
                    FOR UPDATE OF j, a
                    """,
                    UUID(contact_id),
                    UUID(attempt_id),
                )
                if (
                    row is None
                    or row["attempt_contact_id"] != row["contact_id"]
                    or row["attempt_status"] != "started"
                    or row["status"] != "leased"
                    or row["lease_owner"] != worker_id
                    or row["active_attempt_id"] != UUID(attempt_id)
                    or row["invitation_nonce"] != row["attempt_invitation_nonce"]
                ):
                    return False
                await connection.execute(
                    """
                    DELETE FROM safety_invitation_attempts
                    WHERE attempt_id = $1
                    """,
                    UUID(attempt_id),
                )
                await connection.execute(
                    """
                    UPDATE safety_invitation_jobs j
                    SET status = 'retry_wait',
                        available_at = $2,
                        lease_owner = NULL,
                        lease_expires_at = NULL,
                        active_attempt_id = NULL,
                        attempt_count = GREATEST(attempt_count - 1, 0),
                        last_attempt_at = (
                          SELECT max(a.started_at)
                          FROM safety_invitation_attempts a
                          WHERE a.contact_id = j.contact_id
                            AND a.invitation_nonce = j.invitation_nonce
                        ),
                        updated_at = $2
                    WHERE contact_id = $1
                    """,
                    UUID(contact_id),
                    now,
                )
                return True

    async def create_dispatch(
        self,
        *,
        dispatch_id: str,
        profile_id: str,
        idempotency_key: str,
        request_hash: str,
        accepted_request_hashes: frozenset[str] = frozenset(),
        trigger: str,
        share_duration_hours: int = 8,
        evidence: dict[str, Any] | None = None,
        escalation_rounds: int = 1,
        escalation_interval_seconds: int = 15 * 60,
        now: datetime,
        expires_at: datetime,
        voice_fallback_at: datetime,
        delivery_ready: bool = True,
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
                    if existing["request_hash"].strip() not in (
                        accepted_request_hashes | {request_hash}
                    ):
                        raise SafetyConflictError(
                            "Idempotency-Key was already used for a different page"
                        )
                    return await self._dispatch_payload(
                        connection,
                        str(existing["dispatch_id"]),
                        idempotent_replay=True,
                    )
                await connection.execute(
                    """
                    DELETE FROM safety_dispatch_tombstones
                    WHERE profile_id = $1
                      AND idempotency_key = $2
                      AND expires_at <= $3
                    """,
                    profile_uuid,
                    UUID(idempotency_key),
                    now,
                )
                tombstone = await connection.fetchrow(
                    """
                    SELECT request_hash
                    FROM safety_dispatch_tombstones
                    WHERE profile_id = $1 AND idempotency_key = $2
                    """,
                    profile_uuid,
                    UUID(idempotency_key),
                )
                if tombstone is not None:
                    if tombstone["request_hash"].strip() not in (
                        accepted_request_hashes | {request_hash}
                    ):
                        raise SafetyConflictError(
                            "Idempotency-Key was already used for a different page"
                        )
                    raise SafetyConflictError(
                        "this safety page was retired and cannot be replayed"
                    )
                if not delivery_ready:
                    raise SafetyNotReadyError(
                        "safety delivery is temporarily unavailable"
                    )
                paging_enabled = await connection.fetchval(
                    """
                    SELECT enabled
                    FROM safety_runtime_controls
                    WHERE control_name = 'paging'
                    FOR SHARE
                    """
                )
                if paging_enabled is not True:
                    raise SafetyNotReadyError("safety paging is temporarily paused")
                expired = await connection.fetch(
                    """
                    UPDATE safety_dispatches
                    SET status = 'expired', updated_at = $2, completed_at = $2
                    WHERE profile_id = $1
                      AND status IN ('open', 'acknowledged')
                      AND expires_at <= $2
                    RETURNING dispatch_id
                    """,
                    profile_uuid,
                    now,
                )
                if expired:
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
                        [row["dispatch_id"] for row in expired],
                        now,
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
                if trigger == "validated_fall" and evidence is not None:
                    duplicate_event = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM safety_dispatches
                            WHERE profile_id = $1
                              AND trigger = 'validated_fall'
                              AND evidence ->> 'event_id' = $2
                        )
                        """,
                        profile_uuid,
                        str(evidence.get("event_id", "")),
                    )
                    if duplicate_event:
                        raise SafetyConflictError(
                            "this validated fall event was already used"
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
                        expires_at, share_duration_hours, evidence,
                        escalation_rounds, escalation_interval_seconds
                    ) VALUES (
                        $1,$2,$3,$4,$5,'open',$6,$6,$7,$8,$9::jsonb,$10,$11
                    )
                    """,
                    UUID(dispatch_id),
                    profile_uuid,
                    UUID(idempotency_key),
                    request_hash,
                    trigger,
                    now,
                    expires_at,
                    share_duration_hours,
                    (
                        json.dumps(evidence, separators=(",", ":"), sort_keys=True)
                        if evidence is not None
                        else None
                    ),
                    escalation_rounds,
                    escalation_interval_seconds,
                )
                voice_delay = voice_fallback_at - now
                for contact in contacts:
                    for escalation_round in range(escalation_rounds):
                        round_start = now + timedelta(
                            seconds=(escalation_round * escalation_interval_seconds)
                        )
                        for channel in ("sms", "voice"):
                            await connection.execute(
                                """
                                INSERT INTO safety_deliveries (
                                    delivery_id, dispatch_id, contact_id, channel,
                                    escalation_round, available_at, max_attempts,
                                    created_at, updated_at
                                ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8)
                                """,
                                uuid4(),
                                UUID(dispatch_id),
                                contact["contact_id"],
                                channel,
                                escalation_round,
                                (
                                    round_start
                                    if channel == "sms"
                                    else round_start + voice_delay
                                ),
                                3 if channel == "sms" else 2,
                                now,
                            )
                return await self._dispatch_payload(
                    connection,
                    dispatch_id,
                    idempotent_replay=False,
                )

    async def dispatch_for_idempotency_key(
        self,
        *,
        profile_id: str,
        idempotency_key: str,
        accepted_request_hashes: frozenset[str],
    ) -> dict[str, Any] | None:
        pool = self._pool()
        async with pool.acquire() as connection:
            existing = await connection.fetchrow(
                """
                SELECT dispatch_id, request_hash
                FROM safety_dispatches
                WHERE profile_id = $1 AND idempotency_key = $2
                """,
                UUID(profile_id),
                UUID(idempotency_key),
            )
            if existing is None:
                return None
            if existing["request_hash"].strip() not in accepted_request_hashes:
                raise SafetyConflictError(
                    "Idempotency-Key was already used for a different page"
                )
            return await self._dispatch_payload(
                connection,
                str(existing["dispatch_id"]),
                idempotent_replay=True,
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
        dispatches_to_finalize: set[str] = set()
        async with pool.acquire() as connection:
            async with connection.transaction():
                paging_enabled = await connection.fetchval(
                    """
                    SELECT enabled
                    FROM safety_runtime_controls
                    WHERE control_name = 'paging'
                    FOR SHARE
                    """
                )
                if paging_enabled is not True:
                    return []
                rows = await connection.fetch(
                    """
                    SELECT d.delivery_id, d.status, d.attempt_count,
                           d.max_attempts, d.channel, d.dispatch_id,
                           d.contact_id, d.escalation_round
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
                                  AND escalation_round = $4
                                  AND status IN ('pending', 'retry_wait')
                                """,
                                row["dispatch_id"],
                                row["contact_id"],
                                now,
                                row["escalation_round"],
                            )
                        dispatches_to_finalize.add(str(row["dispatch_id"]))
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
                        SELECT d.*, i.expires_at, i.trigger, i.evidence,
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
                    claimed_job = dict(job)
                    if isinstance(claimed_job.get("evidence"), str):
                        claimed_job["evidence"] = json.loads(claimed_job["evidence"])
                    claimed.append(claimed_job | {"attempt_id": attempt_id})
        # Parent incidents are always locked before their delivery rows. Finish
        # exhausted aggregates after releasing the claim transaction's delivery
        # locks to preserve that global order.
        for dispatch_id in sorted(dispatches_to_finalize):
            async with pool.acquire() as connection:
                async with connection.transaction():
                    await connection.execute(
                        """
                        UPDATE safety_dispatches
                        SET updated_at = $2
                        WHERE dispatch_id = $1
                        """,
                        UUID(dispatch_id),
                        now,
                    )
                    await self._finalize_failed_dispatch(
                        connection,
                        dispatch_id=dispatch_id,
                        now=now,
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
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                dispatch_id = await connection.fetchval(
                    """
                    SELECT dispatch_id
                    FROM safety_deliveries
                    WHERE delivery_id = $1
                    """,
                    UUID(delivery_id),
                )
                if dispatch_id is None:
                    raise SafetyNotFoundError("delivery was not found")
                incident = await connection.fetchrow(
                    """
                    SELECT status, expires_at
                    FROM safety_dispatches
                    WHERE dispatch_id = $1
                    FOR UPDATE
                    """,
                    dispatch_id,
                )
                if incident is None:
                    raise SafetyNotFoundError("delivery was not found")
                row = await connection.fetchrow(
                    """
                    SELECT d.*
                    FROM safety_deliveries d
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
                    and incident["status"] == "open"
                    and retry_at < incident["expires_at"]
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
                              AND escalation_round = $4
                              AND status IN ('pending', 'retry_wait')
                            """,
                            row["dispatch_id"],
                            row["contact_id"],
                            now,
                            row["escalation_round"],
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
                await self._finalize_failed_dispatch(
                    connection,
                    dispatch_id=str(row["dispatch_id"]),
                    now=now,
                )

    async def release_delivery_attempt(
        self,
        *,
        delivery_id: str,
        attempt_id: str,
        worker_id: str,
        now: datetime,
    ) -> bool:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT d.delivery_id
                    FROM safety_deliveries d
                    JOIN safety_delivery_attempts a
                      ON a.delivery_id = d.delivery_id
                    WHERE d.delivery_id = $1
                      AND a.attempt_id = $2
                      AND a.status = 'started'
                      AND d.status = 'leased'
                      AND d.lease_owner = $3
                    FOR UPDATE OF d, a
                    """,
                    UUID(delivery_id),
                    UUID(attempt_id),
                    worker_id,
                )
                if row is None:
                    return False
                await connection.execute(
                    """
                    DELETE FROM safety_delivery_attempts
                    WHERE attempt_id = $1
                    """,
                    UUID(attempt_id),
                )
                await connection.execute(
                    """
                    UPDATE safety_deliveries
                    SET status = 'retry_wait',
                        available_at = $2,
                        lease_owner = NULL,
                        lease_expires_at = NULL,
                        attempt_count = GREATEST(attempt_count - 1, 0),
                        last_attempt_at = (
                            SELECT max(started_at)
                            FROM safety_delivery_attempts
                            WHERE delivery_id = $1
                        ),
                        updated_at = $2
                    WHERE delivery_id = $1
                    """,
                    UUID(delivery_id),
                    now,
                )
                return True

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
                invitation_handled = await self._update_invitation_provider_receipt(
                    connection,
                    provider_reference=provider_reference,
                    status=status,
                    now=now,
                    retry_at=retry_at,
                )
                if invitation_handled:
                    return True
                # Backward compatibility for invitations submitted before
                # migration 009 introduced durable invitation attempts.
                legacy_invitation = await connection.fetchval(
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
                if legacy_invitation is not None:
                    return True
                dispatch_id = await connection.fetchval(
                    """
                    SELECT d.dispatch_id
                    FROM safety_delivery_attempts a
                    JOIN safety_deliveries d
                      ON d.delivery_id = a.delivery_id
                    WHERE a.provider_reference = $1
                    """,
                    provider_reference,
                )
                if dispatch_id is None:
                    return False
                incident = await connection.fetchrow(
                    """
                    SELECT status, expires_at
                    FROM safety_dispatches
                    WHERE dispatch_id = $1
                    FOR UPDATE
                    """,
                    dispatch_id,
                )
                if incident is None:
                    return False
                row = await connection.fetchrow(
                    """
                    SELECT a.attempt_id, a.status AS attempt_status,
                           d.*
                    FROM safety_delivery_attempts a
                    JOIN safety_deliveries d
                      ON d.delivery_id = a.delivery_id
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
                        and incident["status"] == "open"
                        and retry_at < incident["expires_at"]
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
                                  AND escalation_round = $4
                                  AND status IN ('pending', 'retry_wait')
                                """,
                                row["dispatch_id"],
                                row["contact_id"],
                                now,
                                row["escalation_round"],
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
                await self._finalize_failed_dispatch(
                    connection,
                    dispatch_id=str(row["dispatch_id"]),
                    now=now,
                )
                return True

    async def mark_stale_provider_receipts(
        self,
        *,
        cutoff: datetime,
        now: datetime,
        limit: int = 200,
    ) -> int:
        if limit <= 0:
            return 0
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    WITH stale AS (
                        SELECT d.delivery_id, d.dispatch_id, d.contact_id,
                               d.channel, d.escalation_round,
                               d.provider_reference,
                               i.status AS incident_status
                        FROM safety_deliveries d
                        JOIN safety_dispatches i
                          ON i.dispatch_id = d.dispatch_id
                        WHERE d.status IN ('queued', 'sent')
                          AND d.updated_at <= $1
                        ORDER BY d.updated_at, d.delivery_id
                        FOR UPDATE OF d SKIP LOCKED
                        LIMIT $3
                    ),
                    updated AS (
                        UPDATE safety_deliveries d
                        SET status = 'unknown',
                            error = 'provider delivery receipt timed out',
                            terminal_at = $2,
                            updated_at = $2
                        FROM stale
                        WHERE d.delivery_id = stale.delivery_id
                        RETURNING d.delivery_id, d.dispatch_id, d.contact_id,
                                  d.channel, d.escalation_round,
                                  d.provider_reference
                    ),
                    attempts AS (
                        UPDATE safety_delivery_attempts a
                        SET status = 'unknown',
                            error = 'provider delivery receipt timed out',
                            finished_at = $2
                        FROM updated
                        WHERE a.provider_reference =
                              updated.provider_reference
                        RETURNING a.attempt_id
                    )
                    SELECT updated.*, stale.incident_status
                    FROM updated
                    JOIN stale USING (delivery_id)
                    """,
                    cutoff,
                    now,
                    limit,
                )
                open_sms = [
                    row
                    for row in rows
                    if row["channel"] == "sms" and row["incident_status"] == "open"
                ]
                if open_sms:
                    await connection.execute(
                        """
                        UPDATE safety_deliveries voice
                        SET available_at = LEAST(voice.available_at, $4),
                            updated_at = $4
                        FROM unnest($1::uuid[], $2::uuid[], $3::smallint[])
                          AS source(dispatch_id, contact_id, escalation_round)
                        WHERE voice.dispatch_id = source.dispatch_id
                          AND voice.contact_id = source.contact_id
                          AND voice.channel = 'voice'
                          AND voice.escalation_round = source.escalation_round
                          AND voice.status IN ('pending', 'retry_wait')
                        """,
                        [row["dispatch_id"] for row in open_sms],
                        [row["contact_id"] for row in open_sms],
                        [row["escalation_round"] for row in open_sms],
                        now,
                    )
                remaining = limit - len(rows)
                invitation_count = 0
                if remaining > 0:
                    invitation_count = int(
                        await connection.fetchval(
                            """
                            WITH stale AS (
                                SELECT contact_id
                                FROM safety_invitation_jobs
                                WHERE status IN ('queued', 'sent')
                                  AND updated_at <= $1
                                ORDER BY updated_at, contact_id
                                FOR UPDATE SKIP LOCKED
                                LIMIT $3
                            ),
                            updated AS (
                                UPDATE safety_invitation_jobs j
                                SET status = 'unknown',
                                    error = (
                                      'provider delivery receipt timed out'
                                    ),
                                    terminal_at = $2,
                                    updated_at = $2
                                FROM stale
                                WHERE j.contact_id = stale.contact_id
                                RETURNING j.contact_id,
                                          j.invitation_nonce,
                                          j.provider_reference
                            ),
                            attempts AS (
                                UPDATE safety_invitation_attempts a
                                SET status = 'unknown',
                                    error = (
                                      'provider delivery receipt timed out'
                                    ),
                                    finished_at = $2
                                FROM updated
                                WHERE a.provider_reference =
                                      updated.provider_reference
                                RETURNING a.attempt_id
                            ),
                            contacts AS (
                                UPDATE safety_contacts c
                                SET invitation_delivery_status = 'unknown',
                                    invitation_error = (
                                      'provider delivery receipt timed out'
                                    ),
                                    updated_at = $2
                                FROM updated
                                WHERE c.contact_id = updated.contact_id
                                  AND c.status = 'pending'
                                  AND c.invitation_provider_reference =
                                      updated.provider_reference
                                RETURNING c.contact_id
                            )
                            SELECT count(*) FROM updated
                            """,
                            cutoff,
                            now,
                            remaining,
                        )
                        or 0
                    )
                return len(rows) + invitation_count

    async def expire_due_dispatches(self, *, now: datetime) -> int:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    UPDATE safety_dispatches
                    SET status = 'expired', updated_at = $1, completed_at = $1
                    WHERE status IN ('open', 'acknowledged')
                      AND expires_at <= $1
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
                     WHEN i.status IN ('open', 'acknowledged')
                          AND i.expires_at <= $3
                     THEN 'expired'
                     ELSE i.status
                   END AS status,
                   i.expires_at, i.trigger, i.share_duration_hours, i.evidence,
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
        if isinstance(decoded.get("evidence"), str):
            decoded["evidence"] = json.loads(decoded["evidence"])
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
        if (
            decoded["status"] not in {"open", "acknowledged"}
            or decoded["location_sequence"] is None
        ):
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
        expired_while_locked = False
        response_payload: dict[str, Any] | None = None
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
                if (
                    incident_status in {"open", "acknowledged"}
                    and incident["expires_at"] <= now
                ):
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
                    await self._cancel_pending_deliveries(
                        connection,
                        dispatch_id=dispatch_id,
                        now=now,
                    )
                    expired_while_locked = True
                else:
                    if incident_status in {
                        "resolved",
                        "cancelled",
                        "expired",
                        "failed",
                    }:
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
                    response_payload = await self._dispatch_payload(
                        connection,
                        dispatch_id,
                        idempotent_replay=False,
                    )
        if expired_while_locked:
            raise SafetyConflictError(
                "this safety incident is no longer accepting responses"
            )
        if response_payload is None:
            raise SafetyNotFoundError("safety incident was not found")
        return response_payload

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
                if incident["status"] in {
                    "resolved",
                    "cancelled",
                    "expired",
                    "failed",
                }:
                    raise SafetyConflictError(
                        f"cannot {action} a {incident['status']} safety incident"
                    )
                await connection.execute(
                    """
                    UPDATE safety_dispatches
                    SET status = $2::text,
                        updated_at = $3::timestamptz,
                        completed_at = $3::timestamptz,
                        resolved_at = CASE
                            WHEN $2::text = 'resolved'
                            THEN $3::timestamptz
                            ELSE NULL
                        END,
                        cancelled_at = CASE
                            WHEN $2::text = 'cancelled'
                            THEN $3::timestamptz
                            ELSE NULL
                        END,
                        resolution_note = $4::text
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

    async def monitoring_snapshot(
        self,
        *,
        now: datetime,
        worker_cutoff: datetime | None = None,
        window_seconds: int = 24 * 60 * 60,
    ) -> dict[str, Any]:
        pool = self._pool()
        active_cutoff = worker_cutoff or now - timedelta(seconds=30)
        bounded_window = max(window_seconds, 1)
        window_start = now - timedelta(seconds=bounded_window)
        incidents = await pool.fetchrow(
            """
            SELECT
              count(*) FILTER (WHERE status = 'open') AS open,
              count(*) FILTER (WHERE status = 'acknowledged') AS acknowledged,
              count(*) FILTER (
                WHERE status = 'failed'
                  AND completed_at >= $2::timestamptz
              ) AS failed,
              count(*) FILTER (
                WHERE status IN ('open', 'acknowledged')
                  AND expires_at <= $1::timestamptz
              ) AS overdue
            FROM safety_dispatches
            """,
            now,
            window_start,
        )
        states = await pool.fetch(
            """
            SELECT status, count(*) AS count
            FROM safety_deliveries
            WHERE status IN ('pending', 'retry_wait', 'leased', 'queued', 'sent')
               OR updated_at >= $1::timestamptz
            GROUP BY status
            """,
            window_start,
        )
        invitation_states = await pool.fetch(
            """
            SELECT status, count(*) AS count
            FROM safety_invitation_jobs
            WHERE status IN ('pending', 'retry_wait', 'leased', 'queued', 'sent')
               OR updated_at >= $1::timestamptz
            GROUP BY status
            """,
            window_start,
        )
        delivery_health = await pool.fetchrow(
            """
            SELECT
              count(*) FILTER (
                WHERE status = 'leased'
                  AND lease_expires_at <= $1::timestamptz
              ) AS stale_leases,
              count(*) FILTER (
                WHERE attempt_count > 1
                  AND updated_at >= $2::timestamptz
              ) AS retrying_deliveries,
              count(*) FILTER (
                WHERE status = 'unknown'
                  AND updated_at >= $2::timestamptz
              ) AS unknown_receipts,
              count(*) FILTER (
                WHERE status = 'failed'
                  AND updated_at >= $2::timestamptz
              ) AS total_delivery_failures,
              COALESCE(
                EXTRACT(
                  epoch FROM $1::timestamptz - (
                    min(available_at) FILTER (
                      WHERE status IN ('pending', 'retry_wait')
                        AND available_at <= $1::timestamptz
                    )
                  )
                ),
                0
              ) AS oldest_due_seconds,
              percentile_cont(0.95) WITHIN GROUP (
                ORDER BY EXTRACT(epoch FROM delivered_at - created_at)
              ) FILTER (
                WHERE delivered_at IS NOT NULL
                  AND delivered_at >= $2::timestamptz
              ) AS provider_delivery_latency_p95_seconds
            FROM safety_deliveries
            """,
            now,
            window_start,
        )
        invitation_health = await pool.fetchrow(
            """
            SELECT
              count(*) FILTER (
                WHERE status = 'leased'
                  AND lease_expires_at <= $1::timestamptz
              ) AS stale_leases,
              count(*) FILTER (
                WHERE status = 'unknown'
                  AND updated_at >= $2::timestamptz
              ) AS unknown_receipts,
              count(*) FILTER (
                WHERE status = 'failed'
                  AND updated_at >= $2::timestamptz
              ) AS total_failures,
              COALESCE(
                EXTRACT(
                  epoch FROM $1::timestamptz - (
                    min(available_at) FILTER (
                      WHERE status IN ('pending', 'retry_wait')
                        AND available_at <= $1::timestamptz
                    )
                  )
                ),
                0
              ) AS oldest_due_seconds
            FROM safety_invitation_jobs
            """,
            now,
            window_start,
        )
        attempts = await pool.fetchrow(
            """
            SELECT
              (
                SELECT count(*)
                FROM safety_delivery_attempts
                WHERE status = 'unknown'
                  AND COALESCE(finished_at, started_at) >= $1::timestamptz
              ) AS delivery_unknown,
              (
                SELECT count(*)
                FROM safety_invitation_attempts
                WHERE status = 'unknown'
                  AND COALESCE(finished_at, started_at) >= $1::timestamptz
              ) AS invitation_unknown
            """,
            window_start,
        )
        workers = await pool.fetchrow(
            """
            SELECT
              count(*) FILTER (
                WHERE last_seen_at >= $2::timestamptz
              ) AS active,
              count(*) FILTER (
                WHERE last_seen_at < $2::timestamptz
              ) AS stale,
              EXTRACT(epoch FROM $1::timestamptz - min(last_seen_at))
                AS oldest_heartbeat_age_seconds
            FROM safety_worker_heartbeats
            """,
            now,
            active_cutoff,
        )
        paging_control = await self.paging_control()
        unknown_delivery_attempts = int(attempts["delivery_unknown"] or 0)
        unknown_invitation_attempts = int(attempts["invitation_unknown"] or 0)
        return {
            "telemetry_window": {
                "seconds": bounded_window,
                "started_at": window_start,
                "ended_at": now,
            },
            "paging_control": paging_control,
            "workers": {
                "active": int(workers["active"] or 0),
                "stale": int(workers["stale"] or 0),
                "oldest_heartbeat_age_seconds": (
                    int(workers["oldest_heartbeat_age_seconds"])
                    if workers["oldest_heartbeat_age_seconds"] is not None
                    else None
                ),
            },
            "incidents": {
                key: int(value or 0) for key, value in dict(incidents).items()
            },
            "queue": {row["status"]: int(row["count"]) for row in states},
            "invitation_queue": {
                row["status"]: int(row["count"]) for row in invitation_states
            },
            "oldest_due_seconds": int(delivery_health["oldest_due_seconds"] or 0),
            "oldest_invitation_due_seconds": int(
                invitation_health["oldest_due_seconds"] or 0
            ),
            "retrying_deliveries": int(delivery_health["retrying_deliveries"] or 0),
            "unknown_receipts": int(delivery_health["unknown_receipts"] or 0),
            "unknown_invitation_receipts": int(
                invitation_health["unknown_receipts"] or 0
            ),
            "unknown_attempts": (
                unknown_delivery_attempts + unknown_invitation_attempts
            ),
            "unknown_delivery_attempts": unknown_delivery_attempts,
            "unknown_invitation_attempts": unknown_invitation_attempts,
            "total_delivery_failures": int(
                delivery_health["total_delivery_failures"] or 0
            ),
            "total_invitation_failures": int(invitation_health["total_failures"] or 0),
            "provider_delivery_latency_p95_seconds": (
                round(
                    float(delivery_health["provider_delivery_latency_p95_seconds"]),
                    3,
                )
                if delivery_health["provider_delivery_latency_p95_seconds"] is not None
                else None
            ),
            "stale_leases": int(delivery_health["stale_leases"] or 0),
            "stale_invitation_leases": int(invitation_health["stale_leases"] or 0),
        }

    async def _update_invitation_provider_receipt(
        self,
        connection: Any,
        *,
        provider_reference: str,
        status: str,
        now: datetime,
        retry_at: datetime,
    ) -> bool:
        contact_id = await connection.fetchval(
            """
            SELECT contact_id
            FROM safety_invitation_attempts
            WHERE provider_reference = $1
            """,
            provider_reference,
        )
        if contact_id is None:
            return False
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            f"noop-safety-invitation:{contact_id}",
        )
        row = await connection.fetchrow(
            """
            SELECT j.*, c.status AS contact_status,
                   c.invite_expires_at,
                   a.attempt_id,
                   a.status AS attempt_status,
                   a.invitation_nonce AS attempt_invitation_nonce
            FROM safety_invitation_attempts a
            JOIN safety_invitation_jobs j
              ON j.contact_id = a.contact_id
            JOIN safety_contacts c
              ON c.contact_id = j.contact_id
            WHERE a.provider_reference = $1
            FOR UPDATE OF a, j, c
            """,
            provider_reference,
        )
        if row is None:
            return False
        await connection.execute(
            """
            UPDATE safety_invitation_attempts
            SET status = $2, finished_at = $3
            WHERE attempt_id = $1
            """,
            row["attempt_id"],
            _advanced_provider_status(str(row["attempt_status"]), status),
            now,
        )
        if (
            row["invitation_nonce"] != row["attempt_invitation_nonce"]
            or row["status"] == "cancelled"
            or row["contact_status"] != "pending"
        ):
            return True
        is_latest = row["provider_reference"] == provider_reference
        if status == "delivered":
            await connection.execute(
                """
                UPDATE safety_invitation_jobs
                SET status = 'delivered',
                    error = NULL,
                    terminal_at = $2,
                    updated_at = $2
                WHERE contact_id = $1
                """,
                row["contact_id"],
                now,
            )
            await connection.execute(
                """
                UPDATE safety_contacts
                SET invitation_delivery_status = 'delivered',
                    invitation_provider_reference = $2,
                    invitation_error = NULL,
                    updated_at = $3
                WHERE contact_id = $1
                  AND status = 'pending'
                """,
                row["contact_id"],
                provider_reference,
                now,
            )
        elif status == "failed" and is_latest and row["status"] != "delivered":
            failure_error = "paging provider reported invitation failure"
            if (
                row["attempt_count"] < row["max_attempts"]
                and retry_at < row["invite_expires_at"]
            ):
                await connection.execute(
                    """
                    UPDATE safety_invitation_jobs
                    SET status = 'retry_wait',
                        available_at = $2,
                        provider_reference = NULL,
                        error = $3,
                        terminal_at = NULL,
                        updated_at = $4
                    WHERE contact_id = $1
                    """,
                    row["contact_id"],
                    retry_at,
                    failure_error,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE safety_contacts
                    SET invitation_delivery_status = 'pending',
                        invitation_provider_reference = NULL,
                        invitation_error = $2,
                        updated_at = $3
                    WHERE contact_id = $1
                      AND status = 'pending'
                    """,
                    row["contact_id"],
                    failure_error,
                    now,
                )
            else:
                await connection.execute(
                    """
                    UPDATE safety_invitation_jobs
                    SET status = 'failed',
                        error = $2,
                        terminal_at = $3,
                        updated_at = $3
                    WHERE contact_id = $1
                    """,
                    row["contact_id"],
                    failure_error,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE safety_contacts
                    SET invitation_delivery_status = 'failed',
                        invitation_error = $2,
                        updated_at = $3
                    WHERE contact_id = $1
                      AND status = 'pending'
                    """,
                    row["contact_id"],
                    failure_error,
                    now,
                )
        elif is_latest and row["status"] not in {
            "delivered",
            "failed",
            "cancelled",
        }:
            advanced = _advanced_provider_status(str(row["status"]), status)
            await connection.execute(
                """
                UPDATE safety_invitation_jobs
                SET status = $2, updated_at = $3
                WHERE contact_id = $1
                """,
                row["contact_id"],
                advanced,
                now,
            )
            await connection.execute(
                """
                UPDATE safety_contacts
                SET invitation_delivery_status = $2,
                    updated_at = $3
                WHERE contact_id = $1
                  AND status = 'pending'
                """,
                row["contact_id"],
                advanced,
                now,
            )
        return True

    async def _finalize_failed_dispatch(
        self,
        connection: Any,
        *,
        dispatch_id: str,
        now: datetime,
    ) -> None:
        # Serialize aggregate completion even when separate workers finish the
        # last deliveries concurrently.
        await connection.fetchval(
            """
            SELECT dispatch_id
            FROM safety_dispatches
            WHERE dispatch_id = $1
            FOR UPDATE
            """,
            UUID(dispatch_id),
        )
        await connection.execute(
            """
            UPDATE safety_dispatches i
            SET status = 'failed',
                updated_at = $2,
                completed_at = $2
            WHERE i.dispatch_id = $1
              AND i.status = 'open'
              AND EXISTS (
                SELECT 1
                FROM safety_deliveries d
                WHERE d.dispatch_id = i.dispatch_id
              )
              AND NOT EXISTS (
                SELECT 1
                FROM safety_deliveries d
                WHERE d.dispatch_id = i.dispatch_id
                  AND d.status <> 'failed'
              )
              AND NOT EXISTS (
                SELECT 1
                FROM safety_deliveries d
                JOIN safety_delivery_attempts a
                  ON a.delivery_id = d.delivery_id
                WHERE d.dispatch_id = i.dispatch_id
                  AND a.status IN ('started', 'queued', 'sent', 'unknown')
              )
            """,
            UUID(dispatch_id),
            now,
        )

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
                   i.completed_at, i.share_duration_hours, i.evidence,
                   i.escalation_rounds, i.escalation_interval_seconds,
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
                   c.phone_e164, d.channel, d.escalation_round, d.status,
                   d.provider_reference, d.error,
                   d.available_at, d.attempt_count, d.max_attempts,
                   d.last_attempt_at, d.delivered_at, d.terminal_at,
                   d.created_at, d.updated_at,
                   EXISTS (
                     SELECT 1
                     FROM safety_delivery_attempts a
                     WHERE a.delivery_id = d.delivery_id
                       AND a.status IN ('started', 'queued', 'sent', 'unknown')
                   ) AS has_unconfirmed_attempt
            FROM safety_deliveries d
            JOIN safety_contacts c ON c.contact_id = d.contact_id
            WHERE d.dispatch_id = $1
            ORDER BY lower(c.display_name), d.escalation_round, d.channel
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
        decoded_dispatch = dict(dispatch)
        if isinstance(decoded_dispatch.get("evidence"), str):
            decoded_dispatch["evidence"] = json.loads(decoded_dispatch["evidence"])
        return decoded_dispatch | {
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
