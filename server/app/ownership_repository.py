from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol
from uuid import UUID, uuid4

from app.managed_identity import ManagedIdentityClaims
from app.ownership_models import (
    OwnershipAccountRegistration,
    OwnershipInstallationAuthorization,
    OwnershipPlanSelection,
    OwnershipPossessionSubmission,
    OwnershipTermsAcceptance,
    OwnershipTermsManifest,
)
from app.ownership_possession import OwnershipPossessionEvidence
from app.repository import PostgresRepository


class OwnershipError(Exception):
    """Base class for ownership control-plane failures."""


class OwnershipNotFoundError(OwnershipError):
    """The requested ownership resource is unavailable."""


class OwnershipForbiddenError(OwnershipError):
    """The authenticated principal cannot perform the operation."""


class OwnershipConflictError(OwnershipError):
    """An idempotency, ownership, or concurrency conflict occurred."""


class OwnershipConfigurationError(OwnershipError):
    """Required immutable ownership configuration is unavailable."""


class OwnershipChallengeError(OwnershipError):
    """The possession challenge is stale, consumed, or does not match."""


@dataclass(frozen=True, slots=True)
class OwnershipPrincipal:
    account_id: UUID
    identity_id: UUID
    account_status: str
    auth_valid_after: datetime


@dataclass(frozen=True, slots=True)
class OwnershipChallenge:
    challenge_id: UUID
    challenge: str
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class OwnershipChallengeWindow:
    created_at: datetime
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class OwnershipClaimResult:
    outcome: str
    band_state: str


class OwnershipRepository(Protocol):
    async def terms_manifest(self, *, locale: str) -> dict[str, Any]: ...

    async def terms_manifest_version(
        self,
        *,
        policy_version: str,
        locale: str,
    ) -> dict[str, Any]: ...

    async def create_challenge(
        self,
        *,
        request_id: UUID,
        platform: str,
        app_id: str,
        ttl_seconds: int,
    ) -> OwnershipChallenge: ...

    async def reject_challenge(
        self,
        *,
        challenge_id: UUID,
        challenge: str,
        app_id: str,
    ) -> None: ...

    async def require_active_challenge(
        self,
        *,
        challenge_id: UUID,
        challenge: str,
        app_id: str,
        platform: str,
    ) -> OwnershipChallengeWindow: ...

    async def register_account(
        self,
        *,
        claims: ManagedIdentityClaims,
        registration: OwnershipAccountRegistration,
    ) -> dict[str, Any]: ...

    async def accept_terms(
        self,
        *,
        principal: OwnershipPrincipal,
        acceptance: OwnershipTermsAcceptance,
    ) -> dict[str, Any]: ...

    async def bootstrap_status(
        self,
        *,
        claims: ManagedIdentityClaims,
    ) -> dict[str, Any]: ...

    async def principal_for_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> OwnershipPrincipal: ...

    async def ensure_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        installation_token_hash: str,
        expected_platform: str,
        identity_auth_time: datetime,
    ) -> None: ...

    async def ensure_current_terms(
        self,
        *,
        principal: OwnershipPrincipal,
    ) -> None: ...

    async def overview(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
    ) -> dict[str, Any]: ...

    async def claim_replay(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        submission: OwnershipPossessionSubmission,
    ) -> OwnershipClaimResult | None: ...

    async def claim_band(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        submission: OwnershipPossessionSubmission,
        evidence: OwnershipPossessionEvidence,
        app_id: str,
        platform: str,
    ) -> OwnershipClaimResult: ...

    async def installation_authorization_replay(
        self,
        *,
        principal: OwnershipPrincipal,
        submission: OwnershipInstallationAuthorization,
        app_id: str,
        identity_auth_time: datetime,
    ) -> dict[str, Any] | None: ...

    async def authorize_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        submission: OwnershipInstallationAuthorization,
        evidence: OwnershipPossessionEvidence,
        app_id: str,
        identity_auth_time: datetime,
    ) -> dict[str, Any]: ...

    async def list_installations(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
    ) -> list[dict[str, Any]]: ...

    async def revoke_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
        target_installation_id: str,
    ) -> None: ...

    async def select_plan(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        selection: OwnershipPlanSelection,
    ) -> dict[str, Any]: ...


