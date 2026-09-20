from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Callable, Literal
from uuid import UUID, uuid4

from app.managed_identity import ManagedIdentityClaims
from app.observability import emit_operational_event
from app.repository import PostgresRepository

AuthorityStateName = Literal[
    "local_only",
    "uploading",
    "shadow",
    "parity_approved",
    "cloud_authoritative",
    "rollback",
    "restore_proven",
]
AuthorityTransitionReason = Literal[
    "migration_started",
    "upload_acknowledged",
    "parity_approved",
    "restore_proven",
    "cloud_authority_enabled",
    "rollback_requested",
    "opt_out_requested",
    "local_authority_restored",
    "reconsent_recorded",
]
OperationalSink = Callable[..., None]

AUTHORITY_STATES = frozenset(
    {
        "local_only",
        "uploading",
        "shadow",
        "parity_approved",
        "cloud_authoritative",
        "rollback",
        "restore_proven",
    }
)
ALLOWED_AUTHORITY_TRANSITIONS: dict[str, frozenset[str]] = {
    "local_only": frozenset({"local_only", "uploading", "rollback"}),
    "uploading": frozenset({"shadow", "rollback"}),
    "shadow": frozenset({"parity_approved", "rollback"}),
    "parity_approved": frozenset({"restore_proven", "rollback"}),
    "restore_proven": frozenset({"cloud_authoritative", "rollback"}),
    "cloud_authoritative": frozenset({"rollback"}),
    "rollback": frozenset({"local_only", "uploading", "rollback"}),
}
AUTHORITY_REASON_TARGETS: dict[str, frozenset[str]] = {
    "migration_started": frozenset({"uploading"}),
    "upload_acknowledged": frozenset({"shadow"}),
    "parity_approved": frozenset({"parity_approved"}),
    "restore_proven": frozenset({"restore_proven"}),
    "cloud_authority_enabled": frozenset({"cloud_authoritative"}),
    "rollback_requested": frozenset({"rollback"}),
    "opt_out_requested": frozenset({"rollback"}),
    "local_authority_restored": frozenset({"local_only"}),
    "reconsent_recorded": frozenset({"local_only"}),
}
_DATA_CLASS_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_POLICY_VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_POLICY_KIND_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_INSTALLATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class UnifiedIdentityAuthorityError(Exception):
    """Base class for unified identity and authority failures."""


class UnifiedIdentityUnavailableError(UnifiedIdentityAuthorityError):
    """The principal or linked account is absent, retired, or inactive."""


class UnifiedIdentityCollisionError(UnifiedIdentityAuthorityError):
    """An identity root or domain account is already linked differently."""


class AuthorityTransitionRejectedError(UnifiedIdentityAuthorityError):
    """The requested authority transition or its evidence is not allowed."""


class AuthorityTransitionConflictError(UnifiedIdentityAuthorityError):
    """An idempotency key was reused for a different authority transition."""


@dataclass(frozen=True, slots=True)
class UnifiedPrincipal:
    principal_id: UUID
    status: str
    managed_account_id: UUID | None
    managed_identity_id: UUID | None
    ownership_account_id: UUID | None
    ownership_identity_id: UUID | None


@dataclass(frozen=True, slots=True)
class AuthorityEvidence:
    evidence_id: UUID
    receipt_sha256: str
    recorded_at: datetime

    def __post_init__(self) -> None:
        if _SHA256_PATTERN.fullmatch(self.receipt_sha256) is None:
            raise ValueError("receipt_sha256 must be a lowercase SHA-256 digest")
        if self.recorded_at.tzinfo is None or self.recorded_at.utcoffset() is None:
            raise ValueError("recorded_at must include a UTC offset")
        object.__setattr__(self, "recorded_at", self.recorded_at.astimezone(UTC))


@dataclass(frozen=True, slots=True)
class ManagedAuthorityState:
    principal_id: UUID
    managed_account_id: UUID
    data_class: str
    state: AuthorityStateName
    transition_version: int
    upload_acknowledgement_id: UUID | None
    upload_acknowledgement_sha256: str | None
    upload_acknowledged_at: datetime | None
    restore_proof_id: UUID | None
    restore_proof_sha256: str | None
    restore_proven_at: datetime | None
    pruning_authorized_at: datetime | None
    last_opt_out_at: datetime | None
    last_reconsented_at: datetime | None
    reconsent_consent_event_id: UUID | None
    reconsent_policy_version: str | None
    reconsent_policy_sha256: str | None

    @property
    def pruning_authorized(self) -> bool:
        return (
            self.state == "cloud_authoritative"
            and self.upload_acknowledgement_id is not None
            and self.restore_proof_id is not None
            and self.pruning_authorized_at is not None
        )


