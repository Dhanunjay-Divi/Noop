from __future__ import annotations

import asyncio
import hashlib
import hmac
import math
from collections.abc import Collection
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

from app.managed_push import (
    ManagedPushSending,
    ManagedPushTokenCodec,
    ManagedPushTokenCorruptError,
    ManagedPushTokenError,
    ManagedPushTokenUnavailableError,
)
from app.managed_repository import (
    ManagedConflictError,
    ManagedForbiddenError,
    ManagedNotFoundError,
    ManagedPrincipal,
    ManagedRateLimitError,
    ManagedStorageError,
    _lock_active_managed_safety_incidents_for_profile_pair,
    _reconcile_managed_safety_incident_acknowledgement,
)
from app.managed_safety_models import (
    ManagedPushRegistration,
    ManagedSafetyIncidentCreate,
    ManagedSafetyInviteCreate,
    ManagedSafetyLocationUpdate,
    ManagedSafetyRequestCreate,
)

SAFETY_MAX_CONTACTS = 5
SAFETY_MAX_OWNERS_PER_CONTACT = 20
SAFETY_MIN_CONTACTS = 2
SAFETY_MAX_ACTIVE_INVITES = 10
SAFETY_MAX_INVITES_PER_DAY = 50
SAFETY_MAX_REQUESTS_PER_DAY = 50
SAFETY_MAX_PENDING_REQUESTS = 10
SAFETY_REQUEST_LIST_LIMIT = 50
# A profile can also own at most SAFETY_MAX_PENDING_REQUESTS outgoing rows. Keeping
# the two bounds additive means list_requests never hides a still-actionable row.
SAFETY_MAX_RECEIVED_PENDING_REQUESTS = (
    SAFETY_REQUEST_LIST_LIMIT - SAFETY_MAX_PENDING_REQUESTS
)
SAFETY_MAX_ACTIVE_PUSH_INSTALLATIONS = 4
SAFETY_PUSH_MIN_CLAIM_SECONDS = 60
SAFETY_PUSH_RECEIPT_MARGIN_SECONDS = 30
SAFETY_PUSH_RETRY_DELAY_SECONDS = 60
SAFETY_MAX_INCIDENTS_PER_HOUR = 4
SAFETY_MAX_INCIDENTS_PER_DAY = 12


@dataclass(frozen=True, slots=True)
class ManagedPushBatchResult:
    claimed: int = 0
    provider_accepted: int = 0
    retryable_failures: int = 0
    terminal_failures: int = 0
    receipt_failures: int = 0


