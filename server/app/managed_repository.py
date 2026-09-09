from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
from collections.abc import Collection
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta, timezone
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.managed_identity import ManagedIdentityClaims
from app.managed_models import (
    ManagedChunkReservation,
    ManagedClientKeyRegistration,
    ManagedDocumentMutation,
    ManagedEnrollment,
    ManagedExportRequest,
    ManagedRestoreRequest,
    ManagedSocialInviteCreate,
    ManagedSocialPokeAcknowledgement,
    ManagedSocialPokeCreate,
    ManagedSocialProfileCreate,
    ManagedSocialProfilePatch,
    ManagedSocialRequestCreate,
    ManagedSocialSummaryMutation,
    ManagedSocialVisibilityPatch,
    ManagedSourceRegistration,
)
from app.managed_object_store import ManagedObjectMetadata

SOCIAL_ALIAS_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
SOCIAL_SUMMARY_FIELDS = (
    "charge",
    "effort",
    "rest",
    "sleep_duration",
    "hrv",
    "rhr",
)
SOCIAL_FIXED_TIME_ZONE = re.compile(r"^(?:(?:UTC|GMT))?([+-])([0-9]{2}):?([0-9]{2})$")
SOCIAL_MAX_ACTIVE_INVITES = 10
SOCIAL_MAX_INVITES_PER_DAY = 50
SOCIAL_MAX_SENT_REQUESTS_PER_DAY = 50
SOCIAL_MAX_PENDING_REQUESTS = 100
SOCIAL_MAX_RECEIVED_REQUESTS_PER_DAY = 100
SOCIAL_MAX_FRIENDS = 500
SOCIAL_MAX_SENT_POKES_PER_DAY = 10
SOCIAL_MAX_RECEIVED_POKES_PER_DAY = 20


async def _lock_active_managed_safety_incidents_for_profile_pair(
    connection: Any,
    *,
    first_profile_id: UUID,
    second_profile_id: UUID,
) -> tuple[UUID, ...]:
    rows = await connection.fetch(
        """
        SELECT incident.incident_id
        FROM managed_safety_incidents incident
        WHERE incident.status IN ('open', 'acknowledged')
          AND (
              (
                incident.owner_profile_id = $1
                AND EXISTS (
                    SELECT 1
                    FROM managed_safety_participants participant
                    WHERE participant.incident_id = incident.incident_id
                      AND participant.contact_profile_id = $2
                      AND participant.status <> 'revoked'
                )
              ) OR (
                incident.owner_profile_id = $2
                AND EXISTS (
                    SELECT 1
                    FROM managed_safety_participants participant
                    WHERE participant.incident_id = incident.incident_id
                      AND participant.contact_profile_id = $1
                      AND participant.status <> 'revoked'
                )
              )
          )
        ORDER BY incident.incident_id
        FOR UPDATE OF incident
        """,
        first_profile_id,
        second_profile_id,
    )
    return tuple(row["incident_id"] for row in rows)


async def _reconcile_managed_safety_incident_acknowledgement(
    connection: Any,
    *,
    incident_ids: Collection[UUID],
    now: datetime,
) -> None:
    ordered_ids = sorted(set(incident_ids), key=str)
    if not ordered_ids:
        return
    await connection.execute(
        """
        UPDATE managed_safety_incidents incident
        SET status = CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM managed_safety_participants participant
                    WHERE participant.incident_id = incident.incident_id
                      AND participant.status = 'responding'
                )
                THEN 'acknowledged'
                ELSE 'open'
            END,
            acknowledged_at = CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM managed_safety_participants participant
                    WHERE participant.incident_id = incident.incident_id
                      AND participant.status = 'responding'
                )
                THEN COALESCE(incident.acknowledged_at, $2)
                ELSE NULL
            END
        WHERE incident.incident_id = ANY($1::uuid[])
          AND incident.status IN ('open', 'acknowledged')
        """,
        ordered_ids,
        now,
    )


async def _retire_managed_safety_profile(
    connection: Any,
    *,
    profile_id: UUID,
    now: datetime,
) -> None:
    incident_rows = await connection.fetch(
        """
        SELECT incident.incident_id,
               incident.owner_profile_id = $1 AS profile_is_owner
        FROM managed_safety_incidents incident
        WHERE incident.status IN ('open', 'acknowledged')
          AND (
              incident.owner_profile_id = $1
              OR EXISTS (
                  SELECT 1
                  FROM managed_safety_participants participant
                  WHERE participant.incident_id = incident.incident_id
                    AND participant.contact_profile_id = $1
                    AND participant.status <> 'revoked'
              )
          )
        ORDER BY incident.incident_id
        FOR UPDATE OF incident
        """,
        profile_id,
    )
    owned_incident_ids = [
        row["incident_id"] for row in incident_rows if row["profile_is_owner"]
    ]
    participating_incident_ids = [
        row["incident_id"] for row in incident_rows if not row["profile_is_owner"]
    ]

    if owned_incident_ids:
        await connection.execute(
            """
            UPDATE managed_safety_incidents
            SET status = 'canceled', ended_at = $2
            WHERE incident_id = ANY($1::uuid[])
              AND status IN ('open', 'acknowledged')
            """,
            owned_incident_ids,
            now,
        )
        await connection.execute(
            """
            DELETE FROM managed_safety_locations
            WHERE incident_id = ANY($1::uuid[])
            """,
            owned_incident_ids,
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
            owned_incident_ids,
            now,
        )

    if participating_incident_ids:
        await connection.execute(
            """
            UPDATE managed_safety_participants
            SET status = 'revoked',
                responded_at = COALESCE(responded_at, $3)
            WHERE contact_profile_id = $1
              AND incident_id = ANY($2::uuid[])
              AND status <> 'revoked'
            """,
            profile_id,
            participating_incident_ids,
            now,
        )
        await _reconcile_managed_safety_incident_acknowledgement(
            connection,
            incident_ids=participating_incident_ids,
            now=now,
        )
        await connection.execute(
            """
            UPDATE managed_safety_push_deliveries
            SET status = 'rejected',
                claim_id = NULL,
                claim_expires_at = NULL,
                updated_at = $3
            WHERE contact_profile_id = $1
              AND incident_id = ANY($2::uuid[])
              AND status IN (
                  'pending',
                  'sending',
                  'transient_failure',
                  'unavailable'
              )
            """,
            profile_id,
            participating_incident_ids,
            now,
        )


class ManagedStorageError(Exception):
    """Base class for managed-storage contract failures."""


class ManagedNotFoundError(ManagedStorageError):
    pass


class ManagedForbiddenError(ManagedStorageError):
    pass


class ManagedConflictError(ManagedStorageError):
    pass


class ManagedRateLimitError(ManagedStorageError):
    def __init__(self, message: str, *, retry_after_seconds: int) -> None:
        super().__init__(message)
        self.retry_after_seconds = max(1, retry_after_seconds)


class ManagedQuotaExceededError(ManagedStorageError):
    def __init__(self, *, maximum_bytes: int | None, used_bytes: int) -> None:
        super().__init__("managed storage quota would be exceeded")
        self.maximum_bytes = maximum_bytes
        self.used_bytes = used_bytes


class ManagedConfigurationError(ManagedStorageError):
    pass


class ManagedProcessingBusyError(ManagedStorageError):
    pass


class ManagedCursorExpiredError(ManagedStorageError):
    def __init__(self, *, minimum_sequence: int) -> None:
        super().__init__("managed sync cursor is older than retained history")
        self.minimum_sequence = minimum_sequence


def _decoded_json(value: Any) -> Any:
    return json.loads(value) if isinstance(value, str) else value


@dataclass(frozen=True, slots=True)
class ManagedPrincipal:
    account_id: UUID
    identity_id: UUID
    subject_hash: str
    account_status: str
    auth_valid_after: datetime