@dataclass(frozen=True, slots=True)
class AuthorityTransitionResult:
    transition_id: UUID
    state: AuthorityStateName
    transition_version: int
    pruning_authorized: bool
    duplicate: bool = False


class PostgresUnifiedIdentityAuthorityRepository:
    """Reconcile Firebase identity roots and enforce D-059 authority changes."""

    def __init__(
        self,
        primary: PostgresRepository,
        *,
        event_sink: OperationalSink = emit_operational_event,
    ) -> None:
        self.primary = primary
        self.event_sink = event_sink

    def _pool(self) -> Any:
        pool = self.primary._pool
        if pool is None:
            raise RuntimeError("unified identity authority repository is not started")
        return pool

    async def reconcile_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> UnifiedPrincipal:
        lock_key = _identity_lock_key(claims)
        outcome = "failed"
        managed_linked = False
        ownership_linked = False
        try:
            async with self._pool().acquire() as connection:
                async with connection.transaction():
                    await connection.execute(
                        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                        lock_key,
                    )
                    now = await connection.fetchval("SELECT clock_timestamp()")
                    await connection.execute(
                        """
                        INSERT INTO unified_account_principals (
                            principal_id,
                            issuer,
                            provider_tenant,
                            subject_hash,
                            created_at,
                            updated_at
                        ) VALUES ($1, $2, $3, $4, $5, $5)
                        ON CONFLICT (
                            issuer,
                            provider_tenant,
                            subject_hash
                        ) DO NOTHING
                        """,
                        uuid4(),
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                        now,
                    )
                    principal = await connection.fetchrow(
                        """
                        SELECT principal_id, status
                        FROM unified_account_principals
                        WHERE issuer = $1
                          AND provider_tenant = $2
                          AND subject_hash = $3
                        FOR UPDATE
                        """,
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                    )
                    if principal is None or principal["status"] != "active":
                        raise UnifiedIdentityUnavailableError(
                            "unified identity root is unavailable"
                        )

                    managed_identity = await connection.fetchrow(
                        """
                        SELECT identity.account_id, identity.identity_id
                        FROM managed_external_identities AS identity
                        JOIN managed_accounts AS account
                          ON account.account_id = identity.account_id
                        WHERE identity.issuer = $1
                          AND identity.provider_tenant = $2
                          AND identity.subject_hash = $3
                          AND identity.status = 'active'
                          AND account.status = 'active'
                        """,
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                    )
                    ownership_identity = await connection.fetchrow(
                        """
                        SELECT identity.account_id, identity.identity_id
                        FROM ownership_external_identities AS identity
                        JOIN ownership_accounts AS account
                          ON account.account_id = identity.account_id
                        WHERE identity.issuer = $1
                          AND identity.provider_tenant = $2
                          AND identity.subject_hash = $3
                          AND identity.status = 'active'
                          AND account.status = 'active'
                        """,
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                    )
                    if managed_identity is not None:
                        await self._reconcile_managed_link(
                            connection,
                            principal_id=principal["principal_id"],
                            account_id=managed_identity["account_id"],
                            identity_id=managed_identity["identity_id"],
                            claims=claims,
                            linked_at=now,
                        )
                        managed_linked = True
                    if ownership_identity is not None:
                        await self._reconcile_ownership_link(
                            connection,
                            principal_id=principal["principal_id"],
                            account_id=ownership_identity["account_id"],
                            identity_id=ownership_identity["identity_id"],
                            claims=claims,
                            linked_at=now,
                        )
                        ownership_linked = True
                    result = await self._principal(
                        connection,
                        principal_id=principal["principal_id"],
                    )
            outcome = "reconciled"
            return result
        except UnifiedIdentityAuthorityError:
            outcome = "rejected"
            raise
        except Exception as error:
            if getattr(error, "sqlstate", None) in {"23503", "23505", "23514"}:
                outcome = "collision"
                raise UnifiedIdentityCollisionError(
                    "unified identity reconciliation conflicted"
                ) from None
            raise
        finally:
            self._event(
                "unified_identity.reconciliation",
                outcome=outcome,
                managed_linked=managed_linked,
                ownership_linked=ownership_linked,
            )

    async def authority_state(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
    ) -> ManagedAuthorityState:
        _validate_data_class(data_class)
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await self._require_authority_scope(
                    connection,
                    principal_id=principal_id,
                    managed_account_id=managed_account_id,
                    data_class=data_class,
                )
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_authority_states
                    WHERE managed_account_id = $1
                      AND data_class = $2
                    """,
                    managed_account_id,
                    data_class,
                )
                if row is None:
                    return _baseline_authority_state(
                        principal_id=principal_id,
                        managed_account_id=managed_account_id,
                        data_class=data_class,
                    )
                if row["principal_id"] != principal_id:
                    raise UnifiedIdentityCollisionError(
                        "managed authority scope is linked differently"
                    )
                return _authority_state(row)

    async def transition_authority(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
        request_id: UUID,
        target_state: AuthorityStateName,
        reason: AuthorityTransitionReason,
        upload_acknowledgement: AuthorityEvidence | None = None,
        restore_proof: AuthorityEvidence | None = None,
        authorize_pruning: bool = False,
        reconsent_policy_kind: str | None = None,
        reconsent_policy_version: str | None = None,
        reconsent_policy_sha256: str | None = None,
        reconsent_installation_id: str | None = None,
    ) -> AuthorityTransitionResult:
        outcome = "failed"
        from_state = "unknown"
        pruning_authorized = False
        try:
            _validate_transition_request(
                data_class=data_class,
                target_state=target_state,
                reason=reason,
                upload_acknowledgement=upload_acknowledgement,
                restore_proof=restore_proof,
                authorize_pruning=authorize_pruning,
                reconsent_policy_kind=reconsent_policy_kind,
                reconsent_policy_version=reconsent_policy_version,
                reconsent_policy_sha256=reconsent_policy_sha256,
                reconsent_installation_id=reconsent_installation_id,
            )
            request_sha256 = _transition_request_digest(
                target_state=target_state,
                reason=reason,
                upload_acknowledgement=upload_acknowledgement,
                restore_proof=restore_proof,
                authorize_pruning=authorize_pruning,
                reconsent_policy_kind=reconsent_policy_kind,
                reconsent_policy_version=reconsent_policy_version,
                reconsent_policy_sha256=reconsent_policy_sha256,
                reconsent_installation_id=reconsent_installation_id,
            )
            async with self._pool().acquire() as connection:
                async with connection.transaction():
                    await connection.execute(
                        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                        _authority_lock_key(managed_account_id, data_class),
                    )
                    state = await self._ensure_authority_state(
                        connection,
                        principal_id=principal_id,
                        managed_account_id=managed_account_id,
                        data_class=data_class,
                    )
                    existing = await connection.fetchrow(
                        """
                        SELECT transition_id,
                               request_sha256,
                               transition_version,
                               to_state,
                               pruning_authorized_at
                        FROM managed_authority_transitions
                        WHERE managed_account_id = $1
                          AND data_class = $2
                          AND request_id = $3
                        """,
                        managed_account_id,
                        data_class,
                        request_id,
                    )
                    if existing is not None:
                        if not hmac.compare_digest(
                            str(existing["request_sha256"]).strip(),
                            request_sha256,
                        ):
                            raise AuthorityTransitionConflictError(
                                "authority request was reused for different content"
                            )
                        outcome = "duplicate"
                        pruning_authorized = (
                            existing["pruning_authorized_at"] is not None
                        )
                        return AuthorityTransitionResult(
                            transition_id=existing["transition_id"],
                            state=str(existing["to_state"]),
                            transition_version=int(existing["transition_version"]),
                            pruning_authorized=pruning_authorized,
                            duplicate=True,
                        )

                    from_state = str(state["state"])
                    if target_state not in ALLOWED_AUTHORITY_TRANSITIONS[from_state]:
                        raise AuthorityTransitionRejectedError(
                            "authority transition is not allowed"
                        )
                    if target_state == "uploading":
                        last_opt_out_at = state["last_opt_out_at"]
                        last_reconsented_at = state["last_reconsented_at"]
                        if last_opt_out_at is not None and (
                            last_reconsented_at is None
                            or last_reconsented_at <= last_opt_out_at
                        ):
                            raise AuthorityTransitionRejectedError(
                                "authority promotion requires explicit re-consent"
                            )
                    now = await connection.fetchval("SELECT clock_timestamp()")
                    (
                        upload_id,
                        upload_sha256,
                        upload_at,
                        restore_id,
                        restore_sha256,
                        restore_at,
                        pruning_at,
                    ) = _transition_evidence(
                        state=state,
                        target_state=target_state,
                        upload_acknowledgement=upload_acknowledgement,
                        restore_proof=restore_proof,
                        authorize_pruning=authorize_pruning,
                        now=now,
                    )
                    transition_id = uuid4()
                    transition_version = int(state["transition_version"]) + 1
                    last_opt_out_at = state["last_opt_out_at"]
                    last_reconsented_at = state["last_reconsented_at"]
                    stored_consent_event_id = state["reconsent_consent_event_id"]
                    stored_policy_version = state["reconsent_policy_version"]
                    stored_policy_sha256 = _optional_digest(
                        state["reconsent_policy_sha256"]
                    )
                    if reason == "opt_out_requested":
                        last_opt_out_at = now
                    elif reason == "reconsent_recorded":
                        last_reconsented_at = now
                        assert reconsent_policy_kind is not None
                        assert reconsent_policy_version is not None
                        assert reconsent_policy_sha256 is not None
                        assert reconsent_installation_id is not None
                        stored_consent_event_id = await self._record_reconsent_event(
                            connection,
                            managed_account_id=managed_account_id,
                            data_class=data_class,
                            request_id=request_id,
                            policy_kind=reconsent_policy_kind,
                            policy_version=reconsent_policy_version,
                            policy_sha256=reconsent_policy_sha256,
                            installation_id=reconsent_installation_id,
                            now=now,
                        )
                        stored_policy_version = reconsent_policy_version
                        stored_policy_sha256 = reconsent_policy_sha256
                    await connection.execute(
                        """
                        INSERT INTO managed_authority_transitions (
                            transition_id,
                            principal_id,
                            managed_account_id,
                            data_class,
                            request_id,
                            request_sha256,
                            transition_version,
                            from_state,
                            to_state,
                            reason,
                            upload_acknowledgement_id,
                            upload_acknowledgement_sha256,
                            upload_acknowledged_at,
                            restore_proof_id,
                            restore_proof_sha256,
                            restore_proven_at,
                            pruning_authorized_at,
                            last_opt_out_at,
                            last_reconsented_at,
                            reconsent_consent_event_id,
                            reconsent_policy_version,
                            reconsent_policy_sha256,
                            occurred_at
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                            $11, $12, $13, $14, $15, $16, $17, $18, $19,
                            $20, $21, $22, $23
                        )
                        """,
                        transition_id,
                        principal_id,
                        managed_account_id,
                        data_class,
                        request_id,
                        request_sha256,
                        transition_version,
                        from_state,
                        target_state,
                        reason,
                        upload_id,
                        upload_sha256,
                        upload_at,
                        restore_id,
                        restore_sha256,
                        restore_at,
                        pruning_at,
                        last_opt_out_at,
                        last_reconsented_at,
                        stored_consent_event_id,
                        stored_policy_version,
                        stored_policy_sha256,
                        now,
                    )
                    await connection.execute(
                        """
                        UPDATE managed_authority_states
                        SET state = $4,
                            transition_version = $5,
                            last_transition_id = $6,
                            upload_acknowledgement_id = $7,
                            upload_acknowledgement_sha256 = $8,
                            upload_acknowledged_at = $9,
                            restore_proof_id = $10,
                            restore_proof_sha256 = $11,
                            restore_proven_at = $12,
                            pruning_authorized_at = $13,
                            last_opt_out_at = $14,
                            last_reconsented_at = $15,
                            reconsent_consent_event_id = $16,
                            reconsent_policy_version = $17,
                            reconsent_policy_sha256 = $18,
                            updated_at = $19
                        WHERE principal_id = $1
                          AND managed_account_id = $2
                          AND data_class = $3
                        """,
                        principal_id,
                        managed_account_id,
                        data_class,
                        target_state,
                        transition_version,
                        transition_id,
                        upload_id,
                        upload_sha256,
                        upload_at,
                        restore_id,
                        restore_sha256,
                        restore_at,
                        pruning_at,
                        last_opt_out_at,
                        last_reconsented_at,
                        stored_consent_event_id,
                        stored_policy_version,
                        stored_policy_sha256,
                        now,
                    )
            outcome = "transitioned"
            pruning_authorized = pruning_at is not None
            return AuthorityTransitionResult(
                transition_id=transition_id,
                state=target_state,
                transition_version=transition_version,
                pruning_authorized=pruning_authorized,
            )
        except UnifiedIdentityAuthorityError:
            outcome = "rejected"
            raise
        except Exception as error:
            if getattr(error, "sqlstate", None) in {"23503", "23505", "23514"}:
                outcome = "rejected"
                raise AuthorityTransitionRejectedError(
                    "authority transition failed closed"
                ) from None
            raise
        finally:
            self._event(
                "managed_authority.transition",
                outcome=outcome,
                from_state=from_state,
                to_state=target_state,
                pruning_authorized=pruning_authorized,
            )

    async def request_rollback(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
        request_id: UUID,
        opt_out: bool = False,
    ) -> AuthorityTransitionResult:
        return await self.transition_authority(
            principal_id=principal_id,
            managed_account_id=managed_account_id,
            data_class=data_class,
            request_id=request_id,
            target_state="rollback",
            reason="opt_out_requested" if opt_out else "rollback_requested",
        )

    async def restore_local_authority(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
        request_id: UUID,
    ) -> AuthorityTransitionResult:
        return await self.transition_authority(
            principal_id=principal_id,
            managed_account_id=managed_account_id,
            data_class=data_class,
            request_id=request_id,
            target_state="local_only",
            reason="local_authority_restored",
        )

    async def record_reconsent(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
        request_id: UUID,
        policy_kind: str,
        policy_version: str,
        policy_sha256: str,
        installation_id: str,
    ) -> AuthorityTransitionResult:
        return await self.transition_authority(
            principal_id=principal_id,
            managed_account_id=managed_account_id,
            data_class=data_class,
            request_id=request_id,
            target_state="local_only",
            reason="reconsent_recorded",
            reconsent_policy_kind=policy_kind,
            reconsent_policy_version=policy_version,
            reconsent_policy_sha256=policy_sha256,
            reconsent_installation_id=installation_id,
        )

    @staticmethod
    async def _record_reconsent_event(
        connection: Any,
        *,
        managed_account_id: UUID,
        data_class: str,
        request_id: UUID,
        policy_kind: str,
        policy_version: str,
        policy_sha256: str,
        installation_id: str,
        now: datetime,
    ) -> UUID:
        reconsent_ready = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM managed_policy_documents AS policy
                JOIN managed_account_installations AS installation
                  ON installation.account_id = $5
                 AND installation.installation_id = $6
                JOIN installation_credentials AS credential
                  ON credential.installation_id
                        = installation.installation_id
                WHERE policy.policy_kind = $1
                  AND policy.policy_version = $2
                  AND policy.document_sha256 = $3
                  AND policy.effective_at <= $4
                  AND (
                        policy.retired_at IS NULL
                        OR policy.retired_at > $4
                  )
                  AND installation.status IN ('active', 'limited')
                  AND installation.revoked_at IS NULL
                  AND installation.registered_at <= $4
                  AND credential.revoked_at IS NULL
                  AND credential.created_at <= $4
            )
            """,
            policy_kind,
            policy_version,
            policy_sha256,
            now,
            managed_account_id,
            installation_id,
        )
        if reconsent_ready is not True:
            raise AuthorityTransitionRejectedError(
                "re-consent policy or installation is not active"
            )
        existing = await connection.fetchrow(
            """
            SELECT consent_event_id,
                   policy_kind,
                   policy_version,
                   decision,
                   data_classes,
                   installation_id,
                   occurred_at
            FROM managed_consent_events
            WHERE account_id = $1 AND request_id = $2
            """,
            managed_account_id,
            request_id,
        )
        if existing is not None:
            raise AuthorityTransitionConflictError(
                "re-consent request was already used by the consent ledger"
            )

        consent_event_id = uuid4()
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
                $1, $2, $3, $4, 'granted', ARRAY[$5]::text[],
                $6, $7, $8, $8
            )
            """,
            consent_event_id,
            managed_account_id,
            policy_kind,
            policy_version,
            data_class,
            installation_id,
            request_id,
            now,
        )
        return consent_event_id

    async def pruning_authorized(
        self,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
    ) -> bool:
        state = await self.authority_state(
            principal_id=principal_id,
            managed_account_id=managed_account_id,
            data_class=data_class,
        )
        return state.pruning_authorized

    async def _reconcile_managed_link(
        self,
        connection: Any,
        *,
        principal_id: UUID,
        account_id: UUID,
        identity_id: UUID,
        claims: ManagedIdentityClaims,
        linked_at: datetime,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            f"noop-managed-erasure-account:{account_id}",
        )
        active_identity = await connection.fetchrow(
            """
            SELECT identity.issuer,
                   identity.provider_tenant,
                   identity.subject_hash
            FROM managed_external_identities AS identity
            JOIN managed_accounts AS account
              ON account.account_id = identity.account_id
            WHERE identity.account_id = $1
              AND identity.identity_id = $2
              AND identity.status = 'active'
              AND account.status = 'active'
            FOR SHARE OF identity, account
            """,
            account_id,
            identity_id,
        )
        if active_identity is None or (
            active_identity["issuer"] != claims.issuer
            or active_identity["provider_tenant"] != claims.provider_tenant
            or str(active_identity["subject_hash"]).strip() != claims.subject_hash
        ):
            raise UnifiedIdentityUnavailableError(
                "managed account identity is unavailable"
            )
        rows = await connection.fetch(
            """
            SELECT principal_id, managed_account_id, managed_identity_id
            FROM unified_managed_account_links
            WHERE principal_id = $1
               OR managed_account_id = $2
               OR managed_identity_id = $3
            FOR UPDATE
            """,
            principal_id,
            account_id,
            identity_id,
        )
        if rows:
            if len(rows) != 1 or not (
                rows[0]["principal_id"] == principal_id
                and rows[0]["managed_account_id"] == account_id
                and rows[0]["managed_identity_id"] == identity_id
            ):
                raise UnifiedIdentityCollisionError(
                    "managed account identity is linked differently"
                )
            return
        await connection.execute(
            """
            INSERT INTO unified_managed_account_links (
                principal_id,
                managed_account_id,
                managed_identity_id,
                issuer,
                provider_tenant,
                subject_hash,
                linked_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7)
            """,
            principal_id,
            account_id,
            identity_id,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
            linked_at,
        )

    async def _reconcile_ownership_link(
        self,
        connection: Any,
        *,
        principal_id: UUID,
        account_id: UUID,
        identity_id: UUID,
        claims: ManagedIdentityClaims,
        linked_at: datetime,
    ) -> None:
        rows = await connection.fetch(
            """
            SELECT principal_id, ownership_account_id, ownership_identity_id
            FROM unified_ownership_account_links
            WHERE principal_id = $1
               OR ownership_account_id = $2
               OR ownership_identity_id = $3
            FOR UPDATE
            """,
            principal_id,
            account_id,
            identity_id,
        )
        if rows:
            if len(rows) != 1 or not (
                rows[0]["principal_id"] == principal_id
                and rows[0]["ownership_account_id"] == account_id
                and rows[0]["ownership_identity_id"] == identity_id
            ):
                raise UnifiedIdentityCollisionError(
                    "ownership account identity is linked differently"
                )
            return
        await connection.execute(
            """
            INSERT INTO unified_ownership_account_links (
                principal_id,
                ownership_account_id,
                ownership_identity_id,
                issuer,
                provider_tenant,
                subject_hash,
                linked_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7)
            """,
            principal_id,
            account_id,
            identity_id,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
            linked_at,
        )

    async def _principal(
        self,
        connection: Any,
        *,
        principal_id: UUID,
    ) -> UnifiedPrincipal:
        row = await connection.fetchrow(
            """
            SELECT principal.principal_id,
                   principal.status,
                   managed.managed_account_id,
                   managed.managed_identity_id,
                   ownership.ownership_account_id,
                   ownership.ownership_identity_id
            FROM unified_account_principals AS principal
            LEFT JOIN unified_managed_account_links AS managed
              USING (principal_id)
            LEFT JOIN unified_ownership_account_links AS ownership
              USING (principal_id)
            WHERE principal.principal_id = $1
            """,
            principal_id,
        )
        if row is None:
            raise UnifiedIdentityUnavailableError(
                "unified identity root is unavailable"
            )
        return UnifiedPrincipal(
            principal_id=row["principal_id"],
            status=str(row["status"]),
            managed_account_id=row["managed_account_id"],
            managed_identity_id=row["managed_identity_id"],
            ownership_account_id=row["ownership_account_id"],
            ownership_identity_id=row["ownership_identity_id"],
        )

    async def _ensure_authority_state(
        self,
        connection: Any,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
    ) -> Any:
        await self._require_authority_scope(
            connection,
            principal_id=principal_id,
            managed_account_id=managed_account_id,
            data_class=data_class,
        )
        await connection.execute(
            """
            INSERT INTO managed_authority_states (
                principal_id,
                managed_account_id,
                data_class
            ) VALUES ($1, $2, $3)
            ON CONFLICT (managed_account_id, data_class) DO NOTHING
            """,
            principal_id,
            managed_account_id,
            data_class,
        )
        row = await connection.fetchrow(
            """
            SELECT *
            FROM managed_authority_states
            WHERE managed_account_id = $1
              AND data_class = $2
            FOR UPDATE
            """,
            managed_account_id,
            data_class,
        )
        if row is None or row["principal_id"] != principal_id:
            raise UnifiedIdentityCollisionError(
                "managed authority scope is linked differently"
            )
        return row

    async def _require_authority_scope(
        self,
        connection: Any,
        *,
        principal_id: UUID,
        managed_account_id: UUID,
        data_class: str,
    ) -> None:
        active = await connection.fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM unified_account_principals AS principal
                JOIN unified_managed_account_links AS link
                  USING (principal_id)
                JOIN managed_accounts AS account
                  ON account.account_id = link.managed_account_id
                JOIN managed_external_identities AS identity
                  ON identity.account_id = link.managed_account_id
                 AND identity.identity_id = link.managed_identity_id
                JOIN managed_subscriptions AS subscription
                  ON subscription.account_id = link.managed_account_id
                 AND subscription.status IN (
                        'trial',
                        'active',
                        'grace',
                        'paused'
                 )
                JOIN managed_plan_data_rules AS rule
                  ON rule.plan_code = subscription.plan_code
                 AND rule.plan_revision = subscription.plan_revision
                 AND rule.data_class = $3
                JOIN LATERAL (
                    SELECT consent.decision
                    FROM managed_consent_events AS consent
                    WHERE consent.account_id = link.managed_account_id
                      AND $3 = ANY(consent.data_classes)
                    ORDER BY consent.occurred_at DESC,
                             consent.recorded_at DESC,
                             consent.consent_event_id DESC
                    LIMIT 1
                ) AS consent
                  ON consent.decision = 'granted'
                WHERE principal.principal_id = $1
                  AND link.managed_account_id = $2
                  AND principal.status = 'active'
                  AND account.status = 'active'
                  AND identity.status = 'active'
            )
            """,
            principal_id,
            managed_account_id,
            data_class,
        )
        if active is not True:
            raise AuthorityTransitionRejectedError(
                "managed authority data class is unavailable"
            )

    def _event(self, event: str, **fields: object) -> None:
        try:
            self.event_sink(
                event,
                service="noop-identity-authority",
                **fields,
            )
        except Exception:
            return