class PostgresManagedSafetyRepository:
    def __init__(self, primary_repository: Any) -> None:
        self.primary_repository = primary_repository

    def _pool(self) -> Any:
        return self.primary_repository._require_pool()

    @staticmethod
    def _require_active(principal: ManagedPrincipal) -> None:
        if principal.account_status != "active":
            raise ManagedForbiddenError("managed account is not active")

    @staticmethod
    def _retired_token_hash(
        *,
        account_id: UUID,
        installation_id: str,
        token_hash: str,
    ) -> str:
        return hashlib.sha256(
            (
                "noop-managed-retired-push-v1\0"
                f"{account_id}\0{installation_id}\0{token_hash}"
            ).encode("utf-8")
        ).hexdigest()

    @staticmethod
    async def _profile(
        connection: Any,
        *,
        account_id: UUID,
        for_update: bool = False,
    ) -> Any:
        lock = " FOR UPDATE OF account, profile" if for_update else ""
        row = await connection.fetchrow(
            f"""
            SELECT profile.*, alias.alias_value AS noop_id
            FROM managed_social_profiles profile
            JOIN managed_accounts account
              ON account.account_id = profile.account_id
             AND account.status = 'active'
            JOIN managed_social_aliases alias
              ON alias.profile_id = profile.profile_id
             AND alias.status = 'active'
            WHERE profile.account_id = $1
              AND profile.status = 'active'
            {lock}
            """,
            account_id,
        )
        if row is None:
            raise ManagedNotFoundError(
                "create a NOOP profile before configuring Safety contacts"
            )
        return row

    @staticmethod
    async def _lock_pair(
        connection: Any,
        *,
        owner_profile_id: UUID,
        contact_profile_id: UUID,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            (f"noop-managed-safety-pair:{owner_profile_id}:{contact_profile_id}"),
        )

    @staticmethod
    async def _lock_active_profiles_and_accounts(
        connection: Any,
        *,
        profile_ids: Collection[UUID],
    ) -> list[Any]:
        return await connection.fetch(
            """
            SELECT profile.profile_id,
                   profile.account_id,
                   profile.display_name
            FROM managed_social_profiles profile
            JOIN managed_accounts account
              ON account.account_id = profile.account_id
             AND account.status = 'active'
            WHERE profile.profile_id = ANY($1::uuid[])
              AND profile.status = 'active'
            ORDER BY profile.profile_id
            FOR UPDATE OF account, profile
            """,
            list(profile_ids),
        )

    @staticmethod
    async def _lock_profiles_and_accounts(
        connection: Any,
        *,
        profile_ids: Collection[UUID],
    ) -> list[Any]:
        return await connection.fetch(
            """
            SELECT profile.profile_id
            FROM managed_social_profiles profile
            JOIN managed_accounts account
              ON account.account_id = profile.account_id
            WHERE profile.profile_id = ANY($1::uuid[])
            ORDER BY profile.profile_id
            FOR UPDATE OF account, profile
            """,
            list(profile_ids),
        )

    @staticmethod
    async def _expire_incidents(
        connection: Any,
        *,
        now: datetime,
        owner_profile_id: UUID | None = None,
    ) -> None:
        expired = await connection.fetch(
            """
            UPDATE managed_safety_incidents
            SET status = 'expired', ended_at = $1
            WHERE status IN ('open', 'acknowledged')
              AND expires_at <= $1
              AND ($2::uuid IS NULL OR owner_profile_id = $2)
            RETURNING incident_id
            """,
            now,
            owner_profile_id,
        )
        if expired:
            incident_ids = [row["incident_id"] for row in expired]
            await connection.execute(
                """
                DELETE FROM managed_safety_locations
                WHERE incident_id = ANY($1::uuid[])
                """,
                incident_ids,
            )
            await connection.execute(
                """
                UPDATE managed_safety_push_deliveries
                SET status = 'rejected',
                    claim_id = NULL,
                    claim_expires_at = NULL,
                    updated_at = $2
                WHERE incident_id = ANY($1::uuid[])
                  AND status IN (
                      'pending',
                      'sending',
                      'transient_failure',
                      'unavailable'
                  )
                """,
                incident_ids,
                now,
            )

    async def _expire(self, connection: Any, now: datetime) -> None:
        await connection.execute(
            """
            UPDATE managed_safety_invites
            SET status = 'expired'
            WHERE status = 'active' AND expires_at <= $1
            """,
            now,
        )
        await connection.execute(
            """
            UPDATE managed_safety_requests
            SET status = 'expired', decided_at = $1
            WHERE status = 'pending' AND expires_at <= $1
            """,
            now,
        )
        await self._expire_incidents(
            connection,
            now=now,
        )
        await connection.execute(
            """
            UPDATE managed_safety_push_deliveries
            SET status = CASE
                    WHEN attempts >= 3 THEN 'rejected'
                    ELSE 'transient_failure'
                END,
                claim_id = NULL,
                claim_expires_at = NULL,
                updated_at = $1
            WHERE status = 'sending' AND claim_expires_at <= $1
            """,
            now,
        )

    async def _expire_before_profile_operation(self) -> None:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                await self._expire(connection, now)

    @staticmethod
    def _public_request(row: Any, caller_profile_id: UUID) -> dict[str, Any]:
        incoming = row["contact_profile_id"] == caller_profile_id
        other_profile_id = (
            row["owner_profile_id"] if incoming else row["contact_profile_id"]
        )
        return {
            "request_id": str(row["request_id"]),
            "profile_id": str(other_profile_id),
            "display_name": str(row["other_display_name"]),
            "direction": "incoming" if incoming else "outgoing",
            "source": str(row["source"]),
            "status": str(row["status"]),
            "created_at": row["created_at"],
            "decided_at": row["decided_at"],
            "expires_at": row["expires_at"],
        }

    async def register_push_installation(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        registration: ManagedPushRegistration,
        token_hash: str,
        token_ciphertext: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-push-account:{principal.account_id}",
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-push-token:{token_hash}",
                )
                installation = await connection.fetchrow(
                    """
                    SELECT platform, status
                    FROM managed_account_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    installation_id,
                )
                if installation is None or installation["status"] != "active":
                    raise ManagedForbiddenError("managed installation is not active")
                if installation["platform"] != registration.platform:
                    raise ManagedConflictError(
                        "push platform does not match the managed installation"
                    )
                conflict = await connection.fetchrow(
                    """
                    SELECT account_id, installation_id, status
                    FROM managed_push_installations
                    WHERE token_hash = $1
                    FOR UPDATE
                    """,
                    token_hash,
                )
                if conflict is not None and (
                    conflict["account_id"] != principal.account_id
                    or conflict["installation_id"] != installation_id
                ):
                    if conflict["status"] == "active":
                        raise ManagedConflictError(
                            "push token is already registered to another installation"
                        )
                    retired_hash = self._retired_token_hash(
                        account_id=conflict["account_id"],
                        installation_id=str(conflict["installation_id"]),
                        token_hash=token_hash,
                    )
                    await connection.execute(
                        """
                        UPDATE managed_push_installations
                        SET token_hash = $2::char(64),
                            token_ciphertext = $3,
                            updated_at = $4
                        WHERE token_hash = $1 AND status <> 'active'
                        """,
                        token_hash,
                        retired_hash,
                        f"retired.{retired_hash}",
                        now,
                    )
                current = await connection.fetchrow(
                    """
                    SELECT token_hash, platform, environment, target_kind, status
                    FROM managed_push_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    installation_id,
                )
                duplicate = (
                    current is not None
                    and hmac.compare_digest(
                        str(current["token_hash"]).strip(),
                        token_hash,
                    )
                    and current["platform"] == registration.platform
                    and current["environment"] == registration.environment
                    and current["target_kind"] == registration.target_kind
                    and current["status"] == "active"
                )
                await connection.execute(
                    """
                    INSERT INTO managed_push_installations (
                        account_id,
                        installation_id,
                        platform,
                        environment,
                        target_kind,
                        token_hash,
                        token_ciphertext,
                        status,
                        created_at,
                        updated_at,
                        last_seen_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, 'active', $8, $8, $8
                    )
                    ON CONFLICT (account_id, installation_id)
                    DO UPDATE SET
                        platform = EXCLUDED.platform,
                        environment = EXCLUDED.environment,
                        target_kind = EXCLUDED.target_kind,
                        token_hash = EXCLUDED.token_hash,
                        token_ciphertext = EXCLUDED.token_ciphertext,
                        status = 'active',
                        updated_at = EXCLUDED.updated_at,
                        last_seen_at = EXCLUDED.last_seen_at,
                        revoked_at = NULL
                    """,
                    principal.account_id,
                    installation_id,
                    registration.platform,
                    registration.environment,
                    registration.target_kind,
                    token_hash,
                    token_ciphertext,
                    now,
                )
                await connection.execute(
                    """
                    WITH surplus AS (
                        SELECT account_id, installation_id
                        FROM managed_push_installations
                        WHERE account_id = $1 AND status = 'active'
                        ORDER BY last_seen_at DESC, installation_id
                        OFFSET $2
                    )
                    UPDATE managed_push_installations target
                    SET status = 'revoked',
                        token_ciphertext = 'revoked.' || target.token_hash,
                        revoked_at = $3,
                        updated_at = $3
                    FROM surplus
                    WHERE target.account_id = surplus.account_id
                      AND target.installation_id = surplus.installation_id
                    """,
                    principal.account_id,
                    SAFETY_MAX_ACTIVE_PUSH_INSTALLATIONS,
                    now,
                )
                await connection.fetch(
                    """
                    SELECT participant.incident_id
                    FROM managed_social_profiles profile
                    JOIN managed_safety_participants participant
                      ON participant.contact_profile_id = profile.profile_id
                     AND participant.status = 'pending'
                    JOIN managed_safety_incidents incident
                      ON incident.incident_id = participant.incident_id
                     AND incident.status IN ('open', 'acknowledged')
                     AND incident.expires_at > $2
                    WHERE profile.account_id = $1
                      AND profile.status = 'active'
                    FOR UPDATE OF participant
                    """,
                    principal.account_id,
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_safety_push_deliveries (
                        delivery_id,
                        incident_id,
                        contact_profile_id,
                        account_id,
                        installation_id,
                        status,
                        attempts,
                        created_at,
                        updated_at
                    )
                    SELECT gen_random_uuid(),
                           incident.incident_id,
                           participant.contact_profile_id,
                           push.account_id,
                           push.installation_id,
                           'pending',
                           0,
                           $3,
                           $3
                    FROM managed_push_installations push
                    JOIN managed_accounts account
                      ON account.account_id = push.account_id
                     AND account.status = 'active'
                    JOIN managed_social_profiles profile
                      ON profile.account_id = push.account_id
                     AND profile.status = 'active'
                    JOIN managed_safety_participants participant
                      ON participant.contact_profile_id = profile.profile_id
                     AND participant.status = 'pending'
                    JOIN managed_safety_incidents incident
                      ON incident.incident_id = participant.incident_id
                     AND incident.status IN ('open', 'acknowledged')
                     AND incident.expires_at > $3
                    WHERE push.account_id = $1
                      AND push.installation_id = $2
                      AND push.status = 'active'
                    ON CONFLICT (
                        incident_id,
                        contact_profile_id,
                        installation_id
                    ) DO UPDATE SET
                        status = 'pending',
                        attempts = 0,
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        last_attempt_at = NULL,
                        delivered_at = NULL,
                        provider_reference_hash = NULL,
                        updated_at = EXCLUDED.updated_at
                    WHERE NOT $4::boolean
                      AND managed_safety_push_deliveries.status <> 'sent'
                    """,
                    principal.account_id,
                    installation_id,
                    now,
                    duplicate,
                )
        return {
            "installation_id": installation_id,
            "platform": registration.platform,
            "environment": registration.environment,
            "target_kind": registration.target_kind,
            "status": "active",
            "updated_at": now,
            "duplicate": duplicate,
        }

    async def revoke_push_installation(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
    ) -> None:
        self._require_active(principal)
        now = await self._pool().fetchval("SELECT clock_timestamp()")
        result = await self._pool().execute(
            """
            UPDATE managed_push_installations
            SET status = 'revoked',
                token_ciphertext = 'revoked.' || token_hash,
                revoked_at = $3,
                updated_at = $3
            WHERE account_id = $1
              AND installation_id = $2
              AND status <> 'revoked'
            """,
            principal.account_id,
            installation_id,
            now,
        )
        if result == "UPDATE 0":
            row = await self._pool().fetchrow(
                """
                SELECT status
                FROM managed_push_installations
                WHERE account_id = $1 AND installation_id = $2
                """,
                principal.account_id,
                installation_id,
            )
            if row is None:
                raise ManagedNotFoundError("managed push installation was not found")

    async def create_invite(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSafetyInviteCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        capability = request.capability.get_secret_value()
        capability_hash = hashlib.sha256(capability.encode("ascii")).hexdigest()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-safety-invite:{owner['account_id']}",
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                replay = await connection.fetchrow(
                    """
                    SELECT quota.*,
                           invite.owner_profile_id,
                           invite.status,
                           invite.created_at AS invite_created_at,
                           invite.expires_at
                    FROM managed_safety_invite_quota_events quota
                    LEFT JOIN managed_safety_invites invite
                      ON invite.invite_id = quota.invite_id
                    WHERE quota.owner_account_id = $1
                      AND quota.client_request_id = $2
                    FOR UPDATE OF quota
                    """,
                    owner["account_id"],
                    request.request_id,
                )
                if replay is not None:
                    if not hmac.compare_digest(
                        str(replay["capability_hash"]).strip(),
                        capability_hash,
                    ):
                        raise ManagedConflictError(
                            "Safety invite request id was reused"
                        )
                    if replay["owner_profile_id"] != owner["profile_id"]:
                        raise ManagedConflictError(
                            "Safety invite request id was already consumed"
                        )
                    return {
                        "invite_id": str(replay["invite_id"]),
                        "capability": capability,
                        "status": str(replay["status"]),
                        "created_at": replay["invite_created_at"],
                        "expires_at": replay["expires_at"],
                        "duplicate": True,
                    }
                invite_counts = await connection.fetchrow(
                    """
                    SELECT
                        (
                            SELECT count(*)
                            FROM managed_safety_invites invite
                            WHERE invite.owner_profile_id = $1
                              AND invite.status = 'active'
                              AND invite.expires_at > $3
                        ) AS active_count,
                        count(*) AS recent_count,
                        min(quota.created_at) AS recent_oldest
                    FROM managed_safety_invite_quota_events quota
                    WHERE quota.owner_account_id = $2
                      AND quota.created_at >
                            $3::timestamptz - interval '24 hours'
                    """,
                    owner["profile_id"],
                    owner["account_id"],
                    now,
                )
                if int(invite_counts["active_count"]) >= SAFETY_MAX_ACTIVE_INVITES:
                    raise ManagedConflictError(
                        "revoke an active Safety invitation first"
                    )
                if int(invite_counts["recent_count"]) >= SAFETY_MAX_INVITES_PER_DAY:
                    retry_at = invite_counts["recent_oldest"] + timedelta(days=1)
                    raise ManagedRateLimitError(
                        "Safety invitation limit has been reached",
                        retry_after_seconds=max(
                            1,
                            math.ceil((retry_at - now).total_seconds()),
                        ),
                    )
                conflict = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_safety_invite_quota_events
                        WHERE capability_hash = $1
                    )
                    """,
                    capability_hash,
                )
                if conflict:
                    raise ManagedConflictError(
                        "Safety invitation capability was already used"
                    )
                invite_id = uuid4()
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_safety_invites (
                        invite_id,
                        owner_profile_id,
                        creation_request_id,
                        capability_hash,
                        status,
                        created_at,
                        expires_at,
                        purge_after
                    ) VALUES (
                        $1, $2, $3, $4, 'active', $5,
                        $5::timestamptz + $6::int * interval '1 hour',
                        $5::timestamptz + $6::int * interval '1 hour'
                            + interval '30 days'
                    )
                    RETURNING *
                    """,
                    invite_id,
                    owner["profile_id"],
                    request.request_id,
                    capability_hash,
                    now,
                    request.expires_in_hours,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_safety_invite_quota_events (
                        owner_account_id,
                        client_request_id,
                        invite_id,
                        capability_hash,
                        created_at,
                        purge_after
                    ) VALUES ($1, $2, $3, $4, $5, $6)
                    """,
                    owner["account_id"],
                    request.request_id,
                    invite_id,
                    capability_hash,
                    now,
                    row["purge_after"],
                )
        return {
            "invite_id": str(row["invite_id"]),
            "capability": capability,
            "status": str(row["status"]),
            "created_at": row["created_at"],
            "expires_at": row["expires_at"],
            "duplicate": False,
        }

    async def revoke_invite(
        self,
        *,
        principal: ManagedPrincipal,
        invite_id: UUID,
    ) -> None:
        self._require_active(principal)
        now = await self._pool().fetchval("SELECT clock_timestamp()")
        await self._pool().execute(
            """
            UPDATE managed_safety_invites invite
            SET status = 'revoked', revoked_at = $3
            FROM managed_social_profiles owner
            WHERE invite.invite_id = $1
              AND invite.owner_profile_id = owner.profile_id
              AND owner.account_id = $2
              AND invite.status = 'active'
            """,
            invite_id,
            principal.account_id,
            now,
        )
        # DELETE semantics are intentionally idempotent. A lost response,
        # expiry, redemption, prior revocation, or bounded purge must not leave
        # a client retaining an invitation that can no longer be used.

    async def _create_request(
        self,
        connection: Any,
        *,
        owner_profile_id: UUID,
        contact_profile_id: UUID,
        client_request_id: UUID,
        source: str,
        invite_id: UUID | None,
    ) -> dict[str, Any]:
        if owner_profile_id == contact_profile_id:
            raise ManagedConflictError("a profile cannot be its own Safety contact")
        await self._lock_pair(
            connection,
            owner_profile_id=owner_profile_id,
            contact_profile_id=contact_profile_id,
        )
        profiles = await self._lock_active_profiles_and_accounts(
            connection,
            profile_ids=[owner_profile_id, contact_profile_id],
        )
        if len(profiles) != 2:
            raise ManagedNotFoundError("NOOP profile was not found")
        now = await connection.fetchval("SELECT clock_timestamp()")
        await connection.execute(
            """
            UPDATE managed_safety_requests
            SET status = 'expired', decided_at = $3
            WHERE owner_profile_id = $1
              AND contact_profile_id = $2
              AND status = 'pending'
              AND expires_at <= $3
            """,
            owner_profile_id,
            contact_profile_id,
            now,
        )
        profiles_by_id = {row["profile_id"]: row for row in profiles}
        names = {
            profile_id: str(row["display_name"])
            for profile_id, row in profiles_by_id.items()
        }
        owner_account_id = profiles_by_id[owner_profile_id]["account_id"]
        contact_account_id = profiles_by_id[contact_profile_id]["account_id"]
        replay = await connection.fetchrow(
            """
            SELECT quota.safety_request_id AS quota_request_id,
                   quota.contact_account_id AS quota_contact_account_id,
                   quota.source AS quota_source,
                   request.*,
                   contact.display_name AS other_display_name
            FROM managed_safety_request_quota_events quota
            LEFT JOIN managed_safety_requests request
              ON request.request_id = quota.safety_request_id
            LEFT JOIN managed_social_profiles contact
              ON contact.profile_id = request.contact_profile_id
            WHERE quota.owner_account_id = $1
              AND quota.client_request_id = $2
            FOR UPDATE OF quota
            """,
            owner_account_id,
            client_request_id,
        )
        if replay is not None:
            if (
                replay["quota_contact_account_id"] != contact_account_id
                or replay["quota_source"] != source
            ):
                raise ManagedConflictError("Safety contact request id was reused")
            if (
                replay["request_id"] is None
                or replay["owner_profile_id"] != owner_profile_id
                or replay["contact_profile_id"] != contact_profile_id
                or replay["other_display_name"] is None
            ):
                raise ManagedConflictError(
                    "Safety contact request id was already consumed"
                )
            result = self._public_request(replay, owner_profile_id)
            result["duplicate"] = True
            return result
        quota = await connection.fetchrow(
            """
            SELECT count(*) AS recent_count,
                   min(created_at) AS recent_oldest
            FROM managed_safety_request_quota_events
            WHERE owner_account_id = $1
              AND created_at > $2::timestamptz - interval '24 hours'
            """,
            owner_account_id,
            now,
        )
        if int(quota["recent_count"]) >= SAFETY_MAX_REQUESTS_PER_DAY:
            retry_at = quota["recent_oldest"] + timedelta(days=1)
            raise ManagedRateLimitError(
                "Safety contact request limit has been reached",
                retry_after_seconds=max(
                    1,
                    math.ceil((retry_at - now).total_seconds()),
                ),
            )
        blocked = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_social_blocks
                WHERE (
                    blocker_profile_id = $1
                    AND blocked_profile_id = $2
                ) OR (
                    blocker_profile_id = $2
                    AND blocked_profile_id = $1
                )
            )
            """,
            owner_profile_id,
            contact_profile_id,
        )
        if blocked:
            raise ManagedNotFoundError("NOOP profile was not found")
        existing = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_safety_contacts
                WHERE owner_profile_id = $1
                  AND contact_profile_id = $2
            )
            """,
            owner_profile_id,
            contact_profile_id,
        )
        if existing:
            raise ManagedConflictError("profile is already a Safety contact")
        pending = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_safety_requests
                WHERE owner_profile_id = $1
                  AND contact_profile_id = $2
                  AND status = 'pending'
                  AND expires_at > $3
            )
            """,
            owner_profile_id,
            contact_profile_id,
            now,
        )
        if pending:
            raise ManagedConflictError("a Safety contact request is already pending")
        counts = await connection.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_safety_contacts
                    WHERE owner_profile_id = $1
                ) AS accepted,
                (
                    SELECT count(*)
                    FROM managed_safety_requests
                    WHERE owner_profile_id = $1
                      AND status = 'pending'
                      AND expires_at > $2
                ) AS pending,
                (
                    SELECT count(*)
                    FROM managed_safety_requests
                    WHERE contact_profile_id = $3
                      AND status = 'pending'
                      AND expires_at > $2
                ) AS pending_received
            """,
            owner_profile_id,
            now,
            contact_profile_id,
        )
        # _lock_active_profiles_and_accounts holds the contact profile row through
        # this count and insert, serializing distinct senders at the receiver cap.
        if int(counts["accepted"]) >= SAFETY_MAX_CONTACTS:
            raise ManagedConflictError("Safety contact limit has been reached")
        if int(counts["pending"]) >= SAFETY_MAX_PENDING_REQUESTS:
            raise ManagedConflictError("too many Safety contact requests are pending")
        if int(counts["pending_received"]) >= SAFETY_MAX_RECEIVED_PENDING_REQUESTS:
            raise ManagedConflictError(
                "Safety contact is not accepting more requests right now"
            )
        row = await connection.fetchrow(
            """
            INSERT INTO managed_safety_requests (
                request_id,
                client_request_id,
                owner_profile_id,
                contact_profile_id,
                invite_id,
                source,
                status,
                created_at,
                expires_at,
                purge_after
            ) VALUES (
                $1, $2, $3, $4, $5, $6, 'pending', $7,
                $7::timestamptz + interval '30 days',
                $7::timestamptz + interval '60 days'
            )
            RETURNING *, $8::text AS other_display_name
            """,
            uuid4(),
            client_request_id,
            owner_profile_id,
            contact_profile_id,
            invite_id,
            source,
            now,
            names[contact_profile_id],
        )
        await connection.execute(
            """
            INSERT INTO managed_safety_request_quota_events (
                owner_account_id,
                client_request_id,
                safety_request_id,
                contact_account_id,
                source,
                created_at,
                purge_after
            ) VALUES ($1, $2, $3, $4, $5, $6, $7)
            """,
            owner_account_id,
            client_request_id,
            row["request_id"],
            contact_account_id,
            source,
            now,
            row["purge_after"],
        )
        result = self._public_request(row, owner_profile_id)
        result["duplicate"] = False
        return result

    async def create_request(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSafetyRequestCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                contact = await connection.fetchrow(
                    """
                    SELECT profile.profile_id
                    FROM managed_social_aliases alias
                    JOIN managed_social_profiles profile USING (profile_id)
                    JOIN managed_accounts account
                      ON account.account_id = profile.account_id
                     AND account.status = 'active'
                    WHERE alias.alias_value = $1
                      AND alias.status = 'active'
                      AND profile.status = 'active'
                    """,
                    request.noop_id,
                )
                if contact is None:
                    raise ManagedNotFoundError("NOOP ID was not found")
                return await self._create_request(
                    connection,
                    owner_profile_id=owner["profile_id"],
                    contact_profile_id=contact["profile_id"],
                    client_request_id=request.request_id,
                    source="noop_id",
                    invite_id=None,
                )

    async def redeem_invite(
        self,
        *,
        principal: ManagedPrincipal,
        request_id: UUID,
        capability: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        capability_hash = hashlib.sha256(capability.encode("ascii")).hexdigest()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                contact = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                invite_snapshot = await connection.fetchrow(
                    """
                    SELECT invite_id,
                           owner_profile_id,
                           status,
                           expires_at,
                           redeemed_by_profile_id,
                           safety_request_id
                    FROM managed_safety_invites
                    WHERE capability_hash = $1
                    """,
                    capability_hash,
                )
                if invite_snapshot is None:
                    raise ManagedNotFoundError("Safety invitation was not found")
                is_duplicate_snapshot = (
                    invite_snapshot["status"] == "redeemed"
                    and invite_snapshot["redeemed_by_profile_id"]
                    == contact["profile_id"]
                    and invite_snapshot["safety_request_id"] is not None
                )
                if not is_duplicate_snapshot and (
                    invite_snapshot["status"] != "active"
                    or invite_snapshot["expires_at"] <= now
                ):
                    raise ManagedNotFoundError("Safety invitation was not found")
                await self._lock_pair(
                    connection,
                    owner_profile_id=invite_snapshot["owner_profile_id"],
                    contact_profile_id=contact["profile_id"],
                )
                profiles = await self._lock_active_profiles_and_accounts(
                    connection,
                    profile_ids=[
                        invite_snapshot["owner_profile_id"],
                        contact["profile_id"],
                    ],
                )
                if len(profiles) != 2:
                    raise ManagedNotFoundError("Safety invitation was not found")
                now = await connection.fetchval("SELECT clock_timestamp()")
                invite = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_invites
                    WHERE invite_id = $1
                      AND capability_hash = $2
                    FOR UPDATE
                    """,
                    invite_snapshot["invite_id"],
                    capability_hash,
                )
                if (
                    invite is None
                    or invite["owner_profile_id"] != invite_snapshot["owner_profile_id"]
                ):
                    raise ManagedNotFoundError("Safety invitation was not found")
                if (
                    invite["status"] == "redeemed"
                    and invite["redeemed_by_profile_id"] == contact["profile_id"]
                    and invite["safety_request_id"] is not None
                ):
                    row = await connection.fetchrow(
                        """
                        SELECT request.*, owner.display_name
                            AS other_display_name
                        FROM managed_safety_requests request
                        JOIN managed_social_profiles owner
                          ON owner.profile_id = request.owner_profile_id
                        WHERE request.request_id = $1
                        """,
                        invite["safety_request_id"],
                    )
                    result = self._public_request(
                        row,
                        contact["profile_id"],
                    )
                    result["duplicate"] = True
                    return result
                if invite["status"] != "active" or invite["expires_at"] <= now:
                    raise ManagedNotFoundError("Safety invitation was not found")
                result = await self._create_request(
                    connection,
                    owner_profile_id=invite["owner_profile_id"],
                    contact_profile_id=contact["profile_id"],
                    client_request_id=request_id,
                    source="invite",
                    invite_id=invite["invite_id"],
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_invites
                    SET status = 'redeemed',
                        redeemed_at = $2,
                        redeemed_by_profile_id = $3,
                        safety_request_id = $4
                    WHERE invite_id = $1
                    """,
                    invite["invite_id"],
                    now,
                    contact["profile_id"],
                    UUID(result["request_id"]),
                )
                return result

    async def list_requests(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                rows = await connection.fetch(
                    """
                    SELECT request.*,
                           other.display_name AS other_display_name
                    FROM managed_safety_requests request
                    JOIN managed_social_profiles other
                      ON other.profile_id = CASE
                          WHEN request.owner_profile_id = $1
                          THEN request.contact_profile_id
                          ELSE request.owner_profile_id
                      END
                    WHERE (
                            request.owner_profile_id = $1
                            OR request.contact_profile_id = $1
                          )
                      AND request.status = 'pending'
                      AND request.expires_at > $2
                    ORDER BY request.created_at DESC, request.request_id
                    LIMIT $3
                    """,
                    profile["profile_id"],
                    now,
                    SAFETY_REQUEST_LIST_LIMIT,
                )
        return [self._public_request(row, profile["profile_id"]) for row in rows]

    async def decide_request(
        self,
        *,
        principal: ManagedPrincipal,
        request_id: UUID,
        decision: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        target_status = "accepted" if decision == "accept" else "declined"
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                contact = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                request_snapshot = await connection.fetchrow(
                    """
                    SELECT owner_profile_id, contact_profile_id
                    FROM managed_safety_requests
                    WHERE request_id = $1
                      AND contact_profile_id = $2
                    """,
                    request_id,
                    contact["profile_id"],
                )
                if request_snapshot is None:
                    raise ManagedNotFoundError("Safety contact request was not found")
                await self._lock_pair(
                    connection,
                    owner_profile_id=request_snapshot["owner_profile_id"],
                    contact_profile_id=request_snapshot["contact_profile_id"],
                )
                if decision == "accept":
                    profiles = await self._lock_active_profiles_and_accounts(
                        connection,
                        profile_ids=[
                            request_snapshot["owner_profile_id"],
                            request_snapshot["contact_profile_id"],
                        ],
                    )
                    if len(profiles) != 2:
                        raise ManagedConflictError(
                            "Safety contact request can no longer be accepted"
                        )
                now = await connection.fetchval("SELECT clock_timestamp()")
                request = await connection.fetchrow(
                    """
                    SELECT request.*, owner.display_name AS other_display_name
                    FROM managed_safety_requests request
                    JOIN managed_social_profiles owner
                      ON owner.profile_id = request.owner_profile_id
                    WHERE request.request_id = $1
                      AND request.contact_profile_id = $2
                    FOR UPDATE OF request
                    """,
                    request_id,
                    contact["profile_id"],
                )
                if request is None:
                    raise ManagedNotFoundError("Safety contact request was not found")
                if request["status"] != "pending":
                    if request["status"] != target_status:
                        raise ManagedConflictError(
                            "Safety contact request was already decided differently"
                        )
                    result = self._public_request(
                        request,
                        contact["profile_id"],
                    )
                    result["duplicate"] = True
                    return result
                if request["expires_at"] <= now:
                    raise ManagedConflictError("Safety contact request has expired")
                if decision == "accept":
                    blocked = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM managed_social_blocks
                            WHERE (
                                blocker_profile_id = $1
                                AND blocked_profile_id = $2
                            ) OR (
                                blocker_profile_id = $2
                                AND blocked_profile_id = $1
                            )
                        )
                        """,
                        request["owner_profile_id"],
                        request["contact_profile_id"],
                    )
                    if blocked:
                        raise ManagedConflictError(
                            "Safety contact request can no longer be accepted"
                        )
                    counts = await connection.fetchrow(
                        """
                        SELECT
                            (
                                SELECT count(*)
                                FROM managed_safety_contacts
                                WHERE owner_profile_id = $1
                            ) AS owner_count,
                            (
                                SELECT count(*)
                                FROM managed_safety_contacts
                                WHERE contact_profile_id = $2
                            ) AS contact_count
                        """,
                        request["owner_profile_id"],
                        request["contact_profile_id"],
                    )
                    if int(counts["owner_count"]) >= SAFETY_MAX_CONTACTS:
                        raise ManagedConflictError(
                            "Safety contact limit has been reached"
                        )
                    if int(counts["contact_count"]) >= SAFETY_MAX_OWNERS_PER_CONTACT:
                        raise ManagedConflictError(
                            "this profile cannot accept more Safety roles"
                        )
                    await connection.execute(
                        """
                        INSERT INTO managed_safety_contacts (
                            owner_profile_id,
                            contact_profile_id,
                            accepted_request_id,
                            created_at
                        ) VALUES ($1, $2, $3, $4)
                        ON CONFLICT (owner_profile_id, contact_profile_id)
                        DO NOTHING
                        """,
                        request["owner_profile_id"],
                        request["contact_profile_id"],
                        request_id,
                        now,
                    )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_safety_requests
                    SET status = $2, decided_at = $3
                    WHERE request_id = $1
                    RETURNING *, $4::text AS other_display_name
                    """,
                    request_id,
                    target_status,
                    now,
                    request["other_display_name"],
                )
        result = self._public_request(row, contact["profile_id"])
        result["duplicate"] = False
        return result

    async def contact_snapshot(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> tuple[list[dict[str, Any]], int]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                rows = await connection.fetch(
                    """
                    SELECT contact.owner_profile_id,
                           contact.contact_profile_id,
                           contact.created_at,
                           other.profile_id AS other_profile_id,
                           other.display_name,
                           (
                               contact.owner_profile_id = $1
                               AND NOT EXISTS (
                                   SELECT 1
                                   FROM managed_social_blocks block
                                   WHERE (
                                       block.blocker_profile_id = $1
                                       AND block.blocked_profile_id =
                                           contact.contact_profile_id
                                   ) OR (
                                       block.blocker_profile_id =
                                           contact.contact_profile_id
                                       AND block.blocked_profile_id = $1
                                   )
                               )
                               AND EXISTS (
                                   SELECT 1
                                   FROM managed_push_installations push
                                   JOIN managed_account_installations installation
                                     ON installation.account_id = push.account_id
                                    AND installation.installation_id =
                                        push.installation_id
                                    AND installation.status = 'active'
                                   WHERE push.account_id = other.account_id
                                     AND push.status = 'active'
                               )
                           ) AS delivery_capable
                    FROM managed_safety_contacts contact
                    JOIN managed_social_profiles other
                      ON other.profile_id = CASE
                          WHEN contact.owner_profile_id = $1
                          THEN contact.contact_profile_id
                          ELSE contact.owner_profile_id
                      END
                     AND other.status = 'active'
                    JOIN managed_accounts other_account
                      ON other_account.account_id = other.account_id
                     AND other_account.status = 'active'
                    WHERE contact.owner_profile_id = $1
                       OR contact.contact_profile_id = $1
                    ORDER BY other.display_name, other.profile_id
                    """,
                    profile["profile_id"],
                )
        contacts = [
            {
                "profile_id": str(row["other_profile_id"]),
                "display_name": str(row["display_name"]),
                "role": (
                    "contact"
                    if row["owner_profile_id"] == profile["profile_id"]
                    else "owner"
                ),
                "accepted_at": row["created_at"],
            }
            for row in rows
        ]
        return contacts, sum(1 for row in rows if bool(row["delivery_capable"]))

    async def list_contacts(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        contacts, _ = await self.contact_snapshot(principal=principal)
        return contacts

    async def remove_contact(
        self,
        *,
        principal: ManagedPrincipal,
        other_profile_id: UUID,
    ) -> None:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                directed_pairs = sorted(
                    (
                        (profile["profile_id"], other_profile_id),
                        (other_profile_id, profile["profile_id"]),
                    ),
                    key=lambda pair: (str(pair[0]), str(pair[1])),
                )
                for owner_profile_id, contact_profile_id in directed_pairs:
                    await self._lock_pair(
                        connection,
                        owner_profile_id=owner_profile_id,
                        contact_profile_id=contact_profile_id,
                    )
                await self._lock_profiles_and_accounts(
                    connection,
                    profile_ids=(profile["profile_id"], other_profile_id),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                active_incident_ids = (
                    await _lock_active_managed_safety_incidents_for_profile_pair(
                        connection,
                        first_profile_id=profile["profile_id"],
                        second_profile_id=other_profile_id,
                    )
                )
                await connection.fetch(
                    """
                    SELECT owner_profile_id, contact_profile_id
                    FROM managed_safety_contacts
                    WHERE (
                        owner_profile_id = $1
                        AND contact_profile_id = $2
                    ) OR (
                        owner_profile_id = $2
                        AND contact_profile_id = $1
                    )
                    ORDER BY owner_profile_id, contact_profile_id
                    FOR UPDATE
                    """,
                    profile["profile_id"],
                    other_profile_id,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_requests
                    SET status = 'canceled', decided_at = $3
                    WHERE status = 'pending'
                      AND (
                          (
                            owner_profile_id = $1
                            AND contact_profile_id = $2
                          ) OR (
                            owner_profile_id = $2
                            AND contact_profile_id = $1
                          )
                      )
                    """,
                    profile["profile_id"],
                    other_profile_id,
                    now,
                )
                await connection.execute(
                    """
                    DELETE FROM managed_safety_contacts
                    WHERE (
                        owner_profile_id = $1
                        AND contact_profile_id = $2
                    ) OR (
                        owner_profile_id = $2
                        AND contact_profile_id = $1
                    )
                    """,
                    profile["profile_id"],
                    other_profile_id,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_participants participant
                    SET status = 'revoked', responded_at = $3
                    FROM managed_safety_incidents incident
                    WHERE participant.incident_id = incident.incident_id
                      AND incident.status IN ('open', 'acknowledged')
                      AND (
                          (
                            incident.owner_profile_id = $1
                            AND participant.contact_profile_id = $2
                          ) OR (
                            incident.owner_profile_id = $2
                            AND participant.contact_profile_id = $1
                          )
                      )
                      AND participant.status <> 'revoked'
                    """,
                    profile["profile_id"],
                    other_profile_id,
                    now,
                )
                await _reconcile_managed_safety_incident_acknowledgement(
                    connection,
                    incident_ids=active_incident_ids,
                    now=now,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries delivery
                    SET status = 'rejected',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $3
                    FROM managed_safety_incidents incident
                    WHERE delivery.incident_id = incident.incident_id
                      AND incident.status IN ('open', 'acknowledged')
                      AND (
                          (
                            incident.owner_profile_id = $1
                            AND delivery.contact_profile_id = $2
                          ) OR (
                            incident.owner_profile_id = $2
                            AND delivery.contact_profile_id = $1
                          )
                      )
                      AND delivery.status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    profile["profile_id"],
                    other_profile_id,
                    now,
                )

    async def create_incident(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSafetyIncidentCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-safety-incident:{owner['account_id']}",
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                replay = await connection.fetchrow(
                    """
                    SELECT quota.*,
                           incident.owner_profile_id AS incident_owner_profile_id
                    FROM managed_safety_page_quota_events quota
                    LEFT JOIN managed_safety_incidents incident
                      ON incident.incident_id = quota.incident_id
                    WHERE quota.owner_account_id = $1
                      AND quota.client_request_id = $2
                    FOR UPDATE OF quota
                    """,
                    owner["account_id"],
                    request.request_id,
                )
                if replay is not None:
                    if (
                        replay["trigger"] != request.trigger
                        or int(replay["duration_hours"]) != request.duration_hours
                        or bool(replay["share_location"]) != request.share_location
                    ):
                        raise ManagedConflictError(
                            "Safety incident request id was reused"
                        )
                    if replay["incident_owner_profile_id"] != owner["profile_id"]:
                        raise ManagedConflictError(
                            "Safety incident request id was already consumed"
                        )
                    result = await self._incident_detail(
                        connection,
                        caller_profile_id=owner["profile_id"],
                        incident_id=replay["incident_id"],
                        now=now,
                    )
                    result["duplicate"] = True
                    return result
                contact_snapshot = await connection.fetch(
                    """
                    SELECT contact.contact_profile_id
                    FROM managed_safety_contacts contact
                    JOIN managed_social_profiles profile
                      ON profile.profile_id = contact.contact_profile_id
                     AND profile.status = 'active'
                    JOIN managed_accounts account
                      ON account.account_id = profile.account_id
                     AND account.status = 'active'
                    WHERE contact.owner_profile_id = $1
                      AND NOT EXISTS (
                          SELECT 1
                          FROM managed_social_blocks block
                          WHERE (
                              block.blocker_profile_id = $1
                              AND block.blocked_profile_id =
                                    contact.contact_profile_id
                          ) OR (
                              block.blocker_profile_id =
                                    contact.contact_profile_id
                              AND block.blocked_profile_id = $1
                          )
                      )
                    ORDER BY contact.created_at, contact.contact_profile_id
                    """,
                    owner["profile_id"],
                )
                contact_snapshot_ids = [
                    row["contact_profile_id"] for row in contact_snapshot
                ]
                locked_profiles = await self._lock_active_profiles_and_accounts(
                    connection,
                    profile_ids=(owner["profile_id"], *contact_snapshot_ids),
                )
                locked_profile_ids = {row["profile_id"] for row in locked_profiles}
                if owner["profile_id"] not in locked_profile_ids:
                    raise ManagedNotFoundError(
                        "create a NOOP profile before configuring Safety contacts"
                    )
                locked_owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                if locked_owner["profile_id"] != owner["profile_id"]:
                    raise ManagedConflictError(
                        "Safety profile changed while paging contacts"
                    )
                owner = locked_owner
                now = await connection.fetchval("SELECT clock_timestamp()")
                await self._expire_incidents(
                    connection,
                    now=now,
                    owner_profile_id=owner["profile_id"],
                )
                active = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_safety_incidents
                        WHERE owner_profile_id = $1
                          AND status IN ('open', 'acknowledged')
                    )
                    """,
                    owner["profile_id"],
                )
                if active:
                    raise ManagedConflictError("a Safety incident is already active")
                limits = await connection.fetchrow(
                    """
                    SELECT
                        count(*) FILTER (
                            WHERE created_at > $2::timestamptz - interval '1 hour'
                        ) AS hourly_count,
                        min(created_at) FILTER (
                            WHERE created_at > $2::timestamptz - interval '1 hour'
                        ) AS hourly_oldest,
                        count(*) AS daily_count,
                        min(created_at) AS daily_oldest
                    FROM managed_safety_page_quota_events
                    WHERE owner_account_id = $1
                      AND created_at > $2::timestamptz - interval '24 hours'
                    """,
                    owner["account_id"],
                    now,
                )
                retry_windows: list[datetime] = []
                if int(limits["hourly_count"]) >= SAFETY_MAX_INCIDENTS_PER_HOUR:
                    retry_windows.append(limits["hourly_oldest"] + timedelta(hours=1))
                daily_limited = (
                    int(limits["daily_count"]) >= SAFETY_MAX_INCIDENTS_PER_DAY
                )
                if daily_limited:
                    retry_windows.append(limits["daily_oldest"] + timedelta(days=1))
                if retry_windows:
                    retry_at = max(retry_windows)
                    raise ManagedRateLimitError(
                        (
                            "daily Safety paging limit reached"
                            if daily_limited
                            else "Safety paging limit reached; wait before paging again"
                        ),
                        retry_after_seconds=math.ceil((retry_at - now).total_seconds()),
                    )
                contact_candidates = await connection.fetch(
                    """
                    SELECT contact.contact_profile_id, profile.account_id
                    FROM managed_safety_contacts contact
                    JOIN managed_social_profiles profile
                      ON profile.profile_id = contact.contact_profile_id
                     AND profile.status = 'active'
                    JOIN managed_accounts account
                      ON account.account_id = profile.account_id
                     AND account.status = 'active'
                    WHERE contact.owner_profile_id = $1
                      AND contact.contact_profile_id = ANY($2::uuid[])
                      AND NOT EXISTS (
                          SELECT 1
                          FROM managed_social_blocks block
                          WHERE (
                              block.blocker_profile_id = $1
                              AND block.blocked_profile_id =
                                    contact.contact_profile_id
                          ) OR (
                              block.blocker_profile_id =
                                    contact.contact_profile_id
                              AND block.blocked_profile_id = $1
                          )
                      )
                    ORDER BY contact.created_at, contact.contact_profile_id
                    FOR UPDATE OF contact
                    """,
                    owner["profile_id"],
                    contact_snapshot_ids,
                )
                active_push_accounts = {
                    row["account_id"]
                    for row in await connection.fetch(
                        """
                        SELECT push.account_id, push.installation_id
                        FROM managed_push_installations push
                        JOIN managed_account_installations installation
                          ON installation.account_id = push.account_id
                         AND installation.installation_id =
                             push.installation_id
                         AND installation.status = 'active'
                        WHERE push.account_id = ANY($1::uuid[])
                          AND push.status = 'active'
                        ORDER BY push.account_id, push.installation_id
                        FOR UPDATE OF push, installation
                        """,
                        [row["account_id"] for row in contact_candidates],
                    )
                }
                contacts = [
                    row
                    for row in contact_candidates
                    if row["account_id"] in active_push_accounts
                ]
                if len(contacts) < SAFETY_MIN_CONTACTS:
                    raise ManagedConflictError(
                        "at least two accepted Safety contacts are required"
                    )
                incident_id = uuid4()
                expires_at = now + timedelta(hours=request.duration_hours)
                await connection.execute(
                    """
                    INSERT INTO managed_safety_incidents (
                        incident_id,
                        owner_profile_id,
                        client_request_id,
                        trigger,
                        status,
                        duration_hours,
                        share_location,
                        created_at,
                        expires_at,
                        purge_after
                    ) VALUES (
                        $1, $2, $3, $4, 'open', $5, $6,
                        $7, $8, $8::timestamptz + interval '30 days'
                    )
                    """,
                    incident_id,
                    owner["profile_id"],
                    request.request_id,
                    request.trigger,
                    request.duration_hours,
                    request.share_location,
                    now,
                    expires_at,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_safety_page_quota_events (
                        owner_account_id,
                        client_request_id,
                        incident_id,
                        trigger,
                        duration_hours,
                        share_location,
                        created_at,
                        purge_after
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7,
                        $8::timestamptz + interval '30 days'
                    )
                    """,
                    owner["account_id"],
                    request.request_id,
                    incident_id,
                    request.trigger,
                    request.duration_hours,
                    request.share_location,
                    now,
                    expires_at,
                )
                contact_ids = [row["contact_profile_id"] for row in contacts]
                await connection.executemany(
                    """
                    INSERT INTO managed_safety_participants (
                        incident_id,
                        contact_profile_id,
                        status,
                        paged_at
                    ) VALUES ($1, $2, 'pending', $3)
                    """,
                    [
                        (incident_id, contact_profile_id, now)
                        for contact_profile_id in contact_ids
                    ],
                )
                await self._insert_current_push_deliveries(
                    connection,
                    incident_id=incident_id,
                    owner_profile_id=owner["profile_id"],
                    now=now,
                )
                result = await self._incident_detail(
                    connection,
                    caller_profile_id=owner["profile_id"],
                    incident_id=incident_id,
                    now=now,
                )
                result["duplicate"] = False
                return result

    @staticmethod
    async def _insert_current_push_deliveries(
        connection: Any,
        *,
        incident_id: UUID,
        owner_profile_id: UUID,
        now: datetime,
    ) -> None:
        await connection.execute(
            """
            INSERT INTO managed_safety_push_deliveries (
                delivery_id,
                incident_id,
                contact_profile_id,
                account_id,
                installation_id,
                status,
                attempts,
                created_at,
                updated_at
            )
            SELECT gen_random_uuid(),
                   $1,
                   participant.contact_profile_id,
                   profile.account_id,
                   push.installation_id,
                   'pending',
                   0,
                   $3,
                   $3
            FROM managed_safety_participants participant
            JOIN managed_safety_incidents incident
              ON incident.incident_id = participant.incident_id
            JOIN managed_social_profiles profile
              ON profile.profile_id = participant.contact_profile_id
             AND profile.status = 'active'
            JOIN managed_accounts account
              ON account.account_id = profile.account_id
             AND account.status = 'active'
            JOIN managed_push_installations push
              ON push.account_id = profile.account_id
             AND push.status = 'active'
            JOIN managed_account_installations installation
              ON installation.account_id = push.account_id
             AND installation.installation_id = push.installation_id
             AND installation.status = 'active'
            WHERE participant.incident_id = $1
              AND incident.owner_profile_id = $2
              AND participant.status = 'pending'
            ON CONFLICT (
                incident_id,
                contact_profile_id,
                installation_id
            ) DO NOTHING
            """,
            incident_id,
            owner_profile_id,
            now,
        )

    async def _incident_detail(
        self,
        connection: Any,
        *,
        caller_profile_id: UUID,
        incident_id: UUID,
        now: datetime,
    ) -> dict[str, Any]:
        incident = await connection.fetchrow(
            """
            SELECT incident.*, owner.display_name AS owner_display_name,
                   (incident.owner_profile_id = $2) AS caller_is_owner
            FROM managed_safety_incidents incident
            JOIN managed_social_profiles owner
              ON owner.profile_id = incident.owner_profile_id
            WHERE incident.incident_id = $1
              AND (
                    incident.owner_profile_id = $2
                    OR EXISTS (
                        SELECT 1
                        FROM managed_safety_participants participant
                        WHERE participant.incident_id = incident.incident_id
                          AND participant.contact_profile_id = $2
                          AND participant.status <> 'revoked'
                    )
                  )
            """,
            incident_id,
            caller_profile_id,
        )
        if incident is None:
            raise ManagedNotFoundError("Safety incident was not found")
        caller_is_owner = bool(incident["caller_is_owner"])
        participants = await connection.fetch(
            """
            SELECT participant.contact_profile_id,
                   participant.status,
                   participant.paged_at,
                   participant.responded_at,
                   profile.display_name,
                   count(delivery.delivery_id) AS installation_count,
                   count(delivery.delivery_id) FILTER (
                       WHERE delivery.status = 'sent'
                   ) AS sent_count,
                   count(delivery.delivery_id) FILTER (
                       WHERE delivery.status IN (
                           'pending',
                           'transient_failure',
                           'unavailable'
                       )
                         AND delivery.attempts < 3
                   ) AS retryable_count,
                   count(delivery.delivery_id) FILTER (
                       WHERE delivery.status IN ('invalid', 'rejected')
                   ) AS terminal_count
            FROM managed_safety_participants participant
            JOIN managed_social_profiles profile
              ON profile.profile_id = participant.contact_profile_id
            LEFT JOIN managed_safety_push_deliveries delivery
              ON delivery.incident_id = participant.incident_id
             AND delivery.contact_profile_id =
                    participant.contact_profile_id
            WHERE participant.incident_id = $1
              AND (
                    $3::boolean
                    OR participant.contact_profile_id = $2
                  )
            GROUP BY participant.contact_profile_id,
                     participant.status,
                     participant.paged_at,
                     participant.responded_at,
                     profile.display_name
            ORDER BY profile.display_name, participant.contact_profile_id
            """,
            incident_id,
            caller_profile_id,
            caller_is_owner,
        )
        location = None
        if (
            incident["status"] in {"open", "acknowledged"}
            and incident["expires_at"] > now
            and bool(incident["share_location"])
        ):
            row = await connection.fetchrow(
                """
                SELECT sequence,
                       latitude,
                       longitude,
                       horizontal_accuracy_m,
                       captured_at,
                       received_at
                FROM managed_safety_locations
                WHERE incident_id = $1
                """,
                incident_id,
            )
            if row is not None:
                location = {
                    "sequence": int(row["sequence"]),
                    "latitude": float(row["latitude"]),
                    "longitude": float(row["longitude"]),
                    "horizontal_accuracy_m": float(row["horizontal_accuracy_m"]),
                    "captured_at": row["captured_at"],
                    "received_at": row["received_at"],
                }
        result: dict[str, Any] = {
            "incident_id": str(incident["incident_id"]),
            "role": "owner" if caller_is_owner else "contact",
            "owner_profile_id": str(incident["owner_profile_id"]),
            "owner_display_name": str(incident["owner_display_name"]),
            "trigger": str(incident["trigger"]),
            "status": str(incident["status"]),
            "duration_hours": int(incident["duration_hours"]),
            "share_location": bool(incident["share_location"]),
            "created_at": incident["created_at"],
            "expires_at": incident["expires_at"],
            "acknowledged_at": incident["acknowledged_at"],
            "ended_at": incident["ended_at"],
            "participants": [
                {
                    "profile_id": str(row["contact_profile_id"]),
                    "display_name": str(row["display_name"]),
                    "status": str(row["status"]),
                    "paged_at": row["paged_at"],
                    "responded_at": row["responded_at"],
                    "push": {
                        "configured": int(row["installation_count"]) > 0,
                        "reached": int(row["sent_count"]) > 0,
                    },
                }
                for row in participants
            ],
            "location": location,
        }
        if caller_is_owner:
            all_participants = participants
            result["delivery"] = {
                "contacts_targeted": len(all_participants),
                "contacts_reached": sum(
                    int(row["sent_count"]) > 0 for row in all_participants
                ),
                "installations_targeted": sum(
                    int(row["installation_count"]) for row in all_participants
                ),
                "installations_reached": sum(
                    int(row["sent_count"]) for row in all_participants
                ),
                "installations_retryable": sum(
                    int(row["retryable_count"]) for row in all_participants
                ),
                "installations_terminal": sum(
                    int(row["terminal_count"]) for row in all_participants
                ),
            }
        return result

    async def list_incidents(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                rows = await connection.fetch(
                    """
                    SELECT incident.incident_id
                    FROM managed_safety_incidents incident
                    WHERE incident.purge_after > $2
                      AND (
                            incident.owner_profile_id = $1
                            OR EXISTS (
                                SELECT 1
                                FROM managed_safety_participants participant
                                WHERE participant.incident_id =
                                        incident.incident_id
                                  AND participant.contact_profile_id = $1
                                  AND participant.status <> 'revoked'
                            )
                          )
                    ORDER BY
                        (incident.status IN ('open', 'acknowledged')) DESC,
                        incident.created_at DESC,
                        incident.incident_id
                    LIMIT 30
                    """,
                    profile["profile_id"],
                    now,
                )
                return [
                    await self._incident_detail(
                        connection,
                        caller_profile_id=profile["profile_id"],
                        incident_id=row["incident_id"],
                        now=now,
                    )
                    for row in rows
                ]

    async def get_incident(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                return await self._incident_detail(
                    connection,
                    caller_profile_id=profile["profile_id"],
                    incident_id=incident_id,
                    now=now,
                )

    async def update_location(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
        update: ManagedSafetyLocationUpdate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                incident = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_incidents
                    WHERE incident_id = $1
                      AND owner_profile_id = $2
                    FOR UPDATE
                    """,
                    incident_id,
                    owner["profile_id"],
                )
                if incident is None:
                    raise ManagedNotFoundError("Safety incident was not found")
                if (
                    incident["status"] not in {"open", "acknowledged"}
                    or incident["expires_at"] <= now
                ):
                    raise ManagedConflictError("Safety incident is no longer active")
                if not bool(incident["share_location"]):
                    raise ManagedConflictError(
                        "location sharing is off for this incident"
                    )
                if update.captured_at < incident["created_at"] - timedelta(
                    minutes=5
                ) or update.captured_at > now + timedelta(minutes=5):
                    raise ManagedConflictError(
                        "Safety location timestamp is outside the active window"
                    )
                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_locations
                    WHERE incident_id = $1
                    FOR UPDATE
                    """,
                    incident_id,
                )
                stored_sequence = 1
                if existing is not None:
                    same = (
                        float(existing["latitude"]) == update.latitude
                        and float(existing["longitude"]) == update.longitude
                        and float(existing["horizontal_accuracy_m"])
                        == update.horizontal_accuracy_m
                        and existing["captured_at"] == update.captured_at
                    )
                    if same:
                        return {
                            "sequence": int(existing["sequence"]),
                            "latitude": float(existing["latitude"]),
                            "longitude": float(existing["longitude"]),
                            "horizontal_accuracy_m": float(
                                existing["horizontal_accuracy_m"]
                            ),
                            "captured_at": existing["captured_at"],
                            "received_at": existing["received_at"],
                            "duplicate": True,
                        }
                    if update.captured_at <= existing["captured_at"]:
                        raise ManagedConflictError(
                            "Safety location is not newer than the current fix"
                        )
                    stored_sequence = int(existing["sequence"]) + 1
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_safety_locations (
                        incident_id,
                        sequence,
                        latitude,
                        longitude,
                        horizontal_accuracy_m,
                        captured_at,
                        received_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (incident_id)
                    DO UPDATE SET
                        sequence = EXCLUDED.sequence,
                        latitude = EXCLUDED.latitude,
                        longitude = EXCLUDED.longitude,
                        horizontal_accuracy_m =
                            EXCLUDED.horizontal_accuracy_m,
                        captured_at = EXCLUDED.captured_at,
                        received_at = EXCLUDED.received_at
                    RETURNING *
                    """,
                    incident_id,
                    stored_sequence,
                    update.latitude,
                    update.longitude,
                    update.horizontal_accuracy_m,
                    update.captured_at,
                    now,
                )
        return {
            "sequence": int(row["sequence"]),
            "latitude": float(row["latitude"]),
            "longitude": float(row["longitude"]),
            "horizontal_accuracy_m": float(row["horizontal_accuracy_m"]),
            "captured_at": row["captured_at"],
            "received_at": row["received_at"],
            "duplicate": False,
        }

    async def respond(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
        decision: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                contact = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                incident = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_incidents
                    WHERE incident_id = $1
                    FOR UPDATE
                    """,
                    incident_id,
                )
                if incident is None:
                    raise ManagedNotFoundError("Safety incident was not found")
                if (
                    incident["status"] not in {"open", "acknowledged"}
                    or incident["expires_at"] <= now
                ):
                    raise ManagedConflictError("Safety incident is no longer active")
                participant = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_participants
                    WHERE incident_id = $1
                      AND contact_profile_id = $2
                    FOR UPDATE
                    """,
                    incident_id,
                    contact["profile_id"],
                )
                if participant is None or participant["status"] == "revoked":
                    raise ManagedNotFoundError("Safety incident was not found")
                duplicate = participant["status"] == decision
                if not duplicate:
                    await connection.execute(
                        """
                        UPDATE managed_safety_participants
                        SET status = $3, responded_at = $4
                        WHERE incident_id = $1
                          AND contact_profile_id = $2
                        """,
                        incident_id,
                        contact["profile_id"],
                        decision,
                        now,
                    )
                await _reconcile_managed_safety_incident_acknowledgement(
                    connection,
                    incident_ids=(incident_id,),
                    now=now,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries
                    SET status = 'rejected',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $3
                    WHERE incident_id = $1
                      AND contact_profile_id = $2
                      AND status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    incident_id,
                    contact["profile_id"],
                    now,
                )
                result = await self._incident_detail(
                    connection,
                    caller_profile_id=contact["profile_id"],
                    incident_id=incident_id,
                    now=now,
                )
                result["duplicate"] = duplicate
                return result

    async def end_incident(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
        outcome: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                incident = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_incidents
                    WHERE incident_id = $1
                      AND owner_profile_id = $2
                    FOR UPDATE
                    """,
                    incident_id,
                    owner["profile_id"],
                )
                if incident is None:
                    raise ManagedNotFoundError("Safety incident was not found")
                if incident["status"] in {"resolved", "canceled"}:
                    if incident["status"] != outcome:
                        raise ManagedConflictError(
                            "Safety incident already ended differently"
                        )
                    duplicate = True
                elif incident["status"] == "expired":
                    raise ManagedConflictError("Safety incident has already expired")
                else:
                    duplicate = False
                    await connection.execute(
                        """
                        UPDATE managed_safety_incidents
                        SET status = $2, ended_at = $3
                        WHERE incident_id = $1
                        """,
                        incident_id,
                        outcome,
                        now,
                    )
                    await connection.execute(
                        """
                        DELETE FROM managed_safety_locations
                        WHERE incident_id = $1
                        """,
                        incident_id,
                    )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries
                    SET status = 'rejected',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $2
                    WHERE incident_id = $1
                      AND status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    incident_id,
                    now,
                )
                result = await self._incident_detail(
                    connection,
                    caller_profile_id=owner["profile_id"],
                    incident_id=incident_id,
                    now=now,
                )
                result["duplicate"] = duplicate
                return result

    async def claim_push_deliveries(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
        limit: int = 20,
        exclude_delivery_ids: Collection[UUID] = (),
        claim_seconds: int = SAFETY_PUSH_MIN_CLAIM_SECONDS,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        if not 1 <= limit <= 20:
            raise ValueError("push delivery claim limit must be 1 through 20")
        if not SAFETY_PUSH_MIN_CLAIM_SECONDS <= claim_seconds <= 15 * 60:
            raise ValueError("push claim duration is outside the supported bound")
        await self._expire_before_profile_operation()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                owner = await self._profile(
                    connection,
                    account_id=principal.account_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                incident = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_incidents
                    WHERE incident_id = $1
                      AND owner_profile_id = $2
                    FOR UPDATE
                    """,
                    incident_id,
                    owner["profile_id"],
                )
                if incident is None:
                    raise ManagedNotFoundError("Safety incident was not found")
                if (
                    incident["status"] not in {"open", "acknowledged"}
                    or incident["expires_at"] <= now
                ):
                    return []
                await self._insert_current_push_deliveries(
                    connection,
                    incident_id=incident_id,
                    owner_profile_id=owner["profile_id"],
                    now=now,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries delivery
                    SET status = 'invalid',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $2
                    FROM managed_push_installations push
                    WHERE delivery.incident_id = $1
                      AND delivery.account_id = push.account_id
                      AND delivery.installation_id = push.installation_id
                      AND push.status <> 'active'
                      AND delivery.status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    incident_id,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries delivery
                    SET status = 'rejected',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $2
                    FROM managed_accounts account
                    WHERE delivery.incident_id = $1
                      AND delivery.account_id = account.account_id
                      AND account.status <> 'active'
                      AND delivery.status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    incident_id,
                    now,
                )
                candidates = await connection.fetch(
                    """
                    SELECT delivery.*,
                           push.platform,
                           push.target_kind,
                           push.token_hash,
                           push.token_ciphertext,
                           incident.expires_at
                    FROM managed_safety_push_deliveries delivery
                    JOIN managed_push_installations push
                      ON push.account_id = delivery.account_id
                     AND push.installation_id = delivery.installation_id
                     AND push.status = 'active'
                    JOIN managed_accounts account
                      ON account.account_id = delivery.account_id
                     AND account.status = 'active'
                    JOIN managed_safety_incidents incident
                      ON incident.incident_id = delivery.incident_id
                    JOIN managed_safety_participants participant
                      ON participant.incident_id = delivery.incident_id
                     AND participant.contact_profile_id =
                            delivery.contact_profile_id
                     AND participant.status = 'pending'
                    WHERE delivery.incident_id = $1
                      AND delivery.status IN (
                          'pending',
                          'transient_failure',
                          'unavailable'
                      )
                      AND delivery.attempts < 3
                      AND NOT (
                          delivery.delivery_id = ANY($3::uuid[])
                      )
                    ORDER BY delivery.attempts,
                             delivery.created_at,
                             delivery.delivery_id
                    FOR UPDATE OF delivery SKIP LOCKED
                    LIMIT $2
                    """,
                    incident_id,
                    limit,
                    list(exclude_delivery_ids),
                )
                return await self._claim_delivery_candidates(
                    connection,
                    candidates=candidates,
                    now=now,
                    claim_seconds=claim_seconds,
                )

    async def claim_due_push_deliveries(
        self,
        *,
        limit: int = 100,
        claim_seconds: int = SAFETY_PUSH_MIN_CLAIM_SECONDS,
    ) -> list[dict[str, Any]]:
        if not 1 <= limit <= 200:
            raise ValueError("push retry claim limit must be 1 through 200")
        if not SAFETY_PUSH_MIN_CLAIM_SECONDS <= claim_seconds <= 15 * 60:
            raise ValueError("push claim duration is outside the supported bound")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                await self._expire(connection, now)
                retry_before = now - timedelta(seconds=SAFETY_PUSH_RETRY_DELAY_SECONDS)
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries delivery
                    SET status = 'invalid',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $1
                    FROM managed_push_installations push
                    WHERE delivery.account_id = push.account_id
                      AND delivery.installation_id = push.installation_id
                      AND push.status <> 'active'
                      AND delivery.status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries delivery
                    SET status = 'rejected',
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        updated_at = $1
                    FROM managed_accounts account
                    WHERE delivery.account_id = account.account_id
                      AND account.status <> 'active'
                      AND delivery.status IN (
                          'pending',
                          'sending',
                          'transient_failure',
                          'unavailable'
                      )
                    """,
                    now,
                )
                candidates = await connection.fetch(
                    """
                    SELECT delivery.*,
                           push.platform,
                           push.target_kind,
                           push.token_hash,
                           push.token_ciphertext,
                           incident.expires_at
                    FROM managed_safety_push_deliveries delivery
                    JOIN managed_push_installations push
                      ON push.account_id = delivery.account_id
                     AND push.installation_id = delivery.installation_id
                     AND push.status = 'active'
                    JOIN managed_accounts account
                      ON account.account_id = delivery.account_id
                     AND account.status = 'active'
                    JOIN managed_safety_incidents incident
                      ON incident.incident_id = delivery.incident_id
                     AND incident.status IN ('open', 'acknowledged')
                     AND incident.expires_at > $1
                    JOIN managed_safety_participants participant
                      ON participant.incident_id = delivery.incident_id
                     AND participant.contact_profile_id =
                            delivery.contact_profile_id
                     AND participant.status = 'pending'
                    WHERE delivery.status IN (
                            'pending',
                            'transient_failure',
                            'unavailable'
                          )
                      AND delivery.attempts < 3
                      AND (
                            delivery.last_attempt_at IS NULL
                            OR delivery.last_attempt_at <= $2
                          )
                    ORDER BY delivery.last_attempt_at NULLS FIRST,
                             delivery.attempts,
                             delivery.created_at,
                             delivery.delivery_id
                    FOR UPDATE OF delivery SKIP LOCKED
                    LIMIT $3
                    """,
                    now,
                    retry_before,
                    limit,
                )
                return await self._claim_delivery_candidates(
                    connection,
                    candidates=candidates,
                    now=now,
                    claim_seconds=claim_seconds,
                )

    @staticmethod
    async def _claim_delivery_candidates(
        connection: Any,
        *,
        candidates: list[Any],
        now: datetime,
        claim_seconds: int,
    ) -> list[dict[str, Any]]:
        claimed: list[dict[str, Any]] = []
        for candidate in candidates:
            claim_id = uuid4()
            claim_expires_at = now + timedelta(seconds=claim_seconds)
            attempt = int(candidate["attempts"]) + 1
            await connection.execute(
                """
                UPDATE managed_safety_push_deliveries
                SET status = 'sending',
                    attempts = $2,
                    claim_id = $3,
                    claim_expires_at = $4,
                    last_attempt_at = $5,
                    updated_at = $5
                WHERE delivery_id = $1
                """,
                candidate["delivery_id"],
                attempt,
                claim_id,
                claim_expires_at,
                now,
            )
            claimed.append(
                {
                    "delivery_id": candidate["delivery_id"],
                    "claim_id": claim_id,
                    "incident_id": candidate["incident_id"],
                    "contact_profile_id": candidate["contact_profile_id"],
                    "account_id": candidate["account_id"],
                    "installation_id": str(candidate["installation_id"]),
                    "platform": str(candidate["platform"]),
                    "target_kind": str(candidate["target_kind"]),
                    "token_hash": str(candidate["token_hash"]).strip(),
                    "token_ciphertext": str(candidate["token_ciphertext"]),
                    "expires_at": candidate["expires_at"],
                    "attempt": attempt,
                }
            )
        return claimed

    async def complete_push_delivery(
        self,
        *,
        delivery_id: UUID,
        claim_id: UUID,
        claimed_token_hash: str,
        outcome: str,
        provider_reference_hash: str | None,
    ) -> None:
        if outcome not in {
            "sent",
            "invalid",
            "transient_failure",
            "unavailable",
            "rejected",
        }:
            raise ValueError("unsupported push delivery outcome")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                delivery_owner = await connection.fetchrow(
                    """
                    SELECT account_id, installation_id
                    FROM managed_safety_push_deliveries
                    WHERE delivery_id = $1
                    """,
                    delivery_id,
                )
                if delivery_owner is None:
                    raise ManagedNotFoundError("Safety push delivery was not found")
                await connection.fetchrow(
                    """
                    SELECT account_id, installation_id
                    FROM managed_push_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    delivery_owner["account_id"],
                    delivery_owner["installation_id"],
                )
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_safety_push_deliveries
                    WHERE delivery_id = $1
                    FOR UPDATE
                    """,
                    delivery_id,
                )
                if row is None:
                    raise ManagedNotFoundError("Safety push delivery was not found")
                if (
                    row["account_id"] != delivery_owner["account_id"]
                    or row["installation_id"] != delivery_owner["installation_id"]
                ):
                    raise ManagedConflictError("Safety push delivery ownership changed")
                if row["status"] != "sending" or row["claim_id"] != claim_id:
                    raise ManagedConflictError(
                        "Safety push delivery claim is no longer valid"
                    )
                await connection.execute(
                    """
                    UPDATE managed_safety_push_deliveries
                    SET status = CASE
                            WHEN $3 IN (
                                'transient_failure',
                                'unavailable'
                            ) AND attempts >= 3
                                THEN 'rejected'
                            ELSE $3
                        END,
                        claim_id = NULL,
                        claim_expires_at = NULL,
                        delivered_at = CASE
                            WHEN $3 = 'sent' THEN $4
                            ELSE delivered_at
                        END,
                        provider_reference_hash = $5,
                        updated_at = $4
                    WHERE delivery_id = $1 AND claim_id = $2
                    """,
                    delivery_id,
                    claim_id,
                    outcome,
                    now,
                    provider_reference_hash,
                )
                if outcome == "invalid":
                    await connection.execute(
                        """
                        UPDATE managed_push_installations
                        SET status = 'invalid',
                            token_ciphertext = 'invalid.' || token_hash,
                            revoked_at = $4,
                            updated_at = $4
                        WHERE account_id = $1
                          AND installation_id = $2
                          AND token_hash = $3::char(64)
                          AND status = 'active'
                        """,
                        row["account_id"],
                        row["installation_id"],
                        claimed_token_hash,
                        now,
                    )

    async def reencrypt_push_installation_token(
        self,
        *,
        account_id: UUID,
        installation_id: str,
        expected_ciphertext: str,
        replacement_ciphertext: str,
    ) -> bool:
        result = await self._pool().execute(
            """
            UPDATE managed_push_installations
            SET token_ciphertext = $4,
                updated_at = clock_timestamp()
            WHERE account_id = $1
              AND installation_id = $2
              AND token_ciphertext = $3
              AND status = 'active'
            """,
            account_id,
            installation_id,
            expected_ciphertext,
            replacement_ciphertext,
        )
        return result == "UPDATE 1"

    async def delivery_summary(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
    ) -> dict[str, int]:
        incident = await self.get_incident(
            principal=principal,
            incident_id=incident_id,
        )
        delivery = incident.get("delivery")
        if not isinstance(delivery, dict):
            raise ManagedForbiddenError("only the incident owner can review delivery")
        return {key: int(value) for key, value in delivery.items()}

    async def purge_expired_rows(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> dict[str, int]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        counts: dict[str, int] = {}
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await self._expire(connection, now)
                deleted_locations = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT location.incident_id
                        FROM managed_safety_locations location
                        JOIN managed_safety_incidents incident
                          ON incident.incident_id = location.incident_id
                        WHERE incident.status NOT IN ('open', 'acknowledged')
                           OR incident.expires_at <= $1
                        ORDER BY incident.expires_at, location.incident_id
                        FOR UPDATE OF location SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_locations location
                    USING candidates
                    WHERE location.incident_id = candidates.incident_id
                    RETURNING location.incident_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_locations_deleted"] = len(deleted_locations)
                deleted_incidents = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT incident_id
                        FROM managed_safety_incidents
                        WHERE purge_after <= $1
                        ORDER BY purge_after, incident_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_incidents incident
                    USING candidates
                    WHERE incident.incident_id = candidates.incident_id
                    RETURNING incident.incident_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_incidents_deleted"] = len(deleted_incidents)
                deleted_quota_events = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT owner_account_id, client_request_id
                        FROM managed_safety_page_quota_events quota
                        WHERE quota.purge_after <= $1
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_safety_incidents incident
                              WHERE incident.incident_id = quota.incident_id
                          )
                        ORDER BY purge_after, owner_account_id, client_request_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_page_quota_events quota
                    USING candidates
                    WHERE quota.owner_account_id = candidates.owner_account_id
                      AND quota.client_request_id = candidates.client_request_id
                    RETURNING quota.client_request_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_page_quota_events_deleted"] = len(
                    deleted_quota_events
                )
                deleted_requests = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT request_id
                        FROM managed_safety_requests
                        WHERE purge_after <= $1
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_safety_contacts contact
                              WHERE contact.accepted_request_id =
                                    managed_safety_requests.request_id
                          )
                        ORDER BY purge_after, request_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_requests request
                    USING candidates
                    WHERE request.request_id = candidates.request_id
                    RETURNING request.request_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_requests_deleted"] = len(deleted_requests)
                deleted_request_quota_events = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT owner_account_id, client_request_id
                        FROM managed_safety_request_quota_events quota
                        WHERE quota.purge_after <= $1
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_safety_requests request
                              WHERE request.request_id =
                                    quota.safety_request_id
                          )
                        ORDER BY purge_after, owner_account_id, client_request_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_request_quota_events quota
                    USING candidates
                    WHERE quota.owner_account_id = candidates.owner_account_id
                      AND quota.client_request_id = candidates.client_request_id
                    RETURNING quota.client_request_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_request_quota_events_deleted"] = len(
                    deleted_request_quota_events
                )
                deleted_invites = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT invite_id
                        FROM managed_safety_invites
                        WHERE purge_after <= $1
                        ORDER BY purge_after, invite_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_invites invite
                    USING candidates
                    WHERE invite.invite_id = candidates.invite_id
                    RETURNING invite.invite_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_invites_deleted"] = len(deleted_invites)
                deleted_invite_quota_events = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT owner_account_id, client_request_id
                        FROM managed_safety_invite_quota_events quota
                        WHERE quota.purge_after <= $1
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_safety_invites invite
                              WHERE invite.invite_id = quota.invite_id
                          )
                        ORDER BY purge_after, owner_account_id, client_request_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    DELETE FROM managed_safety_invite_quota_events quota
                    USING candidates
                    WHERE quota.owner_account_id = candidates.owner_account_id
                      AND quota.client_request_id = candidates.client_request_id
                    RETURNING quota.client_request_id
                    """,
                    now,
                    batch_size,
                )
                counts["managed_safety_invite_quota_events_deleted"] = len(
                    deleted_invite_quota_events
                )
        return counts


class ManagedSafetyPushService:
    def __init__(
        self,
        *,
        repository: PostgresManagedSafetyRepository,
        token_codec: ManagedPushTokenCodec,
        provider: ManagedPushSending,
        max_concurrency: int = 6,
    ) -> None:
        if not 1 <= max_concurrency <= 20:
            raise ValueError("push concurrency must be between 1 and 20")
        self.repository = repository
        self.token_codec = token_codec
        self.provider = provider
        self.max_concurrency = max_concurrency
        provider_delivery_seconds = int(
            getattr(provider, "maximum_delivery_seconds", 30)
        )
        if not 1 <= provider_delivery_seconds <= 14 * 60:
            raise ValueError("push provider delivery bound is unsupported")
        self.claim_seconds = max(
            SAFETY_PUSH_MIN_CLAIM_SECONDS,
            provider_delivery_seconds + SAFETY_PUSH_RECEIPT_MARGIN_SECONDS,
        )

    @property
    def available(self) -> bool:
        return bool(getattr(self.provider, "available", False))

    async def register(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        registration: ManagedPushRegistration,
    ) -> dict[str, Any]:
        token = registration.token.get_secret_value()
        return await self.repository.register_push_installation(
            principal=principal,
            installation_id=installation_id,
            registration=registration,
            token_hash=self.token_codec.token_hash(token),
            token_ciphertext=self.token_codec.seal(
                token,
                account_id=principal.account_id,
                installation_id=installation_id,
            ),
        )

    async def dispatch(
        self,
        *,
        principal: ManagedPrincipal,
        incident_id: UUID,
    ) -> dict[str, int]:
        remaining = 20
        attempted_delivery_ids: set[UUID] = set()
        while remaining > 0:
            wave_limit = min(self.max_concurrency, remaining)
            deliveries = await self.repository.claim_push_deliveries(
                principal=principal,
                incident_id=incident_id,
                limit=wave_limit,
                exclude_delivery_ids=attempted_delivery_ids,
                claim_seconds=self.claim_seconds,
            )
            if not deliveries:
                break
            attempted_delivery_ids.update(
                delivery["delivery_id"] for delivery in deliveries
            )
            await self._send_claimed(deliveries)
            remaining -= len(deliveries)
            if len(deliveries) < wave_limit:
                break
        return await self.repository.delivery_summary(
            principal=principal,
            incident_id=incident_id,
        )

    async def dispatch_due(
        self,
        *,
        limit: int = 100,
    ) -> ManagedPushBatchResult:
        if not 1 <= limit <= 200:
            raise ValueError("push retry dispatch limit must be 1 through 200")
        remaining = limit
        total = ManagedPushBatchResult()
        while remaining > 0:
            wave_limit = min(self.max_concurrency, remaining)
            deliveries = await self.repository.claim_due_push_deliveries(
                limit=wave_limit,
                claim_seconds=self.claim_seconds,
            )
            if not deliveries:
                break
            wave = await self._send_claimed(deliveries)
            total = ManagedPushBatchResult(
                claimed=total.claimed + wave.claimed,
                provider_accepted=(total.provider_accepted + wave.provider_accepted),
                retryable_failures=(total.retryable_failures + wave.retryable_failures),
                terminal_failures=(total.terminal_failures + wave.terminal_failures),
                receipt_failures=(total.receipt_failures + wave.receipt_failures),
            )
            remaining -= len(deliveries)
            if len(deliveries) < wave_limit:
                break
        return total

    async def _send_claimed(
        self,
        deliveries: list[dict[str, Any]],
    ) -> ManagedPushBatchResult:
        semaphore = asyncio.Semaphore(self.max_concurrency)

        async def send(delivery: dict[str, Any]) -> tuple[str, bool]:
            async with semaphore:
                try:
                    opened = self.token_codec.open_with_rotation(
                        delivery["token_ciphertext"],
                        account_id=delivery["account_id"],
                        installation_id=delivery["installation_id"],
                    )
                    if opened.needs_reseal:
                        replacement = self.token_codec.seal(
                            opened.token,
                            account_id=delivery["account_id"],
                            installation_id=delivery["installation_id"],
                        )
                        try:
                            await self.repository.reencrypt_push_installation_token(
                                account_id=delivery["account_id"],
                                installation_id=delivery["installation_id"],
                                expected_ciphertext=delivery["token_ciphertext"],
                                replacement_ciphertext=replacement,
                            )
                        except Exception:
                            # Delivery remains possible with the successfully
                            # opened token; a later attempt can retry the
                            # best-effort compare-and-swap rekey.
                            pass
                    result = await self.provider.send_safety_incident(
                        token=opened.token,
                        platform=delivery["platform"],
                        target_kind=delivery["target_kind"],
                        incident_id=delivery["incident_id"],
                        expires_at=delivery["expires_at"],
                    )
                    outcome = result.outcome
                    provider_reference_hash = result.provider_reference_hash
                except ManagedPushTokenUnavailableError:
                    # A missing previous key is a server configuration failure,
                    # not evidence that the provider registration is invalid.
                    outcome = "unavailable"
                    provider_reference_hash = None
                except ManagedPushTokenCorruptError:
                    # A malformed envelope or authentication failure under its
                    # known key cannot be repaired by retrying this delivery.
                    outcome = "invalid"
                    provider_reference_hash = None
                except ManagedPushTokenError:
                    # Keep unknown codec failures fail-safe and retryable.
                    outcome = "unavailable"
                    provider_reference_hash = None
                except Exception:
                    # Provider implementations are an external boundary. Keep
                    # an unexpected failure retryable without persisting its
                    # message, token, payload, or dynamic identifier.
                    outcome = "unavailable"
                    provider_reference_hash = None
                try:
                    await self.repository.complete_push_delivery(
                        delivery_id=delivery["delivery_id"],
                        claim_id=delivery["claim_id"],
                        claimed_token_hash=delivery["token_hash"],
                        outcome=outcome,
                        provider_reference_hash=provider_reference_hash,
                    )
                except ManagedStorageError:
                    # The incident remains available through authenticated
                    # catch-up even if a bounded delivery receipt races expiry.
                    return outcome, False
                return outcome, True

        outcomes = await asyncio.gather(*(send(delivery) for delivery in deliveries))
        provider_accepted = sum(outcome == "sent" for outcome, _ in outcomes)
        retryable_failures = sum(
            outcome in {"transient_failure", "unavailable"}
            and int(delivery["attempt"]) < 3
            for delivery, (outcome, _) in zip(deliveries, outcomes, strict=True)
        )
        terminal_failures = sum(
            outcome in {"invalid", "rejected"}
            or (
                outcome in {"transient_failure", "unavailable"}
                and int(delivery["attempt"]) >= 3
            )
            for delivery, (outcome, _) in zip(deliveries, outcomes, strict=True)
        )
        return ManagedPushBatchResult(
            claimed=len(deliveries),
            provider_accepted=provider_accepted,
            retryable_failures=retryable_failures,
            terminal_failures=terminal_failures,
            receipt_failures=sum(not completed for _, completed in outcomes),
        )