class PostgresOwnershipRepository:
    def __init__(self, primary: PostgresRepository) -> None:
        self.primary = primary

    def _pool(self) -> Any:
        pool = self.primary._pool
        if pool is None:
            raise RuntimeError("ownership repository is not started")
        return pool

    async def configuration_ready(self) -> bool:
        row = await self._pool().fetchrow(
            """
            WITH ownership_table_allowed (table_name, privilege) AS (
                VALUES
                    ('ownership_accounts', 'SELECT'),
                    ('ownership_accounts', 'INSERT'),
                    ('ownership_external_identities', 'SELECT'),
                    ('ownership_external_identities', 'INSERT'),
                    ('ownership_terms_documents', 'SELECT'),
                    ('ownership_terms_acceptances', 'SELECT'),
                    ('ownership_terms_acceptances', 'INSERT'),
                    ('ownership_installations', 'SELECT'),
                    ('ownership_installations', 'INSERT'),
                    ('ownership_bands', 'SELECT'),
                    ('ownership_possession_challenges', 'SELECT'),
                    ('ownership_possession_challenges', 'INSERT'),
                    ('ownership_claim_requests', 'SELECT'),
                    ('ownership_claim_requests', 'INSERT'),
                    ('ownership_band_claims', 'INSERT'),
                    ('ownership_installation_authorizations', 'SELECT'),
                    ('ownership_installation_authorizations', 'INSERT'),
                    ('ownership_plan_selections', 'SELECT'),
                    ('ownership_plan_selections', 'INSERT'),
                    ('ownership_plan_selection_requests', 'SELECT'),
                    ('ownership_plan_selection_requests', 'INSERT'),
                    ('ownership_events', 'INSERT')
            ),
            ownership_column_allowed (
                table_name,
                column_name,
                privilege
            ) AS (
                VALUES
                    (
                        'ownership_external_identities',
                        'email_verified',
                        'UPDATE'
                    ),
                    (
                        'ownership_external_identities',
                        'phone_verified',
                        'UPDATE'
                    ),
                    (
                        'ownership_external_identities',
                        'last_seen_at',
                        'UPDATE'
                    ),
                    (
                        'ownership_installations',
                        'device_key_fingerprint',
                        'UPDATE'
                    ),
                    (
                        'ownership_installations',
                        'status',
                        'UPDATE'
                    ),
                    (
                        'ownership_installations',
                        'last_seen_at',
                        'UPDATE'
                    ),
                    (
                        'ownership_installations',
                        'revoked_at',
                        'UPDATE'
                    ),
                    ('ownership_bands', 'status', 'UPDATE'),
                    (
                        'ownership_bands',
                        'current_account_id',
                        'UPDATE'
                    ),
                    ('ownership_bands', 'claimed_at', 'UPDATE'),
                    ('ownership_bands', 'firmware_version', 'UPDATE'),
                    ('ownership_bands', 'updated_at', 'UPDATE'),
                    (
                        'ownership_possession_challenges',
                        'status',
                        'UPDATE'
                    ),
                    (
                        'ownership_possession_challenges',
                        'consumed_at',
                        'UPDATE'
                    ),
                    (
                        'ownership_plan_selections',
                        'selection',
                        'UPDATE'
                    ),
                    (
                        'ownership_plan_selections',
                        'request_id',
                        'UPDATE'
                    ),
                    (
                        'ownership_plan_selections',
                        'updated_at',
                        'UPDATE'
                    )
            ),
            ownership_privileges (privilege) AS (
                VALUES
                    ('SELECT'),
                    ('INSERT'),
                    ('UPDATE'),
                    ('DELETE'),
                    ('TRUNCATE'),
                    ('REFERENCES'),
                    ('TRIGGER')
            ),
            non_system_sequences (sequence_oid) AS MATERIALIZED (
                SELECT candidate.oid
                FROM pg_class candidate
                JOIN pg_namespace namespace
                  ON namespace.oid = candidate.relnamespace
                WHERE candidate.relkind = 'S'
                  AND namespace.nspname <> 'information_schema'
                  AND namespace.nspname !~ '^pg_'
            )
            SELECT
                EXISTS (
                    SELECT 1
                    FROM ownership_terms_documents
                    WHERE locale = 'en'
                      AND effective_at <= clock_timestamp()
                      AND (
                          retired_at IS NULL
                          OR retired_at > clock_timestamp()
                      )
                ) AS terms_ready,
                EXISTS (
                    SELECT 1
                    FROM pg_roles
                    WHERE rolname = current_user
                      AND NOT rolsuper
                      AND NOT rolcreaterole
                      AND NOT rolcreatedb
                      AND NOT rolreplication
                      AND NOT rolbypassrls
                      AND NOT rolinherit
                ) AS principal_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_auth_members membership
                    JOIN pg_roles member_role
                      ON member_role.oid = membership.member
                    WHERE member_role.rolname = current_user
                ) AS memberships_bounded,
                (
                    has_schema_privilege('public', 'USAGE')
                    AND NOT has_schema_privilege('public', 'CREATE')
                ) AS schema_bounded,
                (
                    has_database_privilege(current_database(), 'CONNECT')
                    AND NOT has_database_privilege(
                        current_database(),
                        'CREATE'
                    )
                ) AS database_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_class
                    WHERE relowner = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                    UNION ALL
                    SELECT 1
                    FROM pg_namespace
                    WHERE nspowner = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                    UNION ALL
                    SELECT 1
                    FROM pg_database
                    WHERE datdba = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                ) AS ownership_bounded,
                (
                    NOT EXISTS (
                        SELECT 1
                        FROM ownership_table_allowed allowed
                        WHERE NOT has_table_privilege(
                            format('public.%I', allowed.table_name),
                            allowed.privilege
                        )
                    )
                    AND NOT EXISTS (
                        SELECT 1
                        FROM ownership_column_allowed allowed
                        WHERE NOT has_column_privilege(
                            format('public.%I', allowed.table_name),
                            allowed.column_name,
                            allowed.privilege
                        )
                    )
                ) AS privileges_ready,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_class candidate
                    JOIN pg_namespace namespace
                      ON namespace.oid = candidate.relnamespace
                    CROSS JOIN ownership_privileges permission
                    WHERE candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
                      AND namespace.nspname = 'public'
                      AND candidate.relname LIKE 'ownership\\_%'
                          ESCAPE '\\'
                      AND (
                          (
                              has_table_privilege(
                                  candidate.oid,
                                  permission.privilege
                              )
                              AND NOT EXISTS (
                                  SELECT 1
                                  FROM ownership_table_allowed allowed
                                  WHERE allowed.table_name =
                                        candidate.relname
                                    AND allowed.privilege =
                                        permission.privilege
                              )
                          )
                          OR (
                              permission.privilege IN (
                                  'SELECT',
                                  'INSERT',
                                  'UPDATE',
                                  'REFERENCES'
                              )
                              AND NOT has_table_privilege(
                                  candidate.oid,
                                  permission.privilege
                              )
                              AND EXISTS (
                                  SELECT 1
                                  FROM pg_attribute attribute
                                  WHERE attribute.attrelid = candidate.oid
                                    AND attribute.attnum > 0
                                    AND NOT attribute.attisdropped
                                    AND has_column_privilege(
                                        candidate.oid,
                                        attribute.attname,
                                        permission.privilege
                                    )
                                    AND NOT EXISTS (
                                        SELECT 1
                                        FROM ownership_column_allowed allowed
                                        WHERE allowed.table_name =
                                              candidate.relname
                                          AND allowed.column_name =
                                              attribute.attname
                                          AND allowed.privilege =
                                              permission.privilege
                                    )
                              )
                          )
                      )
                ) AS privileges_exact,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_class candidate
                    JOIN pg_namespace namespace
                      ON namespace.oid = candidate.relnamespace
                    WHERE candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
                      AND namespace.nspname <> 'information_schema'
                      AND namespace.nspname !~ '^pg_'
                      AND NOT (
                          namespace.nspname = 'public'
                          AND candidate.relname LIKE 'ownership\\_%'
                              ESCAPE '\\'
                      )
                      AND (
                          has_table_privilege(
                              candidate.oid,
                              'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
                          )
                          OR has_any_column_privilege(
                              candidate.oid,
                              'SELECT,INSERT,UPDATE,REFERENCES'
                          )
                      )
                ) AS scope_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM non_system_sequences candidate
                    WHERE has_sequence_privilege(
                          candidate.sequence_oid,
                          'SELECT,UPDATE,USAGE'
                      )
                ) AS sequences_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_proc candidate
                    JOIN pg_namespace namespace
                      ON namespace.oid = candidate.pronamespace
                    WHERE candidate.prosecdef
                      AND namespace.nspname <> 'information_schema'
                      AND namespace.nspname !~ '^pg_'
                      AND has_function_privilege(
                          candidate.oid,
                          'EXECUTE'
                      )
                ) AS security_definer_bounded
            """
        )
        return bool(
            row is not None
            and row["terms_ready"]
            and row["principal_bounded"]
            and row["memberships_bounded"]
            and row["schema_bounded"]
            and row["database_bounded"]
            and row["ownership_bounded"]
            and row["privileges_ready"]
            and row["privileges_exact"]
            and row["scope_bounded"]
            and row["sequences_bounded"]
            and row["security_definer_bounded"]
        )

    async def runtime_ready(self) -> bool:
        try:
            return await self.configuration_ready()
        except Exception:
            return False

    async def terms_manifest(self, *, locale: str) -> dict[str, Any]:
        row = await _current_terms_document(
            self._pool(),
            locale=locale,
        )
        if row is None:
            raise OwnershipConfigurationError("ownership terms are unavailable")
        return _validated_terms_manifest(row)

    async def terms_manifest_version(
        self,
        *,
        policy_version: str,
        locale: str,
    ) -> dict[str, Any]:
        row = await _terms_document_version(
            self._pool(),
            policy_version=policy_version,
            locale=locale,
        )
        if row is None:
            raise OwnershipNotFoundError("ownership terms version is unavailable")
        return _validated_terms_manifest(row)

    async def create_challenge(
        self,
        *,
        request_id: UUID,
        platform: str,
        app_id: str,
        ttl_seconds: int,
    ) -> OwnershipChallenge:
        app_id_hash = _digest(app_id)
        challenge_id = uuid4()
        challenge = secrets.token_urlsafe(32)
        pool = self._pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                await connection.execute(
                    """
                    INSERT INTO ownership_possession_challenges (
                        challenge_id,
                        request_id,
                        challenge_value,
                        platform,
                        app_id_hash,
                        created_at,
                        expires_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (request_id) DO NOTHING
                    """,
                    challenge_id,
                    request_id,
                    challenge,
                    platform,
                    app_id_hash,
                    now,
                    now + timedelta(seconds=ttl_seconds),
                )
                row = await connection.fetchrow(
                    """
                    SELECT challenge_id,
                           challenge_value,
                           platform,
                           app_id_hash,
                           status,
                           expires_at
                    FROM ownership_possession_challenges
                    WHERE request_id = $1
                    FOR UPDATE
                    """,
                    request_id,
                )
                if (
                    row is None
                    or row["platform"] != platform
                    or not hmac.compare_digest(
                        str(row["app_id_hash"]).strip(),
                        app_id_hash,
                    )
                ):
                    raise OwnershipConflictError(
                        "ownership challenge request conflicts"
                    )
                if row["status"] != "issued" or row["expires_at"] <= now:
                    raise OwnershipChallengeError(
                        "ownership challenge is no longer active"
                    )
        return OwnershipChallenge(
            challenge_id=row["challenge_id"],
            challenge=str(row["challenge_value"]),
            expires_at=row["expires_at"],
        )

    async def reject_challenge(
        self,
        *,
        challenge_id: UUID,
        challenge: str,
        app_id: str,
    ) -> None:
        await self._pool().execute(
            """
            UPDATE ownership_possession_challenges
            SET status = 'rejected',
                consumed_at = clock_timestamp()
            WHERE challenge_id = $1
              AND challenge_value = $2
              AND app_id_hash = $3
              AND status = 'issued'
            """,
            challenge_id,
            challenge,
            _digest(app_id),
        )

    async def require_active_challenge(
        self,
        *,
        challenge_id: UUID,
        challenge: str,
        app_id: str,
        platform: str,
    ) -> OwnershipChallengeWindow:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                now = await connection.fetchval("SELECT clock_timestamp()")
                row = await connection.fetchrow(
                    """
                    SELECT challenge_value,
                           platform,
                           app_id_hash,
                           status,
                           created_at,
                           expires_at
                    FROM ownership_possession_challenges
                    WHERE challenge_id = $1
                    FOR UPDATE
                    """,
                    challenge_id,
                )
                if (
                    row is None
                    or row["status"] != "issued"
                    or row["expires_at"] <= now
                    or row["platform"] != platform
                    or not hmac.compare_digest(
                        str(row["app_id_hash"]).strip(),
                        _digest(app_id),
                    )
                    or not hmac.compare_digest(
                        str(row["challenge_value"]),
                        challenge,
                    )
                ):
                    if (
                        row is not None
                        and row["status"] == "issued"
                        and row["expires_at"] <= now
                    ):
                        await connection.execute(
                            """
                            UPDATE ownership_possession_challenges
                            SET status = 'expired',
                                consumed_at = $2
                            WHERE challenge_id = $1
                            """,
                            challenge_id,
                            now,
                        )
                    raise OwnershipChallengeError(
                        "ownership challenge is no longer active"
                    )
        return OwnershipChallengeWindow(
            created_at=row["created_at"],
            expires_at=row["expires_at"],
        )

    async def register_account(
        self,
        *,
        claims: ManagedIdentityClaims,
        registration: OwnershipAccountRegistration,
    ) -> dict[str, Any]:
        if not claims.email_verified or claims.sign_in_provider != "password":
            raise OwnershipForbiddenError(
                "verified email and password identity are required"
            )
        token_hash = _digest(registration.installation_token.get_secret_value())
        request_digest = _request_digest(
            {
                "installation_id": registration.installation_id,
                "installation_token_hash": token_hash,
                "platform": registration.platform,
                "policy_version": registration.policy_version,
                "policy_sha256": registration.policy_sha256,
                "locale": registration.locale,
                "plan_selection": registration.plan_selection,
                "device_key_fingerprint": (registration.device_key_fingerprint or ""),
            }
        )
        pool = self._pool()
        created = False
        async with pool.acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    (
                        "noop-ownership-identity:"
                        f"{claims.issuer}:{claims.provider_tenant}:"
                        f"{claims.subject_hash}"
                    ),
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                policy = await _current_terms_document(
                    connection,
                    locale=registration.locale,
                    at=now,
                )
                if (
                    policy is None
                    or policy["policy_version"] != registration.policy_version
                    or policy["locale"] != registration.locale
                    or not hmac.compare_digest(
                        str(policy["document_sha256"]).strip(),
                        registration.policy_sha256,
                    )
                ):
                    raise OwnershipConfigurationError(
                        "ownership terms changed or are unavailable"
                    )
                identity = await connection.fetchrow(
                    """
                    SELECT identity.identity_id,
                           identity.account_id,
                           identity.status AS identity_status,
                           account.status AS account_status,
                           account.auth_valid_after
                    FROM ownership_external_identities identity
                    JOIN ownership_accounts account USING (account_id)
                    WHERE identity.issuer = $1
                      AND identity.provider_tenant = $2
                      AND identity.subject_hash = $3
                    FOR UPDATE OF identity
                    """,
                    claims.issuer,
                    claims.provider_tenant,
                    claims.subject_hash,
                )
                if identity is None:
                    created = True
                    account_id = uuid4()
                    identity_id = uuid4()
                    account_auth_valid_after = claims.auth_time
                    await connection.execute(
                        """
                        INSERT INTO ownership_accounts (
                            account_id,
                            auth_valid_after,
                            created_at,
                            updated_at
                        ) VALUES ($1, $2, $3, $3)
                        """,
                        account_id,
                        claims.auth_time,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO ownership_external_identities (
                            identity_id,
                            account_id,
                            issuer,
                            provider_tenant,
                            subject_hash,
                            email_verified,
                            phone_verified,
                            verified_at,
                            last_seen_at,
                            created_at
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, $7, $8, $8, $9
                        )
                        """,
                        identity_id,
                        account_id,
                        claims.issuer,
                        claims.provider_tenant,
                        claims.subject_hash,
                        claims.email_verified,
                        claims.phone_verified,
                        claims.issued_at,
                        now,
                    )
                else:
                    if (
                        identity["identity_status"] != "active"
                        or identity["account_status"] != "active"
                        or claims.auth_time < identity["auth_valid_after"]
                    ):
                        raise OwnershipForbiddenError(
                            "ownership account is unavailable"
                        )
                    account_id = identity["account_id"]
                    identity_id = identity["identity_id"]
                    account_auth_valid_after = identity["auth_valid_after"]
                    await connection.execute(
                        """
                        UPDATE ownership_external_identities
                        SET email_verified = $2,
                            phone_verified = $3,
                            last_seen_at = GREATEST(last_seen_at, $4)
                        WHERE identity_id = $1
                        """,
                        identity_id,
                        claims.email_verified,
                        claims.phone_verified,
                        claims.issued_at,
                    )

                await _lock_account(connection, account_id)
                await _lock_installation(
                    connection,
                    registration.installation_id,
                )
                acceptance = await connection.fetchrow(
                    """
                    SELECT request_digest
                    FROM ownership_terms_acceptances
                    WHERE account_id = $1 AND request_id = $2
                    """,
                    account_id,
                    registration.request_id,
                )
                if acceptance is not None and not hmac.compare_digest(
                    str(acceptance["request_digest"]).strip(),
                    request_digest,
                ):
                    raise OwnershipConflictError(
                        "ownership registration request conflicts"
                    )

                existing_installation = await connection.fetchrow(
                    """
                    SELECT account_id,
                           token_hash,
                           platform,
                           device_key_fingerprint,
                           status,
                           auth_valid_after
                    FROM ownership_installations
                    WHERE installation_id = $1
                    FOR UPDATE
                    """,
                    registration.installation_id,
                )
                if existing_installation is None:
                    owns_band = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM ownership_bands
                            WHERE current_account_id = $1
                              AND status IN ('claimed', 'return_pending')
                        )
                        """,
                        account_id,
                    )
                    if owns_band:
                        raise OwnershipForbiddenError(
                            "replacement installation needs possession proof"
                        )
                    active_installations = await connection.fetchval(
                        """
                        SELECT count(*)
                        FROM ownership_installations
                        WHERE account_id = $1 AND status = 'active'
                        """,
                        account_id,
                    )
                    if int(active_installations) >= 10:
                        raise OwnershipForbiddenError(
                            "ownership installation limit reached"
                        )
                    await connection.execute(
                        """
                        INSERT INTO ownership_installations (
                            installation_id,
                            account_id,
                            platform,
                            token_hash,
                            device_key_fingerprint,
                            auth_valid_after,
                            registered_at,
                            last_seen_at
                        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
                        """,
                        registration.installation_id,
                        account_id,
                        registration.platform,
                        token_hash,
                        registration.device_key_fingerprint,
                        claims.auth_time,
                        now,
                    )
                elif (
                    existing_installation["account_id"] != account_id
                    or existing_installation["status"] != "active"
                    or existing_installation["platform"] != registration.platform
                    or claims.auth_time < existing_installation["auth_valid_after"]
                    or not hmac.compare_digest(
                        str(existing_installation["token_hash"]).strip(),
                        token_hash,
                    )
                    or not _optional_bound_digest_matches(
                        existing_installation["device_key_fingerprint"],
                        registration.device_key_fingerprint,
                    )
                ):
                    raise OwnershipForbiddenError("ownership installation was rejected")
                else:
                    await connection.execute(
                        """
                        UPDATE ownership_installations
                        SET last_seen_at = $2,
                            device_key_fingerprint = COALESCE(
                                device_key_fingerprint,
                                $3
                            )
                        WHERE installation_id = $1
                        """,
                        registration.installation_id,
                        now,
                        registration.device_key_fingerprint,
                    )

                if acceptance is None:
                    await connection.execute(
                        """
                        INSERT INTO ownership_terms_acceptances (
                            acceptance_id,
                            account_id,
                            policy_version,
                            locale,
                            document_sha256,
                            request_id,
                            request_digest,
                            accepted_at,
                            recorded_at
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, $7, $8, $8
                        )
                        """,
                        uuid4(),
                        account_id,
                        registration.policy_version,
                        registration.locale,
                        registration.policy_sha256,
                        registration.request_id,
                        request_digest,
                        now,
                    )
                    await self._record_event(
                        connection,
                        account_id=account_id,
                        installation_id=registration.installation_id,
                        event_kind="terms_accepted",
                        outcome="accepted",
                        occurred_at=now,
                    )
                existing_plan = await connection.fetchrow(
                    """
                    SELECT selection
                    FROM ownership_plan_selections
                    WHERE account_id = $1
                    FOR UPDATE
                    """,
                    account_id,
                )
                if existing_plan is None:
                    await connection.execute(
                        """
                        INSERT INTO ownership_plan_selection_requests (
                            account_id,
                            request_id,
                            selection,
                            created_at
                        ) VALUES ($1, $2, $3, $4)
                        """,
                        account_id,
                        registration.request_id,
                        registration.plan_selection,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO ownership_plan_selections (
                            account_id,
                            selection,
                            request_id,
                            selected_at,
                            updated_at
                        ) VALUES ($1, $2, $3, $4, $4)
                        """,
                        account_id,
                        registration.plan_selection,
                        registration.request_id,
                        now,
                    )
                    await self._record_event(
                        connection,
                        account_id=account_id,
                        event_kind="plan_selected",
                        outcome="completed",
                        occurred_at=now,
                    )
                if created:
                    await self._record_event(
                        connection,
                        account_id=account_id,
                        installation_id=registration.installation_id,
                        event_kind="account_registered",
                        outcome="completed",
                        occurred_at=now,
                    )
        principal = OwnershipPrincipal(
            account_id=account_id,
            identity_id=identity_id,
            account_status="active",
            auth_valid_after=account_auth_valid_after,
        )
        overview = await self.overview(
            principal=principal,
            current_installation_id=registration.installation_id,
        )
        overview["created"] = created
        return overview

    async def accept_terms(
        self,
        *,
        principal: OwnershipPrincipal,
        acceptance: OwnershipTermsAcceptance,
    ) -> dict[str, Any]:
        request_digest = _request_digest(
            {
                "policy_version": acceptance.policy_version,
                "policy_sha256": acceptance.policy_sha256,
                "locale": acceptance.locale,
            }
        )
        resumed = False
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await _lock_account(connection, principal.account_id)
                account_status = await connection.fetchval(
                    """
                    SELECT status
                    FROM ownership_accounts
                    WHERE account_id = $1
                    FOR UPDATE
                    """,
                    principal.account_id,
                )
                if account_status != "active":
                    raise OwnershipForbiddenError("ownership account is unavailable")
                now = await connection.fetchval("SELECT clock_timestamp()")
                policy = await _current_terms_document(
                    connection,
                    locale=acceptance.locale,
                    at=now,
                )
                if (
                    policy is None
                    or policy["policy_version"] != acceptance.policy_version
                    or policy["locale"] != acceptance.locale
                    or not hmac.compare_digest(
                        str(policy["document_sha256"]).strip(),
                        acceptance.policy_sha256,
                    )
                ):
                    raise OwnershipConfigurationError(
                        "ownership terms changed or are unavailable"
                    )
                previous = await connection.fetchrow(
                    """
                    SELECT request_digest
                    FROM ownership_terms_acceptances
                    WHERE account_id = $1 AND request_id = $2
                    """,
                    principal.account_id,
                    acceptance.request_id,
                )
                if previous is not None:
                    if not hmac.compare_digest(
                        str(previous["request_digest"]).strip(),
                        request_digest,
                    ):
                        raise OwnershipConflictError(
                            "ownership terms acceptance request conflicts"
                        )
                    resumed = True
                else:
                    await connection.execute(
                        """
                        INSERT INTO ownership_terms_acceptances (
                            acceptance_id,
                            account_id,
                            policy_version,
                            locale,
                            document_sha256,
                            request_id,
                            request_digest,
                            accepted_at,
                            recorded_at
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, $7, $8, $8
                        )
                        """,
                        uuid4(),
                        principal.account_id,
                        acceptance.policy_version,
                        acceptance.locale,
                        acceptance.policy_sha256,
                        acceptance.request_id,
                        request_digest,
                        now,
                    )
                    await self._record_event(
                        connection,
                        account_id=principal.account_id,
                        event_kind="terms_accepted",
                        outcome="accepted",
                        occurred_at=now,
                    )
        return {
            "acceptance_state": "accepted",
            "policy_version": acceptance.policy_version,
            "locale": acceptance.locale,
            "resumed": resumed,
        }

    async def principal_for_identity(
        self,
        claims: ManagedIdentityClaims,
    ) -> OwnershipPrincipal:
        row = await self._pool().fetchrow(
            """
            SELECT identity.identity_id,
                   identity.account_id,
                   identity.status AS identity_status,
                   account.status AS account_status,
                   account.auth_valid_after
            FROM ownership_external_identities identity
            JOIN ownership_accounts account USING (account_id)
            WHERE identity.issuer = $1
              AND identity.provider_tenant = $2
              AND identity.subject_hash = $3
            """,
            claims.issuer,
            claims.provider_tenant,
            claims.subject_hash,
        )
        if row is None:
            raise OwnershipNotFoundError("ownership account is not registered")
        if (
            row["identity_status"] != "active"
            or row["account_status"] != "active"
            or claims.auth_time < row["auth_valid_after"]
        ):
            raise OwnershipForbiddenError("ownership account is unavailable")
        await self._pool().execute(
            """
            UPDATE ownership_external_identities
            SET email_verified = $2,
                phone_verified = $3,
                last_seen_at = GREATEST(last_seen_at, $4)
            WHERE identity_id = $1
            """,
            row["identity_id"],
            claims.email_verified,
            claims.phone_verified,
            claims.issued_at,
        )
        return OwnershipPrincipal(
            account_id=row["account_id"],
            identity_id=row["identity_id"],
            account_status=str(row["account_status"]),
            auth_valid_after=row["auth_valid_after"],
        )

    async def bootstrap_status(
        self,
        *,
        claims: ManagedIdentityClaims,
    ) -> dict[str, Any]:
        try:
            principal = await self.principal_for_identity(claims)
        except OwnershipNotFoundError:
            return {
                "account_state": "unregistered",
                "band_state": "unclaimed",
                "replacement_authorization_required": False,
                "terms_acceptance_required": False,
            }
        owns_band = await self._pool().fetchval(
            """
            SELECT EXISTS (
                SELECT 1
                FROM ownership_bands
                WHERE current_account_id = $1
                  AND status IN ('claimed', 'return_pending')
            )
            """,
            principal.account_id,
        )
        try:
            await _require_current_terms_acceptance(
                self._pool(),
                account_id=principal.account_id,
            )
            terms_acceptance_required = False
        except OwnershipConfigurationError:
            terms_acceptance_required = True
        return {
            "account_state": "active",
            "band_state": "claimed" if owns_band else "unclaimed",
            "replacement_authorization_required": bool(owns_band),
            "terms_acceptance_required": terms_acceptance_required,
        }

    async def ensure_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        installation_token_hash: str,
        expected_platform: str,
        identity_auth_time: datetime,
    ) -> None:
        row = await self._pool().fetchrow(
            """
            SELECT token_hash, platform, status, auth_valid_after
            FROM ownership_installations
            WHERE account_id = $1 AND installation_id = $2
            """,
            principal.account_id,
            installation_id,
        )
        if (
            row is None
            or row["status"] != "active"
            or row["platform"] != expected_platform
            or identity_auth_time < row["auth_valid_after"]
            or not hmac.compare_digest(
                str(row["token_hash"]).strip(),
                installation_token_hash,
            )
        ):
            raise OwnershipForbiddenError("ownership installation was rejected")
        await self._pool().execute(
            """
            UPDATE ownership_installations
            SET last_seen_at = clock_timestamp()
            WHERE account_id = $1 AND installation_id = $2
            """,
            principal.account_id,
            installation_id,
        )

    async def ensure_current_terms(
        self,
        *,
        principal: OwnershipPrincipal,
    ) -> None:
        await _require_current_terms_acceptance(
            self._pool(),
            account_id=principal.account_id,
        )

    async def overview(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            SELECT account.status,
                   identity.email_verified,
                   identity.phone_verified,
                   (
                       SELECT count(*)
                       FROM ownership_bands band
                       WHERE band.current_account_id = account.account_id
                         AND band.status IN ('claimed', 'return_pending')
                   ) AS band_count,
                   (
                       SELECT count(*)
                       FROM ownership_installations installation
                       WHERE installation.account_id = account.account_id
                         AND installation.status = 'active'
                   ) AS installation_count,
                   COALESCE(selection.selection, 'noop') AS plan_selection
            FROM ownership_accounts account
            JOIN ownership_external_identities identity USING (account_id)
            LEFT JOIN ownership_plan_selections selection USING (account_id)
            WHERE account.account_id = $1
              AND identity.identity_id = $2
            """,
            principal.account_id,
            principal.identity_id,
        )
        if row is None:
            raise OwnershipNotFoundError("ownership account is unavailable")
        return {
            "account_state": str(row["status"]),
            "email_verified": bool(row["email_verified"]),
            "phone_verified": bool(row["phone_verified"]),
            "band_state": "claimed" if int(row["band_count"]) > 0 else "unclaimed",
            "active_installations": int(row["installation_count"]),
            "current_installation_id": current_installation_id,
            "plan_selection": str(row["plan_selection"]),
            "noop_plus_entitled": False,
        }

    async def claim_replay(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        submission: OwnershipPossessionSubmission,
    ) -> OwnershipClaimResult | None:
        row = await self._pool().fetchrow(
            """
            SELECT claim.installation_id,
                   claim.challenge_id,
                   claim.proof_digest,
                   claim.outcome,
                   challenge.challenge_value
            FROM ownership_claim_requests claim
            JOIN ownership_possession_challenges challenge
              USING (challenge_id)
            WHERE claim.account_id = $1
              AND claim.request_id = $2
            """,
            principal.account_id,
            submission.request_id,
        )
        if row is None:
            return None
        if (
            row["installation_id"] != installation_id
            or row["challenge_id"] != submission.challenge_id
            or not hmac.compare_digest(
                str(row["challenge_value"]),
                submission.challenge.get_secret_value(),
            )
            or not hmac.compare_digest(
                str(row["proof_digest"]).strip(),
                _digest(submission.possession_response.get_secret_value()),
            )
        ):
            raise OwnershipConflictError("ownership claim request conflicts")
        outcome = str(row["outcome"])
        return OwnershipClaimResult(
            outcome=outcome,
            band_state=(
                "claimed" if outcome in {"claimed", "already_owned"} else "unavailable"
            ),
        )

    async def claim_band(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        submission: OwnershipPossessionSubmission,
        evidence: OwnershipPossessionEvidence,
        app_id: str,
        platform: str,
    ) -> OwnershipClaimResult:
        proof_digest = _digest(submission.possession_response.get_secret_value())
        request_digest = _request_digest(
            {
                "challenge_id": str(submission.challenge_id),
                "challenge": submission.challenge.get_secret_value(),
                "proof_digest": proof_digest,
                "provisioned_identity_hash": evidence.provisioned_identity_hash,
                "protocol_version": evidence.protocol_version,
                "firmware_version": evidence.firmware_version,
                "installation_id": installation_id,
            }
        )
        pool = self._pool()
        result: OwnershipClaimResult | None = None
        challenge_error: OwnershipError | None = None
        async with pool.acquire() as connection:
            async with connection.transaction():
                await _lock_account(connection, principal.account_id)
                await _require_active_installation(
                    connection,
                    account_id=principal.account_id,
                    installation_id=installation_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                previous = await connection.fetchrow(
                    """
                    SELECT request_digest, outcome
                    FROM ownership_claim_requests
                    WHERE account_id = $1 AND request_id = $2
                    """,
                    principal.account_id,
                    submission.request_id,
                )
                if previous is not None:
                    if not hmac.compare_digest(
                        str(previous["request_digest"]).strip(),
                        request_digest,
                    ):
                        challenge_error = OwnershipConflictError(
                            "ownership claim request conflicts"
                        )
                    else:
                        outcome = str(previous["outcome"])
                        result = OwnershipClaimResult(
                            outcome=outcome,
                            band_state=(
                                "claimed"
                                if outcome in {"claimed", "already_owned"}
                                else "unavailable"
                            ),
                        )
                else:
                    await _require_current_terms_acceptance(
                        connection,
                        account_id=principal.account_id,
                    )
                    challenge = await connection.fetchrow(
                        """
                        SELECT challenge_value,
                               platform,
                               app_id_hash,
                               status,
                               created_at,
                               expires_at
                        FROM ownership_possession_challenges
                        WHERE challenge_id = $1
                        FOR UPDATE
                        """,
                        submission.challenge_id,
                    )
                    supplied_challenge = submission.challenge.get_secret_value()
                    if (
                        challenge is None
                        or challenge["status"] != "issued"
                        or challenge["expires_at"] <= now
                        or not _possession_evidence_within_challenge(
                            evidence,
                            created_at=challenge["created_at"],
                            expires_at=challenge["expires_at"],
                        )
                        or challenge["platform"] != platform
                        or not hmac.compare_digest(
                            str(challenge["app_id_hash"]).strip(),
                            _digest(app_id),
                        )
                        or not hmac.compare_digest(
                            str(challenge["challenge_value"]),
                            supplied_challenge,
                        )
                    ):
                        if challenge is not None and challenge["status"] == "issued":
                            await connection.execute(
                                """
                                UPDATE ownership_possession_challenges
                                SET status = $2,
                                    consumed_at = $3
                                WHERE challenge_id = $1
                                """,
                                submission.challenge_id,
                                (
                                    "expired"
                                    if challenge["expires_at"] <= now
                                    else "rejected"
                                ),
                                now,
                            )
                        challenge_error = OwnershipChallengeError(
                            "ownership challenge was rejected"
                        )
                    else:
                        owned_identity_hash = await connection.fetchval(
                            """
                            SELECT provisioned_identity_hash
                            FROM ownership_bands
                            WHERE current_account_id = $1
                              AND status IN ('claimed', 'return_pending')
                            """,
                            principal.account_id,
                        )
                        owns_different_band = (
                            owned_identity_hash is not None
                            and not hmac.compare_digest(
                                str(owned_identity_hash).strip(),
                                evidence.provisioned_identity_hash,
                            )
                        )
                        band = None
                        if not owns_different_band:
                            band = await connection.fetchrow(
                                """
                                SELECT band_id,
                                       status,
                                       current_account_id,
                                       protocol_version
                                FROM ownership_bands
                                WHERE provisioned_identity_hash = $1
                                FOR UPDATE
                                """,
                                evidence.provisioned_identity_hash,
                            )
                        if (
                            band is not None
                            and band["protocol_version"] != evidence.protocol_version
                        ):
                            challenge_error = OwnershipChallengeError(
                                "ownership proof protocol was rejected"
                            )
                            await connection.execute(
                                """
                                UPDATE ownership_possession_challenges
                                SET status = 'rejected',
                                    consumed_at = $2
                                WHERE challenge_id = $1
                                """,
                                submission.challenge_id,
                                now,
                            )
                        else:
                            if owns_different_band or band is None:
                                outcome = "conflict"
                                band_id = None
                            elif (
                                band["status"] == "unclaimed"
                                and band["current_account_id"] is None
                            ):
                                outcome = "claimed"
                                band_id = band["band_id"]
                                await connection.execute(
                                    """
                                    UPDATE ownership_bands
                                    SET status = 'claimed',
                                        current_account_id = $2,
                                        claimed_at = $3,
                                        firmware_version = $4,
                                        updated_at = $3
                                    WHERE band_id = $1
                                    """,
                                    band_id,
                                    principal.account_id,
                                    now,
                                    evidence.firmware_version,
                                )
                                revoked_installations = await connection.fetch(
                                    """
                                    UPDATE ownership_installations
                                    SET status = 'revoked',
                                        revoked_at = $3,
                                        last_seen_at = GREATEST(last_seen_at, $3)
                                    WHERE account_id = $1
                                      AND installation_id <> $2
                                      AND status = 'active'
                                    RETURNING installation_id
                                    """,
                                    principal.account_id,
                                    installation_id,
                                    now,
                                )
                            elif (
                                band["status"] in {"claimed", "return_pending"}
                                and band["current_account_id"] == principal.account_id
                            ):
                                outcome = "already_owned"
                                band_id = band["band_id"]
                                revoked_installations = []
                            else:
                                outcome = "conflict"
                                # Do not retain another account's band identity
                                # on the rejected claimant's request or event.
                                band_id = None
                                revoked_installations = []

                            await connection.execute(
                                """
                                UPDATE ownership_possession_challenges
                                SET status = 'consumed',
                                    consumed_at = $2
                                WHERE challenge_id = $1
                                """,
                                submission.challenge_id,
                                now,
                            )
                            await connection.execute(
                                """
                                INSERT INTO ownership_claim_requests (
                                    account_id,
                                    request_id,
                                    request_digest,
                                    installation_id,
                                    band_id,
                                    challenge_id,
                                    proof_digest,
                                    outcome,
                                    created_at
                                ) VALUES (
                                    $1, $2, $3, $4, $5, $6, $7, $8, $9
                                )
                                """,
                                principal.account_id,
                                submission.request_id,
                                request_digest,
                                installation_id,
                                band_id,
                                submission.challenge_id,
                                proof_digest,
                                outcome,
                                now,
                            )
                            if outcome == "claimed":
                                await connection.execute(
                                    """
                                    INSERT INTO ownership_band_claims (
                                        claim_id,
                                        band_id,
                                        account_id,
                                        request_id,
                                        claimed_at
                                    ) VALUES ($1, $2, $3, $4, $5)
                                    """,
                                    uuid4(),
                                    band_id,
                                    principal.account_id,
                                    submission.request_id,
                                    now,
                                )
                                for revoked in revoked_installations:
                                    await self._record_event(
                                        connection,
                                        account_id=principal.account_id,
                                        installation_id=str(revoked["installation_id"]),
                                        event_kind="installation_revoked",
                                        outcome="completed",
                                        occurred_at=now,
                                    )
                            await self._record_event(
                                connection,
                                account_id=principal.account_id,
                                band_id=band_id,
                                installation_id=installation_id,
                                event_kind=(
                                    "band_claimed"
                                    if outcome in {"claimed", "already_owned"}
                                    else "claim_conflict"
                                ),
                                outcome=(
                                    "completed"
                                    if outcome in {"claimed", "already_owned"}
                                    else "conflict"
                                ),
                                occurred_at=now,
                            )
                            result = OwnershipClaimResult(
                                outcome=outcome,
                                band_state=(
                                    "claimed"
                                    if outcome in {"claimed", "already_owned"}
                                    else "unavailable"
                                ),
                            )
        if challenge_error is not None:
            raise challenge_error
        if result is None:
            raise OwnershipConflictError("ownership claim did not complete")
        return result

    async def installation_authorization_replay(
        self,
        *,
        principal: OwnershipPrincipal,
        submission: OwnershipInstallationAuthorization,
        app_id: str,
        identity_auth_time: datetime,
    ) -> dict[str, Any] | None:
        row = await self._pool().fetchrow(
            """
            SELECT authz.challenge_id,
                   authz.installation_id,
                   authz.proof_digest,
                   challenge.challenge_value,
                   challenge.platform,
                   challenge.app_id_hash,
                   installation.account_id,
                   installation.platform AS installation_platform,
                   installation.token_hash,
                   installation.device_key_fingerprint,
                   installation.status,
                   installation.auth_valid_after
            FROM ownership_installation_authorizations authz
            JOIN ownership_possession_challenges challenge
              USING (challenge_id)
            JOIN ownership_installations installation
              ON installation.installation_id =
                 authz.installation_id
            WHERE authz.account_id = $1
              AND authz.request_id = $2
            """,
            principal.account_id,
            submission.request_id,
        )
        if row is None:
            return None
        supplied_token_hash = _digest(
            submission.new_installation_token.get_secret_value()
        )
        if identity_auth_time < row["auth_valid_after"]:
            raise OwnershipForbiddenError("ownership installation was rejected")
        if (
            row["challenge_id"] != submission.challenge_id
            or row["installation_id"] != submission.new_installation_id
            or row["account_id"] != principal.account_id
            or row["platform"] != submission.new_platform
            or row["installation_platform"] != submission.new_platform
            or row["status"] != "active"
            or not hmac.compare_digest(
                str(row["challenge_value"]),
                submission.challenge.get_secret_value(),
            )
            or not hmac.compare_digest(
                str(row["proof_digest"]).strip(),
                _digest(submission.possession_response.get_secret_value()),
            )
            or not hmac.compare_digest(
                str(row["app_id_hash"]).strip(),
                _digest(app_id),
            )
            or not hmac.compare_digest(
                str(row["token_hash"]).strip(),
                supplied_token_hash,
            )
            or not _optional_exact_digest_matches(
                row["device_key_fingerprint"],
                submission.device_key_fingerprint,
            )
        ):
            raise OwnershipConflictError("installation authorization request conflicts")
        return {
            "installation_state": "active",
            "installation_id": submission.new_installation_id,
        }

    async def authorize_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        submission: OwnershipInstallationAuthorization,
        evidence: OwnershipPossessionEvidence,
        app_id: str,
        identity_auth_time: datetime,
    ) -> dict[str, Any]:
        new_token_hash = _digest(submission.new_installation_token.get_secret_value())
        proof_digest = _digest(submission.possession_response.get_secret_value())
        request_digest = _request_digest(
            {
                "challenge_id": str(submission.challenge_id),
                "challenge": submission.challenge.get_secret_value(),
                "proof_digest": proof_digest,
                "provisioned_identity_hash": evidence.provisioned_identity_hash,
                "new_installation_id": submission.new_installation_id,
                "new_token_hash": new_token_hash,
                "new_platform": submission.new_platform,
                "device_key_fingerprint": (submission.device_key_fingerprint or ""),
            }
        )
        error: OwnershipError | None = None
        challenge = None
        band = None
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await _lock_account(connection, principal.account_id)
                await _lock_installation(
                    connection,
                    submission.new_installation_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                previous = await connection.fetchrow(
                    """
                    SELECT authz.request_digest,
                           authz.installation_id,
                           installation.account_id,
                           installation.token_hash,
                           installation.platform,
                           installation.device_key_fingerprint,
                           installation.status,
                           installation.auth_valid_after
                    FROM ownership_installation_authorizations authz
                    JOIN ownership_installations installation
                      ON installation.installation_id =
                         authz.installation_id
                    WHERE authz.account_id = $1
                      AND authz.request_id = $2
                    """,
                    principal.account_id,
                    submission.request_id,
                )
                if previous is not None:
                    if identity_auth_time < previous["auth_valid_after"]:
                        error = OwnershipForbiddenError(
                            "ownership installation was rejected"
                        )
                    elif (
                        not hmac.compare_digest(
                            str(previous["request_digest"]).strip(),
                            request_digest,
                        )
                        or previous["installation_id"] != submission.new_installation_id
                        or previous["account_id"] != principal.account_id
                        or previous["platform"] != submission.new_platform
                        or previous["status"] != "active"
                        or not hmac.compare_digest(
                            str(previous["token_hash"]).strip(),
                            new_token_hash,
                        )
                        or not _optional_bound_digest_matches(
                            previous["device_key_fingerprint"],
                            submission.device_key_fingerprint,
                        )
                    ):
                        error = OwnershipConflictError(
                            "installation authorization request conflicts"
                        )
                else:
                    await _require_current_terms_acceptance(
                        connection,
                        account_id=principal.account_id,
                    )
                    challenge = await connection.fetchrow(
                        """
                        SELECT challenge_value,
                               platform,
                               app_id_hash,
                               status,
                               created_at,
                               expires_at
                        FROM ownership_possession_challenges
                        WHERE challenge_id = $1
                        FOR UPDATE
                        """,
                        submission.challenge_id,
                    )
                    if (
                        challenge is None
                        or challenge["status"] != "issued"
                        or challenge["expires_at"] <= now
                        or not _possession_evidence_within_challenge(
                            evidence,
                            created_at=challenge["created_at"],
                            expires_at=challenge["expires_at"],
                        )
                        or challenge["platform"] != submission.new_platform
                        or not hmac.compare_digest(
                            str(challenge["app_id_hash"]).strip(),
                            _digest(app_id),
                        )
                        or not hmac.compare_digest(
                            str(challenge["challenge_value"]),
                            submission.challenge.get_secret_value(),
                        )
                    ):
                        error = OwnershipChallengeError(
                            "installation challenge was rejected"
                        )
                    if error is None:
                        band = await connection.fetchrow(
                            """
                            SELECT band_id, current_account_id, status,
                                   protocol_version
                            FROM ownership_bands
                            WHERE provisioned_identity_hash = $1
                            FOR UPDATE
                            """,
                            evidence.provisioned_identity_hash,
                        )
                        if (
                            band is None
                            or band["current_account_id"] != principal.account_id
                            or band["status"] not in {"claimed", "return_pending"}
                            or band["protocol_version"] != evidence.protocol_version
                        ):
                            error = OwnershipForbiddenError(
                                "installation possession proof was rejected"
                            )
                    if error is None and band is not None:
                        existing = await connection.fetchrow(
                            """
                            SELECT account_id,
                                   token_hash,
                                   platform,
                                   device_key_fingerprint,
                                   status,
                                   auth_valid_after
                            FROM ownership_installations
                            WHERE installation_id = $1
                            FOR UPDATE
                            """,
                            submission.new_installation_id,
                        )
                        if existing is None:
                            active_count = await connection.fetchval(
                                """
                                SELECT count(*)
                                FROM ownership_installations
                                WHERE account_id = $1 AND status = 'active'
                                """,
                                principal.account_id,
                            )
                            if int(active_count) >= 10:
                                error = OwnershipForbiddenError(
                                    "ownership installation limit reached"
                                )
                            else:
                                await connection.execute(
                                    """
                                    INSERT INTO ownership_installations (
                                        installation_id,
                                        account_id,
                                        platform,
                                        token_hash,
                                        device_key_fingerprint,
                                        auth_valid_after,
                                        registered_at,
                                        last_seen_at
                                    ) VALUES (
                                        $1, $2, $3, $4, $5, $6, $7, $7
                                    )
                                    """,
                                    submission.new_installation_id,
                                    principal.account_id,
                                    submission.new_platform,
                                    new_token_hash,
                                    submission.device_key_fingerprint,
                                    identity_auth_time,
                                    now,
                                )
                        elif (
                            existing["account_id"] != principal.account_id
                            or existing["platform"] != submission.new_platform
                            or existing["status"] != "active"
                            or identity_auth_time < existing["auth_valid_after"]
                            or not hmac.compare_digest(
                                str(existing["token_hash"]).strip(),
                                new_token_hash,
                            )
                            or not _optional_bound_digest_matches(
                                existing["device_key_fingerprint"],
                                submission.device_key_fingerprint,
                            )
                        ):
                            error = OwnershipForbiddenError(
                                "ownership installation was rejected"
                            )
                        else:
                            await connection.execute(
                                """
                                UPDATE ownership_installations
                                SET last_seen_at = GREATEST(last_seen_at, $2),
                                    device_key_fingerprint = COALESCE(
                                        device_key_fingerprint,
                                        $3
                                    )
                                WHERE installation_id = $1
                                """,
                                submission.new_installation_id,
                                now,
                                submission.device_key_fingerprint,
                            )
                    if error is None and band is not None:
                        await connection.execute(
                            """
                            UPDATE ownership_possession_challenges
                            SET status = 'consumed',
                                consumed_at = $2
                            WHERE challenge_id = $1
                            """,
                            submission.challenge_id,
                            now,
                        )
                        await connection.execute(
                            """
                            INSERT INTO ownership_installation_authorizations (
                                account_id,
                                request_id,
                                request_digest,
                                challenge_id,
                                band_id,
                                installation_id,
                                proof_digest,
                                created_at
                            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                            """,
                            principal.account_id,
                            submission.request_id,
                            request_digest,
                            submission.challenge_id,
                            band["band_id"],
                            submission.new_installation_id,
                            proof_digest,
                            now,
                        )
                        await self._record_event(
                            connection,
                            account_id=principal.account_id,
                            band_id=band["band_id"],
                            installation_id=submission.new_installation_id,
                            event_kind="installation_authorized",
                            outcome="completed",
                            occurred_at=now,
                        )
                    elif challenge is not None and challenge["status"] == "issued":
                        await connection.execute(
                            """
                            UPDATE ownership_possession_challenges
                            SET status = $2,
                                consumed_at = $3
                            WHERE challenge_id = $1
                            """,
                            submission.challenge_id,
                            (
                                "expired"
                                if challenge["expires_at"] <= now
                                else "rejected"
                            ),
                            now,
                        )
        if error is not None:
            raise error
        return {
            "installation_state": "active",
            "installation_id": submission.new_installation_id,
        }

    async def list_installations(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
    ) -> list[dict[str, Any]]:
        rows = await self._pool().fetch(
            """
            SELECT installation_id,
                   platform,
                   status,
                   registered_at,
                   last_seen_at
            FROM ownership_installations
            WHERE account_id = $1
              AND status = 'active'
            ORDER BY registered_at DESC, installation_id
            """,
            principal.account_id,
        )
        return [
            {
                "installation_id": str(row["installation_id"]),
                "platform": str(row["platform"]),
                "status": str(row["status"]),
                "current": row["installation_id"] == current_installation_id,
                "registered_at": row["registered_at"],
                "last_seen_at": row["last_seen_at"],
            }
            for row in rows
        ]

    async def revoke_installation(
        self,
        *,
        principal: OwnershipPrincipal,
        current_installation_id: str,
        target_installation_id: str,
    ) -> None:
        if target_installation_id == current_installation_id:
            raise OwnershipForbiddenError("current installation cannot revoke itself")
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await _lock_account(connection, principal.account_id)
                now = await connection.fetchval("SELECT clock_timestamp()")
                current = await connection.fetchval(
                    """
                    SELECT status
                    FROM ownership_installations
                    WHERE account_id = $1 AND installation_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    current_installation_id,
                )
                if current != "active":
                    raise OwnershipForbiddenError(
                        "current ownership installation is unavailable"
                    )
                result = await connection.execute(
                    """
                    UPDATE ownership_installations
                    SET status = 'revoked',
                        revoked_at = $3,
                        last_seen_at = GREATEST(last_seen_at, $3)
                    WHERE account_id = $1
                      AND installation_id = $2
                      AND status = 'active'
                    """,
                    principal.account_id,
                    target_installation_id,
                    now,
                )
                if result != "UPDATE 1":
                    raise OwnershipNotFoundError(
                        "ownership installation is unavailable"
                    )
                await self._record_event(
                    connection,
                    account_id=principal.account_id,
                    installation_id=target_installation_id,
                    event_kind="installation_revoked",
                    outcome="completed",
                    occurred_at=now,
                )

    async def select_plan(
        self,
        *,
        principal: OwnershipPrincipal,
        installation_id: str,
        selection: OwnershipPlanSelection,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await _lock_account(connection, principal.account_id)
                await _require_active_installation(
                    connection,
                    account_id=principal.account_id,
                    installation_id=installation_id,
                )
                now = await connection.fetchval("SELECT clock_timestamp()")
                prior = await connection.fetchrow(
                    """
                    SELECT selection
                    FROM ownership_plan_selection_requests
                    WHERE account_id = $1 AND request_id = $2
                    """,
                    principal.account_id,
                    selection.request_id,
                )
                if prior is not None and prior["selection"] != selection.selection:
                    raise OwnershipConflictError("plan selection request conflicts")
                if prior is None:
                    await connection.execute(
                        """
                        INSERT INTO ownership_plan_selection_requests (
                            account_id,
                            request_id,
                            selection,
                            created_at
                        ) VALUES ($1, $2, $3, $4)
                        """,
                        principal.account_id,
                        selection.request_id,
                        selection.selection,
                        now,
                    )
                    await connection.execute(
                        """
                        INSERT INTO ownership_plan_selections (
                            account_id,
                            selection,
                            request_id,
                            selected_at,
                            updated_at
                        ) VALUES ($1, $2, $3, $4, $4)
                        ON CONFLICT (account_id) DO UPDATE
                        SET selection = EXCLUDED.selection,
                            request_id = EXCLUDED.request_id,
                            updated_at = EXCLUDED.updated_at
                        """,
                        principal.account_id,
                        selection.selection,
                        selection.request_id,
                        now,
                    )
                    await self._record_event(
                        connection,
                        account_id=principal.account_id,
                        event_kind="plan_selected",
                        outcome="completed",
                        occurred_at=now,
                    )
                current = await connection.fetchval(
                    """
                    SELECT selection
                    FROM ownership_plan_selections
                    WHERE account_id = $1
                    """,
                    principal.account_id,
                )
        return {
            "plan_selection": str(current or "noop"),
            "noop_plus_entitled": False,
            "payment_state": "unavailable",
        }

    @staticmethod
    async def _record_event(
        connection: Any,
        *,
        event_kind: str,
        outcome: str,
        occurred_at: datetime,
        account_id: UUID | None = None,
        band_id: UUID | None = None,
        installation_id: str | None = None,
    ) -> None:
        await connection.execute(
            """
            INSERT INTO ownership_events (
                event_id,
                account_id,
                band_id,
                installation_id,
                event_kind,
                outcome,
                actor_kind,
                occurred_at
            ) VALUES ($1, $2, $3, $4, $5, $6, 'customer', $7)
            """,
            uuid4(),
            account_id,
            band_id,
            installation_id,
            event_kind,
            outcome,
            occurred_at,
        )


def _validated_terms_manifest(row: Any) -> dict[str, Any]:
    try:
        manifest = OwnershipTermsManifest.model_validate(
            {
                "policy_version": str(row["policy_version"]),
                "locale": str(row["locale"]),
                "document_sha256": str(row["document_sha256"]).strip(),
                "document_uri": str(row["document_uri"]),
                "effective_at": row["effective_at"],
            }
        )
    except ValueError as error:
        raise OwnershipConfigurationError("ownership terms are unavailable") from error
    return manifest.model_dump()


async def _current_terms_document(
    connection: Any,
    *,
    locale: str,
    at: datetime | None = None,
) -> Any:
    requested_locale = "en" if locale.casefold() == "en" else locale
    return await connection.fetchrow(
        """
        WITH request_time AS (
            SELECT COALESCE($2::timestamptz, clock_timestamp()) AS value
        ),
        canonical AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256,
                   document.document_uri,
                   document.effective_at
            FROM ownership_terms_documents document
            CROSS JOIN request_time
            WHERE document.locale = 'en'
              AND document.effective_at <= request_time.value
              AND (
                  document.retired_at IS NULL
                  OR document.retired_at > request_time.value
              )
            ORDER BY document.effective_at DESC,
                     document.policy_version DESC
            LIMIT 1
        ),
        localized AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256,
                   document.document_uri,
                   document.effective_at
            FROM ownership_terms_documents document
            JOIN canonical
              ON canonical.policy_version = document.policy_version
            CROSS JOIN request_time
            WHERE document.locale = $1
              AND document.effective_at <= request_time.value
              AND (
                  document.retired_at IS NULL
                  OR document.retired_at > request_time.value
              )
            LIMIT 1
        )
        SELECT COALESCE(
                   localized.policy_version,
                   canonical.policy_version
               ) AS policy_version,
               COALESCE(localized.locale, canonical.locale) AS locale,
               COALESCE(
                   localized.document_sha256,
                   canonical.document_sha256
               ) AS document_sha256,
               COALESCE(
                   localized.document_uri,
                   canonical.document_uri
               ) AS document_uri,
               COALESCE(
                   localized.effective_at,
                   canonical.effective_at
               ) AS effective_at
        FROM canonical
        LEFT JOIN localized ON TRUE
        """,
        requested_locale,
        at,
    )


async def _terms_document_version(
    connection: Any,
    *,
    policy_version: str,
    locale: str,
) -> Any:
    requested_locale = "en" if locale.casefold() == "en" else locale
    return await connection.fetchrow(
        """
        WITH canonical AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256,
                   document.document_uri,
                   document.effective_at
            FROM ownership_terms_documents document
            WHERE document.policy_version = $1
              AND document.locale = 'en'
              AND document.effective_at <= clock_timestamp()
            LIMIT 1
        ),
        localized AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256,
                   document.document_uri,
                   document.effective_at
            FROM ownership_terms_documents document
            JOIN canonical
              ON canonical.policy_version = document.policy_version
            WHERE document.locale = $2
              AND document.effective_at <= clock_timestamp()
            LIMIT 1
        )
        SELECT COALESCE(
                   localized.policy_version,
                   canonical.policy_version
               ) AS policy_version,
               COALESCE(localized.locale, canonical.locale) AS locale,
               COALESCE(
                   localized.document_sha256,
                   canonical.document_sha256
               ) AS document_sha256,
               COALESCE(
                   localized.document_uri,
                   canonical.document_uri
               ) AS document_uri,
               COALESCE(
                   localized.effective_at,
                   canonical.effective_at
               ) AS effective_at
        FROM canonical
        LEFT JOIN localized ON TRUE
        """,
        policy_version,
        requested_locale,
    )


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


async def _lock_account(connection: Any, account_id: UUID) -> None:
    await connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        f"noop-ownership-account:{account_id}",
    )


async def _lock_installation(connection: Any, installation_id: str) -> None:
    await connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        f"noop-ownership-installation:{installation_id}",
    )


async def _require_active_installation(
    connection: Any,
    *,
    account_id: UUID,
    installation_id: str,
) -> None:
    status = await connection.fetchval(
        """
        SELECT status
        FROM ownership_installations
        WHERE account_id = $1 AND installation_id = $2
        FOR UPDATE
        """,
        account_id,
        installation_id,
    )
    if status != "active":
        raise OwnershipForbiddenError("ownership installation was rejected")


async def _require_current_terms_acceptance(
    connection: Any,
    *,
    account_id: UUID,
) -> None:
    row = await connection.fetchrow(
        """
        WITH request_time AS (
            SELECT clock_timestamp() AS value
        ),
        acceptance AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256,
                   document.accepted_at,
                   document.recorded_at,
                   document.acceptance_id
            FROM ownership_terms_acceptances document
            WHERE document.account_id = $1
            ORDER BY document.accepted_at DESC,
                     document.recorded_at DESC,
                     document.acceptance_id DESC
            LIMIT 1
        ),
        canonical AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256
            FROM ownership_terms_documents document
            CROSS JOIN request_time
            WHERE document.locale = 'en'
              AND document.effective_at <= request_time.value
              AND (
                  document.retired_at IS NULL
                  OR document.retired_at > request_time.value
              )
            ORDER BY document.effective_at DESC,
                     document.policy_version DESC
            LIMIT 1
        ),
        localized AS (
            SELECT document.policy_version,
                   document.locale,
                   document.document_sha256
            FROM ownership_terms_documents document
            JOIN canonical
              ON canonical.policy_version = document.policy_version
            JOIN acceptance
              ON acceptance.locale = document.locale
            CROSS JOIN request_time
            WHERE document.effective_at <= request_time.value
              AND (
                  document.retired_at IS NULL
                  OR document.retired_at > request_time.value
              )
            LIMIT 1
        )
        SELECT acceptance.policy_version AS accepted_policy_version,
               acceptance.locale AS accepted_locale,
               acceptance.document_sha256 AS accepted_document_sha256,
               canonical.policy_version AS current_policy_version,
               COALESCE(localized.locale, canonical.locale) AS current_locale,
               COALESCE(
                   localized.document_sha256,
                   canonical.document_sha256
               ) AS current_document_sha256
        FROM acceptance
        CROSS JOIN canonical
        LEFT JOIN localized ON TRUE
        """,
        account_id,
    )
    if (
        row is None
        or row["current_policy_version"] is None
        or row["current_locale"] is None
        or row["current_document_sha256"] is None
        or row["accepted_policy_version"] != row["current_policy_version"]
        or row["accepted_locale"] != row["current_locale"]
        or not hmac.compare_digest(
            str(row["accepted_document_sha256"]).strip(),
            str(row["current_document_sha256"]).strip(),
        )
    ):
        raise OwnershipConfigurationError(
            "current ownership terms have not been accepted"
        )


def _request_digest(values: dict[str, object]) -> str:
    encoded = json.dumps(
        values,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _optional_bound_digest_matches(
    stored: object | None,
    supplied: str | None,
) -> bool:
    if stored is None:
        return True
    if supplied is None:
        return False
    return hmac.compare_digest(str(stored).strip(), supplied)


def _optional_exact_digest_matches(
    stored: object | None,
    supplied: str | None,
) -> bool:
    if stored is None or supplied is None:
        return stored is None and supplied is None
    return hmac.compare_digest(str(stored).strip(), supplied)


def valid_possession_evidence(evidence: OwnershipPossessionEvidence) -> bool:
    if (
        re.fullmatch(r"[0-9a-f]{64}", evidence.provisioned_identity_hash) is None
        or re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}",
            evidence.protocol_version,
        )
        is None
        or re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}",
            evidence.firmware_version,
        )
        is None
        or evidence.confirmed_at.tzinfo is None
        or evidence.confirmed_at.utcoffset() is None
        or evidence.confirmed_at.astimezone(UTC)
        > datetime.now(UTC) + timedelta(seconds=30)
    ):
        return False
    return True


def _possession_evidence_within_challenge(
    evidence: OwnershipPossessionEvidence,
    *,
    created_at: datetime,
    expires_at: datetime,
) -> bool:
    if not valid_possession_evidence(evidence):
        return False
    confirmed_at = evidence.confirmed_at.astimezone(UTC)
    return created_at <= confirmed_at < expires_at