def _validate_data_class(data_class: str) -> None:
    if _DATA_CLASS_PATTERN.fullmatch(data_class) is None:
        raise AuthorityTransitionRejectedError("data_class is invalid")


def _validate_transition_request(
    *,
    data_class: str,
    target_state: str,
    reason: str,
    upload_acknowledgement: AuthorityEvidence | None,
    restore_proof: AuthorityEvidence | None,
    authorize_pruning: bool,
    reconsent_policy_kind: str | None = None,
    reconsent_policy_version: str | None = None,
    reconsent_policy_sha256: str | None = None,
    reconsent_installation_id: str | None = None,
) -> None:
    _validate_data_class(data_class)
    if target_state not in AUTHORITY_STATES:
        raise AuthorityTransitionRejectedError("authority target state is invalid")
    if target_state not in AUTHORITY_REASON_TARGETS.get(reason, frozenset()):
        raise AuthorityTransitionRejectedError(
            "authority transition reason does not match its target"
        )
    if target_state == "shadow":
        if upload_acknowledgement is None or restore_proof is not None:
            raise AuthorityTransitionRejectedError(
                "shadow authority requires one exact upload acknowledgement"
            )
    elif upload_acknowledgement is not None:
        raise AuthorityTransitionRejectedError(
            "upload acknowledgement is accepted only when entering shadow"
        )
    if target_state == "restore_proven":
        if restore_proof is None:
            raise AuthorityTransitionRejectedError(
                "restore_proven requires one exact restore proof"
            )
    elif restore_proof is not None:
        raise AuthorityTransitionRejectedError(
            "restore proof is accepted only when entering restore_proven"
        )
    if authorize_pruning and target_state != "cloud_authoritative":
        raise AuthorityTransitionRejectedError(
            "pruning can be authorized only with cloud authority"
        )
    if reason == "reconsent_recorded":
        if (
            reconsent_policy_kind is None
            or _POLICY_KIND_PATTERN.fullmatch(reconsent_policy_kind) is None
            or reconsent_policy_version is None
            or _POLICY_VERSION_PATTERN.fullmatch(reconsent_policy_version) is None
            or reconsent_policy_sha256 is None
            or _SHA256_PATTERN.fullmatch(reconsent_policy_sha256) is None
            or reconsent_installation_id is None
            or _INSTALLATION_ID_PATTERN.fullmatch(reconsent_installation_id) is None
        ):
            raise AuthorityTransitionRejectedError(
                "re-consent requires an exact policy version and digest"
            )
    elif (
        reconsent_policy_kind is not None
        or reconsent_policy_version is not None
        or reconsent_policy_sha256 is not None
        or reconsent_installation_id is not None
    ):
        raise AuthorityTransitionRejectedError(
            "re-consent policy evidence is accepted only for re-consent"
        )