class PostgresManagedRepository:
    """Tenant-scoped NOOP+ storage control plane on the primary database pool."""

    def __init__(
        self,
        primary_repository: Any,
        *,
        home_region: str,
        residency_policy_version: str,
        default_plan_code: str,
        default_plan_revision: int,
        consent_policy_kind: str,
        entitlement_mode: str = "closed",
        replay_secret: str = "",
    ) -> None:
        if entitlement_mode not in {"closed", "pilot", "open_beta", "paid"}:
            raise ValueError("invalid managed entitlement mode")
        self.primary_repository = primary_repository
        self.home_region = home_region
        self.residency_policy_version = residency_policy_version
        self.default_plan_code = default_plan_code
        self.default_plan_revision = default_plan_revision
        self.consent_policy_kind = consent_policy_kind
        self.entitlement_mode = entitlement_mode
        self.replay_secret = replay_secret

    def _pool(self) -> Any:
        return self.primary_repository._require_pool()

    async def coordination_now(self) -> datetime:
        return await self._pool().fetchval("SELECT clock_timestamp()")

    def _tenant_replay_hash(self, account_id: UUID) -> str:
        if len(self.replay_secret.encode("utf-8")) < 32:
            raise ManagedConfigurationError("managed replay secret is not configured")
        return hmac.new(
            self.replay_secret.encode("utf-8"),
            f"account:{account_id}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    def _resource_replay_hash(self, resource_kind: str, resource_id: UUID) -> str:
        if len(self.replay_secret.encode("utf-8")) < 32:
            raise ManagedConfigurationError("managed replay secret is not configured")
        return hmac.new(
            self.replay_secret.encode("utf-8"),
            f"{resource_kind}:{resource_id}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    async def _append_chunk_change(
        self,
        connection: Any,
        *,
        chunk: Any,
        operation: str,
        now: datetime,
    ) -> int:
        generation = chunk["object_generation"]
        content_sha256 = str(chunk["expected_sha256"]).strip()
        idempotency_hash = hashlib.sha256(
            (
                f"change:chunk:{chunk['account_id']}:{chunk['chunk_id']}:"
                f"{operation}:{generation}:{content_sha256}"
            ).encode("utf-8")
        ).hexdigest()
        sequence = await connection.fetchval(
            """
            SELECT noop_managed_append_change(
                $1,
                $2::char(64),
                'chunk',
                $3,
                $4,
                $5,
                $6::char(64),
                $7,
                $8,
                $9,
                $10::jsonb,
                $11,
                $11::timestamptz + interval '400 days'
            )
            """,
            chunk["account_id"],
            idempotency_hash,
            chunk["chunk_id"],
            generation,
            operation,
            content_sha256,
            chunk["data_class"],
            chunk["event_start"],
            chunk["event_end"],
            json.dumps(
                {
                    "object_generation": generation,
                    "state": str(chunk["state"]),
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            now,
        )
        return int(sequence)

    async def _supersede_exact_chunk_window(
        self,
        connection: Any,
        *,
        account_id: UUID,
        replacement_chunk_id: UUID,
        now: datetime,
    ) -> None:
        replacement = await connection.fetchrow(
            """
            SELECT authoritative_snapshot,
                   pg_advisory_xact_lock(
                       hashtextextended(
                           concat_ws(
                               ':',
                               'noop-managed-window',
                               account_id::text,
                               source_id::text,
                               data_class,
                               extract(epoch FROM event_start)::text,
                               extract(epoch FROM event_end)::text
                           ),
                           0
                       )
                   ) AS window_lock
            FROM managed_chunks
            WHERE account_id = $1 AND chunk_id = $2
            """,
            account_id,
            replacement_chunk_id,
        )
        if replacement is None:
            raise ManagedNotFoundError("managed replacement chunk was not found")
        if not replacement["authoritative_snapshot"]:
            return
        await connection.execute(
            """
            UPDATE managed_chunks prior
            SET superseded_by_chunk_id = replacement.chunk_id,
                superseded_at = $3
            FROM managed_chunks replacement
            WHERE replacement.account_id = $1
              AND replacement.chunk_id = $2
              AND replacement.authoritative_snapshot
              AND prior.account_id = replacement.account_id
              AND prior.source_id = replacement.source_id
              AND prior.data_class = replacement.data_class
              AND prior.event_start = replacement.event_start
              AND prior.event_end = replacement.event_end
              AND prior.chunk_id <> replacement.chunk_id
              AND prior.state = 'available'
              AND prior.superseded_by_chunk_id IS NULL
            """,
            account_id,
            replacement_chunk_id,
            now,
        )

    async def acquire_worker_lease(
        self,
        *,
        lease_name: str,
        owner_id: UUID,
        now: datetime,
        lease_seconds: int,
    ) -> bool:
        if not 60 <= lease_seconds <= 3_600:
            raise ValueError("lease_seconds must be between 60 and 3600")
        row = await self._pool().fetchrow(
            """
            INSERT INTO managed_worker_leases (
                lease_name,
                owner_id,
                acquired_at,
                heartbeat_at,
                expires_at
            ) VALUES (
                $1,
                $2,
                $3::timestamptz,
                $3::timestamptz,
                $3::timestamptz
                    + make_interval(secs => $4::integer)
            )
            ON CONFLICT (lease_name) DO UPDATE
            SET owner_id = EXCLUDED.owner_id,
                acquired_at = EXCLUDED.acquired_at,
                heartbeat_at = EXCLUDED.heartbeat_at,
                expires_at = EXCLUDED.expires_at
            WHERE managed_worker_leases.expires_at <= EXCLUDED.acquired_at
            RETURNING owner_id
            """,
            lease_name,
            owner_id,
            now,
            lease_seconds,
        )
        return row is not None and row["owner_id"] == owner_id

    async def release_worker_lease(
        self,
        *,
        lease_name: str,
        owner_id: UUID,
    ) -> None:
        await self._pool().execute(
            """
            DELETE FROM managed_worker_leases
            WHERE lease_name = $1 AND owner_id = $2
            """,
            lease_name,
            owner_id,
        )

    async def configuration_ready(
        self,
        *,
        policy_version: str,
        policy_sha256: str,
    ) -> bool:
        row = await self._pool().fetchrow(
            """
            SELECT EXISTS (
                       SELECT 1
                       FROM managed_policy_documents
                       WHERE policy_kind = $1
                         AND policy_version = $2
                         AND document_sha256 = $3
                         AND effective_at <= clock_timestamp()
                         AND (
                             retired_at IS NULL
                             OR retired_at > clock_timestamp()
                         )
                   ) AS policy_ready,
                   EXISTS (
                       SELECT 1
                       FROM managed_storage_plans plan
                       WHERE plan.plan_code = $4
                         AND plan.revision = $5
                         AND plan.status = 'active'
                         AND plan.effective_at <= clock_timestamp()
                         AND (
                             plan.retired_at IS NULL
                             OR plan.retired_at > clock_timestamp()
                         )
                         AND EXISTS (
                             SELECT 1
                             FROM managed_plan_data_rules rule
                             WHERE rule.plan_code = plan.plan_code
                               AND rule.plan_revision = plan.revision
                         )
                   ) AS plan_ready
            """,
            self.consent_policy_kind,
            policy_version,
            policy_sha256,
            self.default_plan_code,
            self.default_plan_revision,
        )
        return bool(row is not None and row["policy_ready"] and row["plan_ready"])

    async def principal_for_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> ManagedPrincipal:
        row = await self._pool().fetchrow(
            """
            SELECT identity.identity_id,
                   identity.account_id,
                   identity.subject_hash,
                   identity.status AS identity_status,
                   account.status AS account_status,
                   account.auth_valid_after
            FROM managed_external_identities identity
            JOIN managed_accounts account USING (account_id)
            WHERE identity.issuer = $1
              AND identity.provider_tenant = $2
              AND identity.subject_hash = $3
            """,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
        )
        if row is None:
            raise ManagedNotFoundError("managed account is not enrolled")
        if (
            row["identity_status"] != "active"
            or row["account_status"] not in {"active", "suspended", "erasure_pending"}
            or claims.auth_time < row["auth_valid_after"]
        ):
            raise ManagedForbiddenError("managed account authorization was revoked")
        await self._pool().execute(
            """
            UPDATE managed_external_identities
            SET last_seen_at = GREATEST(last_seen_at, $2)
            WHERE identity_id = $1
            """,
            row["identity_id"],
            claims.issued_at,
        )
        return ManagedPrincipal(
            account_id=row["account_id"],
            identity_id=row["identity_id"],
            subject_hash=str(row["subject_hash"]).strip(),
            account_status=str(row["account_status"]),
            auth_valid_after=row["auth_valid_after"],
        )

    async def enroll(
        self,
        *,
        claims: ManagedIdentityClaims,
        enrollment: ManagedEnrollment,
    ) -> dict[str, Any]:
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    (
                        "noop-managed-identity:"
                        f"{claims.issuer}:{claims.provider_tenant}:"
                        f"{claims.subject_hash}"
                    ),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                policy = await connection.fetchrow(
                    """
                    SELECT document_sha256, effective_at, retired_at
                    FROM managed_policy_documents
                    WHERE policy_kind = $1 AND policy_version = $2
                    """,
                    self.consent_policy_kind,
                    enrollment.policy_version,
                )
                if (
                    policy is None
                    or str(policy["document_sha256"]).strip()
                    != enrollment.policy_sha256
                    or policy["effective_at"] > now
                    or (
                        policy["retired_at"] is not None and policy["retired_at"] <= now
                    )
                ):
                    raise ManagedConfigurationError(
                        "managed consent policy is not active"
                    )
                identity = await connection.fetchrow(
                    """
                    SELECT identity.identity_id,
                           identity.account_id,
                           identity.status AS identity_status,
                           account.status AS account_status,
                           account.auth_valid_after,
                           subscription.subscription_id,
                           subscription.plan_code,
                           subscription.plan_revision
                    FROM managed_external_identities identity
                    JOIN managed_accounts account USING (account_id)
                    LEFT JOIN managed_subscriptions subscription
                      ON subscription.account_id = account.account_id
                     AND subscription.status
                         IN ('trial', 'active', 'grace', 'paused')
                    WHERE identity.issuer = $1
                      AND identity.provider_tenant = $2
                      AND identity.subject_hash = $3
                    FOR UPDATE OF identity, account
                    """,
                    claims.issuer,
                    claims.provider_tenant,
                    claims.subject_hash,
                )
                created = identity is None
                if self.entitlement_mode == "closed":
                    raise ManagedForbiddenError("managed storage enrollment is closed")
                if (
                    identity is None
                    and self.entitlement_mode != "open_beta"
                    and not (self.entitlement_mode == "pilot" and claims.managed_pilot)
                ):
                    raise ManagedForbiddenError(
                        "managed storage requires a provisioned entitlement"
                    )
                selected_plan_code = self.default_plan_code
                selected_plan_revision = self.default_plan_revision
                if identity is not None:
                    if (
                        identity["identity_status"] != "active"
                        or identity["account_status"] != "active"
                        or claims.auth_time < identity["auth_valid_after"]
                    ):
                        raise ManagedForbiddenError(
                            "managed account cannot be enrolled"
                        )
                    if identity["subscription_id"] is None:
                        raise ManagedConfigurationError(
                            "managed account has no current storage subscription"
                        )
                    selected_plan_code = str(identity["plan_code"])
                    selected_plan_revision = int(identity["plan_revision"])
                plan = await connection.fetchrow(
                    """
                    SELECT max_installations
                    FROM managed_storage_plans
                    WHERE plan_code = $1
                      AND revision = $2
                      AND effective_at IS NOT NULL
                      AND effective_at <= $3
                      AND (
                          (
                              status = 'active'
                              AND (retired_at IS NULL OR retired_at > $3)
                          )
                          OR ($4::boolean AND status = 'retired')
                      )
                    """,
                    selected_plan_code,
                    selected_plan_revision,
                    now,
                    identity is not None,
                )
                rules = await connection.fetch(
                    """
                    SELECT data_class,
                           cloud_retention_days,
                           summary_retention_days,
                           recommended_local_raw_days,
                           storage_class,
                           server_processing_allowed,
                           maximum_daily_bytes
                    FROM managed_plan_data_rules
                    WHERE plan_code = $1
                      AND plan_revision = $2
                      AND data_class = ANY($3::text[])
                    ORDER BY data_class
                    """,
                    selected_plan_code,
                    selected_plan_revision,
                    enrollment.data_classes,
                )
                if plan is None or {str(row["data_class"]) for row in rules} != set(
                    enrollment.data_classes
                ):
                    plan_scope = "account" if identity is not None else "default"
                    raise ManagedConfigurationError(
                        f"managed {plan_scope} plan does not cover every "
                        "consented data class"
                    )
                if identity is None:
                    account_id = uuid4()
                    identity_id = uuid4()
                    subscription_id = uuid4()
                    storage_namespace = uuid4()
                    await connection.execute(
                        """
                        INSERT INTO managed_accounts (
                            account_id,
                            storage_namespace,
                            home_region,
                            residency_policy_version,
                            auth_valid_after,
                            created_at,
                            updated_at
                        ) VALUES ($1, $2, $3, $4, $5, $6, $6)
                        """,
                        account_id,
                        storage_namespace,
                        self.home_region,
                        self.residency_policy_version,
                        claims.auth_time,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO managed_external_identities (
                            identity_id,
                            account_id,
                            issuer,
                            provider_tenant,
                            subject_hash,
                            verified_at,
                            last_seen_at,
                            created_at
                        ) VALUES ($1, $2, $3, $4, $5, $6, $6, $7)
                        """,
                        identity_id,
                        account_id,
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                        claims.issued_at,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO managed_subscriptions (
                            subscription_id,
                            account_id,
                            plan_code,
                            plan_revision,
                            status,
                            billing_provider,
                            period_started_at,
                            created_at,
                            updated_at
                        ) VALUES (
                            $1,
                            $2,
                            $3,
                            $4,
                            'active',
                            'manual',
                            $5,
                            $5,
                            $5
                        )
                        """,
                        subscription_id,
                        account_id,
                        selected_plan_code,
                        selected_plan_revision,
                        now,
                    )
                else:
                    account_id = identity["account_id"]
                    identity_id = identity["identity_id"]
                    subscription_id = identity["subscription_id"]
                    await connection.execute(
                        """
                        UPDATE managed_external_identities
                        SET last_seen_at = GREATEST(last_seen_at, $2)
                        WHERE identity_id = $1
                        """,
                        identity_id,
                        claims.issued_at,
                    )

                await self._enroll_installation(
                    connection,
                    account_id=account_id,
                    enrollment=enrollment,
                    maximum_installations=int(plan["max_installations"]),
                    now=now,
                )
                await self._record_consent(
                    connection,
                    account_id=account_id,
                    enrollment=enrollment,
                    now=now,
                )
                for rule in rules:
                    await self._ensure_retention_snapshot(
                        connection,
                        account_id=account_id,
                        subscription_id=subscription_id,
                        plan_code=selected_plan_code,
                        plan_revision=selected_plan_revision,
                        rule=dict(rule),
                        now=now,
                    )
                overview = await self._overview(
                    connection,
                    account_id=account_id,
                )
        overview["created"] = created
        overview["identity_id"] = identity_id
        return overview

    async def _enroll_installation(
        self,
        connection: Any,
        *,
        account_id: UUID,
        enrollment: ManagedEnrollment,
        maximum_installations: int,
        now: datetime,
    ) -> None:
        installation_token_hash = hashlib.sha256(
            enrollment.installation_token.get_secret_value().encode("ascii")
        ).hexdigest()
        existing_owner = await connection.fetchrow(
            """
            SELECT account_id,
                   platform,
                   device_key_fingerprint,
                   status,
                   credential.token_hash,
                   credential.revoked_at AS credential_revoked_at
            FROM managed_account_installations installation
            JOIN installation_credentials credential
              USING (installation_id)
            WHERE installation.installation_id = $1
            FOR UPDATE OF installation, credential
            """,
            enrollment.installation_id,
        )
        if existing_owner is not None:
            if existing_owner["account_id"] != account_id:
                raise ManagedConflictError(
                    "installation is already enrolled to another account"
                )
            stored_fingerprint = existing_owner["device_key_fingerprint"]
            if (
                stored_fingerprint is not None
                and enrollment.device_key_fingerprint is not None
                and str(stored_fingerprint).strip() != enrollment.device_key_fingerprint
            ):
                raise ManagedConflictError(
                    "installation device key does not match enrollment"
                )
            if (
                existing_owner["status"] == "revoked"
                or existing_owner["credential_revoked_at"] is not None
            ):
                raise ManagedForbiddenError("installation was revoked")
            if not hmac.compare_digest(
                str(existing_owner["token_hash"]).strip(),
                installation_token_hash,
            ):
                raise ManagedForbiddenError(
                    "installation credential does not match enrollment"
                )
            await connection.execute(
                """
                UPDATE managed_account_installations
                SET last_seen_at = $3,
                    device_key_fingerprint = COALESCE(
                        device_key_fingerprint,
                        $2
                    )
                WHERE account_id = $1 AND installation_id = $4
                """,
                account_id,
                enrollment.device_key_fingerprint,
                now,
                enrollment.installation_id,
            )
            return
        installation_count = await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_account_installations
            WHERE account_id = $1 AND status <> 'revoked'
            """,
            account_id,
        )
        if int(installation_count) >= maximum_installations:
            raise ManagedQuotaExceededError(
                maximum_bytes=None,
                used_bytes=int(installation_count),
            )
        try:
            await connection.execute(
                """
                INSERT INTO installation_credentials (
                    installation_id,
                    enrollment_id,
                    token_hash,
                    created_at,
                    updated_at
                ) VALUES ($1, $2, $3, $4, $4)
                """,
                enrollment.installation_id,
                enrollment.enrollment_request_id,
                installation_token_hash,
                now,
            )
            await connection.execute(
                """
                INSERT INTO managed_account_installations (
                    account_id,
                    installation_id,
                    platform,
                    device_key_fingerprint,
                    token_valid_after,
                    registered_at,
                    last_seen_at
                ) VALUES ($1, $2, $3, $4, $5, $5, $5)
                """,
                account_id,
                enrollment.installation_id,
                enrollment.platform,
                enrollment.device_key_fingerprint,
                now,
            )
        except Exception as error:
            if getattr(error, "sqlstate", None) == "23505":
                raise ManagedConflictError(
                    "installation is already enrolled"
                ) from error
            raise

    async def _record_consent(
        self,
        connection: Any,
        *,
        account_id: UUID,
        enrollment: ManagedEnrollment,
        now: datetime,
    ) -> None:
        existing = await connection.fetchrow(
            """
            SELECT policy_kind,
                   policy_version,
                   decision,
                   data_classes,
                   installation_id
            FROM managed_consent_events
            WHERE account_id = $1 AND request_id = $2
            """,
            account_id,
            enrollment.enrollment_request_id,
        )
        if existing is not None:
            if (
                existing["policy_kind"] != self.consent_policy_kind
                or existing["policy_version"] != enrollment.policy_version
                or existing["decision"] != "granted"
                or list(existing["data_classes"]) != enrollment.data_classes
                or existing["installation_id"] != enrollment.installation_id
            ):
                raise ManagedConflictError(
                    "enrollment request id was reused with different consent"
                )
            return
        await connection.execute(
            """
            INSERT INTO managed_consent_events (
                consent_event_id,
                account_id,
                policy_kind,
                policy_version,
                decision,
                data_classes,
                installation_id,
                request_id,
                occurred_at,
                recorded_at
            ) VALUES (
                $1,
                $2,
                $3,
                $4,
                'granted',
                $5,
                $6,
                $7,
                $8,
                $8
            )
            """,
            uuid4(),
            account_id,
            self.consent_policy_kind,
            enrollment.policy_version,
            enrollment.data_classes,
            enrollment.installation_id,
            enrollment.enrollment_request_id,
            now,
        )

    async def _ensure_retention_snapshot(
        self,
        connection: Any,
        *,
        account_id: UUID,
        subscription_id: UUID,
        plan_code: str,
        plan_revision: int,
        rule: dict[str, Any],
        now: datetime,
    ) -> UUID:
        existing = await connection.fetchval(
            """
            SELECT retention_snapshot_id
            FROM managed_retention_policy_snapshots
            WHERE account_id = $1
              AND subscription_id = $2
              AND data_class = $3
            ORDER BY effective_at DESC
            LIMIT 1
            """,
            account_id,
            subscription_id,
            rule["data_class"],
        )
        policy = {
            "plan_code": plan_code,
            "plan_revision": plan_revision,
            "data_class": rule["data_class"],
            "cloud_retention_days": rule["cloud_retention_days"],
            "summary_retention_days": rule["summary_retention_days"],
            "local_raw_days": rule["recommended_local_raw_days"],
            "storage_class": rule["storage_class"],
        }
        policy_hash = hashlib.sha256(
            json.dumps(
                policy,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        if existing is not None:
            stored_hash = await connection.fetchval(
                """
                SELECT policy_sha256
                FROM managed_retention_policy_snapshots
                WHERE retention_snapshot_id = $1
                """,
                existing,
            )
            if str(stored_hash).strip() == policy_hash:
                return existing
        snapshot_id = uuid4()
        await connection.execute(
            """
            INSERT INTO managed_retention_policy_snapshots (
                retention_snapshot_id,
                account_id,
                subscription_id,
                plan_code,
                plan_revision,
                data_class,
                cloud_retention_days,
                summary_retention_days,
                local_raw_days,
                storage_class,
                policy_sha256,
                effective_at,
                created_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12
            )
            """,
            snapshot_id,
            account_id,
            subscription_id,
            plan_code,
            plan_revision,
            rule["data_class"],
            rule["cloud_retention_days"],
            rule["summary_retention_days"],
            rule["recommended_local_raw_days"],
            rule["storage_class"],
            policy_hash,
            now,
        )
        return snapshot_id

    async def ensure_installation(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        installation_token_hash: str,
    ) -> dict[str, Any]:
        if re.fullmatch(r"[0-9a-f]{64}", installation_token_hash) is None:
            raise ManagedForbiddenError("managed installation credential was rejected")
        row = await self._pool().fetchrow(
            """
            UPDATE managed_account_installations installation
            SET last_seen_at = GREATEST(last_seen_at, clock_timestamp())
            FROM installation_credentials credential
            WHERE installation.account_id = $1
              AND installation.installation_id = $2
              AND installation.status IN ('active', 'limited')
              AND credential.installation_id = installation.installation_id
              AND credential.token_hash = $3
              AND credential.revoked_at IS NULL
              AND credential.updated_at >= installation.token_valid_after
            RETURNING installation.installation_id,
                      installation.platform,
                      installation.status,
                      installation.attestation_state,
                      installation.registered_at,
                      installation.last_seen_at
            """,
            principal.account_id,
            installation_id,
            installation_token_hash,
        )
        if row is None:
            raise ManagedForbiddenError("managed installation credential was rejected")
        return dict(row)

    async def list_installations(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        rows = await self._pool().fetch(
            """
            SELECT installation_id,
                   platform,
                   status,
                   attestation_state,
                   registered_at,
                   last_seen_at,
                   revoked_at
            FROM managed_account_installations
            WHERE account_id = $1
            ORDER BY
                CASE status WHEN 'active' THEN 0 WHEN 'limited' THEN 1 ELSE 2 END,
                last_seen_at DESC,
                installation_id
            """,
            principal.account_id,
        )
        return [dict(row) for row in rows]

    async def revoke_installation(
        self,
        *,
        principal: ManagedPrincipal,
        requesting_installation_id: str,
        installation_id: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        if requesting_installation_id == installation_id:
            raise ManagedConflictError("the current installation cannot revoke itself")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                requester = await connection.fetchrow(
                    """
                    SELECT status
                    FROM managed_account_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    requesting_installation_id,
                )
                if requester is None or requester["status"] not in {
                    "active",
                    "limited",
                }:
                    raise ManagedForbiddenError(
                        "requesting managed installation is not active"
                    )
                target = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_account_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    installation_id,
                )
                if target is None:
                    raise ManagedNotFoundError("managed installation was not found")
                duplicate = target["status"] == "revoked"
                if not duplicate:
                    now = await connection.fetchval("SELECT clock_timestamp()")
                    target = await connection.fetchrow(
                        """
                        UPDATE managed_account_installations
                        SET status = 'revoked',
                            revoked_at = $3,
                            token_valid_after = $3
                        WHERE account_id = $1 AND installation_id = $2
                        RETURNING *
                        """,
                        principal.account_id,
                        installation_id,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE installation_credentials
                        SET revoked_at = COALESCE(revoked_at, $2),
                            updated_at = GREATEST(updated_at, $2),
                            token_version = token_version + 1
                        WHERE installation_id = $1
                        """,
                        installation_id,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE managed_push_installations
                        SET status = 'revoked',
                            token_ciphertext = 'revoked.' || token_hash,
                            revoked_at = COALESCE(revoked_at, $3),
                            updated_at = GREATEST(updated_at, $3)
                        WHERE account_id = $1
                          AND installation_id = $2
                          AND status <> 'revoked'
                        """,
                        principal.account_id,
                        installation_id,
                        now,
                    )
        public = {
            key: target[key]
            for key in (
                "installation_id",
                "platform",
                "status",
                "attestation_state",
                "registered_at",
                "last_seen_at",
                "revoked_at",
            )
        }
        public["duplicate"] = duplicate
        return public

    async def overview(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            return await self._overview(
                connection,
                account_id=principal.account_id,
            )

    async def _overview(
        self,
        connection: Any,
        *,
        account_id: UUID,
    ) -> dict[str, Any]:
        account = await connection.fetchrow(
            """
            SELECT account.account_id,
                   account.status,
                   account.home_region,
                   account.created_at,
                   subscription.plan_code,
                   subscription.plan_revision,
                   subscription.status AS subscription_status,
                   plan.display_tier,
                   plan.max_total_bytes,
                   plan.max_chunk_bytes,
                   plan.max_uncompressed_chunk_bytes,
                   plan.max_inflight_bytes,
                   plan.max_installations
            FROM managed_accounts account
            JOIN managed_subscriptions subscription
              ON subscription.account_id = account.account_id
             AND subscription.status IN ('trial', 'active', 'grace', 'paused')
            JOIN managed_storage_plans plan
              ON plan.plan_code = subscription.plan_code
             AND plan.revision = subscription.plan_revision
            WHERE account.account_id = $1
            """,
            account_id,
        )
        if account is None:
            raise ManagedConfigurationError(
                "managed account has no current storage plan"
            )
        rules = await connection.fetch(
            """
            SELECT rule.data_class,
                   snapshot.cloud_retention_days,
                   snapshot.summary_retention_days,
                   snapshot.local_raw_days,
                   snapshot.storage_class,
                   rule.server_processing_allowed,
                   rule.maximum_daily_bytes,
                   COALESCE(usage.committed_bytes, 0) AS committed_bytes,
                   COALESCE(usage.reserved_bytes, 0) AS reserved_bytes,
                   COALESCE(usage.object_count, 0) AS object_count
            FROM managed_plan_data_rules rule
            JOIN managed_retention_policy_snapshots snapshot
              ON snapshot.account_id = $1
             AND snapshot.plan_code = rule.plan_code
             AND snapshot.plan_revision = rule.plan_revision
             AND snapshot.data_class = rule.data_class
            LEFT JOIN managed_storage_usage usage
              ON usage.account_id = $1
             AND usage.data_class = rule.data_class
            WHERE rule.plan_code = $2
              AND rule.plan_revision = $3
              AND snapshot.effective_at = (
                  SELECT max(newer.effective_at)
                  FROM managed_retention_policy_snapshots newer
                  WHERE newer.account_id = snapshot.account_id
                    AND newer.data_class = snapshot.data_class
              )
            ORDER BY rule.data_class
            """,
            account_id,
            account["plan_code"],
            account["plan_revision"],
        )
        installations = await connection.fetchval(
            """
            SELECT count(*)
            FROM managed_account_installations
            WHERE account_id = $1 AND status <> 'revoked'
            """,
            account_id,
        )
        public_account = dict(account)
        public_account["account_id"] = str(public_account["account_id"])
        return {
            "account": public_account,
            "storage": {
                "installations": int(installations),
                "rules": [dict(row) for row in rules],
            },
            "entitlements": {
                "managed_storage": True,
                "feature_restrictions": [],
            },
        }

    async def register_source(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        registration: ManagedSourceRegistration,
    ) -> dict[str, Any]:
        self._require_active(principal)
        now = await self.coordination_now()
        try:
            row = await self._pool().fetchrow(
                """
                INSERT INTO managed_sources (
                    account_id,
                    source_id,
                    installation_id,
                    source_kind,
                    platform,
                    logical_source_hash,
                    first_seen_at,
                    last_seen_at
                )
                SELECT $1, $2, $3, $4, $5, $6, $7, $7
                FROM managed_account_installations installation
                WHERE installation.account_id = $1
                  AND installation.installation_id = $3
                  AND installation.status IN ('active', 'limited')
                ON CONFLICT (account_id, source_id) DO UPDATE
                SET last_seen_at = EXCLUDED.last_seen_at
                WHERE managed_sources.installation_id = EXCLUDED.installation_id
                  AND managed_sources.source_kind = EXCLUDED.source_kind
                  AND managed_sources.platform = EXCLUDED.platform
                  AND managed_sources.logical_source_hash
                      = EXCLUDED.logical_source_hash
                RETURNING account_id, source_id, installation_id,
                          source_kind, platform, status,
                          first_seen_at, last_seen_at
                """,
                principal.account_id,
                registration.source_id,
                installation_id,
                registration.source_kind,
                registration.platform,
                registration.logical_source_hash,
                now,
            )
        except Exception as error:
            if getattr(error, "sqlstate", None) == "23505":
                raise ManagedConflictError(
                    "managed source identifier is already registered"
                ) from error
            raise
        if row is None:
            raise ManagedConflictError(
                "managed source registration conflicts with existing state"
            )
        result = dict(row)
        result["account_id"] = str(result["account_id"])
        result["source_id"] = str(result["source_id"])
        return result

    async def register_client_key(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        registration: ManagedClientKeyRegistration,
    ) -> dict[str, Any]:
        self._require_active(principal)
        public_key: bytes | None = None
        if registration.public_key_base64 is not None:
            try:
                public_key = base64.b64decode(
                    registration.public_key_base64,
                    validate=True,
                )
            except ValueError:
                raise ManagedConflictError("client key is not valid base64") from None
        now = await self.coordination_now()
        try:
            row = await self._pool().fetchrow(
                """
                INSERT INTO managed_client_keys (
                    account_id,
                    client_key_id,
                    installation_id,
                    purpose,
                    algorithm,
                    public_key,
                    key_fingerprint,
                    recovery_method,
                    hardware_backed,
                    created_at
                )
                SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
                FROM managed_account_installations installation
                WHERE installation.account_id = $1
                  AND installation.installation_id = $3
                  AND installation.status IN ('active', 'limited')
                ON CONFLICT (account_id, client_key_id) DO UPDATE
                SET client_key_id = managed_client_keys.client_key_id
                WHERE managed_client_keys.installation_id
                          = EXCLUDED.installation_id
                  AND managed_client_keys.purpose = EXCLUDED.purpose
                  AND managed_client_keys.algorithm = EXCLUDED.algorithm
                  AND managed_client_keys.public_key
                      IS NOT DISTINCT FROM EXCLUDED.public_key
                  AND managed_client_keys.key_fingerprint
                      = EXCLUDED.key_fingerprint
                  AND managed_client_keys.recovery_method
                      = EXCLUDED.recovery_method
                RETURNING client_key_id, purpose, algorithm,
                          key_fingerprint, recovery_method,
                          hardware_backed, created_at, revoked_at
                """,
                principal.account_id,
                registration.client_key_id,
                installation_id,
                registration.purpose,
                registration.algorithm,
                public_key,
                registration.key_fingerprint,
                registration.recovery_method,
                registration.hardware_backed,
                now,
            )
        except Exception as error:
            if getattr(error, "sqlstate", None) in {"23505", "23514"}:
                raise ManagedConflictError(
                    "managed client key conflicts with existing state"
                ) from error
            raise
        if row is None:
            raise ManagedConflictError(
                "managed client key conflicts with existing state"
            )
        result = dict(row)
        result["client_key_id"] = str(result["client_key_id"])
        return result

    async def reserve_chunk(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        reservation: ManagedChunkReservation,
    ) -> dict[str, Any]:
        self._require_active(principal)
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-account-quota:{principal.account_id}",
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-chunk:{principal.account_id}:{reservation.chunk_id}",
                )
                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_chunks
                    WHERE account_id = $1
                      AND (
                          chunk_id = $2
                          OR idempotency_key = $3
                      )
                    FOR UPDATE
                    """,
                    principal.account_id,
                    reservation.chunk_id,
                    reservation.request_id,
                )
                if existing is not None:
                    self._assert_matching_chunk(
                        dict(existing),
                        installation_id=installation_id,
                        reservation=reservation,
                    )
                    return self._public_chunk(dict(existing), duplicate=True)

                now = await connection.fetchval("SELECT clock_timestamp()")
                replayed = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_replay_tombstones
                        WHERE tenant_replay_hash = $1
                          AND resource_kind = 'chunk'
                          AND resource_id_hash = $2
                          AND expires_at > $3
                    )
                    """,
                    self._tenant_replay_hash(principal.account_id),
                    self._resource_replay_hash("chunk", reservation.chunk_id),
                    now,
                )
                if replayed:
                    raise ManagedConflictError(
                        "managed chunk was previously deleted and cannot be replayed"
                    )
                contract = await connection.fetchrow(
                    """
                    SELECT account.storage_namespace,
                           plan.max_total_bytes,
                           plan.max_inflight_bytes,
                           plan.max_chunk_bytes,
                           plan.max_uncompressed_chunk_bytes,
                           rule.maximum_daily_bytes,
                           rule.server_processing_allowed,
                           snapshot.retention_snapshot_id,
                           snapshot.cloud_retention_days,
                           chunk_schema.maximum_event_span_seconds,
                           chunk_schema.maximum_streams
                    FROM managed_accounts account
                    JOIN managed_account_installations installation
                      ON installation.account_id = account.account_id
                     AND installation.installation_id = $2
                     AND installation.status IN ('active', 'limited')
                    JOIN managed_subscriptions subscription
                      ON subscription.account_id = account.account_id
                     AND subscription.status IN ('trial', 'active', 'grace')
                    JOIN managed_storage_plans plan
                      ON plan.plan_code = subscription.plan_code
                     AND plan.revision = subscription.plan_revision
                    JOIN managed_plan_data_rules rule
                      ON rule.plan_code = plan.plan_code
                     AND rule.plan_revision = plan.revision
                     AND rule.data_class = $3
                    JOIN managed_chunk_schemas chunk_schema
                      ON chunk_schema.data_class = rule.data_class
                     AND chunk_schema.schema_version = $4
                     AND chunk_schema.status = 'active'
                     AND chunk_schema.content_mode = $5
                     AND chunk_schema.content_type = $6
                     AND $7 = ANY(chunk_schema.allowed_compressions)
                     AND chunk_schema.effective_at <= clock_timestamp()
                     AND (
                         chunk_schema.retired_at IS NULL
                         OR chunk_schema.retired_at > clock_timestamp()
                     )
                    JOIN managed_retention_policy_snapshots snapshot
                      ON snapshot.account_id = account.account_id
                     AND snapshot.subscription_id = subscription.subscription_id
                     AND snapshot.data_class = rule.data_class
                    WHERE account.account_id = $1
                      AND account.status = 'active'
                      AND snapshot.effective_at = (
                          SELECT max(newer.effective_at)
                          FROM managed_retention_policy_snapshots newer
                          WHERE newer.account_id = snapshot.account_id
                            AND newer.data_class = snapshot.data_class
                      )
                    """,
                    principal.account_id,
                    installation_id,
                    reservation.data_class,
                    reservation.schema_version,
                    reservation.content_mode,
                    reservation.content_type,
                    reservation.compression,
                )
                if contract is None:
                    raise ManagedForbiddenError(
                        "managed data class or payload schema is not enabled "
                        "for this account"
                    )
                if (
                    reservation.content_mode == "server_readable"
                    and not contract["server_processing_allowed"]
                ):
                    raise ManagedForbiddenError(
                        "server processing is not enabled for this data class"
                    )
                event_span_seconds = (
                    reservation.event_end - reservation.event_start
                ).total_seconds()
                if event_span_seconds > int(contract["maximum_event_span_seconds"]):
                    raise ManagedConflictError(
                        "chunk event window exceeds its schema contract"
                    )
                if len(reservation.streams) > int(contract["maximum_streams"]):
                    raise ManagedConflictError(
                        "chunk stream count exceeds its schema contract"
                    )
                if reservation.content_mode == "client_encrypted" and (
                    reservation.streams
                    or reservation.compression != "none"
                    or reservation.expected_uncompressed_bytes
                    != reservation.expected_compressed_bytes
                ):
                    raise ManagedConflictError(
                        "encrypted backup must be opaque, uncompressed, and stream-free"
                    )
                registered_streams = await connection.fetch(
                    """
                    SELECT mapping.stream_key,
                           mapping.stream_schema_revision,
                           mapping.required
                    FROM managed_chunk_schema_streams mapping
                    JOIN managed_stream_schemas stream_schema
                      ON stream_schema.data_class = mapping.data_class
                     AND stream_schema.stream_key = mapping.stream_key
                     AND stream_schema.schema_revision
                         = mapping.stream_schema_revision
                     AND stream_schema.status = 'active'
                     AND stream_schema.effective_at <= clock_timestamp()
                     AND (
                         stream_schema.retired_at IS NULL
                         OR stream_schema.retired_at > clock_timestamp()
                     )
                    WHERE mapping.data_class = $1
                      AND mapping.chunk_schema_version = $2
                    """,
                    reservation.data_class,
                    reservation.schema_version,
                )
                allowed_streams = {
                    (
                        str(row["stream_key"]),
                        int(row["stream_schema_revision"]),
                    )
                    for row in registered_streams
                }
                supplied_streams = {
                    (stream.stream_key, stream.schema_revision)
                    for stream in reservation.streams
                }
                required_streams = {
                    (
                        str(row["stream_key"]),
                        int(row["stream_schema_revision"]),
                    )
                    for row in registered_streams
                    if row["required"]
                }
                if not supplied_streams.issubset(
                    allowed_streams
                ) or not required_streams.issubset(supplied_streams):
                    raise ManagedConflictError(
                        "chunk streams do not match the active schema contract"
                    )
                authoritative_snapshot = (
                    reservation.content_mode == "server_readable"
                    and bool(allowed_streams)
                    and supplied_streams == allowed_streams
                )
                if reservation.expected_compressed_bytes > int(
                    contract["max_chunk_bytes"]
                ):
                    raise ManagedQuotaExceededError(
                        maximum_bytes=int(contract["max_chunk_bytes"]),
                        used_bytes=reservation.expected_compressed_bytes,
                    )
                if reservation.expected_uncompressed_bytes > int(
                    contract["max_uncompressed_chunk_bytes"]
                ):
                    raise ManagedQuotaExceededError(
                        maximum_bytes=int(contract["max_uncompressed_chunk_bytes"]),
                        used_bytes=reservation.expected_uncompressed_bytes,
                    )
                if reservation.event_end > now + timedelta(days=1):
                    raise ManagedConflictError(
                        "chunk event window is too far in the future"
                    )
                source_exists = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_sources
                        WHERE account_id = $1
                          AND source_id = $2
                          AND installation_id = $3
                          AND status = 'active'
                    )
                    """,
                    principal.account_id,
                    reservation.source_id,
                    installation_id,
                )
                if not source_exists:
                    raise ManagedNotFoundError("managed source was not found")
                if reservation.client_key_id is not None:
                    key_exists = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM managed_client_keys
                            WHERE account_id = $1
                              AND client_key_id = $2
                              AND revoked_at IS NULL
                        )
                        """,
                        principal.account_id,
                        reservation.client_key_id,
                    )
                    if not key_exists:
                        raise ManagedNotFoundError("managed client key was not found")

                usage = await connection.fetchrow(
                    """
                    INSERT INTO managed_storage_usage (
                        account_id,
                        data_class
                    ) VALUES ($1, $2)
                    ON CONFLICT (account_id, data_class) DO UPDATE
                    SET data_class = managed_storage_usage.data_class
                    RETURNING committed_bytes,
                              reserved_bytes,
                              object_count,
                              revision
                    """,
                    principal.account_id,
                    reservation.data_class,
                )
                maximum = contract["max_total_bytes"]
                override = await connection.fetchrow(
                    """
                    SELECT maximum_bytes, maximum_daily_bytes
                    FROM managed_quota_overrides
                    WHERE account_id = $1
                      AND data_class = $2
                      AND effective_at <= $3
                      AND (expires_at IS NULL OR expires_at > $3)
                      AND revoked_at IS NULL
                    ORDER BY effective_at DESC
                    LIMIT 1
                    """,
                    principal.account_id,
                    reservation.data_class,
                    now,
                )
                if override is not None:
                    maximum = override["maximum_bytes"]
                usage_rows = await connection.fetch(
                    """
                    SELECT data_class, committed_bytes, reserved_bytes
                    FROM managed_storage_usage
                    WHERE account_id = $1
                    FOR UPDATE
                    """,
                    principal.account_id,
                )
                total_committed = sum(int(row["committed_bytes"]) for row in usage_rows)
                total_reserved = sum(int(row["reserved_bytes"]) for row in usage_rows)
                projected_total = (
                    total_committed
                    + total_reserved
                    + reservation.expected_compressed_bytes
                )
                plan_maximum = contract["max_total_bytes"]
                if plan_maximum is not None and projected_total > int(plan_maximum):
                    raise ManagedQuotaExceededError(
                        maximum_bytes=int(plan_maximum),
                        used_bytes=projected_total,
                    )
                projected_class = (
                    int(usage["committed_bytes"])
                    + int(usage["reserved_bytes"])
                    + reservation.expected_compressed_bytes
                )
                if override is not None and projected_class > int(maximum):
                    raise ManagedQuotaExceededError(
                        maximum_bytes=int(maximum),
                        used_bytes=projected_class,
                    )
                inflight = total_reserved
                if inflight + reservation.expected_compressed_bytes > int(
                    contract["max_inflight_bytes"]
                ):
                    raise ManagedQuotaExceededError(
                        maximum_bytes=int(contract["max_inflight_bytes"]),
                        used_bytes=(inflight + reservation.expected_compressed_bytes),
                    )
                daily_limit = (
                    override["maximum_daily_bytes"]
                    if override is not None
                    and override["maximum_daily_bytes"] is not None
                    else contract["maximum_daily_bytes"]
                )
                utc_day = reservation.event_start.astimezone(UTC).date()
                daily_usage = await connection.fetchrow(
                    """
                    INSERT INTO managed_daily_ingest_usage (
                        account_id,
                        data_class,
                        utc_day
                    ) VALUES ($1, $2, $3)
                    ON CONFLICT (account_id, data_class, utc_day) DO UPDATE
                    SET data_class = managed_daily_ingest_usage.data_class
                    RETURNING accepted_bytes, accepted_objects
                    """,
                    principal.account_id,
                    reservation.data_class,
                    utc_day,
                )
                if daily_limit is not None:
                    projected_daily = (
                        int(daily_usage["accepted_bytes"])
                        + reservation.expected_compressed_bytes
                    )
                    if projected_daily > int(daily_limit):
                        raise ManagedQuotaExceededError(
                            maximum_bytes=int(daily_limit),
                            used_bytes=projected_daily,
                        )
                retention_days = contract["cloud_retention_days"]
                expires_at = (
                    reservation.event_end + timedelta(days=int(retention_days))
                    if retention_days is not None
                    else None
                )
                if expires_at is not None and expires_at <= now:
                    raise ManagedConflictError(
                        "chunk event window is outside managed retention"
                    )
                try:
                    chunk = await connection.fetchrow(
                        """
                        INSERT INTO managed_chunks (
                            chunk_id,
                            account_id,
                            storage_namespace,
                            source_id,
                            installation_id,
                            retention_snapshot_id,
                            client_key_id,
                            data_class,
                            schema_version,
                            idempotency_key,
                            content_mode,
                            authoritative_snapshot,
                            event_start,
                            event_end,
                            compression,
                            content_type,
                            expected_sha256,
                            expected_compressed_bytes,
                            expected_uncompressed_bytes,
                            expires_at,
                            reserved_at
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                            $11, $12, $13, $14, $15, $16, $17, $18, $19, $20,
                            $21
                        )
                        RETURNING *
                        """,
                        reservation.chunk_id,
                        principal.account_id,
                        contract["storage_namespace"],
                        reservation.source_id,
                        installation_id,
                        contract["retention_snapshot_id"],
                        reservation.client_key_id,
                        reservation.data_class,
                        reservation.schema_version,
                        reservation.request_id,
                        reservation.content_mode,
                        authoritative_snapshot,
                        reservation.event_start,
                        reservation.event_end,
                        reservation.compression,
                        reservation.content_type,
                        reservation.expected_sha256,
                        reservation.expected_compressed_bytes,
                        reservation.expected_uncompressed_bytes,
                        expires_at,
                        now,
                    )
                except Exception as error:
                    if getattr(error, "sqlstate", None) == "23505":
                        raise ManagedConflictError(
                            "managed chunk identity is already reserved"
                        ) from error
                    raise
                for stream in reservation.streams:
                    await connection.execute(
                        """
                        INSERT INTO managed_chunk_streams (
                            account_id,
                            chunk_id,
                            stream_key,
                            sample_count,
                            first_event_at,
                            last_event_at,
                            encoded_bytes,
                            schema_revision
                        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                        """,
                        principal.account_id,
                        reservation.chunk_id,
                        stream.stream_key,
                        stream.sample_count,
                        stream.first_event_at,
                        stream.last_event_at,
                        stream.encoded_bytes,
                        stream.schema_revision,
                    )
                ledger_hash = hashlib.sha256(
                    (f"reserve:{principal.account_id}:{reservation.request_id}").encode(
                        "utf-8"
                    )
                ).hexdigest()
                await connection.execute(
                    """
                    INSERT INTO managed_storage_usage_ledger (
                        usage_event_id,
                        account_id,
                        data_class,
                        chunk_id,
                        idempotency_hash,
                        reason,
                        reserved_bytes_delta,
                        occurred_at,
                        purge_after
                    ) VALUES (
                        $1, $2, $3, $4, $5, 'reserve', $6,
                        $7::timestamptz,
                        $7::timestamptz + interval '400 days'
                    )
                    """,
                    uuid4(),
                    principal.account_id,
                    reservation.data_class,
                    reservation.chunk_id,
                    ledger_hash,
                    reservation.expected_compressed_bytes,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_daily_ingest_usage
                    SET accepted_bytes = accepted_bytes + $4,
                        accepted_objects = accepted_objects + 1,
                        revision = revision + 1,
                        updated_at = $5
                    WHERE account_id = $1
                      AND data_class = $2
                      AND utc_day = $3
                    """,
                    principal.account_id,
                    reservation.data_class,
                    utc_day,
                    reservation.expected_compressed_bytes,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_storage_usage
                    SET reserved_bytes = reserved_bytes + $3,
                        revision = revision + 1,
                        updated_at = $4
                    WHERE account_id = $1 AND data_class = $2
                    """,
                    principal.account_id,
                    reservation.data_class,
                    reservation.expected_compressed_bytes,
                    now,
                )
                return self._public_chunk(dict(chunk), duplicate=False)

    @staticmethod
    def _assert_matching_chunk(
        row: dict[str, Any],
        *,
        installation_id: str,
        reservation: ManagedChunkReservation,
    ) -> None:
        expected = {
            "chunk_id": reservation.chunk_id,
            "source_id": reservation.source_id,
            "installation_id": installation_id,
            "data_class": reservation.data_class,
            "schema_version": reservation.schema_version,
            "idempotency_key": reservation.request_id,
            "client_key_id": reservation.client_key_id,
            "content_mode": reservation.content_mode,
            "event_start": reservation.event_start,
            "event_end": reservation.event_end,
            "compression": reservation.compression,
            "content_type": reservation.content_type,
            "expected_sha256": reservation.expected_sha256,
            "expected_compressed_bytes": (reservation.expected_compressed_bytes),
            "expected_uncompressed_bytes": (reservation.expected_uncompressed_bytes),
        }
        for key, value in expected.items():
            stored = row.get(key)
            if hasattr(stored, "strip") and key == "expected_sha256":
                stored = stored.strip()
            if stored != value:
                raise ManagedConflictError(
                    "managed chunk retry changed the reserved content contract"
                )

    async def record_upload_grant(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        chunk_id: UUID,
        capability_hash: str,
        expires_at: datetime,
    ) -> UUID:
        self._require_active(principal)
        grant_id = uuid4()
        request_id = uuid4()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                chunk = await connection.fetchrow(
                    """
                    SELECT expected_sha256, expected_compressed_bytes
                    FROM managed_chunks
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND installation_id = $3
                      AND state IN ('reserved', 'uploading')
                    FOR UPDATE
                    """,
                    principal.account_id,
                    chunk_id,
                    installation_id,
                )
                if chunk is None:
                    raise ManagedConflictError(
                        "managed chunk is not eligible for upload"
                    )
                await connection.execute(
                    """
                    UPDATE managed_upload_grants
                    SET status = 'expired'
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND status = 'issued'
                    """,
                    principal.account_id,
                    chunk_id,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_upload_grants (
                        upload_grant_id,
                        account_id,
                        chunk_id,
                        installation_id,
                        request_id,
                        capability_hash,
                        expected_sha256,
                        expected_bytes,
                        issued_at,
                        expires_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                    """,
                    grant_id,
                    principal.account_id,
                    chunk_id,
                    installation_id,
                    request_id,
                    capability_hash,
                    str(chunk["expected_sha256"]).strip(),
                    chunk["expected_compressed_bytes"],
                    now,
                    expires_at,
                )
                await connection.execute(
                    """
                    UPDATE managed_chunks
                    SET state = 'uploading'
                    WHERE account_id = $1 AND chunk_id = $2
                    """,
                    principal.account_id,
                    chunk_id,
                )
        return grant_id

    async def chunk_for_upload_completion(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        chunk_id: UUID,
    ) -> dict[str, Any]:
        self._require_active(principal)
        row = await self._pool().fetchrow(
            """
            SELECT *
            FROM managed_chunks
            WHERE account_id = $1
              AND chunk_id = $2
              AND installation_id = $3
            """,
            principal.account_id,
            chunk_id,
            installation_id,
        )
        if row is None:
            raise ManagedNotFoundError("managed chunk was not found")
        return dict(row)

    async def complete_chunk_upload(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        chunk_id: UUID,
        metadata: ManagedObjectMetadata,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                chunk = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_chunks
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND installation_id = $3
                    FOR UPDATE
                    """,
                    principal.account_id,
                    chunk_id,
                    installation_id,
                )
                if chunk is None:
                    raise ManagedNotFoundError("managed chunk was not found")
                if chunk["state"] in {"delete_pending", "deleted"}:
                    raise ManagedConflictError(
                        "managed chunk cannot complete from its current state"
                    )
                expected_hash = str(chunk["expected_sha256"]).strip()
                if (
                    metadata.object_key != chunk["object_key"]
                    or metadata.size != chunk["expected_compressed_bytes"]
                    or metadata.content_type != chunk["content_type"]
                    or metadata.metadata.get("noop-sha256") != expected_hash
                ):
                    raise ManagedConflictError(
                        "uploaded object does not match the chunk reservation"
                    )
                if chunk["state"] not in {"reserved", "uploading"}:
                    if (
                        chunk["object_generation"] != metadata.generation
                        or chunk["object_metageneration"] != metadata.metageneration
                        or chunk["object_crc32c"] != metadata.crc32c
                    ):
                        raise ManagedConflictError(
                            "managed chunk object generation changed"
                        )
                    return self._public_chunk(dict(chunk), duplicate=True)
                now = await connection.fetchval("SELECT clock_timestamp()")
                updated = await connection.fetchrow(
                    """
                    UPDATE managed_chunks
                    SET state = 'uploaded',
                        object_generation = $4,
                        object_metageneration = $5,
                        object_crc32c = $6,
                        actual_compressed_bytes = $7,
                        uploaded_at = $8
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND installation_id = $3
                    RETURNING *
                    """,
                    principal.account_id,
                    chunk_id,
                    installation_id,
                    metadata.generation,
                    metadata.metageneration,
                    metadata.crc32c,
                    metadata.size,
                    now,
                )
                ledger_hash = hashlib.sha256(
                    (
                        f"commit:{principal.account_id}:{chunk_id}:"
                        f"{metadata.generation}"
                    ).encode("utf-8")
                ).hexdigest()
                await connection.execute(
                    """
                    INSERT INTO managed_storage_usage_ledger (
                        usage_event_id,
                        account_id,
                        data_class,
                        chunk_id,
                        idempotency_hash,
                        reason,
                        committed_bytes_delta,
                        reserved_bytes_delta,
                        object_count_delta,
                        occurred_at,
                        purge_after
                    ) VALUES (
                        $1, $2, $3, $4, $5, 'commit_upload',
                        $6, -($7::bigint), 1, $8::timestamptz,
                        $8::timestamptz + interval '400 days'
                    )
                    """,
                    uuid4(),
                    principal.account_id,
                    chunk["data_class"],
                    chunk_id,
                    ledger_hash,
                    metadata.size,
                    chunk["expected_compressed_bytes"],
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_daily_ingest_usage (
                        account_id,
                        data_class,
                        utc_day,
                        accepted_bytes,
                        committed_bytes,
                        accepted_objects,
                        committed_objects,
                        updated_at
                    ) VALUES (
                        $1,
                        $2,
                        $3,
                        $4,
                        $5,
                        1,
                        1,
                        $6
                    )
                    ON CONFLICT (account_id, data_class, utc_day) DO UPDATE
                    SET committed_bytes =
                            managed_daily_ingest_usage.committed_bytes
                            + EXCLUDED.committed_bytes,
                        committed_objects =
                            managed_daily_ingest_usage.committed_objects + 1,
                        revision =
                            managed_daily_ingest_usage.revision + 1,
                        updated_at = EXCLUDED.updated_at
                    """,
                    principal.account_id,
                    chunk["data_class"],
                    chunk["event_start"].astimezone(UTC).date(),
                    chunk["expected_compressed_bytes"],
                    metadata.size,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_storage_usage
                    SET committed_bytes = committed_bytes + $3,
                        reserved_bytes = reserved_bytes - $4,
                        object_count = object_count + 1,
                        revision = revision + 1,
                        updated_at = $5
                    WHERE account_id = $1 AND data_class = $2
                    """,
                    principal.account_id,
                    chunk["data_class"],
                    metadata.size,
                    chunk["expected_compressed_bytes"],
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_upload_grants
                    SET status = 'consumed', consumed_at = $3
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND status = 'issued'
                    """,
                    principal.account_id,
                    chunk_id,
                    now,
                )
        return self._public_chunk(dict(updated), duplicate=False)

    async def complete_chunk_upload_for_object(
        self,
        *,
        metadata: ManagedObjectMetadata,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT chunk.account_id,
                   chunk.chunk_id,
                   chunk.installation_id,
                   account.status,
                   account.auth_valid_after
            FROM managed_chunks chunk
            JOIN managed_accounts account USING (account_id)
            WHERE chunk.object_key = $1
            """,
            metadata.object_key,
        )
        if row is None:
            raise ManagedNotFoundError("managed chunk was not found")
        principal = ManagedPrincipal(
            account_id=row["account_id"],
            identity_id=UUID(int=0),
            subject_hash="0" * 64,
            account_status=str(row["status"]),
            auth_valid_after=row["auth_valid_after"],
        )
        return await self.complete_chunk_upload(
            principal=principal,
            installation_id=str(row["installation_id"]),
            chunk_id=row["chunk_id"],
            metadata=metadata,
        )

    async def processing_reconciliation_candidates(
        self,
        *,
        now: datetime,
        batch_size: int,
        minimum_age_seconds: int = 120,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 200:
            raise ValueError("batch_size must be between 1 and 200")
        if not 30 <= minimum_age_seconds <= 86_400:
            raise ValueError("minimum_age_seconds must be between 30 and 86400")
        rows = await self._pool().fetch(
            """
            SELECT chunk.account_id,
                   chunk.chunk_id,
                   chunk.object_key,
                   chunk.object_generation,
                   chunk.state,
                   chunk.uploaded_at
            FROM managed_chunks chunk
            WHERE chunk.state IN ('uploaded', 'validating')
              AND chunk.object_generation IS NOT NULL
              AND chunk.uploaded_at
                    <= $1::timestamptz
                       - make_interval(secs => $2::integer)
              AND NOT EXISTS (
                  SELECT 1
                  FROM managed_processing_attempts attempt
                  WHERE attempt.account_id = chunk.account_id
                    AND attempt.chunk_id = chunk.chunk_id
                    AND (
                        (
                            attempt.status = 'leased'
                            AND attempt.lease_expires_at > $1
                        )
                        OR (
                            attempt.status = 'retryable_error'
                            AND attempt.next_attempt_at > $1
                        )
                    )
              )
            ORDER BY chunk.uploaded_at, chunk.chunk_id
            LIMIT $3
            """,
            now,
            minimum_age_seconds,
            batch_size,
        )
        return [dict(row) for row in rows]

    async def lease_chunk_processing(
        self,
        *,
        object_key: str,
        processor_revision: str,
        queue_event_hash: str,
        lease_token_hash: str,
        now: datetime,
        lease_seconds: int,
    ) -> dict[str, Any] | None:
        if not 10 <= lease_seconds <= 3_600:
            raise ValueError("lease_seconds must be between 10 and 3600")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                chunk = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_chunks
                    WHERE object_key = $1
                    FOR UPDATE
                    """,
                    object_key,
                )
                if chunk is None:
                    raise ManagedNotFoundError("managed chunk was not found")
                if chunk["state"] in {
                    "available",
                    "delete_pending",
                    "deleted",
                }:
                    return None
                if chunk["state"] not in {
                    "uploaded",
                    "validating",
                    "quarantined",
                }:
                    raise ManagedConflictError(
                        "managed chunk is not ready for processing"
                    )
                latest = await connection.fetchrow(
                    """
                    SELECT processing_attempt_id,
                           status,
                           attempt_number,
                           lease_expires_at,
                           next_attempt_at
                    FROM managed_processing_attempts
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND processor_revision = $3
                    ORDER BY attempt_number DESC
                    LIMIT 1
                    FOR UPDATE
                    """,
                    chunk["account_id"],
                    chunk["chunk_id"],
                    processor_revision,
                )
                if (
                    latest is not None
                    and latest["status"] == "leased"
                    and latest["lease_expires_at"] > now
                ):
                    raise ManagedProcessingBusyError(
                        "managed chunk already has an active processing lease"
                    )
                if (
                    latest is not None
                    and latest["status"] == "retryable_error"
                    and latest["next_attempt_at"] is not None
                    and latest["next_attempt_at"] > now
                ):
                    raise ManagedProcessingBusyError(
                        "managed chunk processing retry is not due"
                    )
                if latest is not None and latest["status"] in {
                    "succeeded",
                    "terminal_error",
                }:
                    return None
                if latest is not None and latest["status"] == "leased":
                    await connection.execute(
                        """
                        UPDATE managed_processing_attempts
                        SET status = 'retryable_error',
                            finished_at = $2,
                            next_attempt_at = $2,
                            error_code = 'lease_expired',
                            error_detail_sha256 = $3
                        WHERE processing_attempt_id = $1
                        """,
                        latest["processing_attempt_id"],
                        now,
                        hashlib.sha256(
                            b"processing lease expired before completion"
                        ).hexdigest(),
                    )
                attempt_number = (
                    int(latest["attempt_number"]) + 1 if latest is not None else 1
                )
                attempt_id = uuid4()
                await connection.execute(
                    """
                    INSERT INTO managed_processing_attempts (
                        processing_attempt_id,
                        account_id,
                        chunk_id,
                        processor_revision,
                        queue_event_hash,
                        lease_token_hash,
                        status,
                        attempt_number,
                        started_at,
                        lease_expires_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, 'leased', $7,
                        $8::timestamptz,
                        $8::timestamptz
                            + make_interval(secs => $9::integer)
                    )
                    """,
                    attempt_id,
                    chunk["account_id"],
                    chunk["chunk_id"],
                    processor_revision,
                    queue_event_hash,
                    lease_token_hash,
                    attempt_number,
                    now,
                    lease_seconds,
                )
                if chunk["state"] != "validating":
                    await connection.execute(
                        """
                        UPDATE managed_chunks
                        SET state = 'validating'
                        WHERE account_id = $1 AND chunk_id = $2
                        """,
                        chunk["account_id"],
                        chunk["chunk_id"],
                    )
                streams = await connection.fetch(
                    """
                    SELECT chunk_stream.stream_key,
                           chunk_stream.sample_count,
                           chunk_stream.first_event_at,
                           chunk_stream.last_event_at,
                           chunk_stream.encoded_bytes,
                           chunk_stream.schema_revision,
                           stream_schema.value_schema
                    FROM managed_chunk_streams chunk_stream
                    JOIN managed_stream_schemas stream_schema
                      ON stream_schema.data_class = $3
                     AND stream_schema.stream_key
                         = chunk_stream.stream_key
                     AND stream_schema.schema_revision
                         = chunk_stream.schema_revision
                    WHERE chunk_stream.account_id = $1
                      AND chunk_stream.chunk_id = $2
                    ORDER BY chunk_stream.stream_key
                    """,
                    chunk["account_id"],
                    chunk["chunk_id"],
                    chunk["data_class"],
                )
        result = dict(chunk)
        result["processing_attempt_id"] = attempt_id
        result["processing_attempt_number"] = attempt_number
        result["streams"] = [
            {
                **dict(stream),
                "value_schema": _decoded_json(stream["value_schema"]),
            }
            for stream in streams
        ]
        return result

    async def finish_chunk_processing(
        self,
        *,
        processing_attempt_id: UUID,
        lease_token_hash: str,
        now: datetime,
        succeeded: bool,
        retryable: bool = False,
        error_code: str | None = None,
        error_detail_sha256: str | None = None,
        verified_sha256: str | None = None,
        decompressed_bytes: int | None = None,
        decoded_samples: int | None = None,
    ) -> None:
        if not succeeded and (error_code is None or error_detail_sha256 is None):
            raise ValueError("failed processing requires error details")
        if succeeded and verified_sha256 is None:
            raise ValueError("successful processing requires a verified digest")
        if succeeded and (error_code is not None or error_detail_sha256 is not None):
            raise ValueError("successful processing cannot include error details")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                attempt = await connection.fetchrow(
                    """
                    SELECT attempt.account_id,
                           attempt.chunk_id,
                           attempt.status,
                           chunk.content_mode,
                           chunk.state AS chunk_state,
                           chunk.data_class,
                           chunk.event_start,
                           chunk.event_end,
                           chunk.object_generation,
                           chunk.expected_sha256,
                           chunk.expected_uncompressed_bytes,
                           chunk.verified_sha256
                    FROM managed_processing_attempts attempt
                    JOIN managed_chunks chunk
                      ON chunk.account_id = attempt.account_id
                     AND chunk.chunk_id = attempt.chunk_id
                    WHERE attempt.processing_attempt_id = $1
                      AND attempt.lease_token_hash = $2
                    FOR UPDATE
                    """,
                    processing_attempt_id,
                    lease_token_hash,
                )
                if attempt is None:
                    raise ManagedNotFoundError("managed processing lease was not found")
                if attempt["status"] != "leased":
                    raise ManagedConflictError(
                        "managed processing lease is already finished"
                    )
                processing_status = (
                    "succeeded"
                    if succeeded
                    else ("retryable_error" if retryable else "terminal_error")
                )
                if succeeded:
                    expected_hash = str(attempt["expected_sha256"]).strip()
                    if verified_sha256 != expected_hash:
                        raise ManagedConflictError(
                            "managed processor digest does not match reservation"
                        )
                    if attempt["content_mode"] == "server_readable":
                        if (
                            decompressed_bytes != attempt["expected_uncompressed_bytes"]
                            or decoded_samples is None
                        ):
                            raise ManagedConflictError(
                                "managed processor output does not match "
                                "the readable chunk contract"
                            )
                    elif decompressed_bytes is not None or decoded_samples is not None:
                        raise ManagedConflictError(
                            "encrypted chunk cannot publish decoded output"
                        )
                    if attempt["chunk_state"] == "available":
                        if str(attempt["verified_sha256"]).strip() != verified_sha256:
                            raise ManagedConflictError(
                                "managed chunk was validated with another digest"
                            )
                    else:
                        await self._supersede_exact_chunk_window(
                            connection,
                            account_id=attempt["account_id"],
                            replacement_chunk_id=attempt["chunk_id"],
                            now=now,
                        )
                        updated = await connection.execute(
                            """
                            UPDATE managed_chunks
                            SET state = 'available',
                                verified_sha256 = $3,
                                actual_uncompressed_bytes = CASE
                                    WHEN content_mode = 'server_readable'
                                    THEN $4
                                    ELSE actual_uncompressed_bytes
                                END,
                                sample_count = CASE
                                    WHEN content_mode = 'server_readable'
                                    THEN $5
                                    ELSE sample_count
                                END,
                                validated_at = $6,
                                available_at = $6
                            WHERE account_id = $1
                              AND chunk_id = $2
                              AND state IN ('uploaded', 'validating')
                            """,
                            attempt["account_id"],
                            attempt["chunk_id"],
                            verified_sha256,
                            decompressed_bytes,
                            decoded_samples,
                            now,
                        )
                        if updated != "UPDATE 1":
                            raise ManagedConflictError(
                                "managed chunk cannot complete validation "
                                "from its current state"
                            )
                    available_chunk = await connection.fetchrow(
                        """
                        SELECT *
                        FROM managed_chunks
                        WHERE account_id = $1 AND chunk_id = $2
                        """,
                        attempt["account_id"],
                        attempt["chunk_id"],
                    )
                    await self._append_chunk_change(
                        connection,
                        chunk=available_chunk,
                        operation="available",
                        now=now,
                    )
                await connection.execute(
                    """
                    UPDATE managed_processing_attempts
                    SET status = $3,
                        finished_at = $4,
                        next_attempt_at = CASE
                            WHEN $3 = 'retryable_error'
                            THEN $4::timestamptz + interval '30 seconds'
                            ELSE NULL
                        END,
                        error_code = $5,
                        error_detail_sha256 = $6,
                        decompressed_bytes = $7,
                        decoded_samples = $8
                    WHERE processing_attempt_id = $1
                      AND lease_token_hash = $2
                    """,
                    processing_attempt_id,
                    lease_token_hash,
                    processing_status,
                    now,
                    error_code,
                    error_detail_sha256,
                    decompressed_bytes,
                    decoded_samples,
                )
                if not succeeded and not retryable:
                    await connection.execute(
                        """
                        UPDATE managed_chunks
                        SET state = 'quarantined'
                        WHERE account_id = $1
                          AND chunk_id = $2
                          AND state = 'validating'
                        """,
                        attempt["account_id"],
                        attempt["chunk_id"],
                    )

    async def available_chunk(
        self,
        *,
        principal: ManagedPrincipal,
        chunk_id: UUID,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT *
            FROM managed_chunks
            WHERE account_id = $1
              AND chunk_id = $2
              AND state = 'available'
            """,
            principal.account_id,
            chunk_id,
        )
        if row is None:
            raise ManagedNotFoundError("managed chunk was not found")
        return dict(row)

    async def list_available_chunks(
        self,
        *,
        principal: ManagedPrincipal,
        start: datetime | None,
        end: datetime | None,
        data_class: str | None,
        after_event_start: datetime | None,
        after_chunk_id: UUID | None,
        limit: int,
        snapshot_at: datetime | None = None,
    ) -> list[dict[str, Any]]:
        if (after_event_start is None) != (after_chunk_id is None):
            raise ManagedConflictError("both chunk cursor fields are required")
        rows = await self._pool().fetch(
            """
            SELECT *
            FROM managed_chunks
            WHERE account_id = $1
              AND state = 'available'
              AND (
                  (
                      $7::timestamptz IS NULL
                      AND superseded_by_chunk_id IS NULL
                  )
                  OR (
                      $7::timestamptz IS NOT NULL
                      AND available_at <= $7
                      AND (
                          superseded_at IS NULL
                          OR superseded_at > $7
                      )
                  )
              )
              AND ($2::timestamptz IS NULL OR event_end >= $2)
              AND ($3::timestamptz IS NULL OR event_start < $3)
              AND ($4::text IS NULL OR data_class = $4)
              AND (
                  $5::timestamptz IS NULL
                  OR (event_start, chunk_id) > ($5, $6)
              )
            ORDER BY event_start, chunk_id
            LIMIT $8
            """,
            principal.account_id,
            start,
            end,
            data_class,
            after_event_start,
            after_chunk_id,
            snapshot_at,
            limit,
        )
        return [self._public_chunk(dict(row), duplicate=False) for row in rows]

    async def list_changes(
        self,
        *,
        principal: ManagedPrincipal,
        after_sequence: int,
        limit: int,
    ) -> dict[str, Any]:
        if after_sequence < 0:
            raise ValueError("after_sequence cannot be negative")
        if not 1 <= limit <= 500:
            raise ValueError("limit must be between 1 and 500")
        sequence = await self._pool().fetchrow(
            """
            SELECT last_sequence, minimum_retained_sequence
            FROM managed_account_change_sequences
            WHERE account_id = $1
            """,
            principal.account_id,
        )
        high_watermark = int(sequence["last_sequence"]) if sequence else 0
        minimum_sequence = int(sequence["minimum_retained_sequence"]) if sequence else 1
        if after_sequence < minimum_sequence - 1:
            raise ManagedCursorExpiredError(
                minimum_sequence=minimum_sequence,
            )
        rows = await self._pool().fetch(
            """
            SELECT change.change_sequence,
                   change.change_event_id,
                   change.resource_kind,
                   change.resource_id,
                   change.resource_revision,
                   change.operation,
                   change.content_sha256,
                   change.data_class,
                   change.event_start,
                   change.event_end,
                   change.metadata,
                   change.occurred_at,
                   chunk.source_id AS chunk_source_id,
                   chunk.schema_version AS chunk_schema_version,
                   chunk.content_mode AS chunk_content_mode,
                   chunk.state AS chunk_state,
                   chunk.compression AS chunk_compression,
                   chunk.content_type AS chunk_content_type,
                   chunk.expected_compressed_bytes
                       AS chunk_expected_compressed_bytes,
                   chunk.expected_uncompressed_bytes
                       AS chunk_expected_uncompressed_bytes,
                   chunk.object_generation AS chunk_object_generation,
                   chunk.expires_at AS chunk_expires_at,
                   document.document_kind,
                   document.content_mode AS document_content_mode,
                   document.client_key_id AS document_client_key_id,
                   document.updated_at AS document_updated_at,
                   document.deleted_at AS document_deleted_at
            FROM managed_change_events change
            LEFT JOIN managed_chunks chunk
              ON change.resource_kind = 'chunk'
             AND chunk.account_id = change.account_id
             AND chunk.chunk_id = change.resource_id
            LEFT JOIN managed_documents document
              ON change.resource_kind = 'document'
             AND document.account_id = change.account_id
             AND document.document_id = change.resource_id
             AND document.document_revision = change.resource_revision
            WHERE change.account_id = $1
              AND change.change_sequence > $2
              AND change.change_sequence <= $3
            ORDER BY change.change_sequence
            LIMIT $4
            """,
            principal.account_id,
            after_sequence,
            high_watermark,
            limit + 1,
        )
        has_more = len(rows) > limit
        selected = rows[:limit]
        changes: list[dict[str, Any]] = []
        for row in selected:
            change = {
                "sequence": int(row["change_sequence"]),
                "change_event_id": str(row["change_event_id"]),
                "resource_kind": str(row["resource_kind"]),
                "resource_id": str(row["resource_id"]),
                "resource_revision": row["resource_revision"],
                "operation": str(row["operation"]),
                "content_sha256": (
                    str(row["content_sha256"]).strip()
                    if row["content_sha256"] is not None
                    else None
                ),
                "data_class": row["data_class"],
                "event_start": row["event_start"],
                "event_end": row["event_end"],
                "metadata": _decoded_json(row["metadata"]),
                "occurred_at": row["occurred_at"],
            }
            if row["resource_kind"] == "chunk":
                change["chunk"] = {
                    "chunk_id": str(row["resource_id"]),
                    "source_id": (
                        str(row["chunk_source_id"])
                        if row["chunk_source_id"] is not None
                        else None
                    ),
                    "schema_version": row["chunk_schema_version"],
                    "content_mode": row["chunk_content_mode"],
                    "state": row["chunk_state"],
                    "compression": row["chunk_compression"],
                    "content_type": row["chunk_content_type"],
                    "expected_compressed_bytes": (
                        row["chunk_expected_compressed_bytes"]
                    ),
                    "expected_uncompressed_bytes": (
                        row["chunk_expected_uncompressed_bytes"]
                    ),
                    "object_generation": row["chunk_object_generation"],
                    "expires_at": row["chunk_expires_at"],
                }
            elif row["resource_kind"] == "document":
                change["document"] = {
                    "document_kind": row["document_kind"],
                    "document_id": str(row["resource_id"]),
                    "revision": row["resource_revision"],
                    "content_mode": row["document_content_mode"],
                    "client_key_id": (
                        str(row["document_client_key_id"])
                        if row["document_client_key_id"] is not None
                        else None
                    ),
                    "updated_at": row["document_updated_at"],
                    "deleted_at": row["document_deleted_at"],
                }
            changes.append(change)
        return {
            "changes": changes,
            "minimum_sequence": minimum_sequence,
            "high_watermark": high_watermark,
            "next_sequence": (changes[-1]["sequence"] if changes else after_sequence),
            "has_more": has_more,
        }

    async def record_access_grant(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        chunk_id: UUID,
        request_id: UUID,
        capability_hash: str,
        purpose: str,
        expires_at: datetime,
    ) -> UUID:
        self._require_active(principal)
        grant_id = uuid4()
        try:
            status = await self._pool().execute(
                """
                INSERT INTO managed_object_access_grants (
                    access_grant_id,
                    account_id,
                    installation_id,
                    chunk_id,
                    request_id,
                    capability_hash,
                    purpose,
                    expires_at
                )
                SELECT $1, $2, $3, $4, $5, $6, $7, $8
                FROM managed_chunks chunk
                JOIN managed_account_installations installation
                  ON installation.account_id = chunk.account_id
                 AND installation.installation_id = $3
                 AND installation.status IN ('active', 'limited')
                WHERE chunk.account_id = $2
                  AND chunk.chunk_id = $4
                  AND chunk.state = 'available'
                """,
                grant_id,
                principal.account_id,
                installation_id,
                chunk_id,
                request_id,
                capability_hash,
                purpose,
                expires_at,
            )
        except Exception as error:
            if getattr(error, "sqlstate", None) == "23505":
                raise ManagedConflictError(
                    "managed object access request was already used"
                ) from error
            raise
        if status != "INSERT 0 1":
            raise ManagedNotFoundError("managed chunk was not found")
        return grant_id

    async def mark_chunk_validated(
        self,
        *,
        account_id: UUID,
        chunk_id: UUID,
        verified_sha256: str,
        uncompressed_bytes: int,
        sample_count: int,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await self._supersede_exact_chunk_window(
                    connection,
                    account_id=account_id,
                    replacement_chunk_id=chunk_id,
                    now=now,
                )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_chunks
                    SET state = 'available',
                        verified_sha256 = $3,
                        actual_uncompressed_bytes = $4,
                        sample_count = $5,
                        validated_at = $6,
                        available_at = $6
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND state IN ('uploaded', 'validating')
                      AND expected_sha256 = $3
                      AND expected_uncompressed_bytes = $4
                    RETURNING *
                    """,
                    account_id,
                    chunk_id,
                    verified_sha256,
                    uncompressed_bytes,
                    sample_count,
                    now,
                )
                if row is None:
                    raise ManagedConflictError(
                        "managed chunk validation does not match its reservation"
                    )
                await self._append_chunk_change(
                    connection,
                    chunk=row,
                    operation="available",
                    now=now,
                )
        return self._public_chunk(dict(row), duplicate=False)

    async def mark_encrypted_chunk_available(
        self,
        *,
        account_id: UUID,
        chunk_id: UUID,
        verified_sha256: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await self._supersede_exact_chunk_window(
                    connection,
                    account_id=account_id,
                    replacement_chunk_id=chunk_id,
                    now=now,
                )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_chunks
                    SET state = 'available',
                        verified_sha256 = $3,
                        validated_at = $4,
                        available_at = $4
                    WHERE account_id = $1
                      AND chunk_id = $2
                      AND content_mode = 'client_encrypted'
                      AND state IN ('uploaded', 'validating')
                      AND expected_sha256 = $3
                    RETURNING *
                    """,
                    account_id,
                    chunk_id,
                    verified_sha256,
                    now,
                )
                if row is None:
                    raise ManagedConflictError(
                        "encrypted chunk validation does not match its reservation"
                    )
                await self._append_chunk_change(
                    connection,
                    chunk=row,
                    operation="available",
                    now=now,
                )
        return self._public_chunk(dict(row), duplicate=False)

    async def release_expired_reservations(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        released: list[dict[str, Any]] = []
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    SELECT account_id,
                           chunk_id,
                           data_class,
                           object_key,
                           object_generation,
                           expected_compressed_bytes
                    FROM managed_chunks
                    WHERE state IN ('reserved', 'uploading')
                      AND reservation_expires_at <= $1
                    ORDER BY reservation_expires_at, chunk_id
                    FOR UPDATE SKIP LOCKED
                    LIMIT $2
                    """,
                    now,
                    batch_size,
                )
                for row in rows:
                    await connection.execute(
                        """
                        UPDATE managed_chunks
                        SET state = 'delete_pending',
                            delete_requested_at = $3
                        WHERE account_id = $1 AND chunk_id = $2
                        """,
                        row["account_id"],
                        row["chunk_id"],
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE managed_upload_grants
                        SET status = 'expired'
                        WHERE account_id = $1
                          AND chunk_id = $2
                          AND status = 'issued'
                        """,
                        row["account_id"],
                        row["chunk_id"],
                    )
                    ledger_hash = hashlib.sha256(
                        (f"release:{row['account_id']}:{row['chunk_id']}").encode(
                            "utf-8"
                        )
                    ).hexdigest()
                    await connection.execute(
                        """
                        INSERT INTO managed_storage_usage_ledger (
                            usage_event_id,
                            account_id,
                            data_class,
                            chunk_id,
                            idempotency_hash,
                            reason,
                            reserved_bytes_delta,
                            occurred_at,
                            purge_after
                        ) VALUES (
                            $1, $2, $3, $4, $5,
                            'release_reservation',
                            -($6::bigint),
                            $7::timestamptz,
                            $7::timestamptz + interval '400 days'
                        )
                        """,
                        uuid4(),
                        row["account_id"],
                        row["data_class"],
                        row["chunk_id"],
                        ledger_hash,
                        row["expected_compressed_bytes"],
                        now,
                    )
                    status = await connection.execute(
                        """
                        UPDATE managed_storage_usage
                        SET reserved_bytes = reserved_bytes - $3,
                            revision = revision + 1,
                            updated_at = $4
                        WHERE account_id = $1
                          AND data_class = $2
                          AND reserved_bytes >= $3
                        """,
                        row["account_id"],
                        row["data_class"],
                        row["expected_compressed_bytes"],
                        now,
                    )
                    if status != "UPDATE 1":
                        raise ManagedConflictError(
                            "managed reservation usage is inconsistent"
                        )
                    released.append(dict(row))
        return released

    async def claim_retention_deletions(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        claimed: list[dict[str, Any]] = []
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                accounts = await connection.fetch(
                    """
                    SELECT account_id, min(expires_at) AS earliest_expiry
                    FROM managed_chunks
                    WHERE state IN (
                        'uploaded',
                        'validating',
                        'available',
                        'quarantined'
                    )
                      AND expires_at IS NOT NULL
                      AND expires_at <= $1
                    GROUP BY account_id
                    ORDER BY earliest_expiry, account_id
                    LIMIT $2
                    """,
                    now,
                    batch_size,
                )
                for account in accounts:
                    if len(claimed) >= batch_size:
                        break
                    account_id = account["account_id"]
                    # Restore creation uses the same account lock. Whichever
                    # transaction wins establishes one coherent truth: either
                    # the chunks enter the snapshot, or retention marks them
                    # unavailable before the snapshot is counted.
                    await connection.execute(
                        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                        f"noop-managed-change:{account_id}",
                    )
                    active_restore = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM managed_restore_jobs
                            WHERE account_id = $1
                              AND status = 'running'
                              AND expires_at > $2
                        )
                        """,
                        account_id,
                        now,
                    )
                    if active_restore:
                        continue
                    rows = await connection.fetch(
                        """
                        SELECT account_id,
                               chunk_id,
                               data_class,
                               object_key,
                               object_generation,
                               actual_compressed_bytes
                        FROM managed_chunks
                        WHERE account_id = $1
                          AND state IN (
                              'uploaded',
                              'validating',
                              'available',
                              'quarantined'
                          )
                          AND expires_at IS NOT NULL
                          AND expires_at <= $2
                        ORDER BY expires_at, chunk_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $3
                        """,
                        account_id,
                        now,
                        batch_size - len(claimed),
                    )
                    for row in rows:
                        await connection.execute(
                            """
                            UPDATE managed_chunks
                            SET state = 'delete_pending',
                                delete_requested_at = $3
                            WHERE account_id = $1 AND chunk_id = $2
                            """,
                            row["account_id"],
                            row["chunk_id"],
                            now,
                        )
                        claimed.append(dict(row))
        return claimed

    async def pending_chunk_deletions(
        self,
        *,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        rows = await self._pool().fetch(
            """
            SELECT account_id,
                   chunk_id,
                   data_class,
                   object_key,
                   object_generation,
                   actual_compressed_bytes,
                   delete_requested_at
            FROM managed_chunks
            WHERE state = 'delete_pending'
            ORDER BY delete_requested_at, chunk_id
            LIMIT $1
            """,
            batch_size,
        )
        return [dict(row) for row in rows]

    async def claim_erasure_deletions(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        claimed: list[dict[str, Any]] = []
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                jobs = await connection.fetch(
                    """
                    SELECT *
                    FROM managed_erasure_jobs
                    WHERE status IN ('queued', 'cooling_off', 'running')
                      AND not_before <= $1
                    ORDER BY requested_at, erasure_job_id
                    FOR UPDATE SKIP LOCKED
                    LIMIT 10
                    """,
                    now,
                )
                remaining = batch_size
                for job in jobs:
                    await connection.execute(
                        """
                        UPDATE managed_erasure_jobs
                        SET status = 'running',
                            started_at = COALESCE(started_at, $2)
                        WHERE erasure_job_id = $1
                        """,
                        job["erasure_job_id"],
                        now,
                    )
                    if job["scope"] not in {
                        "raw_chunks",
                        "all_managed_data",
                        "account",
                    }:
                        continue
                    if job["objects_selected"] is None:
                        totals = await connection.fetchrow(
                            """
                            SELECT count(*) AS objects,
                                   COALESCE(
                                       sum(
                                           COALESCE(
                                               actual_compressed_bytes,
                                               expected_compressed_bytes
                                           )
                                       ),
                                       0
                                   ) AS bytes
                            FROM managed_chunks
                            WHERE account_id = $1
                              AND state <> 'deleted'
                            """,
                            job["account_id"],
                        )
                        await connection.execute(
                            """
                            UPDATE managed_erasure_jobs
                            SET objects_selected = $2,
                                bytes_selected = $3
                            WHERE erasure_job_id = $1
                            """,
                            job["erasure_job_id"],
                            int(totals["objects"]),
                            int(totals["bytes"]),
                        )
                    if remaining <= 0:
                        break
                    chunks = await connection.fetch(
                        """
                        SELECT *
                        FROM managed_chunks
                        WHERE account_id = $1
                          AND state NOT IN ('delete_pending', 'deleted')
                        ORDER BY event_start, chunk_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                        """,
                        job["account_id"],
                        remaining,
                    )
                    for chunk in chunks:
                        if chunk["state"] in {"reserved", "uploading"}:
                            ledger_hash = hashlib.sha256(
                                (
                                    f"erasure-release:{job['erasure_job_id']}:"
                                    f"{chunk['chunk_id']}"
                                ).encode("utf-8")
                            ).hexdigest()
                            ledger = await connection.fetchrow(
                                """
                                INSERT INTO managed_storage_usage_ledger (
                                    usage_event_id,
                                    account_id,
                                    data_class,
                                    chunk_id,
                                    idempotency_hash,
                                    reason,
                                    reserved_bytes_delta,
                                    occurred_at,
                                    purge_after
                                ) VALUES (
                                    $1, $2, $3, $4, $5,
                                    'release_reservation',
                                    -($6::bigint),
                                    $7,
                                    $7::timestamptz + interval '400 days'
                                )
                                ON CONFLICT (
                                    account_id,
                                    idempotency_hash
                                ) DO NOTHING
                                RETURNING usage_event_id
                                """,
                                uuid4(),
                                chunk["account_id"],
                                chunk["data_class"],
                                chunk["chunk_id"],
                                ledger_hash,
                                chunk["expected_compressed_bytes"],
                                now,
                            )
                            if ledger is not None:
                                status = await connection.execute(
                                    """
                                    UPDATE managed_storage_usage
                                    SET reserved_bytes =
                                            reserved_bytes - $3,
                                        revision = revision + 1,
                                        updated_at = $4
                                    WHERE account_id = $1
                                      AND data_class = $2
                                      AND reserved_bytes >= $3
                                    """,
                                    chunk["account_id"],
                                    chunk["data_class"],
                                    chunk["expected_compressed_bytes"],
                                    now,
                                )
                                if status != "UPDATE 1":
                                    raise ManagedConflictError(
                                        "managed erasure reservation usage "
                                        "is inconsistent"
                                    )
                        await connection.execute(
                            """
                            UPDATE managed_chunks
                            SET state = 'delete_pending',
                                delete_requested_at = $3
                            WHERE account_id = $1 AND chunk_id = $2
                            """,
                            chunk["account_id"],
                            chunk["chunk_id"],
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_upload_grants
                            SET status = 'revoked',
                                revoked_at = $3
                            WHERE account_id = $1
                              AND chunk_id = $2
                              AND status = 'issued'
                            """,
                            chunk["account_id"],
                            chunk["chunk_id"],
                            now,
                        )
                        claimed.append(
                            {
                                "erasure_job_id": job["erasure_job_id"],
                                "account_id": chunk["account_id"],
                                "chunk_id": chunk["chunk_id"],
                            }
                        )
                    remaining -= len(chunks)
                    await connection.execute(
                        """
                        INSERT INTO managed_erasure_targets (
                            erasure_job_id,
                            target_kind,
                            target_partition,
                            status,
                            selected_count,
                            attempts,
                            updated_at
                        ) VALUES (
                            $1,
                            'object_storage',
                            'managed_chunks',
                            'running',
                            $2,
                            1,
                            $3
                        )
                        ON CONFLICT (
                            erasure_job_id,
                            target_kind,
                            target_partition
                        ) DO UPDATE
                        SET status = 'running',
                            selected_count = COALESCE(
                                managed_erasure_targets.selected_count,
                                EXCLUDED.selected_count
                            ),
                            attempts =
                                managed_erasure_targets.attempts + 1,
                            updated_at = EXCLUDED.updated_at
                        """,
                        job["erasure_job_id"],
                        job["objects_selected"],
                        now,
                    )
        return claimed

    async def finalize_erasure_jobs(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")

        def affected(status: str) -> int:
            try:
                return int(status.rsplit(" ", maxsplit=1)[-1])
            except ValueError:
                return 0

        completed: list[dict[str, Any]] = []
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                jobs = await connection.fetch(
                    """
                    SELECT *
                    FROM managed_erasure_jobs
                    WHERE status IN ('running', 'verifying')
                    ORDER BY requested_at, erasure_job_id
                    FOR UPDATE SKIP LOCKED
                    LIMIT $1
                    """,
                    min(batch_size, 50),
                )
                for job in jobs:
                    account_id = job["account_id"]
                    scope = str(job["scope"])
                    if scope == "account":
                        identity_target_exists = await connection.fetchval(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM managed_erasure_targets
                                WHERE erasure_job_id = $1
                                  AND target_kind = 'identity'
                                  AND target_partition = 'firebase_auth'
                                  AND status IN ('pending', 'running')
                            )
                            """,
                            job["erasure_job_id"],
                        )
                        if identity_target_exists:
                            continue
                    includes_raw = scope in {
                        "raw_chunks",
                        "all_managed_data",
                        "account",
                    }
                    if includes_raw:
                        pending = await connection.fetchval(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM managed_chunks
                                WHERE account_id = $1
                                  AND state <> 'deleted'
                            )
                            """,
                            account_id,
                        )
                        if pending:
                            continue
                    if scope in {"all_managed_data", "account"}:
                        pending_exports = await connection.fetchval(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM managed_export_jobs
                                WHERE account_id = $1
                                  AND status = 'completed'
                                  AND output_generation IS NOT NULL
                            )
                            """,
                            account_id,
                        )
                        if pending_exports:
                            continue
                    await connection.execute(
                        """
                        UPDATE managed_erasure_jobs
                        SET status = 'verifying'
                        WHERE erasure_job_id = $1
                        """,
                        job["erasure_job_id"],
                    )
                    database_rows = 0
                    if scope in {
                        "derived_data",
                        "all_managed_data",
                        "account",
                    }:
                        for statement in (
                            "DELETE FROM managed_daily_aggregates "
                            "WHERE account_id = $1",
                            "DELETE FROM managed_sleep_summaries WHERE account_id = $1",
                            "DELETE FROM managed_workout_summaries "
                            "WHERE account_id = $1",
                            "DELETE FROM managed_aggregate_inputs "
                            "WHERE account_id = $1",
                            "DELETE FROM managed_aggregate_provenance "
                            "WHERE account_id = $1",
                        ):
                            database_rows += affected(
                                await connection.execute(
                                    statement,
                                    account_id,
                                )
                            )
                    if scope in {"all_managed_data", "account"}:
                        for statement in (
                            "DELETE FROM managed_document_heads WHERE account_id = $1",
                            "DELETE FROM managed_documents WHERE account_id = $1",
                            "DELETE FROM managed_sync_checkpoints "
                            "WHERE account_id = $1",
                            "DELETE FROM managed_object_access_grants "
                            "WHERE account_id = $1",
                            "DELETE FROM managed_upload_grants WHERE account_id = $1",
                            "DELETE FROM managed_restore_jobs WHERE account_id = $1",
                            "DELETE FROM managed_export_jobs WHERE account_id = $1",
                            "DELETE FROM managed_social_profiles WHERE account_id = $1",
                        ):
                            database_rows += affected(
                                await connection.execute(
                                    statement,
                                    account_id,
                                )
                            )
                    if scope == "account":
                        database_rows += affected(
                            await connection.execute(
                                """
                                DELETE FROM managed_audit_events
                                WHERE account_id = $1
                                """,
                                account_id,
                            )
                        )
                        database_rows += affected(
                            await connection.execute(
                                """
                                DELETE FROM managed_support_access_grants
                                WHERE account_id = $1
                                """,
                                account_id,
                            )
                        )
                        database_rows += affected(
                            await connection.execute(
                                """
                                DELETE FROM managed_consent_events
                                WHERE account_id = $1
                                """,
                                account_id,
                            )
                        )
                        await connection.execute(
                            """
                            UPDATE managed_erasure_jobs
                            SET requested_by_identity_id = NULL
                            WHERE account_id = $1
                            """,
                            account_id,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_external_identities
                            SET status = 'revoked',
                                revoked_at = COALESCE(revoked_at, $2)
                            WHERE account_id = $1
                            """,
                            account_id,
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_account_installations
                            SET status = 'revoked',
                                revoked_at = COALESCE(revoked_at, $2),
                                token_valid_after = $2
                            WHERE account_id = $1
                            """,
                            account_id,
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_push_installations
                            SET status = 'revoked',
                                token_ciphertext = 'revoked.' || token_hash,
                                revoked_at = COALESCE(revoked_at, $2),
                                updated_at = GREATEST(updated_at, $2)
                            WHERE account_id = $1
                            """,
                            account_id,
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_subscriptions
                            SET status = 'expired',
                                provider_customer_hash = NULL,
                                provider_subscription_hash = NULL,
                                updated_at = $2
                            WHERE account_id = $1
                            """,
                            account_id,
                            now,
                        )
                        await connection.execute(
                            """
                            UPDATE managed_accounts
                            SET status = 'erased',
                                erased_at = $2,
                                auth_valid_after = $2,
                                updated_at = $2
                            WHERE account_id = $1
                            """,
                            account_id,
                            now,
                        )
                    elif scope == "all_managed_data":
                        await connection.execute(
                            """
                            UPDATE managed_accounts
                            SET status = 'active',
                                erasure_requested_at = NULL,
                                updated_at = $2
                            WHERE account_id = $1
                              AND status = 'erasure_pending'
                            """,
                            account_id,
                            now,
                        )
                    objects_deleted = (
                        int(job["objects_selected"] or 0) if includes_raw else 0
                    )
                    bytes_deleted = (
                        int(job["bytes_selected"] or 0) if includes_raw else 0
                    )
                    await connection.execute(
                        """
                        INSERT INTO managed_erasure_targets (
                            erasure_job_id,
                            target_kind,
                            target_partition,
                            status,
                            selected_count,
                            deleted_count,
                            attempts,
                            updated_at,
                            completed_at
                        ) VALUES (
                            $1,
                            'database',
                            'managed_account',
                            'completed',
                            $2,
                            $2,
                            1,
                            $3,
                            $3
                        )
                        ON CONFLICT (
                            erasure_job_id,
                            target_kind,
                            target_partition
                        ) DO UPDATE
                        SET status = 'completed',
                            selected_count = EXCLUDED.selected_count,
                            deleted_count = EXCLUDED.deleted_count,
                            updated_at = EXCLUDED.updated_at,
                            completed_at = EXCLUDED.completed_at
                        """,
                        job["erasure_job_id"],
                        database_rows,
                        now,
                    )
                    if includes_raw:
                        await connection.execute(
                            """
                            UPDATE managed_erasure_targets
                            SET status = 'completed',
                                deleted_count = COALESCE(selected_count, 0),
                                updated_at = $2,
                                completed_at = $2
                            WHERE erasure_job_id = $1
                              AND target_kind = 'object_storage'
                              AND target_partition = 'managed_chunks'
                            """,
                            job["erasure_job_id"],
                            now,
                        )
                    if scope == "account":
                        if job["identity_deletion_ticket"] is None:
                            raise ManagedConfigurationError(
                                "account erasure is missing its identity deletion ticket"
                            )
                        await connection.execute(
                            """
                            UPDATE managed_erasure_jobs
                            SET objects_deleted = $2,
                                bytes_deleted = $3,
                                database_rows_deleted =
                                    database_rows_deleted + $4
                            WHERE erasure_job_id = $1
                            """,
                            job["erasure_job_id"],
                            objects_deleted,
                            bytes_deleted,
                            database_rows,
                        )
                        await connection.execute(
                            """
                            INSERT INTO managed_erasure_targets (
                                erasure_job_id,
                                target_kind,
                                target_partition,
                                status,
                                selected_count,
                                deleted_count,
                                attempts,
                                updated_at
                            ) VALUES (
                                $1,
                                'identity',
                                'firebase_auth',
                                'pending',
                                1,
                                0,
                                0,
                                $2
                            )
                            ON CONFLICT (
                                erasure_job_id,
                                target_kind,
                                target_partition
                            ) DO NOTHING
                            """,
                            job["erasure_job_id"],
                            now,
                        )
                        continue
                    finished = await connection.fetchrow(
                        """
                        UPDATE managed_erasure_jobs
                        SET status = 'completed',
                            objects_deleted = $2,
                            bytes_deleted = $3,
                            database_rows_deleted =
                                database_rows_deleted + $4,
                            completed_at = $5
                        WHERE erasure_job_id = $1
                        RETURNING *
                        """,
                        job["erasure_job_id"],
                        objects_deleted,
                        bytes_deleted,
                        database_rows,
                        now,
                    )
                    completed.append(dict(finished))
        return completed

    async def pending_identity_deletions(
        self,
        *,
        batch_size: int,
        now: datetime,
    ) -> list[dict[str, Any]]:
        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                rows = await connection.fetch(
                    """
                    SELECT job.erasure_job_id,
                           job.account_id,
                           job.request_id,
                           job.identity_deletion_ticket
                    FROM managed_erasure_jobs job
                    JOIN managed_erasure_targets target
                      ON target.erasure_job_id = job.erasure_job_id
                     AND target.target_kind = 'identity'
                     AND target.target_partition = 'firebase_auth'
                    WHERE job.scope = 'account'
                      AND job.status = 'verifying'
                      AND job.identity_deletion_ticket IS NOT NULL
                      AND target.status IN ('pending', 'running')
                    ORDER BY job.requested_at, job.erasure_job_id
                    FOR UPDATE OF job, target SKIP LOCKED
                    LIMIT $1
                    """,
                    batch_size,
                )
                for row in rows:
                    await connection.execute(
                        """
                        UPDATE managed_erasure_targets
                        SET status = 'running',
                            attempts = attempts + 1,
                            updated_at = $2
                        WHERE erasure_job_id = $1
                          AND target_kind = 'identity'
                          AND target_partition = 'firebase_auth'
                        """,
                        row["erasure_job_id"],
                        now,
                    )
        return [dict(row) for row in rows]

    async def mark_identity_deletion_succeeded(
        self,
        *,
        account_id: UUID,
        erasure_job_id: UUID,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                job = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_erasure_jobs
                    WHERE account_id = $1 AND erasure_job_id = $2
                    FOR UPDATE
                    """,
                    account_id,
                    erasure_job_id,
                )
                if job is None:
                    raise ManagedNotFoundError("managed erasure was not found")
                if job["status"] == "completed":
                    return dict(job)
                if job["scope"] != "account" or job["status"] != "verifying":
                    raise ManagedConflictError(
                        "managed identity deletion is not pending"
                    )
                target_status = await connection.execute(
                    """
                    UPDATE managed_erasure_targets
                    SET status = 'completed',
                        deleted_count = 1,
                        updated_at = $2,
                        completed_at = $2
                    WHERE erasure_job_id = $1
                      AND target_kind = 'identity'
                      AND target_partition = 'firebase_auth'
                      AND status IN ('pending', 'running')
                    """,
                    erasure_job_id,
                    now,
                )
                if target_status != "UPDATE 1":
                    raise ManagedConflictError(
                        "managed identity deletion target is not pending"
                    )
                identity_delete_status = await connection.execute(
                    """
                    DELETE FROM managed_external_identities
                    WHERE account_id = $1
                    """,
                    account_id,
                )
                try:
                    deleted_identity_rows = int(
                        identity_delete_status.rsplit(" ", maxsplit=1)[-1]
                    )
                except ValueError:
                    deleted_identity_rows = 0
                finished = await connection.fetchrow(
                    """
                    UPDATE managed_erasure_jobs
                    SET status = 'completed',
                        identity_deletion_ticket = NULL,
                        error_code = NULL,
                        error_detail_sha256 = NULL,
                        database_rows_deleted =
                            database_rows_deleted + $3,
                        completed_at = $4
                    WHERE account_id = $1 AND erasure_job_id = $2
                    RETURNING *
                    """,
                    account_id,
                    erasure_job_id,
                    deleted_identity_rows,
                    now,
                )
        return dict(finished)

    async def mark_identity_deletion_failed(
        self,
        *,
        account_id: UUID,
        erasure_job_id: UUID,
        error_detail_sha256: str,
        now: datetime,
    ) -> None:
        if not re.fullmatch(r"[0-9a-f]{64}", error_detail_sha256):
            raise ValueError("identity deletion error digest is invalid")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    """
                    UPDATE managed_erasure_targets
                    SET status = 'pending',
                        updated_at = $3
                    WHERE erasure_job_id = $2
                      AND target_kind = 'identity'
                      AND target_partition = 'firebase_auth'
                      AND status = 'running'
                      AND EXISTS (
                          SELECT 1
                          FROM managed_erasure_jobs job
                          WHERE job.account_id = $1
                            AND job.erasure_job_id = $2
                            AND job.status = 'verifying'
                      )
                    """,
                    account_id,
                    erasure_job_id,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_erasure_jobs
                    SET error_code = 'identity_provider_unavailable',
                        error_detail_sha256 = $3
                    WHERE account_id = $1
                      AND erasure_job_id = $2
                      AND status = 'verifying'
                    """,
                    account_id,
                    erasure_job_id,
                    error_detail_sha256,
                )

    async def mark_chunk_deleted(
        self,
        *,
        account_id: UUID,
        chunk_id: UUID,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_chunks
                    WHERE account_id = $1 AND chunk_id = $2
                    FOR UPDATE
                    """,
                    account_id,
                    chunk_id,
                )
                if row is None:
                    raise ManagedNotFoundError("managed chunk was not found")
                if row["state"] == "deleted":
                    return self._public_chunk(dict(row), duplicate=True)
                if row["state"] != "delete_pending":
                    raise ManagedConflictError("managed chunk is not pending deletion")
                committed = int(row["actual_compressed_bytes"] or 0)
                if committed > 0:
                    ledger_hash = hashlib.sha256(
                        (
                            f"delete:{account_id}:{chunk_id}:{row['object_generation']}"
                        ).encode("utf-8")
                    ).hexdigest()
                    await connection.execute(
                        """
                        INSERT INTO managed_storage_usage_ledger (
                            usage_event_id,
                            account_id,
                            data_class,
                            chunk_id,
                            idempotency_hash,
                            reason,
                            committed_bytes_delta,
                            object_count_delta,
                            occurred_at,
                            purge_after
                        ) VALUES (
                            $1, $2, $3, $4, $5,
                            'delete_object',
                            -($6::bigint),
                            -1,
                            $7::timestamptz,
                            $7::timestamptz + interval '400 days'
                        )
                        """,
                        uuid4(),
                        account_id,
                        row["data_class"],
                        chunk_id,
                        ledger_hash,
                        committed,
                        now,
                    )
                    status = await connection.execute(
                        """
                        UPDATE managed_storage_usage
                        SET committed_bytes = committed_bytes - $3,
                            object_count = object_count - 1,
                            revision = revision + 1,
                            updated_at = $4
                        WHERE account_id = $1
                          AND data_class = $2
                          AND committed_bytes >= $3
                          AND object_count >= 1
                        """,
                        account_id,
                        row["data_class"],
                        committed,
                        now,
                    )
                    if status != "UPDATE 1":
                        raise ManagedConflictError(
                            "managed committed usage is inconsistent"
                        )
                deleted = await connection.fetchrow(
                    """
                    UPDATE managed_chunks
                    SET state = 'deleted',
                        deleted_at = $3
                    WHERE account_id = $1 AND chunk_id = $2
                    RETURNING *
                    """,
                    account_id,
                    chunk_id,
                    now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_replay_tombstones (
                        replay_tombstone_id,
                        tenant_replay_hash,
                        resource_kind,
                        resource_id_hash,
                        content_sha256,
                        deletion_reason,
                        deleted_at,
                        expires_at
                    ) VALUES (
                        $1, $2, 'chunk', $3, $4, $5, $6,
                        $6::timestamptz + interval '800 days'
                    )
                    ON CONFLICT (
                        tenant_replay_hash,
                        resource_kind,
                        resource_id_hash
                    ) DO UPDATE
                    SET content_sha256 = EXCLUDED.content_sha256,
                        deletion_reason = EXCLUDED.deletion_reason,
                        deleted_at = LEAST(
                            managed_replay_tombstones.deleted_at,
                            EXCLUDED.deleted_at
                        ),
                        expires_at = GREATEST(
                            managed_replay_tombstones.expires_at,
                            EXCLUDED.expires_at
                        )
                    """,
                    uuid4(),
                    self._tenant_replay_hash(account_id),
                    self._resource_replay_hash("chunk", chunk_id),
                    str(row["expected_sha256"]).strip(),
                    (
                        "retention"
                        if row["expires_at"] is not None and row["expires_at"] <= now
                        else "user_delete"
                    ),
                    now,
                )
                await self._append_chunk_change(
                    connection,
                    chunk=deleted,
                    operation="deleted",
                    now=now,
                )
        return self._public_chunk(dict(deleted), duplicate=False)

    async def put_document(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        mutation: ManagedDocumentMutation,
    ) -> dict[str, Any]:
        self._require_active(principal)
        revision = mutation.base_revision + 1
        idempotency_hash = hashlib.sha256(
            (f"change:document:{principal.account_id}:{mutation.request_id}").encode(
                "utf-8"
            )
        ).hexdigest()
        payload_json = mutation.payload_json
        payload_ciphertext: bytes | None = None
        if mutation.deleted:
            digest = hashlib.sha256(
                (
                    f"deleted:{mutation.document_kind}:"
                    f"{mutation.document_id}:{revision}"
                ).encode("utf-8")
            ).hexdigest()
        elif mutation.content_mode == "server_readable":
            try:
                canonical = json.dumps(
                    payload_json,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                    allow_nan=False,
                ).encode("utf-8")
            except (TypeError, ValueError):
                raise ManagedConflictError(
                    "managed document JSON is not canonicalizable"
                ) from None
            if len(canonical) > 1_000_000:
                raise ManagedConflictError("managed document payload is too large")
            digest = hashlib.sha256(canonical).hexdigest()
        else:
            try:
                payload_ciphertext = base64.b64decode(
                    mutation.payload_ciphertext_base64 or "",
                    validate=True,
                )
            except (ValueError, TypeError):
                raise ManagedConflictError(
                    "managed document ciphertext is not valid base64"
                ) from None
            if not 17 <= len(payload_ciphertext) <= 1_048_576:
                raise ManagedConflictError(
                    "managed document ciphertext size is invalid"
                )
            digest = hashlib.sha256(payload_ciphertext).hexdigest()
        if mutation.content_sha256 is not None and mutation.content_sha256 != digest:
            raise ManagedConflictError(
                "managed document digest does not match its payload"
            )

        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    (
                        f"noop-managed-document:{principal.account_id}:"
                        f"{mutation.document_kind}:{mutation.document_id}"
                    ),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                if mutation.updated_at > now + timedelta(days=1):
                    raise ManagedConflictError(
                        "managed document timestamp is too far in the future"
                    )
                prior_request = await connection.fetchrow(
                    """
                    SELECT resource_id,
                           resource_revision,
                           operation,
                           content_sha256
                    FROM managed_change_events
                    WHERE account_id = $1
                      AND idempotency_hash = $2
                    """,
                    principal.account_id,
                    idempotency_hash,
                )
                expected_operation = "tombstone" if mutation.deleted else "upsert"
                if prior_request is not None and (
                    prior_request["resource_id"] != mutation.document_id
                    or int(prior_request["resource_revision"]) != revision
                    or prior_request["operation"] != expected_operation
                    or str(prior_request["content_sha256"]).strip() != digest
                ):
                    raise ManagedConflictError("managed document request id was reused")
                installation_exists = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_account_installations
                        WHERE account_id = $1
                          AND installation_id = $2
                          AND status IN ('active', 'limited')
                    )
                    """,
                    principal.account_id,
                    installation_id,
                )
                if not installation_exists:
                    raise ManagedNotFoundError("managed installation was not found")
                if mutation.client_key_id is not None:
                    key_exists = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM managed_client_keys
                            WHERE account_id = $1
                              AND client_key_id = $2
                              AND revoked_at IS NULL
                        )
                        """,
                        principal.account_id,
                        mutation.client_key_id,
                    )
                    if not key_exists:
                        raise ManagedNotFoundError("managed client key was not found")

                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_documents
                    WHERE account_id = $1
                      AND document_kind = $2
                      AND document_id = $3
                      AND document_revision = $4
                    """,
                    principal.account_id,
                    mutation.document_kind,
                    mutation.document_id,
                    revision,
                )
                if existing is not None:
                    if (
                        str(existing["content_sha256"]).strip() != digest
                        or existing["content_mode"] != mutation.content_mode
                        or existing["client_key_id"] != mutation.client_key_id
                        or (existing["deleted_at"] is not None) != mutation.deleted
                    ):
                        raise ManagedConflictError(
                            "managed document revision already has different content"
                        )
                    return self._public_document(
                        dict(existing),
                        duplicate=True,
                    )

                head = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_document_heads
                    WHERE account_id = $1
                      AND document_kind = $2
                      AND document_id = $3
                    FOR UPDATE
                    """,
                    principal.account_id,
                    mutation.document_kind,
                    mutation.document_id,
                )
                current_revision = (
                    int(head["current_revision"]) if head is not None else 0
                )
                if current_revision != mutation.base_revision:
                    raise ManagedConflictError(
                        "managed document changed on another device"
                    )
                stored_updated_at = max(
                    mutation.updated_at,
                    head["updated_at"] if head is not None else mutation.updated_at,
                )
                deleted_at = now if mutation.deleted else None
                document = await connection.fetchrow(
                    """
                    INSERT INTO managed_documents (
                        account_id,
                        document_kind,
                        document_id,
                        document_revision,
                        origin_installation_id,
                        content_mode,
                        client_key_id,
                        content_sha256,
                        payload_json,
                        payload_ciphertext,
                        updated_at,
                        deleted_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8,
                        $9::jsonb, $10, $11, $12
                    )
                    RETURNING *
                    """,
                    principal.account_id,
                    mutation.document_kind,
                    mutation.document_id,
                    revision,
                    installation_id,
                    mutation.content_mode,
                    mutation.client_key_id,
                    digest,
                    (
                        json.dumps(
                            payload_json,
                            sort_keys=True,
                            separators=(",", ":"),
                            ensure_ascii=False,
                            allow_nan=False,
                        )
                        if payload_json is not None
                        else None
                    ),
                    payload_ciphertext,
                    stored_updated_at,
                    deleted_at,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_document_heads (
                        account_id,
                        document_kind,
                        document_id,
                        current_revision,
                        content_sha256,
                        origin_installation_id,
                        updated_at,
                        deleted_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8
                    )
                    ON CONFLICT (
                        account_id,
                        document_kind,
                        document_id
                    ) DO UPDATE
                    SET current_revision = EXCLUDED.current_revision,
                        content_sha256 = EXCLUDED.content_sha256,
                        origin_installation_id =
                            EXCLUDED.origin_installation_id,
                        updated_at = EXCLUDED.updated_at,
                        deleted_at = EXCLUDED.deleted_at
                    """,
                    principal.account_id,
                    mutation.document_kind,
                    mutation.document_id,
                    revision,
                    digest,
                    installation_id,
                    stored_updated_at,
                    deleted_at,
                )
                await connection.fetchval(
                    """
                    SELECT noop_managed_append_change(
                        $1,
                        $2::char(64),
                        'document',
                        $3,
                        $4,
                        $5,
                        $6::char(64),
                        'user_documents',
                        NULL,
                        NULL,
                        $7::jsonb,
                        $8,
                        $8::timestamptz + interval '400 days'
                    )
                    """,
                    principal.account_id,
                    idempotency_hash,
                    mutation.document_id,
                    revision,
                    "tombstone" if mutation.deleted else "upsert",
                    digest,
                    json.dumps(
                        {
                            "document_kind": mutation.document_kind,
                            "origin_installation_id": installation_id,
                        },
                        sort_keys=True,
                        separators=(",", ":"),
                    ),
                    now,
                )
        return self._public_document(dict(document), duplicate=False)

    async def get_document(
        self,
        *,
        principal: ManagedPrincipal,
        document_kind: str,
        document_id: UUID,
        revision: int | None = None,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT document.*
            FROM managed_documents document
            LEFT JOIN managed_document_heads head
              ON head.account_id = document.account_id
             AND head.document_kind = document.document_kind
             AND head.document_id = document.document_id
            WHERE document.account_id = $1
              AND document.document_kind = $2
              AND document.document_id = $3
              AND document.document_revision = COALESCE(
                    $4,
                    head.current_revision
                  )
            """,
            principal.account_id,
            document_kind,
            document_id,
            revision,
        )
        if row is None:
            raise ManagedNotFoundError("managed document was not found")
        return self._public_document(dict(row), duplicate=False)

    async def list_documents(
        self,
        *,
        principal: ManagedPrincipal,
        document_kind: str | None,
        include_deleted: bool,
        after_updated_at: datetime | None,
        after_document_kind: str | None,
        after_document_id: UUID | None,
        snapshot_at: datetime | None,
        limit: int,
    ) -> list[dict[str, Any]]:
        cursor_values = (
            after_updated_at,
            after_document_kind,
            after_document_id,
        )
        if any(value is None for value in cursor_values) and any(
            value is not None for value in cursor_values
        ):
            raise ManagedConflictError(
                "all managed document cursor fields are required"
            )
        if snapshot_at is None:
            rows = await self._pool().fetch(
                """
                SELECT document.*
                FROM managed_document_heads head
                JOIN managed_documents document
                  ON document.account_id = head.account_id
                 AND document.document_kind = head.document_kind
                 AND document.document_id = head.document_id
                 AND document.document_revision = head.current_revision
                WHERE head.account_id = $1
                  AND ($2::text IS NULL OR head.document_kind = $2)
                  AND ($3::boolean OR head.deleted_at IS NULL)
                  AND (
                      $4::timestamptz IS NULL
                      OR (
                          head.updated_at,
                          head.document_kind,
                          head.document_id
                      ) > ($4, $5, $6)
                  )
                ORDER BY head.updated_at,
                         head.document_kind,
                         head.document_id
                LIMIT $7
                """,
                principal.account_id,
                document_kind,
                include_deleted,
                after_updated_at,
                after_document_kind,
                after_document_id,
                limit,
            )
        else:
            rows = await self._pool().fetch(
                """
                WITH snapshot AS (
                    SELECT DISTINCT ON (
                        document_kind,
                        document_id
                    ) *
                    FROM managed_documents
                    WHERE account_id = $1
                      AND updated_at <= $2
                    ORDER BY document_kind,
                             document_id,
                             document_revision DESC
                )
                SELECT *
                FROM snapshot
                WHERE ($3::text IS NULL OR document_kind = $3)
                  AND ($4::boolean OR deleted_at IS NULL)
                  AND (
                      $5::timestamptz IS NULL
                      OR (
                          updated_at,
                          document_kind,
                          document_id
                      ) > ($5, $6, $7)
                  )
                ORDER BY updated_at, document_kind, document_id
                LIMIT $8
                """,
                principal.account_id,
                snapshot_at,
                document_kind,
                include_deleted,
                after_updated_at,
                after_document_kind,
                after_document_id,
                limit,
            )
        return [self._public_document(dict(row), duplicate=False) for row in rows]

    async def create_restore(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        request: ManagedRestoreRequest,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                # Serialize the restore anchor with change publication. A writer that
                # commits after this point receives a sequence above change_sequence,
                # so it is either in this snapshot or in the following change feed.
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-change:{principal.account_id}",
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                snapshot_at = request.snapshot_at or now
                if snapshot_at > now:
                    raise ManagedConflictError(
                        "restore snapshot cannot be in the future"
                    )
                change_sequence = await connection.fetchval(
                    """
                    SELECT last_sequence
                    FROM managed_account_change_sequences
                    WHERE account_id = $1
                    """,
                    principal.account_id,
                )
                change_sequence = int(change_sequence or 0)
                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_restore_jobs
                    WHERE account_id = $1 AND request_id = $2
                    """,
                    principal.account_id,
                    request.request_id,
                )
                filters = {
                    "data_classes": request.data_classes,
                    "document_kinds": request.document_kinds,
                    "include_documents": request.include_documents,
                    "start": (
                        request.start.isoformat() if request.start is not None else None
                    ),
                    "end": (
                        request.end.isoformat() if request.end is not None else None
                    ),
                }
                if existing is not None:
                    if (
                        request.snapshot_at is not None
                        and existing["snapshot_at"] != request.snapshot_at
                    ) or _decoded_json(existing["filters"]) != filters:
                        raise ManagedConflictError("restore request id was reused")
                    return self._public_restore(dict(existing), duplicate=True)
                installation_exists = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_account_installations
                        WHERE account_id = $1
                          AND installation_id = $2
                          AND status IN ('active', 'limited')
                    )
                    """,
                    principal.account_id,
                    installation_id,
                )
                if not installation_exists:
                    raise ManagedNotFoundError("managed installation was not found")
                chunk_totals = await connection.fetchrow(
                    """
                    SELECT count(*) AS objects,
                           COALESCE(sum(actual_compressed_bytes), 0) AS bytes
                    FROM managed_chunks
                    WHERE account_id = $1
                      AND state = 'available'
                      AND available_at <= $2
                      AND (
                          superseded_at IS NULL
                          OR superseded_at > $2
                      )
                      AND (
                          cardinality($3::text[]) = 0
                          OR data_class = ANY($3)
                      )
                      AND ($4::timestamptz IS NULL OR event_end >= $4)
                      AND ($5::timestamptz IS NULL OR event_start < $5)
                    """,
                    principal.account_id,
                    snapshot_at,
                    request.data_classes,
                    request.start,
                    request.end,
                )
                document_total = 0
                if request.include_documents:
                    document_total = await connection.fetchval(
                        """
                        SELECT count(*)
                        FROM (
                            SELECT DISTINCT ON (
                                document_kind,
                                document_id
                            ) document_kind, document_id, deleted_at
                            FROM managed_documents
                            WHERE account_id = $1
                              AND updated_at <= $2
                              AND (
                                  cardinality($3::text[]) = 0
                                  OR document_kind = ANY($3)
                              )
                            ORDER BY document_kind,
                                     document_id,
                                     document_revision DESC
                        ) snapshot
                        WHERE snapshot.deleted_at IS NULL
                        """,
                        principal.account_id,
                        snapshot_at,
                        request.document_kinds,
                    )
                selected_objects = int(chunk_totals["objects"]) + int(document_total)
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_restore_jobs (
                        restore_job_id,
                        account_id,
                        installation_id,
                        request_id,
                        status,
                        snapshot_at,
                        filters,
                        selected_objects,
                        selected_bytes,
                        change_sequence,
                        created_at,
                        started_at,
                        expires_at
                    ) VALUES (
                        $1, $2, $3, $4, 'running', $5, $6::jsonb,
                        $7, $8, $9, $10, $10,
                        $10::timestamptz + interval '24 hours'
                    )
                    RETURNING *
                    """,
                    uuid4(),
                    principal.account_id,
                    installation_id,
                    request.request_id,
                    snapshot_at,
                    json.dumps(
                        filters,
                        sort_keys=True,
                        separators=(",", ":"),
                    ),
                    selected_objects,
                    int(chunk_totals["bytes"]),
                    change_sequence,
                    now,
                )
        return self._public_restore(dict(row), duplicate=False)

    async def create_export(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        request: ManagedExportRequest,
    ) -> dict[str, Any]:
        self._require_active(principal)
        try:
            canonical_scope = json.dumps(
                request.scope,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            )
        except (TypeError, ValueError):
            raise ManagedConflictError(
                "managed export scope is not canonicalizable"
            ) from None
        if len(canonical_scope.encode("utf-8")) > 65_536:
            raise ManagedConflictError("managed export scope is too large")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_export_jobs
                    WHERE account_id = $1 AND request_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    request.request_id,
                )
                if existing is not None:
                    if (
                        existing["format"] != request.format
                        or existing["client_key_id"] != request.client_key_id
                        or _decoded_json(existing["scope"]) != request.scope
                        or str(existing["expected_sha256"]).strip()
                        != request.expected_sha256
                        or int(existing["expected_bytes"]) != request.expected_bytes
                        or existing["content_type"] != request.content_type
                    ):
                        raise ManagedConflictError(
                            "managed export request id was reused"
                        )
                    return self._public_export(
                        dict(existing),
                        duplicate=True,
                    )
                contract = await connection.fetchrow(
                    """
                    SELECT account.storage_namespace
                    FROM managed_accounts account
                    JOIN managed_account_installations installation
                      ON installation.account_id = account.account_id
                     AND installation.installation_id = $2
                     AND installation.status IN ('active', 'limited')
                    JOIN managed_client_keys client_key
                      ON client_key.account_id = account.account_id
                     AND client_key.client_key_id = $3
                     AND client_key.revoked_at IS NULL
                    WHERE account.account_id = $1
                      AND account.status = 'active'
                    """,
                    principal.account_id,
                    installation_id,
                    request.client_key_id,
                )
                if contract is None:
                    raise ManagedNotFoundError(
                        "managed export installation or key was not found"
                    )
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_export_jobs (
                        export_job_id,
                        account_id,
                        storage_namespace,
                        installation_id,
                        request_id,
                        status,
                        format,
                        content_mode,
                        client_key_id,
                        scope,
                        expected_sha256,
                        expected_bytes,
                        content_type,
                        created_at,
                        started_at,
                        expires_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, 'running', $6,
                        'client_encrypted', $7, $8::jsonb,
                        $9, $10, $11, $12, $12,
                        $12::timestamptz + interval '24 hours'
                    )
                    RETURNING *
                    """,
                    uuid4(),
                    principal.account_id,
                    contract["storage_namespace"],
                    installation_id,
                    request.request_id,
                    request.format,
                    request.client_key_id,
                    canonical_scope,
                    request.expected_sha256,
                    request.expected_bytes,
                    request.content_type,
                    now,
                )
        return self._public_export(dict(row), duplicate=False)

    async def complete_export(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        export_job_id: UUID,
        metadata: ManagedObjectMetadata,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_export_jobs
                    WHERE account_id = $1
                      AND installation_id = $2
                      AND export_job_id = $3
                    FOR UPDATE
                    """,
                    principal.account_id,
                    installation_id,
                    export_job_id,
                )
                if row is None:
                    raise ManagedNotFoundError("managed export was not found")
                if row["status"] == "completed":
                    if row["output_generation"] != metadata.generation:
                        raise ManagedConflictError("managed export generation changed")
                    return self._public_export(dict(row), duplicate=True)
                supplied_sha = metadata.metadata.get("noop-sha256", "")
                expected_sha = str(row["expected_sha256"]).strip()
                if (
                    row["status"] != "running"
                    or row["expires_at"]
                    <= await connection.fetchval("SELECT clock_timestamp()")
                    or metadata.object_key != row["output_object_key"]
                    or metadata.size != int(row["expected_bytes"])
                    or metadata.content_type != row["content_type"]
                    or supplied_sha != expected_sha
                ):
                    raise ManagedConflictError(
                        "managed export object does not match its contract"
                    )
                completed = await connection.fetchrow(
                    """
                    UPDATE managed_export_jobs
                    SET status = 'completed',
                        output_generation = $4,
                        output_sha256 = expected_sha256,
                        output_bytes = expected_bytes,
                        completed_at = $5
                    WHERE account_id = $1
                      AND installation_id = $2
                      AND export_job_id = $3
                    RETURNING *
                    """,
                    principal.account_id,
                    installation_id,
                    export_job_id,
                    metadata.generation,
                    await connection.fetchval("SELECT clock_timestamp()"),
                )
        return self._public_export(dict(completed), duplicate=False)

    async def get_export(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        export_job_id: UUID,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT *
            FROM managed_export_jobs
            WHERE account_id = $1
              AND installation_id = $2
              AND export_job_id = $3
            """,
            principal.account_id,
            installation_id,
            export_job_id,
        )
        if row is None:
            raise ManagedNotFoundError("managed export was not found")
        return self._public_export(dict(row), duplicate=False)

    async def pending_export_deletions(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> list[dict[str, Any]]:
        rows = await self._pool().fetch(
            """
            SELECT export.export_job_id,
                   export.account_id,
                   export.output_object_key,
                   export.output_generation
            FROM managed_export_jobs export
            JOIN managed_accounts account USING (account_id)
            WHERE export.output_generation IS NOT NULL
              AND export.status = 'completed'
              AND (
                  export.expires_at <= $1
                  OR account.status IN ('erasure_pending', 'erased')
              )
            ORDER BY export.expires_at, export.export_job_id
            LIMIT $2
            """,
            now,
            batch_size,
        )
        return [dict(row) for row in rows]

    async def mark_export_deleted(
        self,
        *,
        account_id: UUID,
        export_job_id: UUID,
        now: datetime,
    ) -> None:
        status = await self._pool().execute(
            """
            UPDATE managed_export_jobs
            SET status = 'expired',
                completed_at = GREATEST(completed_at, $3)
            WHERE account_id = $1
              AND export_job_id = $2
              AND status = 'completed'
            """,
            account_id,
            export_job_id,
            now,
        )
        if status not in {"UPDATE 0", "UPDATE 1"}:
            raise ManagedConflictError("managed export deletion state is inconsistent")

    async def complete_restore(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        restore_job_id: UUID,
        delivered_objects: int,
        delivered_bytes: int,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_restore_jobs
                    WHERE account_id = $1
                      AND installation_id = $2
                      AND restore_job_id = $3
                    FOR UPDATE
                    """,
                    principal.account_id,
                    installation_id,
                    restore_job_id,
                )
                if row is None:
                    raise ManagedNotFoundError("managed restore was not found")
                if (
                    int(row["selected_objects"]) != delivered_objects
                    or int(row["selected_bytes"]) < delivered_bytes
                ):
                    raise ManagedConflictError(
                        "restore completion does not match the active restore"
                    )
                if row["status"] == "completed":
                    if (
                        int(row["delivered_objects"]) != delivered_objects
                        or int(row["delivered_bytes"]) != delivered_bytes
                    ):
                        raise ManagedConflictError(
                            "completed restore receipt does not match"
                        )
                    return self._public_restore(dict(row), duplicate=True)
                if row["status"] != "running" or row[
                    "expires_at"
                ] <= await connection.fetchval("SELECT clock_timestamp()"):
                    raise ManagedConflictError(
                        "restore completion does not match the active restore"
                    )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_restore_jobs
                    SET status = 'completed',
                        delivered_objects = $4,
                        delivered_bytes = $5,
                        completed_at = clock_timestamp()
                    WHERE account_id = $1
                      AND installation_id = $2
                      AND restore_job_id = $3
                    RETURNING *
                    """,
                    principal.account_id,
                    installation_id,
                    restore_job_id,
                    delivered_objects,
                    delivered_bytes,
                )
        return self._public_restore(dict(row), duplicate=False)

    async def get_restore(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        restore_job_id: UUID,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT *
            FROM managed_restore_jobs
            WHERE account_id = $1
              AND installation_id = $2
              AND restore_job_id = $3
            """,
            principal.account_id,
            installation_id,
            restore_job_id,
        )
        if row is None:
            raise ManagedNotFoundError("managed restore was not found")
        return self._public_restore(dict(row), duplicate=False)

    async def _social_profile(
        self,
        connection: Any,
        *,
        account_id: UUID,
        for_update: bool = False,
    ) -> Any:
        suffix = " FOR UPDATE OF profile" if for_update else ""
        row = await connection.fetchrow(
            """
            SELECT profile.*,
                   alias.alias_value AS noop_id
            FROM managed_social_profiles profile
            LEFT JOIN managed_social_aliases alias
              ON alias.profile_id = profile.profile_id
             AND alias.status = 'active'
            WHERE profile.account_id = $1
            """
            + suffix,
            account_id,
        )
        if row is None or row["status"] != "active":
            raise ManagedNotFoundError("managed Friends profile was not found")
        return row

    @staticmethod
    async def _lock_social_profile_scope(
        connection: Any,
        *,
        scope: str,
        profile_ids: tuple[UUID, ...],
    ) -> None:
        for profile_id in sorted(set(profile_ids), key=str):
            await connection.execute(
                "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                f"noop-managed-social:{scope}:{profile_id}",
            )

    @staticmethod
    def _social_relationship_lock_key(
        first_profile_id: UUID,
        second_profile_id: UUID,
    ) -> str:
        low_profile_id = min(first_profile_id, second_profile_id)
        high_profile_id = max(first_profile_id, second_profile_id)
        return f"noop-managed-social:relationship:{low_profile_id}:{high_profile_id}"

    @classmethod
    async def _lock_social_relationship(
        cls,
        connection: Any,
        *,
        first_profile_id: UUID,
        second_profile_id: UUID,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            cls._social_relationship_lock_key(
                first_profile_id,
                second_profile_id,
            ),
        )

    @staticmethod
    async def _lock_active_social_profiles(
        connection: Any,
        *,
        profile_ids: tuple[UUID, ...],
    ) -> dict[UUID, Any]:
        ordered_profile_ids = sorted(set(profile_ids), key=str)
        rows = await connection.fetch(
            """
            SELECT profile.*
            FROM managed_social_profiles profile
            WHERE profile.profile_id = ANY($1::uuid[])
              AND profile.status = 'active'
            ORDER BY profile.profile_id
            FOR UPDATE OF profile
            """,
            ordered_profile_ids,
        )
        if len(rows) != len(ordered_profile_ids):
            raise ManagedNotFoundError("managed profile was not found")
        return {row["profile_id"]: row for row in rows}

    @staticmethod
    def _public_social_profile(row: Any, *, duplicate: bool = False) -> dict[str, Any]:
        return {
            "profile_id": str(row["profile_id"]),
            "display_name": str(row["display_name"]),
            "noop_id": row["noop_id"],
            "poke_opt_in": bool(row["poke_opt_in"]),
            "quiet_start_minute": int(row["quiet_start_minute"]),
            "quiet_end_minute": int(row["quiet_end_minute"]),
            "time_zone": str(row["time_zone"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "duplicate": duplicate,
        }

    async def _insert_social_alias(
        self,
        connection: Any,
        *,
        profile_id: UUID,
        now: datetime,
    ) -> str:
        for _ in range(16):
            symbols = "".join(secrets.choice(SOCIAL_ALIAS_ALPHABET) for _ in range(16))
            alias_value = "NOOP-" + "-".join(
                symbols[index : index + 4] for index in range(0, 16, 4)
            )
            inserted = await connection.fetchval(
                """
                INSERT INTO managed_social_aliases (
                    alias_id,
                    profile_id,
                    alias_value,
                    status,
                    created_at
                ) VALUES ($1, $2, $3, 'active', $4)
                ON CONFLICT (alias_value) DO NOTHING
                RETURNING alias_value
                """,
                uuid4(),
                profile_id,
                alias_value,
                now,
            )
            if inserted is not None:
                return str(inserted)
        raise ManagedConflictError("a unique NOOP ID could not be allocated")

    async def create_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSocialProfileCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-social-profile:{principal.account_id}",
                )
                existing = await connection.fetchrow(
                    """
                    SELECT profile.*, alias.alias_value AS noop_id
                    FROM managed_social_profiles profile
                    LEFT JOIN managed_social_aliases alias
                      ON alias.profile_id = profile.profile_id
                     AND alias.status = 'active'
                    WHERE profile.account_id = $1
                    FOR UPDATE OF profile
                    """,
                    principal.account_id,
                )
                if existing is not None:
                    if existing["status"] != "active":
                        raise ManagedForbiddenError(
                            "managed Friends profile is unavailable"
                        )
                    return self._public_social_profile(existing, duplicate=True)
                now = await connection.fetchval("SELECT clock_timestamp()")
                profile_id = uuid4()
                await connection.execute(
                    """
                    INSERT INTO managed_social_profiles (
                        profile_id,
                        account_id,
                        creation_request_id,
                        display_name,
                        created_at,
                        updated_at
                    ) VALUES ($1, $2, $3, $4, $5, $5)
                    """,
                    profile_id,
                    principal.account_id,
                    request.request_id,
                    request.display_name,
                    now,
                )
                noop_id = await self._insert_social_alias(
                    connection,
                    profile_id=profile_id,
                    now=now,
                )
                created = await connection.fetchrow(
                    """
                    SELECT profile.*, $2::text AS noop_id
                    FROM managed_social_profiles profile
                    WHERE profile.profile_id = $1
                    """,
                    profile_id,
                    noop_id,
                )
        return self._public_social_profile(created)

    async def get_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> dict[str, Any]:
        self._require_active(principal)
        row = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        badges = await self._pool().fetch(
            """
            SELECT badge_code, earned_at
            FROM managed_social_badges
            WHERE profile_id = $1
            ORDER BY earned_at, badge_code
            """,
            row["profile_id"],
        )
        result = self._public_social_profile(row)
        result["badges"] = [
            {"code": str(badge["badge_code"]), "earned_at": badge["earned_at"]}
            for badge in badges
        ]
        return result

    async def delete_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> None:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                incident_rows = await connection.fetch(
                    """
                    SELECT incident.incident_id
                    FROM managed_safety_incidents incident
                    JOIN managed_safety_participants participant
                      ON participant.incident_id = incident.incident_id
                    WHERE participant.contact_profile_id = $1
                      AND incident.status IN ('open', 'acknowledged')
                    ORDER BY incident.incident_id
                    FOR UPDATE OF incident
                    """,
                    profile["profile_id"],
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                await connection.execute(
                    """
                    DELETE FROM managed_social_profiles
                    WHERE profile_id = $1
                    """,
                    profile["profile_id"],
                )
                await _reconcile_managed_safety_incident_acknowledgement(
                    connection,
                    incident_ids=(row["incident_id"] for row in incident_rows),
                    now=now,
                )

    async def update_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
        patch: ManagedSocialProfilePatch,
    ) -> dict[str, Any]:
        self._require_active(principal)
        if patch.time_zone is not None:
            try:
                self._social_time_zone(patch.time_zone)
            except ValueError:
                raise ManagedConflictError(
                    "managed Friends time zone is unknown"
                ) from None
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                row = await connection.fetchrow(
                    """
                    UPDATE managed_social_profiles profile
                    SET display_name = COALESCE($2, profile.display_name),
                        poke_opt_in = COALESCE($3, profile.poke_opt_in),
                        quiet_start_minute =
                            COALESCE($4, profile.quiet_start_minute),
                        quiet_end_minute =
                            COALESCE($5, profile.quiet_end_minute),
                        time_zone = COALESCE($6, profile.time_zone),
                        updated_at = $7
                    FROM managed_social_aliases alias
                    WHERE profile.account_id = $1
                      AND profile.status = 'active'
                      AND alias.profile_id = profile.profile_id
                      AND alias.status = 'active'
                    RETURNING profile.*, alias.alias_value AS noop_id
                    """,
                    principal.account_id,
                    patch.display_name,
                    patch.poke_opt_in,
                    patch.quiet_start_minute,
                    patch.quiet_end_minute,
                    patch.time_zone,
                    now,
                )
                if row is not None and patch.poke_opt_in is False:
                    await connection.execute(
                        """
                        UPDATE managed_social_pokes
                        SET status = 'expired'
                        WHERE recipient_profile_id = $1
                          AND status IN ('queued', 'claimed')
                        """,
                        row["profile_id"],
                    )
        if row is None:
            raise ManagedNotFoundError("managed Friends profile was not found")
        return self._public_social_profile(row)

    async def rotate_social_alias(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                await connection.execute(
                    """
                    UPDATE managed_social_aliases
                    SET status = 'revoked',
                        revoked_at = $2,
                        purge_after = $2::timestamptz + interval '400 days'
                    WHERE profile_id = $1 AND status = 'active'
                    """,
                    profile["profile_id"],
                    now,
                )
                noop_id = await self._insert_social_alias(
                    connection,
                    profile_id=profile["profile_id"],
                    now=now,
                )
                row = await connection.fetchrow(
                    """
                    SELECT profile.*, $2::text AS noop_id
                    FROM managed_social_profiles profile
                    WHERE profile.profile_id = $1
                    """,
                    profile["profile_id"],
                    noop_id,
                )
        return self._public_social_profile(row)

    async def lookup_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
        noop_id: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        caller = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        row = await self._pool().fetchrow(
            """
            SELECT target.profile_id, target.display_name, alias.alias_value
            FROM managed_social_aliases alias
            JOIN managed_social_profiles target USING (profile_id)
            WHERE alias.alias_value = $1
              AND alias.status = 'active'
              AND target.status = 'active'
              AND NOT EXISTS (
                  SELECT 1
                  FROM managed_social_blocks block
                  WHERE (
                      block.blocker_profile_id = $2
                      AND block.blocked_profile_id = target.profile_id
                  ) OR (
                      block.blocker_profile_id = target.profile_id
                      AND block.blocked_profile_id = $2
                  )
              )
            """,
            noop_id,
            caller["profile_id"],
        )
        if row is None:
            raise ManagedNotFoundError("NOOP ID was not found")
        return {
            "profile_id": str(row["profile_id"]),
            "display_name": str(row["display_name"]),
            "noop_id": str(row["alias_value"]),
            "self": row["profile_id"] == caller["profile_id"],
        }

    async def create_social_invite(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSocialInviteCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                replay = await connection.fetchrow(
                    """
                    SELECT invite_id,
                           capability_hash,
                           status,
                           created_at,
                           expires_at
                    FROM managed_social_invites
                    WHERE inviter_profile_id = $1
                      AND creation_request_id = $2
                    """,
                    profile["profile_id"],
                    request.request_id,
                )
                if replay is not None:
                    supplied_hash = hashlib.sha256(
                        request.capability.get_secret_value().encode("ascii")
                    ).hexdigest()
                    if not hmac.compare_digest(
                        str(replay["capability_hash"]).strip(),
                        supplied_hash,
                    ):
                        raise ManagedConflictError("invite request id was reused")
                    replay_status = str(replay["status"])
                    if replay_status == "active" and replay["expires_at"] <= now:
                        await connection.execute(
                            """
                            UPDATE managed_social_invites
                            SET status = 'expired'
                            WHERE invite_id = $1 AND status = 'active'
                            """,
                            replay["invite_id"],
                        )
                        replay_status = "expired"
                    return {
                        "invite_id": str(replay["invite_id"]),
                        "capability": request.capability.get_secret_value(),
                        "status": replay_status,
                        "created_at": replay["created_at"],
                        "expires_at": replay["expires_at"],
                        "duplicate": True,
                    }
                invite_counts = await connection.fetchrow(
                    """
                    SELECT
                        count(*) FILTER (
                            WHERE status = 'active' AND expires_at > $2
                        ) AS active_count,
                        count(*) FILTER (
                            WHERE created_at >
                                $2::timestamptz - interval '24 hours'
                        ) AS recent_count
                    FROM managed_social_invites
                    WHERE inviter_profile_id = $1
                    """,
                    profile["profile_id"],
                    now,
                )
                if int(invite_counts["active_count"]) >= SOCIAL_MAX_ACTIVE_INVITES:
                    raise ManagedConflictError(
                        "revoke an active invite before creating another"
                    )
                if int(invite_counts["recent_count"]) >= SOCIAL_MAX_INVITES_PER_DAY:
                    raise ManagedConflictError(
                        "managed Friends invite limit has been reached"
                    )
                capability = request.capability.get_secret_value()
                capability_hash = hashlib.sha256(capability.encode("ascii")).hexdigest()
                invite_id = uuid4()
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_social_invites (
                        invite_id,
                        inviter_profile_id,
                        creation_request_id,
                        capability_hash,
                        status,
                        created_at,
                        expires_at
                    ) VALUES (
                        $1, $2, $3, $4, 'active', $5,
                        $5::timestamptz + $6::int * interval '1 hour'
                    )
                    RETURNING invite_id, status, created_at, expires_at
                    """,
                    invite_id,
                    profile["profile_id"],
                    request.request_id,
                    capability_hash,
                    now,
                    request.expires_in_hours,
                )
        return {
            "invite_id": str(row["invite_id"]),
            "capability": capability,
            "status": str(row["status"]),
            "created_at": row["created_at"],
            "expires_at": row["expires_at"],
            "duplicate": False,
        }

    async def revoke_social_invite(
        self,
        *,
        principal: ManagedPrincipal,
        invite_id: UUID,
    ) -> None:
        self._require_active(principal)
        now = await self.coordination_now()
        status = await self._pool().execute(
            """
            UPDATE managed_social_invites invite
            SET status = 'revoked', revoked_at = $3
            FROM managed_social_profiles profile
            WHERE invite.invite_id = $1
              AND invite.inviter_profile_id = profile.profile_id
              AND profile.account_id = $2
              AND invite.status = 'active'
            """,
            invite_id,
            principal.account_id,
            now,
        )
        if status == "UPDATE 0":
            row = await self._pool().fetchrow(
                """
                SELECT invite.status
                FROM managed_social_invites invite
                JOIN managed_social_profiles profile
                  ON profile.profile_id = invite.inviter_profile_id
                WHERE invite.invite_id = $1 AND profile.account_id = $2
                """,
                invite_id,
                principal.account_id,
            )
            if row is None:
                raise ManagedNotFoundError("managed Friends invite was not found")
            if row["status"] != "revoked":
                raise ManagedConflictError("managed Friends invite is no longer active")

    async def _create_social_request(
        self,
        connection: Any,
        *,
        sender_profile_id: UUID,
        recipient_profile_id: UUID,
        client_request_id: UUID,
        source: str,
        invite_id: UUID | None,
        now: datetime,
    ) -> dict[str, Any]:
        if sender_profile_id == recipient_profile_id:
            raise ManagedConflictError("a profile cannot add itself")
        await self._lock_social_relationship(
            connection,
            first_profile_id=sender_profile_id,
            second_profile_id=recipient_profile_id,
        )
        await self._lock_social_profile_scope(
            connection,
            scope="request-rate",
            profile_ids=(sender_profile_id, recipient_profile_id),
        )
        profiles = await self._lock_active_social_profiles(
            connection,
            profile_ids=(sender_profile_id, recipient_profile_id),
        )
        replay = await connection.fetchrow(
            """
            SELECT request.*, recipient.display_name AS other_display_name
            FROM managed_social_requests request
            JOIN managed_social_profiles recipient
              ON recipient.profile_id = request.recipient_profile_id
            WHERE request.sender_profile_id = $1
              AND request.client_request_id = $2
            """,
            sender_profile_id,
            client_request_id,
        )
        if replay is not None:
            if (
                replay["recipient_profile_id"] != recipient_profile_id
                or replay["source"] != source
            ):
                raise ManagedConflictError("friend request id was reused")
            result = self._public_social_request(replay, sender_profile_id)
            result["duplicate"] = True
            return result
        blocked = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_social_blocks
                WHERE (
                    blocker_profile_id = $1 AND blocked_profile_id = $2
                ) OR (
                    blocker_profile_id = $2 AND blocked_profile_id = $1
                )
            )
            """,
            sender_profile_id,
            recipient_profile_id,
        )
        if blocked:
            raise ManagedNotFoundError("NOOP ID or invite was not found")
        friendship = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_social_friendships
                WHERE profile_low_id = LEAST($1::uuid, $2::uuid)
                  AND profile_high_id = GREATEST($1::uuid, $2::uuid)
            )
            """,
            sender_profile_id,
            recipient_profile_id,
        )
        if friendship:
            raise ManagedConflictError("profiles are already friends")
        pending = await connection.fetchrow(
            """
            SELECT request.*, other.display_name AS other_display_name
            FROM managed_social_requests request
            JOIN managed_social_profiles other
              ON other.profile_id = CASE
                  WHEN request.sender_profile_id = $1
                  THEN request.recipient_profile_id
                  ELSE request.sender_profile_id
              END
            WHERE request.status = 'pending'
              AND LEAST(
                    request.sender_profile_id,
                    request.recipient_profile_id
                  ) = LEAST($1::uuid, $2::uuid)
              AND GREATEST(
                    request.sender_profile_id,
                    request.recipient_profile_id
                  ) = GREATEST($1::uuid, $2::uuid)
            FOR UPDATE OF request
            """,
            sender_profile_id,
            recipient_profile_id,
        )
        if pending is not None:
            raise ManagedConflictError("a friend request is already pending")
        request_counts = await connection.fetchrow(
            """
            SELECT
                (
                    SELECT count(*)
                    FROM managed_social_requests
                    WHERE sender_profile_id = $1
                      AND created_at >
                          $3::timestamptz - interval '24 hours'
                ) AS sent_recent,
                (
                    SELECT count(*)
                    FROM managed_social_requests
                    WHERE recipient_profile_id = $2
                      AND created_at >
                          $3::timestamptz - interval '24 hours'
                ) AS received_recent,
                (
                    SELECT count(*)
                    FROM managed_social_requests
                    WHERE sender_profile_id = $1
                      AND status = 'pending'
                      AND expires_at > $3
                ) AS pending_sent,
                (
                    SELECT count(*)
                    FROM managed_social_requests
                    WHERE sender_profile_id = $1
                      AND recipient_profile_id = $2
                      AND created_at >
                          $3::timestamptz - interval '24 hours'
                ) AS sent_to_pair_recent
            """,
            sender_profile_id,
            recipient_profile_id,
            now,
        )
        if (
            int(request_counts["sent_recent"]) >= SOCIAL_MAX_SENT_REQUESTS_PER_DAY
            or int(request_counts["pending_sent"]) >= SOCIAL_MAX_PENDING_REQUESTS
        ):
            raise ManagedConflictError("managed Friends request limit has been reached")
        if int(request_counts["sent_to_pair_recent"]) >= 1:
            raise ManagedConflictError(
                "wait before sending this profile another request"
            )
        if (
            int(request_counts["received_recent"])
            >= SOCIAL_MAX_RECEIVED_REQUESTS_PER_DAY
        ):
            raise ManagedConflictError(
                "this profile cannot receive more requests right now"
            )
        recipient = profiles[recipient_profile_id]
        row = await connection.fetchrow(
            """
            INSERT INTO managed_social_requests (
                request_id,
                client_request_id,
                sender_profile_id,
                recipient_profile_id,
                invite_id,
                source,
                status,
                created_at,
                expires_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, 'pending', $7,
                $7::timestamptz + interval '30 days'
            )
            RETURNING *, $8::text AS other_display_name
            """,
            uuid4(),
            client_request_id,
            sender_profile_id,
            recipient_profile_id,
            invite_id,
            source,
            now,
            recipient["display_name"],
        )
        result = self._public_social_request(row, sender_profile_id)
        result["duplicate"] = False
        return result

    @staticmethod
    def _public_social_request(row: Any, caller_profile_id: UUID) -> dict[str, Any]:
        incoming = row["recipient_profile_id"] == caller_profile_id
        other_profile_id = (
            row["sender_profile_id"] if incoming else row["recipient_profile_id"]
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

    async def create_social_request(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSocialRequestCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                sender = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                recipient = await connection.fetchrow(
                    """
                    SELECT profile.profile_id
                    FROM managed_social_aliases alias
                    JOIN managed_social_profiles profile USING (profile_id)
                    WHERE alias.alias_value = $1
                      AND alias.status = 'active'
                      AND profile.status = 'active'
                    """,
                    request.noop_id,
                )
                if recipient is None:
                    raise ManagedNotFoundError("NOOP ID was not found")
                now = await connection.fetchval("SELECT clock_timestamp()")
                return await self._create_social_request(
                    connection,
                    sender_profile_id=sender["profile_id"],
                    recipient_profile_id=recipient["profile_id"],
                    client_request_id=request.request_id,
                    source="noop_id",
                    invite_id=None,
                    now=now,
                )

    async def redeem_social_invite(
        self,
        *,
        principal: ManagedPrincipal,
        request_id: UUID,
        capability: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        capability_hash = hashlib.sha256(capability.encode("ascii")).hexdigest()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                sender = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                invite_snapshot = await connection.fetchrow(
                    """
                    SELECT inviter_profile_id
                    FROM managed_social_invites
                    WHERE capability_hash = $1
                    """,
                    capability_hash,
                )
                if invite_snapshot is None:
                    raise ManagedNotFoundError("NOOP invite was not found")
                if invite_snapshot["inviter_profile_id"] == sender["profile_id"]:
                    raise ManagedConflictError("a profile cannot add itself")
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=sender["profile_id"],
                    second_profile_id=invite_snapshot["inviter_profile_id"],
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                invite = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_social_invites
                    WHERE capability_hash = $1
                    FOR UPDATE
                    """,
                    capability_hash,
                )
                if invite is None:
                    raise ManagedNotFoundError("NOOP invite was not found")
                if (
                    invite["status"] == "redeemed"
                    and invite["redeemed_by_profile_id"] == sender["profile_id"]
                    and invite["friend_request_id"] is not None
                ):
                    row = await connection.fetchrow(
                        """
                        SELECT request.*, recipient.display_name
                            AS other_display_name
                        FROM managed_social_requests request
                        JOIN managed_social_profiles recipient
                          ON recipient.profile_id =
                             request.recipient_profile_id
                        WHERE request.request_id = $1
                        """,
                        invite["friend_request_id"],
                    )
                    result = self._public_social_request(
                        row,
                        sender["profile_id"],
                    )
                    result["duplicate"] = True
                    return result
                if invite["status"] != "active" or invite["expires_at"] <= now:
                    if invite["status"] == "active":
                        await connection.execute(
                            """
                            UPDATE managed_social_invites
                            SET status = 'expired'
                            WHERE invite_id = $1
                            """,
                            invite["invite_id"],
                        )
                    raise ManagedNotFoundError("NOOP invite was not found")
                result = await self._create_social_request(
                    connection,
                    sender_profile_id=sender["profile_id"],
                    recipient_profile_id=invite["inviter_profile_id"],
                    client_request_id=request_id,
                    source="invite",
                    invite_id=invite["invite_id"],
                    now=now,
                )
                await connection.execute(
                    """
                    UPDATE managed_social_invites
                    SET status = 'redeemed',
                        redeemed_at = $2,
                        redeemed_by_profile_id = $3,
                        friend_request_id = $4
                    WHERE invite_id = $1
                    """,
                    invite["invite_id"],
                    now,
                    sender["profile_id"],
                    UUID(result["request_id"]),
                )
                return result

    async def list_social_requests(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        profile = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        rows = await self._pool().fetch(
            """
            SELECT request.*,
                   other.display_name AS other_display_name
            FROM managed_social_requests request
            JOIN managed_social_profiles other
              ON other.profile_id = CASE
                  WHEN request.sender_profile_id = $1
                  THEN request.recipient_profile_id
                  ELSE request.sender_profile_id
              END
            WHERE (
                    request.sender_profile_id = $1
                    OR request.recipient_profile_id = $1
                  )
              AND request.status = 'pending'
              AND request.expires_at > clock_timestamp()
            ORDER BY request.created_at DESC, request.request_id
            LIMIT 100
            """,
            profile["profile_id"],
        )
        return [self._public_social_request(row, profile["profile_id"]) for row in rows]

    async def decide_social_request(
        self,
        *,
        principal: ManagedPrincipal,
        request_id: UUID,
        decision: str,
    ) -> dict[str, Any]:
        self._require_active(principal)
        target_status = "accepted" if decision == "accept" else "declined"
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                request_snapshot = await connection.fetchrow(
                    """
                    SELECT sender_profile_id, recipient_profile_id
                    FROM managed_social_requests
                    WHERE request_id = $1
                      AND recipient_profile_id = $2
                    """,
                    request_id,
                    profile["profile_id"],
                )
                if request_snapshot is None:
                    raise ManagedNotFoundError("friend request was not found")
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=request_snapshot["sender_profile_id"],
                    second_profile_id=request_snapshot["recipient_profile_id"],
                )
                if decision == "accept":
                    await self._lock_social_profile_scope(
                        connection,
                        scope="friend-capacity",
                        profile_ids=(
                            request_snapshot["sender_profile_id"],
                            request_snapshot["recipient_profile_id"],
                        ),
                    )
                await self._lock_active_social_profiles(
                    connection,
                    profile_ids=(
                        request_snapshot["sender_profile_id"],
                        request_snapshot["recipient_profile_id"],
                    ),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                request = await connection.fetchrow(
                    """
                    SELECT request.*, sender.display_name AS other_display_name
                    FROM managed_social_requests request
                    JOIN managed_social_profiles sender
                      ON sender.profile_id = request.sender_profile_id
                    WHERE request.request_id = $1
                      AND request.recipient_profile_id = $2
                    FOR UPDATE OF request
                    """,
                    request_id,
                    profile["profile_id"],
                )
                if request is None:
                    raise ManagedNotFoundError("friend request was not found")
                if request["status"] != "pending":
                    if request["status"] != target_status:
                        raise ManagedConflictError(
                            "friend request was already decided differently"
                        )
                    result = self._public_social_request(
                        request,
                        profile["profile_id"],
                    )
                    result["duplicate"] = True
                    return result
                if request["expires_at"] <= now:
                    await connection.execute(
                        """
                        UPDATE managed_social_requests
                        SET status = 'expired', decided_at = $2
                        WHERE request_id = $1
                        """,
                        request_id,
                        now,
                    )
                    raise ManagedConflictError("friend request has expired")
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
                        request["sender_profile_id"],
                        request["recipient_profile_id"],
                    )
                    if blocked:
                        raise ManagedConflictError(
                            "friend request can no longer be accepted"
                        )
                    counts = await connection.fetchrow(
                        """
                        SELECT
                            (
                                SELECT count(*)
                                FROM managed_social_friendships
                                WHERE profile_low_id = $1
                                   OR profile_high_id = $1
                            ) AS recipient_count,
                            (
                                SELECT count(*)
                                FROM managed_social_friendships
                                WHERE profile_low_id = $2
                                   OR profile_high_id = $2
                            ) AS sender_count
                        """,
                        request["recipient_profile_id"],
                        request["sender_profile_id"],
                    )
                    if (
                        int(counts["recipient_count"]) >= SOCIAL_MAX_FRIENDS
                        or int(counts["sender_count"]) >= SOCIAL_MAX_FRIENDS
                    ):
                        raise ManagedConflictError("friend limit has been reached")
                    low = min(
                        request["sender_profile_id"],
                        request["recipient_profile_id"],
                    )
                    high = max(
                        request["sender_profile_id"],
                        request["recipient_profile_id"],
                    )
                    await connection.execute(
                        """
                        INSERT INTO managed_social_friendships (
                            friendship_id,
                            profile_low_id,
                            profile_high_id,
                            accepted_request_id,
                            created_at
                        ) VALUES ($1, $2, $3, $4, $5)
                        ON CONFLICT (profile_low_id, profile_high_id)
                        DO NOTHING
                        """,
                        uuid4(),
                        low,
                        high,
                        request_id,
                        now,
                    )
                    for owner, reader in (
                        (
                            request["sender_profile_id"],
                            request["recipient_profile_id"],
                        ),
                        (
                            request["recipient_profile_id"],
                            request["sender_profile_id"],
                        ),
                    ):
                        await connection.execute(
                            """
                            INSERT INTO managed_social_visibility (
                                owner_profile_id,
                                reader_profile_id,
                                updated_at
                            ) VALUES ($1, $2, $3)
                            ON CONFLICT (
                                owner_profile_id,
                                reader_profile_id
                            ) DO NOTHING
                            """,
                            owner,
                            reader,
                            now,
                        )
                        await connection.execute(
                            """
                            INSERT INTO managed_social_badges (
                                profile_id,
                                badge_code,
                                earned_at
                            ) VALUES ($1, 'connected', $2)
                            ON CONFLICT DO NOTHING
                            """,
                            owner,
                            now,
                        )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_social_requests
                    SET status = $2, decided_at = $3
                    WHERE request_id = $1
                    RETURNING *, $4::text AS other_display_name
                    """,
                    request_id,
                    target_status,
                    now,
                    request["other_display_name"],
                )
        result = self._public_social_request(row, profile["profile_id"])
        result["duplicate"] = False
        return result

    @staticmethod
    def _public_visibility(row: Any, prefix: str) -> dict[str, bool]:
        return {
            field: bool(row[f"{prefix}{field}"])
            for field in (*SOCIAL_SUMMARY_FIELDS, "poke_allowed")
        }

    async def _social_visibility_union(
        self,
        connection: Any,
        *,
        owner_profile_id: UUID,
    ) -> dict[str, bool]:
        row = await connection.fetchrow(
            """
            SELECT
                COALESCE(bool_or(visibility.charge), false) AS charge,
                COALESCE(bool_or(visibility.effort), false) AS effort,
                COALESCE(bool_or(visibility.rest), false) AS rest,
                COALESCE(
                    bool_or(visibility.sleep_duration),
                    false
                ) AS sleep_duration,
                COALESCE(bool_or(visibility.hrv), false) AS hrv,
                COALESCE(bool_or(visibility.rhr), false) AS rhr
            FROM managed_social_visibility visibility
            JOIN managed_social_friendships friendship
              ON friendship.profile_low_id = LEAST(
                    visibility.owner_profile_id,
                    visibility.reader_profile_id
                 )
             AND friendship.profile_high_id = GREATEST(
                    visibility.owner_profile_id,
                    visibility.reader_profile_id
                 )
            WHERE visibility.owner_profile_id = $1
            """,
            owner_profile_id,
        )
        return {field: bool(row[field]) for field in SOCIAL_SUMMARY_FIELDS}

    async def _clear_unshared_social_summary_fields(
        self,
        connection: Any,
        *,
        owner_profile_id: UUID,
    ) -> None:
        allowed = await self._social_visibility_union(
            connection,
            owner_profile_id=owner_profile_id,
        )
        await connection.execute(
            """
            UPDATE managed_social_daily_summaries
            SET charge = CASE WHEN $2 THEN charge ELSE NULL END,
                effort = CASE WHEN $3 THEN effort ELSE NULL END,
                rest = CASE WHEN $4 THEN rest ELSE NULL END,
                sleep_duration =
                    CASE WHEN $5 THEN sleep_duration ELSE NULL END,
                hrv = CASE WHEN $6 THEN hrv ELSE NULL END,
                rhr = CASE WHEN $7 THEN rhr ELSE NULL END,
                revision = revision + 1,
                updated_at = clock_timestamp()
            WHERE profile_id = $1
              AND (
                    (NOT $2 AND charge IS NOT NULL)
                    OR (NOT $3 AND effort IS NOT NULL)
                    OR (NOT $4 AND rest IS NOT NULL)
                    OR (NOT $5 AND sleep_duration IS NOT NULL)
                    OR (NOT $6 AND hrv IS NOT NULL)
                    OR (NOT $7 AND rhr IS NOT NULL)
                  )
            """,
            owner_profile_id,
            allowed["charge"],
            allowed["effort"],
            allowed["rest"],
            allowed["sleep_duration"],
            allowed["hrv"],
            allowed["rhr"],
        )

    async def list_social_friends(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        profile = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        rows = await self._pool().fetch(
            """
            SELECT friend.profile_id,
                   friend.display_name,
                   friendship.created_at AS friends_since,
                   own.charge AS own_charge,
                   own.effort AS own_effort,
                   own.rest AS own_rest,
                   own.sleep_duration AS own_sleep_duration,
                   own.hrv AS own_hrv,
                   own.rhr AS own_rhr,
                   own.poke_allowed AS own_poke_allowed,
                   shared.charge AS shared_charge,
                   shared.effort AS shared_effort,
                   shared.rest AS shared_rest,
                   shared.sleep_duration AS shared_sleep_duration,
                   shared.hrv AS shared_hrv,
                   shared.rhr AS shared_rhr,
                   shared.poke_allowed AS shared_poke_allowed,
                   latest.day AS latest_day,
                   latest.charge AS latest_charge,
                   latest.effort AS latest_effort,
                   latest.rest AS latest_rest,
                   latest.sleep_duration AS latest_sleep_duration,
                   latest.hrv AS latest_hrv,
                   latest.rhr AS latest_rhr
            FROM managed_social_friendships friendship
            JOIN managed_social_profiles friend
              ON friend.profile_id = CASE
                  WHEN friendship.profile_low_id = $1
                  THEN friendship.profile_high_id
                  ELSE friendship.profile_low_id
              END
            JOIN managed_social_visibility own
              ON own.owner_profile_id = $1
             AND own.reader_profile_id = friend.profile_id
            JOIN managed_social_visibility shared
              ON shared.owner_profile_id = friend.profile_id
             AND shared.reader_profile_id = $1
            LEFT JOIN LATERAL (
                SELECT summary.*
                FROM managed_social_daily_summaries summary
                WHERE summary.profile_id = friend.profile_id
                  AND summary.day >= friendship.created_at::date
                  AND (
                        (shared.charge AND summary.charge IS NOT NULL)
                        OR (shared.effort AND summary.effort IS NOT NULL)
                        OR (shared.rest AND summary.rest IS NOT NULL)
                        OR (
                            shared.sleep_duration
                            AND summary.sleep_duration IS NOT NULL
                        )
                        OR (shared.hrv AND summary.hrv IS NOT NULL)
                        OR (shared.rhr AND summary.rhr IS NOT NULL)
                      )
                ORDER BY summary.day DESC
                LIMIT 1
            ) latest ON true
            WHERE friendship.profile_low_id = $1
               OR friendship.profile_high_id = $1
            ORDER BY friend.display_name, friend.profile_id
            LIMIT 500
            """,
            profile["profile_id"],
        )
        friend_ids = [row["profile_id"] for row in rows]
        badge_rows = (
            await self._pool().fetch(
                """
                SELECT profile_id, badge_code, earned_at
                FROM managed_social_badges
                WHERE profile_id = ANY($1::uuid[])
                ORDER BY earned_at, badge_code
                """,
                friend_ids,
            )
            if friend_ids
            else []
        )
        badges: dict[UUID, list[dict[str, Any]]] = {}
        for badge in badge_rows:
            badges.setdefault(badge["profile_id"], []).append(
                {
                    "code": str(badge["badge_code"]),
                    "earned_at": badge["earned_at"],
                }
            )
        result: list[dict[str, Any]] = []
        for row in rows:
            shared = self._public_visibility(row, "shared_")
            latest = None
            if row["latest_day"] is not None:
                projected = {
                    field: row[f"latest_{field}"]
                    for field in SOCIAL_SUMMARY_FIELDS
                    if shared[field] and row[f"latest_{field}"] is not None
                }
                if projected:
                    latest = {
                        "day": row["latest_day"].isoformat(),
                        "summary": projected,
                    }
            result.append(
                {
                    "profile_id": str(row["profile_id"]),
                    "display_name": str(row["display_name"]),
                    "friends_since": row["friends_since"],
                    "sharing": self._public_visibility(row, "own_"),
                    "shared_with_me": shared,
                    "latest": latest,
                    "badges": badges.get(row["profile_id"], []),
                }
            )
        return result

    async def update_social_visibility(
        self,
        *,
        principal: ManagedPrincipal,
        friend_profile_id: UUID,
        patch: ManagedSocialVisibilityPatch,
    ) -> dict[str, bool]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=profile["profile_id"],
                    second_profile_id=friend_profile_id,
                )
                await self._lock_active_social_profiles(
                    connection,
                    profile_ids=(profile["profile_id"], friend_profile_id),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                row = await connection.fetchrow(
                    """
                    UPDATE managed_social_visibility visibility
                    SET charge = COALESCE($3, visibility.charge),
                        effort = COALESCE($4, visibility.effort),
                        rest = COALESCE($5, visibility.rest),
                        sleep_duration =
                            COALESCE($6, visibility.sleep_duration),
                        hrv = COALESCE($7, visibility.hrv),
                        rhr = COALESCE($8, visibility.rhr),
                        poke_allowed =
                            COALESCE($9, visibility.poke_allowed),
                        updated_at = $10
                    WHERE visibility.owner_profile_id = $1
                      AND visibility.reader_profile_id = $2
                      AND EXISTS (
                          SELECT 1
                          FROM managed_social_friendships friendship
                          WHERE friendship.profile_low_id =
                                LEAST($1::uuid, $2::uuid)
                            AND friendship.profile_high_id =
                                GREATEST($1::uuid, $2::uuid)
                      )
                    RETURNING
                        charge AS value_charge,
                        effort AS value_effort,
                        rest AS value_rest,
                        sleep_duration AS value_sleep_duration,
                        hrv AS value_hrv,
                        rhr AS value_rhr,
                        poke_allowed AS value_poke_allowed
                    """,
                    profile["profile_id"],
                    friend_profile_id,
                    patch.charge,
                    patch.effort,
                    patch.rest,
                    patch.sleep_duration,
                    patch.hrv,
                    patch.rhr,
                    patch.poke_allowed,
                    now,
                )
                if row is not None:
                    if patch.poke_allowed is False:
                        await connection.execute(
                            """
                            UPDATE managed_social_pokes
                            SET status = 'expired'
                            WHERE recipient_profile_id = $1
                              AND sender_profile_id = $2
                              AND status IN ('queued', 'claimed')
                            """,
                            profile["profile_id"],
                            friend_profile_id,
                        )
                    await self._clear_unshared_social_summary_fields(
                        connection,
                        owner_profile_id=profile["profile_id"],
                    )
        if row is None:
            raise ManagedNotFoundError("managed friend was not found")
        return self._public_visibility(row, "value_")

    async def remove_social_friend(
        self,
        *,
        principal: ManagedPrincipal,
        friend_profile_id: UUID,
    ) -> None:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=profile["profile_id"],
                    second_profile_id=friend_profile_id,
                )
                await self._lock_active_social_profiles(
                    connection,
                    profile_ids=(profile["profile_id"], friend_profile_id),
                )
                low = min(profile["profile_id"], friend_profile_id)
                high = max(profile["profile_id"], friend_profile_id)
                deleted = await connection.execute(
                    """
                    DELETE FROM managed_social_friendships
                    WHERE profile_low_id = $1 AND profile_high_id = $2
                    """,
                    low,
                    high,
                )
                if deleted == "DELETE 0":
                    raise ManagedNotFoundError("managed friend was not found")
                await connection.execute(
                    """
                    DELETE FROM managed_social_visibility
                    WHERE (
                        owner_profile_id = $1 AND reader_profile_id = $2
                    ) OR (
                        owner_profile_id = $2 AND reader_profile_id = $1
                    )
                    """,
                    profile["profile_id"],
                    friend_profile_id,
                )
                await connection.execute(
                    """
                    UPDATE managed_social_pokes
                    SET status = 'expired'
                    WHERE status IN ('queued', 'claimed')
                      AND (
                          (
                            sender_profile_id = $1
                            AND recipient_profile_id = $2
                          ) OR (
                            sender_profile_id = $2
                            AND recipient_profile_id = $1
                          )
                      )
                    """,
                    profile["profile_id"],
                    friend_profile_id,
                )
                for owner_profile_id in (
                    profile["profile_id"],
                    friend_profile_id,
                ):
                    await self._clear_unshared_social_summary_fields(
                        connection,
                        owner_profile_id=owner_profile_id,
                    )

    async def block_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
        blocked_profile_id: UUID,
    ) -> None:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                if profile["profile_id"] == blocked_profile_id:
                    raise ManagedConflictError("a profile cannot block itself")
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=profile["profile_id"],
                    second_profile_id=blocked_profile_id,
                )
                await self._lock_active_social_profiles(
                    connection,
                    profile_ids=(profile["profile_id"], blocked_profile_id),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                await connection.execute(
                    """
                    INSERT INTO managed_social_blocks (
                        blocker_profile_id,
                        blocked_profile_id,
                        created_at
                    ) VALUES ($1, $2, $3)
                    ON CONFLICT DO NOTHING
                    """,
                    profile["profile_id"],
                    blocked_profile_id,
                    now,
                )
                low = min(profile["profile_id"], blocked_profile_id)
                high = max(profile["profile_id"], blocked_profile_id)
                await connection.execute(
                    """
                    DELETE FROM managed_social_friendships
                    WHERE profile_low_id = $1 AND profile_high_id = $2
                    """,
                    low,
                    high,
                )
                await connection.execute(
                    """
                    DELETE FROM managed_social_visibility
                    WHERE (
                        owner_profile_id = $1 AND reader_profile_id = $2
                    ) OR (
                        owner_profile_id = $2 AND reader_profile_id = $1
                    )
                    """,
                    profile["profile_id"],
                    blocked_profile_id,
                )
                await connection.execute(
                    """
                    UPDATE managed_social_requests
                    SET status = 'canceled', decided_at = $3
                    WHERE status = 'pending'
                      AND (
                          (
                            sender_profile_id = $1
                            AND recipient_profile_id = $2
                          ) OR (
                            sender_profile_id = $2
                            AND recipient_profile_id = $1
                          )
                      )
                    """,
                    profile["profile_id"],
                    blocked_profile_id,
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_social_pokes
                    SET status = 'expired'
                    WHERE status IN ('queued', 'claimed')
                      AND (
                          (
                            sender_profile_id = $1
                            AND recipient_profile_id = $2
                          ) OR (
                            sender_profile_id = $2
                            AND recipient_profile_id = $1
                          )
                      )
                    """,
                    profile["profile_id"],
                    blocked_profile_id,
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
                    blocked_profile_id,
                )
                active_incident_ids = (
                    await _lock_active_managed_safety_incidents_for_profile_pair(
                        connection,
                        first_profile_id=profile["profile_id"],
                        second_profile_id=blocked_profile_id,
                    )
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
                    blocked_profile_id,
                    now,
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
                    blocked_profile_id,
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
                    blocked_profile_id,
                    now,
                )
                for owner_profile_id in (
                    profile["profile_id"],
                    blocked_profile_id,
                ):
                    await self._clear_unshared_social_summary_fields(
                        connection,
                        owner_profile_id=owner_profile_id,
                    )

    async def unblock_social_profile(
        self,
        *,
        principal: ManagedPrincipal,
        blocked_profile_id: UUID,
    ) -> None:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                if profile["profile_id"] == blocked_profile_id:
                    raise ManagedConflictError("a profile cannot unblock itself")
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=profile["profile_id"],
                    second_profile_id=blocked_profile_id,
                )
                await connection.execute(
                    """
                    DELETE FROM managed_social_blocks
                    WHERE blocker_profile_id = $1 AND blocked_profile_id = $2
                    """,
                    profile["profile_id"],
                    blocked_profile_id,
                )

    async def list_social_blocks(
        self,
        *,
        principal: ManagedPrincipal,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        profile = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        rows = await self._pool().fetch(
            """
            SELECT blocked.profile_id,
                   blocked.display_name,
                   social_block.created_at AS blocked_at
            FROM managed_social_blocks social_block
            JOIN managed_social_profiles blocked
              ON blocked.profile_id = social_block.blocked_profile_id
            WHERE social_block.blocker_profile_id = $1
            ORDER BY social_block.created_at DESC, blocked.profile_id
            LIMIT 500
            """,
            profile["profile_id"],
        )
        return [
            {
                "profile_id": str(row["profile_id"]),
                "display_name": str(row["display_name"]),
                "blocked_at": row["blocked_at"],
            }
            for row in rows
        ]

    async def put_social_summary(
        self,
        *,
        principal: ManagedPrincipal,
        day: date,
        mutation: ManagedSocialSummaryMutation,
    ) -> dict[str, Any]:
        self._require_active(principal)
        if day > datetime.now(UTC).date() + timedelta(days=1):
            raise ManagedConflictError("managed Friends summary day is in the future")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                allowed = await self._social_visibility_union(
                    connection,
                    owner_profile_id=profile["profile_id"],
                )
                if any(
                    mutation.summary.get(field) is not None and not allowed[field]
                    for field in SOCIAL_SUMMARY_FIELDS
                ):
                    raise ManagedForbiddenError(
                        "summary contains a field that is not currently shared"
                    )
                replay = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_social_daily_summaries
                    WHERE profile_id = $1 AND request_id = $2
                    """,
                    profile["profile_id"],
                    mutation.request_id,
                )
                if replay is not None:
                    expected_values = {
                        field: mutation.summary.get(field)
                        for field in SOCIAL_SUMMARY_FIELDS
                    }
                    if replay["day"] != day or any(
                        replay[field] != expected_values[field]
                        for field in SOCIAL_SUMMARY_FIELDS
                    ):
                        raise ManagedConflictError("summary request id was reused")
                    return self._public_social_summary(replay, duplicate=True)
                now = await connection.fetchval("SELECT clock_timestamp()")
                values = mutation.summary
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_social_daily_summaries (
                        profile_id,
                        day,
                        request_id,
                        charge,
                        effort,
                        rest,
                        sleep_duration,
                        hrv,
                        rhr,
                        revision,
                        updated_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6, $7, $8, $9, 1, $10
                    )
                    ON CONFLICT (profile_id, day)
                    DO UPDATE SET
                        request_id = EXCLUDED.request_id,
                        charge = EXCLUDED.charge,
                        effort = EXCLUDED.effort,
                        rest = EXCLUDED.rest,
                        sleep_duration = EXCLUDED.sleep_duration,
                        hrv = EXCLUDED.hrv,
                        rhr = EXCLUDED.rhr,
                        revision =
                            managed_social_daily_summaries.revision + 1,
                        updated_at = EXCLUDED.updated_at
                    RETURNING *
                    """,
                    profile["profile_id"],
                    day,
                    mutation.request_id,
                    values.get("charge"),
                    values.get("effort"),
                    values.get("rest"),
                    values.get("sleep_duration"),
                    values.get("hrv"),
                    values.get("rhr"),
                    now,
                )
                count = await connection.fetchval(
                    """
                    SELECT count(*)
                    FROM managed_social_daily_summaries
                    WHERE profile_id = $1
                      AND (
                          charge IS NOT NULL
                          OR effort IS NOT NULL
                          OR rest IS NOT NULL
                          OR sleep_duration IS NOT NULL
                          OR hrv IS NOT NULL
                          OR rhr IS NOT NULL
                      )
                    """,
                    profile["profile_id"],
                )
                for threshold, code in (
                    (7, "steady_week"),
                    (30, "steady_month"),
                ):
                    if int(count) >= threshold:
                        await connection.execute(
                            """
                            INSERT INTO managed_social_badges (
                                profile_id,
                                badge_code,
                                earned_at
                            ) VALUES ($1, $2, $3)
                            ON CONFLICT DO NOTHING
                            """,
                            profile["profile_id"],
                            code,
                            now,
                        )
        return self._public_social_summary(row, duplicate=False)

    @staticmethod
    def _public_social_summary(row: Any, *, duplicate: bool) -> dict[str, Any]:
        return {
            "day": row["day"].isoformat(),
            "summary": {
                field: row[field]
                for field in SOCIAL_SUMMARY_FIELDS
                if row[field] is not None
            },
            "revision": int(row["revision"]),
            "updated_at": row["updated_at"],
            "duplicate": duplicate,
        }

    async def social_feed(
        self,
        *,
        principal: ManagedPrincipal,
        start: date,
        end: date,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        if end < start or end - start > timedelta(days=89):
            raise ManagedConflictError("managed Friends feed range is invalid")
        profile = await self._social_profile(
            self._pool(),
            account_id=principal.account_id,
        )
        rows = await self._pool().fetch(
            """
            SELECT owner.profile_id,
                   owner.display_name,
                   summary.*,
                   visibility.charge AS allowed_charge,
                   visibility.effort AS allowed_effort,
                   visibility.rest AS allowed_rest,
                   visibility.sleep_duration AS allowed_sleep_duration,
                   visibility.hrv AS allowed_hrv,
                   visibility.rhr AS allowed_rhr
            FROM managed_social_daily_summaries summary
            JOIN managed_social_profiles owner
              ON owner.profile_id = summary.profile_id
            JOIN managed_social_visibility visibility
              ON visibility.owner_profile_id = summary.profile_id
             AND visibility.reader_profile_id = $1
            JOIN managed_social_friendships friendship
              ON friendship.profile_low_id =
                    LEAST(summary.profile_id, $1::uuid)
             AND friendship.profile_high_id =
                    GREATEST(summary.profile_id, $1::uuid)
            WHERE summary.day BETWEEN $2 AND $3
              AND summary.day >= friendship.created_at::date
            ORDER BY summary.day DESC, owner.display_name, owner.profile_id
            LIMIT 45000
            """,
            profile["profile_id"],
            start,
            end,
        )
        feed: list[dict[str, Any]] = []
        for row in rows:
            projected = {
                field: row[field]
                for field in SOCIAL_SUMMARY_FIELDS
                if row[f"allowed_{field}"] and row[field] is not None
            }
            if projected:
                feed.append(
                    {
                        "profile_id": str(row["profile_id"]),
                        "display_name": str(row["display_name"]),
                        "day": row["day"].isoformat(),
                        "summary": projected,
                    }
                )
        return feed

    @staticmethod
    def _social_time_zone(value: str) -> ZoneInfo | timezone:
        try:
            return ZoneInfo(value)
        except ZoneInfoNotFoundError:
            match = SOCIAL_FIXED_TIME_ZONE.fullmatch(value)
            if match is None:
                raise ValueError("unknown managed Friends time zone") from None
            sign = 1 if match.group(1) == "+" else -1
            hours = int(match.group(2))
            minutes = int(match.group(3))
            if minutes > 59 or hours > 14 or (hours == 14 and minutes != 0):
                raise ValueError("invalid managed Friends UTC offset")
            return timezone(
                sign * timedelta(hours=hours, minutes=minutes),
                name=value,
            )

    @staticmethod
    def _inside_quiet_hours(
        *,
        now: datetime,
        time_zone: str,
        start_minute: int,
        end_minute: int,
    ) -> bool:
        local = now.astimezone(PostgresManagedRepository._social_time_zone(time_zone))
        minute = local.hour * 60 + local.minute
        if start_minute == end_minute:
            return False
        if start_minute < end_minute:
            return start_minute <= minute < end_minute
        return minute >= start_minute or minute < end_minute

    async def create_social_poke(
        self,
        *,
        principal: ManagedPrincipal,
        request: ManagedSocialPokeCreate,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                sender_snapshot = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                await self._lock_social_relationship(
                    connection,
                    first_profile_id=sender_snapshot["profile_id"],
                    second_profile_id=request.recipient_profile_id,
                )
                locked_profiles = await self._lock_active_social_profiles(
                    connection,
                    profile_ids=(
                        sender_snapshot["profile_id"],
                        request.recipient_profile_id,
                    ),
                )
                sender = locked_profiles[sender_snapshot["profile_id"]]
                replay = await connection.fetchrow(
                    """
                    SELECT poke.*, recipient.display_name
                        AS recipient_display_name
                    FROM managed_social_pokes poke
                    JOIN managed_social_profiles recipient
                      ON recipient.profile_id = poke.recipient_profile_id
                    WHERE poke.sender_profile_id = $1
                      AND poke.request_id = $2
                    """,
                    sender["profile_id"],
                    request.request_id,
                )
                if replay is not None:
                    if replay["recipient_profile_id"] != request.recipient_profile_id:
                        raise ManagedConflictError("poke request id was reused")
                    return self._public_social_poke(replay, duplicate=True)
                recipient = await connection.fetchrow(
                    """
                    SELECT profile.*
                    FROM managed_social_profiles profile
                    JOIN managed_social_friendships friendship
                      ON friendship.profile_low_id =
                            LEAST($1::uuid, profile.profile_id)
                     AND friendship.profile_high_id =
                            GREATEST($1::uuid, profile.profile_id)
                    JOIN managed_social_visibility visibility
                      ON visibility.owner_profile_id = profile.profile_id
                     AND visibility.reader_profile_id = $1
                    WHERE profile.profile_id = $2
                      AND profile.status = 'active'
                      AND profile.poke_opt_in
                      AND visibility.poke_allowed
                      AND NOT EXISTS (
                          SELECT 1
                          FROM managed_social_blocks block
                          WHERE (
                              block.blocker_profile_id = $1
                              AND block.blocked_profile_id = profile.profile_id
                          ) OR (
                              block.blocker_profile_id = profile.profile_id
                              AND block.blocked_profile_id = $1
                          )
                      )
                    """,
                    sender["profile_id"],
                    request.recipient_profile_id,
                )
                if recipient is None:
                    raise ManagedForbiddenError(
                        "this friend is not accepting pokes right now"
                    )
                now = await connection.fetchval("SELECT clock_timestamp()")
                if self._inside_quiet_hours(
                    now=now,
                    time_zone=str(recipient["time_zone"]),
                    start_minute=int(recipient["quiet_start_minute"]),
                    end_minute=int(recipient["quiet_end_minute"]),
                ):
                    raise ManagedForbiddenError(
                        "this friend is not accepting pokes right now"
                    )
                pair_recent = await connection.fetchval(
                    """
                    SELECT EXISTS (
                        SELECT 1
                        FROM managed_social_pokes
                        WHERE sender_profile_id = $1
                          AND recipient_profile_id = $2
                          AND created_at >
                              $3::timestamptz - interval '15 minutes'
                    )
                    """,
                    sender["profile_id"],
                    recipient["profile_id"],
                    now,
                )
                if pair_recent:
                    raise ManagedConflictError("wait before poking this friend again")
                counts = await connection.fetchrow(
                    """
                    SELECT
                        (
                            SELECT count(*)
                            FROM managed_social_pokes
                            WHERE sender_profile_id = $1
                              AND created_at >=
                                  date_trunc('day', $3::timestamptz)
                        ) AS sent_today,
                        (
                            SELECT count(*)
                            FROM managed_social_pokes
                            WHERE recipient_profile_id = $2
                              AND created_at >=
                                  date_trunc('day', $3::timestamptz)
                        ) AS received_today
                    """,
                    sender["profile_id"],
                    recipient["profile_id"],
                    now,
                )
                if int(counts["sent_today"]) >= SOCIAL_MAX_SENT_POKES_PER_DAY:
                    raise ManagedConflictError("daily poke limit has been reached")
                if int(counts["received_today"]) >= SOCIAL_MAX_RECEIVED_POKES_PER_DAY:
                    raise ManagedConflictError(
                        "this friend cannot receive more pokes today"
                    )
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_social_pokes (
                        poke_id,
                        request_id,
                        sender_profile_id,
                        recipient_profile_id,
                        status,
                        created_at,
                        expires_at
                    ) VALUES (
                        $1, $2, $3, $4, 'queued', $5,
                        $5::timestamptz + interval '24 hours'
                    )
                    RETURNING *, $6::text AS recipient_display_name
                    """,
                    uuid4(),
                    request.request_id,
                    sender["profile_id"],
                    recipient["profile_id"],
                    now,
                    recipient["display_name"],
                )
        return self._public_social_poke(row, duplicate=False)

    @staticmethod
    def _public_social_poke(row: Any, *, duplicate: bool) -> dict[str, Any]:
        return {
            "poke_id": str(row["poke_id"]),
            "recipient_profile_id": str(row["recipient_profile_id"]),
            "recipient_display_name": str(row["recipient_display_name"]),
            "status": str(row["status"]),
            "created_at": row["created_at"],
            "expires_at": row["expires_at"],
            "duplicate": duplicate,
        }

    async def claim_social_pokes(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        limit: int,
    ) -> list[dict[str, Any]]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                    for_update=True,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                if not bool(profile["poke_opt_in"]):
                    await connection.execute(
                        """
                        UPDATE managed_social_pokes
                        SET status = 'expired'
                        WHERE recipient_profile_id = $1
                          AND status IN ('queued', 'claimed')
                        """,
                        profile["profile_id"],
                    )
                    return []
                if self._inside_quiet_hours(
                    now=now,
                    time_zone=str(profile["time_zone"]),
                    start_minute=int(profile["quiet_start_minute"]),
                    end_minute=int(profile["quiet_end_minute"]),
                ):
                    return []
                await connection.execute(
                    """
                    UPDATE managed_social_pokes poke
                    SET status = 'expired'
                    WHERE poke.recipient_profile_id = $1
                      AND poke.status IN ('queued', 'claimed')
                      AND (
                          NOT EXISTS (
                              SELECT 1
                              FROM managed_social_friendships friendship
                              WHERE friendship.profile_low_id = LEAST(
                                    poke.sender_profile_id,
                                    poke.recipient_profile_id
                                  )
                                AND friendship.profile_high_id = GREATEST(
                                    poke.sender_profile_id,
                                    poke.recipient_profile_id
                                  )
                          )
                          OR NOT EXISTS (
                              SELECT 1
                              FROM managed_social_visibility visibility
                              WHERE visibility.owner_profile_id =
                                    poke.recipient_profile_id
                                AND visibility.reader_profile_id =
                                    poke.sender_profile_id
                                AND visibility.poke_allowed
                          )
                          OR EXISTS (
                              SELECT 1
                              FROM managed_social_blocks block
                              WHERE (
                                  block.blocker_profile_id =
                                        poke.sender_profile_id
                                  AND block.blocked_profile_id =
                                        poke.recipient_profile_id
                              ) OR (
                                  block.blocker_profile_id =
                                        poke.recipient_profile_id
                                  AND block.blocked_profile_id =
                                        poke.sender_profile_id
                              )
                          )
                      )
                    """,
                    profile["profile_id"],
                )
                await connection.execute(
                    """
                    UPDATE managed_social_pokes
                    SET status = 'expired'
                    WHERE recipient_profile_id = $1
                      AND status IN ('queued', 'claimed')
                      AND expires_at <= $2
                    """,
                    profile["profile_id"],
                    now,
                )
                await connection.execute(
                    """
                    UPDATE managed_social_pokes
                    SET status = 'queued',
                        claim_id = NULL,
                        claimed_installation_id = NULL,
                        claimed_at = NULL,
                        claim_expires_at = NULL
                    WHERE recipient_profile_id = $1
                      AND status = 'claimed'
                      AND claim_expires_at <= $2
                      AND expires_at > $2
                    """,
                    profile["profile_id"],
                    now,
                )
                candidates = await connection.fetch(
                    """
                    SELECT poke.*, sender.display_name AS sender_display_name
                    FROM managed_social_pokes poke
                    JOIN managed_social_profiles sender
                      ON sender.profile_id = poke.sender_profile_id
                    WHERE poke.recipient_profile_id = $1
                      AND poke.status = 'queued'
                      AND poke.expires_at > $2
                    ORDER BY poke.created_at, poke.poke_id
                    FOR UPDATE OF poke SKIP LOCKED
                    LIMIT $3
                    """,
                    profile["profile_id"],
                    now,
                    limit,
                )
                claimed: list[dict[str, Any]] = []
                for candidate in candidates:
                    claim_id = uuid4()
                    claim_expires_at = min(
                        candidate["expires_at"],
                        now + timedelta(minutes=5),
                    )
                    await connection.execute(
                        """
                        UPDATE managed_social_pokes
                        SET status = 'claimed',
                            claim_id = $2,
                            claimed_installation_id = $3,
                            claimed_at = $4,
                            claim_expires_at = $5
                        WHERE poke_id = $1
                        """,
                        candidate["poke_id"],
                        claim_id,
                        installation_id,
                        now,
                        claim_expires_at,
                    )
                    claimed.append(
                        {
                            "poke_id": str(candidate["poke_id"]),
                            "claim_id": str(claim_id),
                            "sender_profile_id": str(candidate["sender_profile_id"]),
                            "sender_display_name": str(
                                candidate["sender_display_name"]
                            ),
                            "created_at": candidate["created_at"],
                            "expires_at": candidate["expires_at"],
                            "claim_expires_at": claim_expires_at,
                        }
                    )
        return claimed

    async def acknowledge_social_poke(
        self,
        *,
        principal: ManagedPrincipal,
        installation_id: str,
        poke_id: UUID,
        acknowledgement: ManagedSocialPokeAcknowledgement,
    ) -> dict[str, Any]:
        self._require_active(principal)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                profile = await self._social_profile(
                    connection,
                    account_id=principal.account_id,
                )
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_social_pokes
                    WHERE poke_id = $1
                      AND recipient_profile_id = $2
                    FOR UPDATE
                    """,
                    poke_id,
                    profile["profile_id"],
                )
                if row is None:
                    raise ManagedNotFoundError("managed poke was not found")
                if row["status"] == "acknowledged":
                    if (
                        row["claim_id"] != acknowledgement.claim_id
                        or row["claimed_installation_id"] != installation_id
                        or row["notification_outcome"]
                        != acknowledgement.notification_outcome
                        or row["haptic_outcome"] != acknowledgement.haptic_outcome
                    ):
                        raise ManagedConflictError(
                            "managed poke was acknowledged differently"
                        )
                    return {
                        "poke_id": str(poke_id),
                        "status": "acknowledged",
                        "duplicate": True,
                        "notification_outcome": str(row["notification_outcome"]),
                        "haptic_outcome": str(row["haptic_outcome"]),
                    }
                now = await connection.fetchval("SELECT clock_timestamp()")
                if (
                    row["status"] != "claimed"
                    or row["claim_id"] != acknowledgement.claim_id
                    or row["claimed_installation_id"] != installation_id
                    or row["claim_expires_at"] <= now
                ):
                    raise ManagedConflictError("managed poke claim is no longer valid")
                await connection.execute(
                    """
                    UPDATE managed_social_pokes
                    SET status = 'acknowledged',
                        acknowledged_at = $2,
                        notification_outcome = $3,
                        haptic_outcome = $4
                    WHERE poke_id = $1
                    """,
                    poke_id,
                    now,
                    acknowledgement.notification_outcome,
                    acknowledgement.haptic_outcome,
                )
        return {
            "poke_id": str(poke_id),
            "status": "acknowledged",
            "duplicate": False,
            "notification_outcome": acknowledgement.notification_outcome,
            "haptic_outcome": acknowledgement.haptic_outcome,
        }

    async def purge_expired_control_rows(
        self,
        *,
        now: datetime,
        batch_size: int,
    ) -> dict[str, int]:
        """Purge bounded control history without invalidating live cursors.

        Change events are removed only from each account's contiguous expired
        prefix. The retained cursor floor advances in the same transaction, so
        a client can never resume in a silently missing portion of the feed.
        """

        if not 1 <= batch_size <= 1_000:
            raise ValueError("batch_size must be between 1 and 1000")
        counts: dict[str, int] = {}
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                expired_jobs = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT restore_job_id
                        FROM managed_restore_jobs
                        WHERE expires_at <= $1
                          AND status <> 'expired'
                        ORDER BY expires_at, restore_job_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_restore_jobs job
                    SET status = 'expired',
                        started_at = COALESCE(job.started_at, job.created_at),
                        completed_at = GREATEST(
                            COALESCE(job.started_at, job.created_at),
                            $1::timestamptz
                        )
                    FROM candidates
                    WHERE job.restore_job_id = candidates.restore_job_id
                    RETURNING job.restore_job_id
                    """,
                    now,
                    batch_size,
                )
                counts["restore_jobs_expired"] = len(expired_jobs)

                expired_exports = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT export_job_id
                        FROM managed_export_jobs
                        WHERE expires_at <= $1
                          AND status <> 'expired'
                          AND output_generation IS NULL
                        ORDER BY expires_at, export_job_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_export_jobs job
                    SET status = 'expired',
                        started_at = COALESCE(job.started_at, job.created_at),
                        completed_at = GREATEST(
                            COALESCE(job.started_at, job.created_at),
                            $1::timestamptz
                        )
                    FROM candidates
                    WHERE job.export_job_id = candidates.export_job_id
                    RETURNING job.export_job_id
                    """,
                    now,
                    batch_size,
                )
                counts["export_jobs_expired"] = len(expired_exports)

                expired_social_invites = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT invite_id
                        FROM managed_social_invites
                        WHERE status = 'active' AND expires_at <= $1
                        ORDER BY expires_at, invite_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_social_invites invite
                    SET status = 'expired'
                    FROM candidates
                    WHERE invite.invite_id = candidates.invite_id
                    RETURNING invite.invite_id
                    """,
                    now,
                    batch_size,
                )
                counts["social_invites_expired"] = len(expired_social_invites)

                expired_social_requests = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT request_id
                        FROM managed_social_requests
                        WHERE status = 'pending' AND expires_at <= $1
                        ORDER BY expires_at, request_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_social_requests request
                    SET status = 'expired', decided_at = $1
                    FROM candidates
                    WHERE request.request_id = candidates.request_id
                    RETURNING request.request_id
                    """,
                    now,
                    batch_size,
                )
                counts["social_requests_expired"] = len(expired_social_requests)

                expired_social_pokes = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT poke_id
                        FROM managed_social_pokes
                        WHERE status IN ('queued', 'claimed')
                          AND expires_at <= $1
                        ORDER BY expires_at, poke_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_social_pokes poke
                    SET status = 'expired'
                    FROM candidates
                    WHERE poke.poke_id = candidates.poke_id
                    RETURNING poke.poke_id
                    """,
                    now,
                    batch_size,
                )
                counts["social_pokes_expired"] = len(expired_social_pokes)

                released_social_claims = await connection.fetch(
                    """
                    WITH candidates AS (
                        SELECT poke_id
                        FROM managed_social_pokes
                        WHERE status = 'claimed'
                          AND claim_expires_at <= $1
                          AND expires_at > $1
                        ORDER BY claim_expires_at, poke_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $2
                    )
                    UPDATE managed_social_pokes poke
                    SET status = 'queued',
                        claim_id = NULL,
                        claimed_installation_id = NULL,
                        claimed_at = NULL,
                        claim_expires_at = NULL
                    FROM candidates
                    WHERE poke.poke_id = candidates.poke_id
                    RETURNING poke.poke_id
                    """,
                    now,
                    batch_size,
                )
                counts["social_poke_claims_released"] = len(released_social_claims)

                for key, statement in (
                    (
                        "access_grants",
                        """
                        DELETE FROM managed_object_access_grants
                        WHERE access_grant_id IN (
                            SELECT access_grant_id
                            FROM managed_object_access_grants
                            WHERE expires_at <= $1
                            ORDER BY expires_at, access_grant_id
                            LIMIT $2
                        )
                        RETURNING access_grant_id
                        """,
                    ),
                    (
                        "upload_grants",
                        """
                        DELETE FROM managed_upload_grants
                        WHERE upload_grant_id IN (
                            SELECT upload_grant_id
                            FROM managed_upload_grants
                            WHERE expires_at
                                <= $1::timestamptz - interval '7 days'
                            ORDER BY expires_at, upload_grant_id
                            LIMIT $2
                        )
                        RETURNING upload_grant_id
                        """,
                    ),
                    (
                        "processing_attempts",
                        """
                        DELETE FROM managed_processing_attempts
                        WHERE processing_attempt_id IN (
                            SELECT processing_attempt_id
                            FROM managed_processing_attempts
                            WHERE finished_at
                                <= $1::timestamptz - interval '30 days'
                            ORDER BY finished_at, processing_attempt_id
                            LIMIT $2
                        )
                        RETURNING processing_attempt_id
                        """,
                    ),
                    (
                        "usage_ledger",
                        """
                        DELETE FROM managed_storage_usage_ledger
                        WHERE usage_event_id IN (
                            SELECT usage_event_id
                            FROM managed_storage_usage_ledger
                            WHERE purge_after <= $1
                            ORDER BY purge_after, usage_event_id
                            LIMIT $2
                        )
                        RETURNING usage_event_id
                        """,
                    ),
                    (
                        "audit_events",
                        """
                        DELETE FROM managed_audit_events
                        WHERE audit_event_id IN (
                            SELECT audit_event_id
                            FROM managed_audit_events
                            WHERE purge_after <= $1
                            ORDER BY purge_after, audit_event_id
                            LIMIT $2
                        )
                        RETURNING audit_event_id
                        """,
                    ),
                    (
                        "replay_tombstones",
                        """
                        DELETE FROM managed_replay_tombstones
                        WHERE replay_tombstone_id IN (
                            SELECT replay_tombstone_id
                            FROM managed_replay_tombstones
                            WHERE expires_at <= $1
                            ORDER BY expires_at, replay_tombstone_id
                            LIMIT $2
                        )
                        RETURNING replay_tombstone_id
                        """,
                    ),
                    (
                        "daily_ingest_usage",
                        """
                        DELETE FROM managed_daily_ingest_usage
                        WHERE (account_id, data_class, utc_day) IN (
                            SELECT account_id, data_class, utc_day
                            FROM managed_daily_ingest_usage
                            WHERE utc_day < ($1::date - 400)
                            ORDER BY utc_day, account_id, data_class
                            LIMIT $2
                        )
                        RETURNING account_id
                        """,
                    ),
                    (
                        "social_aliases",
                        """
                        DELETE FROM managed_social_aliases
                        WHERE alias_id IN (
                            SELECT alias_id
                            FROM managed_social_aliases
                            WHERE status = 'revoked'
                              AND purge_after <= $1
                            ORDER BY purge_after, alias_id
                            LIMIT $2
                        )
                        RETURNING alias_id
                        """,
                    ),
                    (
                        "social_invites",
                        """
                        DELETE FROM managed_social_invites
                        WHERE invite_id IN (
                            SELECT invite_id
                            FROM managed_social_invites
                            WHERE status IN ('revoked', 'redeemed', 'expired')
                              AND COALESCE(
                                    redeemed_at,
                                    revoked_at,
                                    expires_at
                                  ) <= $1::timestamptz - interval '30 days'
                            ORDER BY expires_at, invite_id
                            LIMIT $2
                        )
                        RETURNING invite_id
                        """,
                    ),
                    (
                        "social_requests",
                        """
                        DELETE FROM managed_social_requests request
                        WHERE request.request_id IN (
                            SELECT candidate.request_id
                            FROM managed_social_requests candidate
                            WHERE candidate.status IN (
                                    'accepted',
                                    'declined',
                                    'canceled',
                                    'expired'
                                  )
                              AND candidate.decided_at
                                  <= $1::timestamptz - interval '90 days'
                              AND NOT EXISTS (
                                  SELECT 1
                                  FROM managed_social_friendships friendship
                                  WHERE friendship.accepted_request_id =
                                        candidate.request_id
                              )
                            ORDER BY candidate.decided_at, candidate.request_id
                            LIMIT $2
                        )
                        RETURNING request.request_id
                        """,
                    ),
                    (
                        "social_summaries",
                        """
                        DELETE FROM managed_social_daily_summaries
                        WHERE (profile_id, day) IN (
                            SELECT profile_id, day
                            FROM managed_social_daily_summaries
                            WHERE day < (
                                ($1 AT TIME ZONE 'UTC')::date - 89
                            )
                            ORDER BY day, profile_id
                            LIMIT $2
                        )
                        RETURNING profile_id
                        """,
                    ),
                    (
                        "social_pokes",
                        """
                        DELETE FROM managed_social_pokes
                        WHERE poke_id IN (
                            SELECT poke_id
                            FROM managed_social_pokes
                            WHERE status IN ('acknowledged', 'expired')
                              AND created_at
                                  <= $1::timestamptz - interval '30 days'
                            ORDER BY created_at, poke_id
                            LIMIT $2
                        )
                        RETURNING poke_id
                        """,
                    ),
                ):
                    rows = await connection.fetch(statement, now, batch_size)
                    counts[key] = len(rows)

                removed_changes = await connection.fetch(
                    """
                    WITH boundaries AS (
                        SELECT account_id,
                               COALESCE(
                                   min(change_sequence)
                                       FILTER (WHERE purge_after > $1),
                                   max(change_sequence) + 1
                               ) AS first_retained
                        FROM managed_change_events
                        GROUP BY account_id
                    ),
                    candidates AS (
                        SELECT event.account_id, event.change_sequence
                        FROM managed_change_events event
                        JOIN boundaries USING (account_id)
                        WHERE event.purge_after <= $1
                          AND event.change_sequence
                              < boundaries.first_retained
                        ORDER BY event.account_id, event.change_sequence
                        LIMIT $2
                    ),
                    removed AS (
                        DELETE FROM managed_change_events event
                        USING candidates
                        WHERE event.account_id = candidates.account_id
                          AND event.change_sequence
                              = candidates.change_sequence
                        RETURNING event.account_id, event.change_sequence
                    )
                    SELECT account_id,
                           max(change_sequence) AS maximum_sequence,
                           count(*) AS removed_count
                    FROM removed
                    GROUP BY account_id
                    """,
                    now,
                    batch_size,
                )
                counts["change_events"] = sum(
                    int(row["removed_count"]) for row in removed_changes
                )
                for row in removed_changes:
                    await connection.execute(
                        """
                        UPDATE managed_account_change_sequences
                        SET minimum_retained_sequence = GREATEST(
                                minimum_retained_sequence,
                                $2::bigint + 1
                            ),
                            updated_at = $3
                        WHERE account_id = $1
                        """,
                        row["account_id"],
                        row["maximum_sequence"],
                        now,
                    )

                deleted_chunks = await connection.fetch(
                    """
                    DELETE FROM managed_chunks chunk
                    WHERE chunk.chunk_id IN (
                        SELECT candidate.chunk_id
                        FROM managed_chunks candidate
                        WHERE candidate.state = 'deleted'
                          AND candidate.deleted_at
                              <= $1::timestamptz - interval '400 days'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_storage_usage_ledger ledger
                              WHERE ledger.account_id = candidate.account_id
                                AND ledger.chunk_id = candidate.chunk_id
                          )
                          AND NOT EXISTS (
                              SELECT 1
                              FROM managed_aggregate_inputs aggregate_input
                              WHERE aggregate_input.account_id
                                      = candidate.account_id
                                AND aggregate_input.chunk_id
                                      = candidate.chunk_id
                          )
                        ORDER BY candidate.deleted_at, candidate.chunk_id
                        LIMIT $2
                    )
                    RETURNING chunk.chunk_id
                    """,
                    now,
                    batch_size,
                )
                counts["chunk_manifests"] = len(deleted_chunks)
        return counts

    async def request_erasure(
        self,
        *,
        principal: ManagedPrincipal,
        request_id: UUID,
        scope: str,
        confirmation_sha256: str,
        identity_deletion_ticket: bytes | None,
        cooling_off: timedelta,
    ) -> dict[str, Any]:
        if (scope == "account") != (identity_deletion_ticket is not None):
            raise ManagedConfigurationError(
                "account erasure requires one identity deletion ticket"
            )
        if (
            identity_deletion_ticket is not None
            and not 29 <= len(identity_deletion_ticket) <= 1_024
        ):
            raise ManagedConfigurationError("identity deletion ticket is invalid")
        now = await self.coordination_now()
        tenant_replay_hash = self._tenant_replay_hash(principal.account_id)
        job_id = uuid4()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                account = await connection.fetchrow(
                    """
                    SELECT status
                    FROM managed_accounts
                    WHERE account_id = $1
                    FOR UPDATE
                    """,
                    principal.account_id,
                )
                if account is None:
                    raise ManagedNotFoundError("managed account was not found")
                existing = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_erasure_jobs
                    WHERE account_id = $1 AND request_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    request_id,
                )
                if existing is not None:
                    if (
                        existing["scope"] != scope
                        or str(existing["confirmation_sha256"]).strip()
                        != confirmation_sha256
                    ):
                        raise ManagedConflictError("erasure request id was reused")
                    return self._public_erasure(
                        dict(existing),
                        duplicate=True,
                    )
                not_before = now + cooling_off
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_erasure_jobs (
                        erasure_job_id,
                        account_id,
                        request_id,
                        requested_by_identity_id,
                        scope,
                        status,
                        tenant_replay_hash,
                        confirmation_sha256,
                        identity_deletion_ticket,
                        requested_at,
                        not_before,
                        verification_expires_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, 'cooling_off',
                        $6, $7, $8, $9::timestamptz, $10,
                        $9::timestamptz + interval '400 days'
                    )
                    RETURNING *
                    """,
                    job_id,
                    principal.account_id,
                    request_id,
                    principal.identity_id,
                    scope,
                    tenant_replay_hash,
                    confirmation_sha256,
                    identity_deletion_ticket,
                    now,
                    not_before,
                )
                if scope in {"all_managed_data", "account"}:
                    profile = await connection.fetchrow(
                        """
                        SELECT profile_id
                        FROM managed_social_profiles
                        WHERE account_id = $1 AND status = 'active'
                        FOR UPDATE
                        """,
                        principal.account_id,
                    )
                    if profile is not None:
                        await _retire_managed_safety_profile(
                            connection,
                            profile_id=profile["profile_id"],
                            now=now,
                        )
                    await connection.execute(
                        """
                        UPDATE managed_accounts
                        SET status = 'erasure_pending',
                            erasure_requested_at = $2,
                            updated_at = $2
                        WHERE account_id = $1
                        """,
                        principal.account_id,
                        now,
                    )
        return self._public_erasure(dict(row), duplicate=False)

    async def get_erasure(
        self,
        *,
        principal: ManagedPrincipal,
        erasure_job_id: UUID,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT *
            FROM managed_erasure_jobs
            WHERE account_id = $1 AND erasure_job_id = $2
            """,
            principal.account_id,
            erasure_job_id,
        )
        if row is None:
            raise ManagedNotFoundError("managed erasure was not found")
        return self._public_erasure(dict(row), duplicate=False)

    async def cancel_erasure(
        self,
        *,
        principal: ManagedPrincipal,
        erasure_job_id: UUID,
    ) -> dict[str, Any]:
        now = await self.coordination_now()
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    UPDATE managed_erasure_jobs
                    SET status = 'canceled',
                        identity_deletion_ticket = NULL,
                        started_at = COALESCE(started_at, not_before),
                        completed_at = GREATEST(not_before, $3)
                    WHERE account_id = $1
                      AND erasure_job_id = $2
                      AND status = 'cooling_off'
                      AND not_before > $3
                    RETURNING *
                    """,
                    principal.account_id,
                    erasure_job_id,
                    now,
                )
                if row is None:
                    raise ManagedConflictError(
                        "managed erasure can no longer be canceled"
                    )
                await connection.execute(
                    """
                    UPDATE managed_accounts
                    SET status = 'active',
                        erasure_requested_at = NULL,
                        updated_at = $2
                    WHERE account_id = $1
                      AND status = 'erasure_pending'
                    """,
                    principal.account_id,
                    now,
                )
        return self._public_erasure(dict(row), duplicate=False)

    @staticmethod
    def _public_document(
        row: dict[str, Any],
        *,
        duplicate: bool,
    ) -> dict[str, Any]:
        ciphertext = row.get("payload_ciphertext")
        return {
            "document_kind": row["document_kind"],
            "document_id": str(row["document_id"]),
            "revision": int(row["document_revision"]),
            "origin_installation_id": row["origin_installation_id"],
            "content_mode": row["content_mode"],
            "client_key_id": (
                str(row["client_key_id"])
                if row.get("client_key_id") is not None
                else None
            ),
            "content_sha256": str(row["content_sha256"]).strip(),
            "payload_json": _decoded_json(row.get("payload_json")),
            "payload_ciphertext_base64": (
                base64.b64encode(bytes(ciphertext)).decode("ascii")
                if ciphertext is not None
                else None
            ),
            "updated_at": row["updated_at"],
            "deleted_at": row.get("deleted_at"),
            "duplicate": duplicate,
        }

    @staticmethod
    def _public_restore(
        row: dict[str, Any],
        *,
        duplicate: bool,
    ) -> dict[str, Any]:
        return {
            "restore_job_id": str(row["restore_job_id"]),
            "status": row["status"],
            "snapshot_at": row["snapshot_at"],
            "change_sequence": int(row["change_sequence"]),
            "filters": _decoded_json(row["filters"]),
            "selected_objects": row["selected_objects"],
            "selected_bytes": row["selected_bytes"],
            "delivered_objects": row["delivered_objects"],
            "delivered_bytes": row["delivered_bytes"],
            "created_at": row["created_at"],
            "started_at": row["started_at"],
            "completed_at": row["completed_at"],
            "expires_at": row["expires_at"],
            "duplicate": duplicate,
        }

    @staticmethod
    def _public_export(
        row: dict[str, Any],
        *,
        duplicate: bool,
    ) -> dict[str, Any]:
        return {
            "export_job_id": str(row["export_job_id"]),
            "status": row["status"],
            "format": row["format"],
            "content_mode": row["content_mode"],
            "client_key_id": (
                str(row["client_key_id"]) if row["client_key_id"] is not None else None
            ),
            "scope": _decoded_json(row["scope"]),
            "object_key": row["output_object_key"],
            "expected_sha256": (
                str(row["expected_sha256"]).strip()
                if row.get("expected_sha256") is not None
                else None
            ),
            "expected_bytes": row.get("expected_bytes"),
            "content_type": row.get("content_type"),
            "output_generation": row["output_generation"],
            "output_sha256": (
                str(row["output_sha256"]).strip()
                if row["output_sha256"] is not None
                else None
            ),
            "output_bytes": row["output_bytes"],
            "created_at": row["created_at"],
            "completed_at": row["completed_at"],
            "expires_at": row["expires_at"],
            "duplicate": duplicate,
        }

    @staticmethod
    def _public_erasure(
        row: dict[str, Any],
        *,
        duplicate: bool,
    ) -> dict[str, Any]:
        return {
            "erasure_job_id": str(row["erasure_job_id"]),
            "scope": row["scope"],
            "status": row["status"],
            "objects_selected": row["objects_selected"],
            "objects_deleted": row["objects_deleted"],
            "bytes_selected": row["bytes_selected"],
            "bytes_deleted": row["bytes_deleted"],
            "database_rows_deleted": row["database_rows_deleted"],
            "requested_at": row["requested_at"],
            "not_before": row["not_before"],
            "started_at": row["started_at"],
            "completed_at": row["completed_at"],
            "verification_expires_at": row["verification_expires_at"],
            "duplicate": duplicate,
        }

    @staticmethod
    def _public_chunk(
        row: dict[str, Any],
        *,
        duplicate: bool,
    ) -> dict[str, Any]:
        return {
            "chunk_id": str(row["chunk_id"]),
            "source_id": str(row["source_id"]),
            "data_class": row["data_class"],
            "schema_version": row["schema_version"],
            "content_mode": row["content_mode"],
            "authoritative_snapshot": row["authoritative_snapshot"],
            "state": row["state"],
            "event_start": row["event_start"],
            "event_end": row["event_end"],
            "compression": row["compression"],
            "content_type": row["content_type"],
            "expected_sha256": str(row["expected_sha256"]).strip(),
            "expected_compressed_bytes": row["expected_compressed_bytes"],
            "expected_uncompressed_bytes": row["expected_uncompressed_bytes"],
            "object_key": row["object_key"],
            "object_generation": row["object_generation"],
            "expires_at": row["expires_at"],
            "reserved_at": row["reserved_at"],
            "uploaded_at": row["uploaded_at"],
            "available_at": row["available_at"],
            "duplicate": duplicate,
        }

    @staticmethod
    def _require_active(principal: ManagedPrincipal) -> None:
        if principal.account_status != "active":
            raise ManagedForbiddenError("managed account is not active")