def _transition_evidence(
    *,
    state: Any,
    target_state: str,
    upload_acknowledgement: AuthorityEvidence | None,
    restore_proof: AuthorityEvidence | None,
    authorize_pruning: bool,
    now: datetime,
) -> tuple[
    UUID | None,
    str | None,
    datetime | None,
    UUID | None,
    str | None,
    datetime | None,
    datetime | None,
]:
    if upload_acknowledgement is not None and upload_acknowledgement.recorded_at > now:
        raise AuthorityTransitionRejectedError(
            "upload acknowledgement cannot be future dated"
        )
    if restore_proof is not None and restore_proof.recorded_at > now:
        raise AuthorityTransitionRejectedError("restore proof cannot be future dated")
    if target_state in {"local_only", "uploading", "rollback"}:
        return (None, None, None, None, None, None, None)
    if target_state == "shadow":
        assert upload_acknowledgement is not None
        return (
            upload_acknowledgement.evidence_id,
            upload_acknowledgement.receipt_sha256,
            upload_acknowledgement.recorded_at,
            None,
            None,
            None,
            None,
        )

    upload_id = state["upload_acknowledgement_id"]
    upload_sha256 = _optional_digest(state["upload_acknowledgement_sha256"])
    upload_at = state["upload_acknowledged_at"]
    if upload_id is None or upload_sha256 is None or upload_at is None:
        raise AuthorityTransitionRejectedError(
            "authority transition requires an exact upload acknowledgement"
        )
    if target_state == "parity_approved":
        return (upload_id, upload_sha256, upload_at, None, None, None, None)
    if target_state == "restore_proven":
        assert restore_proof is not None
        if restore_proof.recorded_at < upload_at:
            raise AuthorityTransitionRejectedError(
                "restore proof cannot predate upload acknowledgement"
            )
        return (
            upload_id,
            upload_sha256,
            upload_at,
            restore_proof.evidence_id,
            restore_proof.receipt_sha256,
            restore_proof.recorded_at,
            None,
        )

    restore_id = state["restore_proof_id"]
    restore_sha256 = _optional_digest(state["restore_proof_sha256"])
    restore_at = state["restore_proven_at"]
    if restore_id is None or restore_sha256 is None or restore_at is None:
        raise AuthorityTransitionRejectedError(
            "cloud authority requires an exact restore proof"
        )
    return (
        upload_id,
        upload_sha256,
        upload_at,
        restore_id,
        restore_sha256,
        restore_at,
        now if authorize_pruning else None,
    )


def _authority_state(row: Any) -> ManagedAuthorityState:
    return ManagedAuthorityState(
        principal_id=row["principal_id"],
        managed_account_id=row["managed_account_id"],
        data_class=str(row["data_class"]),
        state=str(row["state"]),
        transition_version=int(row["transition_version"]),
        upload_acknowledgement_id=row["upload_acknowledgement_id"],
        upload_acknowledgement_sha256=_optional_digest(
            row["upload_acknowledgement_sha256"]
        ),
        upload_acknowledged_at=row["upload_acknowledged_at"],
        restore_proof_id=row["restore_proof_id"],
        restore_proof_sha256=_optional_digest(row["restore_proof_sha256"]),
        restore_proven_at=row["restore_proven_at"],
        pruning_authorized_at=row["pruning_authorized_at"],
        last_opt_out_at=row["last_opt_out_at"],
        last_reconsented_at=row["last_reconsented_at"],
        reconsent_consent_event_id=row["reconsent_consent_event_id"],
        reconsent_policy_version=row["reconsent_policy_version"],
        reconsent_policy_sha256=_optional_digest(row["reconsent_policy_sha256"]),
    )


def _baseline_authority_state(
    *,
    principal_id: UUID,
    managed_account_id: UUID,
    data_class: str,
) -> ManagedAuthorityState:
    return ManagedAuthorityState(
        principal_id=principal_id,
        managed_account_id=managed_account_id,
        data_class=data_class,
        state="local_only",
        transition_version=0,
        upload_acknowledgement_id=None,
        upload_acknowledgement_sha256=None,
        upload_acknowledged_at=None,
        restore_proof_id=None,
        restore_proof_sha256=None,
        restore_proven_at=None,
        pruning_authorized_at=None,
        last_opt_out_at=None,
        last_reconsented_at=None,
        reconsent_consent_event_id=None,
        reconsent_policy_version=None,
        reconsent_policy_sha256=None,
    )


def _optional_digest(value: object) -> str | None:
    return str(value).strip() if value is not None else None


def _identity_lock_key(claims: ManagedIdentityClaims) -> str:
    digest = hashlib.sha256(
        json.dumps(
            [claims.issuer, claims.provider_tenant, claims.subject_hash],
            ensure_ascii=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return f"noop-unified-principal:{digest}"


def _authority_lock_key(managed_account_id: UUID, data_class: str) -> str:
    digest = hashlib.sha256(
        f"{managed_account_id}:{data_class}".encode("ascii")
    ).hexdigest()
    return f"noop-managed-authority:{digest}"


def _transition_request_digest(
    *,
    target_state: str,
    reason: str,
    upload_acknowledgement: AuthorityEvidence | None,
    restore_proof: AuthorityEvidence | None,
    authorize_pruning: bool,
    reconsent_policy_kind: str | None = None,
    reconsent_policy_version: str | None = None,
    reconsent_policy_sha256: str | None = None,
    reconsent_installation_id: str | None = None,
) -> str:
    def evidence(value: AuthorityEvidence | None) -> dict[str, str] | None:
        if value is None:
            return None
        return {
            "evidence_id": str(value.evidence_id),
            "receipt_sha256": value.receipt_sha256,
            "recorded_at": value.recorded_at.isoformat(),
        }

    payload = json.dumps(
        {
            "authorize_pruning": authorize_pruning,
            "reason": reason,
            "reconsent_installation_id": reconsent_installation_id,
            "reconsent_policy_kind": reconsent_policy_kind,
            "reconsent_policy_sha256": reconsent_policy_sha256,
            "reconsent_policy_version": reconsent_policy_version,
            "restore_proof": evidence(restore_proof),
            "target_state": target_state,
            "upload_acknowledgement": evidence(upload_acknowledgement),
        },
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()
