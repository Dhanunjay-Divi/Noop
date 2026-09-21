from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal
from uuid import UUID

from app.managed_repository import ManagedPrincipal

MAX_MANAGED_DOCUMENT_ENVELOPE_BYTES = 1_048_576
MIN_MANAGED_DOCUMENT_ENVELOPE_BYTES = 40
_DOCUMENT_MAGIC = b"NOOPDOC\x00"
_WRAPPED_KEY_DIGEST = re.compile(r"^[0-9a-f]{64}$")


class ManagedDocumentKeyError(Exception):
    """Base error for the opaque managed-document key boundary."""


class ManagedDocumentKeyDisabledError(ManagedDocumentKeyError):
    pass


class ManagedDocumentKeyConflictError(ManagedDocumentKeyError):
    pass


class ManagedDocumentKeyNotFoundError(ManagedDocumentKeyError):
    pass


class ManagedDocumentKeyAccountUnavailableError(ManagedDocumentKeyNotFoundError):
    pass


@dataclass(frozen=True, slots=True)
class ManagedDocumentEnvelopeHeader:
    version: int
    nonce: bytes
    ciphertext_bytes: int


@dataclass(frozen=True, slots=True)
class ManagedWrappedKeyMutation:
    key_id: UUID
    key_kind: Literal["account_master", "document"]
    wrapping_key_id: UUID | None
    wrapping_revision: int
    algorithm: Literal["A256GCM"]
    wrapped_key: bytes
    wrapped_key_sha256: str
    master_key_confirmation_hmac_sha256: str | None = None
    recovery_method: (
        Literal[
            "recovery_key",
            "device_transfer",
            "platform_escrow",
        ]
        | None
    ) = None

    def __post_init__(self) -> None:
        if self.wrapping_revision <= 0:
            raise ValueError("wrapping_revision must be positive")
        if not 40 <= len(self.wrapped_key) <= 16_384:
            raise ValueError("wrapped_key size is invalid")
        if (
            _WRAPPED_KEY_DIGEST.fullmatch(self.wrapped_key_sha256) is None
            or hashlib.sha256(self.wrapped_key).hexdigest() != self.wrapped_key_sha256
        ):
            raise ValueError("wrapped_key digest is invalid")
        if self.key_kind == "account_master":
            if (
                self.wrapping_key_id is not None
                or self.recovery_method is None
                or self.master_key_confirmation_hmac_sha256 is None
                or _WRAPPED_KEY_DIGEST.fullmatch(
                    self.master_key_confirmation_hmac_sha256
                )
                is None
            ):
                raise ValueError("account master keys require recovery wrapping")
        elif (
            self.wrapping_key_id is None
            or self.wrapping_key_id == self.key_id
            or self.recovery_method is not None
            or self.master_key_confirmation_hmac_sha256 is not None
            or len(self.wrapped_key) != 72
        ):
            raise ValueError("document keys require an account master wrapping key")


@dataclass(frozen=True, slots=True)
class ManagedWrappedKeyRecord:
    account_id: UUID
    key_id: UUID
    key_kind: str
    wrapping_key_id: UUID | None
    wrapping_revision: int
    algorithm: str
    wrapped_key: bytes
    wrapped_key_sha256: str
    master_key_confirmation_hmac_sha256: str | None
    recovery_method: str | None
    status: str
    successor_key_id: UUID | None
    created_at: datetime
    updated_at: datetime
    revoked_at: datetime | None


@dataclass(frozen=True, slots=True)
class ManagedWrappedKeyVersionRecord:
    account_id: UUID
    key_id: UUID
    key_kind: str
    wrapping_key_id: UUID | None
    wrapping_revision: int
    algorithm: str
    wrapped_key: bytes
    wrapped_key_sha256: str
    master_key_confirmation_hmac_sha256: str | None
    recovery_method: str | None
    created_at: datetime


def parse_managed_document_envelope(
    envelope: bytes,
) -> ManagedDocumentEnvelopeHeader:
    if not (
        MIN_MANAGED_DOCUMENT_ENVELOPE_BYTES
        <= len(envelope)
        <= MAX_MANAGED_DOCUMENT_ENVELOPE_BYTES
    ):
        raise ValueError("managed document envelope size is invalid")
    if (
        envelope[:8] != _DOCUMENT_MAGIC
        or envelope[8] != 1
        or envelope[9] != 12
        or envelope[10:12] != b"\x00\x00"
    ):
        raise ValueError("managed document envelope header is invalid")
    return ManagedDocumentEnvelopeHeader(
        version=1,
        nonce=envelope[12:24],
        ciphertext_bytes=len(envelope) - 40,
    )


class PostgresManagedDocumentKeyRepository:
    """Default-off account-scoped storage for opaque wrapped key material."""

    def __init__(self, primary_repository: Any, *, enabled: bool = False) -> None:
        self._primary = primary_repository
        self._enabled = enabled

    def _require_enabled(self, principal: ManagedPrincipal) -> None:
        if not self._enabled:
            raise ManagedDocumentKeyDisabledError(
                "managed document key recovery is not enabled"
            )
        if principal.account_status != "active":
            raise ManagedDocumentKeyAccountUnavailableError(
                "managed document key account is unavailable"
            )

    @staticmethod
    async def _lock_active_account(
        connection: Any,
        *,
        principal: ManagedPrincipal,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            f"noop-managed-erasure-account:{principal.account_id}",
        )
        account = await connection.fetchrow(
            """
            SELECT status, auth_valid_after
            FROM managed_accounts
            WHERE account_id = $1
            FOR SHARE
            """,
            principal.account_id,
        )
        if (
            account is None
            or account["status"] != "active"
            or account["auth_valid_after"] != principal.auth_valid_after
        ):
            raise ManagedDocumentKeyAccountUnavailableError(
                "managed document key account is unavailable"
            )

    async def put(
        self,
        *,
        principal: ManagedPrincipal,
        mutation: ManagedWrappedKeyMutation,
        now: datetime | None = None,
    ) -> ManagedWrappedKeyRecord:
        self._require_enabled(principal)
        timestamp = _aware_utc(now)
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_active_account(
                    connection,
                    principal=principal,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-document-key:{principal.account_id}:{mutation.key_id}",
                )
                if mutation.wrapping_key_id is not None:
                    wrapping = await connection.fetchrow(
                        """
                        SELECT key_kind, status
                        FROM managed_document_keys
                        WHERE account_id = $1 AND key_id = $2
                        FOR SHARE
                        """,
                        principal.account_id,
                        mutation.wrapping_key_id,
                    )
                    if (
                        wrapping is None
                        or wrapping["key_kind"] != "account_master"
                        or wrapping["status"] != "active"
                    ):
                        raise ManagedDocumentKeyConflictError(
                            "active account master wrapping key is required"
                        )
                row = await connection.fetchrow(
                    """
                    INSERT INTO managed_document_keys (
                        account_id, key_id, key_kind, wrapping_key_id,
                        wrapping_revision, algorithm, wrapped_key,
                        wrapped_key_sha256,
                        master_key_confirmation_hmac_sha256,
                        recovery_method,
                        status, created_at, updated_at
                    ) VALUES (
                        $1, $2, $3, $4,
                        $5, $6, $7,
                        $8, $9, $10,
                        'active', $11, $11
                    )
                    ON CONFLICT (account_id, key_id) DO UPDATE
                    SET updated_at = managed_document_keys.updated_at
                    WHERE managed_document_keys.key_kind = EXCLUDED.key_kind
                      AND managed_document_keys.wrapping_key_id
                          IS NOT DISTINCT FROM EXCLUDED.wrapping_key_id
                      AND managed_document_keys.wrapping_revision
                          = EXCLUDED.wrapping_revision
                      AND managed_document_keys.algorithm = EXCLUDED.algorithm
                      AND managed_document_keys.wrapped_key = EXCLUDED.wrapped_key
                      AND managed_document_keys.wrapped_key_sha256
                          = EXCLUDED.wrapped_key_sha256
                      AND managed_document_keys
                            .master_key_confirmation_hmac_sha256
                          IS NOT DISTINCT FROM EXCLUDED
                            .master_key_confirmation_hmac_sha256
                      AND managed_document_keys.recovery_method
                          IS NOT DISTINCT FROM EXCLUDED.recovery_method
                      AND managed_document_keys.status = 'active'
                    RETURNING *
                    """,
                    principal.account_id,
                    mutation.key_id,
                    mutation.key_kind,
                    mutation.wrapping_key_id,
                    mutation.wrapping_revision,
                    mutation.algorithm,
                    mutation.wrapped_key,
                    mutation.wrapped_key_sha256,
                    mutation.master_key_confirmation_hmac_sha256,
                    mutation.recovery_method,
                    timestamp,
                )
                if row is None:
                    raise ManagedDocumentKeyConflictError(
                        "managed document key conflicts with existing state"
                    )
                await _store_version(
                    connection,
                    account_id=principal.account_id,
                    mutation=mutation,
                    created_at=timestamp,
                )
                return _record(row)

    async def get(
        self,
        *,
        principal: ManagedPrincipal,
        key_id: UUID,
    ) -> ManagedWrappedKeyRecord:
        self._require_enabled(principal)
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_active_account(
                    connection,
                    principal=principal,
                )
                row = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_document_keys
                    WHERE account_id = $1
                      AND key_id = $2
                      AND status <> 'revoked'
                    """,
                    principal.account_id,
                    key_id,
                )
        if row is None:
            raise ManagedDocumentKeyNotFoundError("managed document key was not found")
        return _record(row)

    async def get_version(
        self,
        *,
        principal: ManagedPrincipal,
        key_id: UUID,
        wrapping_revision: int,
    ) -> ManagedWrappedKeyVersionRecord:
        self._require_enabled(principal)
        if wrapping_revision <= 0:
            raise ValueError("wrapping_revision must be positive")
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_active_account(
                    connection,
                    principal=principal,
                )
                row = await connection.fetchrow(
                    """
                    SELECT version.*
                    FROM managed_document_key_versions AS version
                    JOIN managed_document_keys AS key
                      USING (account_id, key_id)
                    WHERE version.account_id = $1
                      AND version.key_id = $2
                      AND version.wrapping_revision = $3
                      AND key.status <> 'revoked'
                    """,
                    principal.account_id,
                    key_id,
                    wrapping_revision,
                )
        if row is None:
            raise ManagedDocumentKeyNotFoundError(
                "managed document key version was not found"
            )
        return _version_record(row)

    async def rotate_wrapping(
        self,
        *,
        principal: ManagedPrincipal,
        mutation: ManagedWrappedKeyMutation,
        expected_wrapping_revision: int,
        now: datetime | None = None,
    ) -> ManagedWrappedKeyRecord:
        self._require_enabled(principal)
        if mutation.key_kind != "document" or expected_wrapping_revision <= 0:
            raise ValueError("only document-key wrapping can be rotated")
        if mutation.wrapping_revision != expected_wrapping_revision + 1:
            raise ValueError("wrapping_revision must increase by exactly one")
        timestamp = _aware_utc(now)
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_active_account(
                    connection,
                    principal=principal,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-document-key:{principal.account_id}:{mutation.key_id}",
                )
                current = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_document_keys
                    WHERE account_id = $1 AND key_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    mutation.key_id,
                )
                if current is None:
                    raise ManagedDocumentKeyNotFoundError(
                        "managed document key was not found"
                    )
                if current["key_kind"] != "document" or current["status"] != "active":
                    raise ManagedDocumentKeyConflictError(
                        "only an active document key can be rotated"
                    )
                if current[
                    "wrapping_revision"
                ] == mutation.wrapping_revision and _matches_mutation(
                    current, mutation
                ):
                    return _record(current)
                if current["wrapping_revision"] != expected_wrapping_revision:
                    raise ManagedDocumentKeyConflictError(
                        "managed document key rotation lost its compare-and-swap"
                    )
                wrapping = await connection.fetchrow(
                    """
                    SELECT key_kind, status
                    FROM managed_document_keys
                    WHERE account_id = $1 AND key_id = $2
                    FOR SHARE
                    """,
                    principal.account_id,
                    mutation.wrapping_key_id,
                )
                if (
                    wrapping is None
                    or wrapping["key_kind"] != "account_master"
                    or wrapping["status"] != "active"
                ):
                    raise ManagedDocumentKeyConflictError(
                        "active account master wrapping key is required"
                    )
                await _store_version(
                    connection,
                    account_id=principal.account_id,
                    mutation=mutation,
                    created_at=timestamp,
                )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_document_keys
                    SET wrapping_key_id = $3,
                        wrapping_revision = $4,
                        algorithm = $5,
                        wrapped_key = $6,
                        wrapped_key_sha256 = $7,
                        updated_at = $8
                    WHERE account_id = $1
                      AND key_id = $2
                      AND key_kind = 'document'
                      AND status = 'active'
                      AND wrapping_revision = $9
                    RETURNING *
                    """,
                    principal.account_id,
                    mutation.key_id,
                    mutation.wrapping_key_id,
                    mutation.wrapping_revision,
                    mutation.algorithm,
                    mutation.wrapped_key,
                    mutation.wrapped_key_sha256,
                    timestamp,
                    expected_wrapping_revision,
                )
                if row is None:
                    raise ManagedDocumentKeyConflictError(
                        "managed document key rotation lost its compare-and-swap"
                    )
                return _record(row)

    async def revoke(
        self,
        *,
        principal: ManagedPrincipal,
        key_id: UUID,
        successor_key_id: UUID | None = None,
        now: datetime | None = None,
    ) -> ManagedWrappedKeyRecord:
        self._require_enabled(principal)
        if successor_key_id == key_id:
            raise ValueError("a key cannot succeed itself")
        timestamp = _aware_utc(now)
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_active_account(
                    connection,
                    principal=principal,
                )
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-managed-document-key:{principal.account_id}:{key_id}",
                )
                current = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_document_keys
                    WHERE account_id = $1 AND key_id = $2
                    FOR UPDATE
                    """,
                    principal.account_id,
                    key_id,
                )
                if current is None:
                    raise ManagedDocumentKeyNotFoundError(
                        "managed document key was not found"
                    )
                if current["status"] == "revoked":
                    if current["successor_key_id"] == successor_key_id:
                        return _record(current)
                    raise ManagedDocumentKeyConflictError(
                        "revoked key has a different successor"
                    )
                if current["status"] != "active":
                    raise ManagedDocumentKeyConflictError(
                        "only an active key can be revoked"
                    )
                if current["key_kind"] == "document":
                    live_document = await connection.fetchval(
                        """
                        SELECT document_id
                        FROM managed_documents
                        WHERE account_id = $1
                          AND document_key_id = $2
                          AND deleted_at IS NULL
                        ORDER BY document_id
                        LIMIT 1
                        FOR SHARE
                        """,
                        principal.account_id,
                        key_id,
                    )
                    if live_document is not None:
                        raise ManagedDocumentKeyConflictError(
                            "document key is still referenced by live documents"
                        )
                if current["key_kind"] == "account_master":
                    active_dependents = await connection.fetchval(
                        """
                        SELECT EXISTS (
                            SELECT 1
                            FROM managed_document_keys
                            WHERE account_id = $1
                              AND key_kind = 'document'
                              AND wrapping_key_id = $2
                              AND status = 'active'
                        )
                        """,
                        principal.account_id,
                        key_id,
                    )
                    if active_dependents is True:
                        raise ManagedDocumentKeyConflictError(
                            "account master key has active document keys"
                        )
                if successor_key_id is not None:
                    successor = await connection.fetchrow(
                        """
                        SELECT key_kind, status
                        FROM managed_document_keys
                        WHERE account_id = $1 AND key_id = $2
                        FOR SHARE
                        """,
                        principal.account_id,
                        successor_key_id,
                    )
                    if (
                        successor is None
                        or successor["key_kind"] != current["key_kind"]
                        or successor["status"] != "active"
                    ):
                        raise ManagedDocumentKeyConflictError(
                            "successor key must be active and same-kind"
                        )
                    cycle_found = await connection.fetchval(
                        """
                        WITH RECURSIVE successor_chain AS (
                            SELECT key_id, successor_key_id, ARRAY[key_id] AS path
                            FROM managed_document_keys
                            WHERE account_id = $1 AND key_id = $2
                            UNION ALL
                            SELECT candidate.key_id,
                                   candidate.successor_key_id,
                                   chain.path || candidate.key_id
                            FROM successor_chain AS chain
                            JOIN managed_document_keys AS candidate
                              ON candidate.account_id = $1
                             AND candidate.key_id = chain.successor_key_id
                            WHERE NOT candidate.key_id = ANY(chain.path)
                        )
                        SELECT EXISTS (
                            SELECT 1
                            FROM successor_chain
                            WHERE key_id = $3 OR successor_key_id = $3
                        )
                        """,
                        principal.account_id,
                        successor_key_id,
                        key_id,
                    )
                    if cycle_found is True:
                        raise ManagedDocumentKeyConflictError(
                            "successor key cycle is invalid"
                        )
                row = await connection.fetchrow(
                    """
                    UPDATE managed_document_keys
                    SET status = 'revoked',
                        successor_key_id = $3,
                        revoked_at = $4,
                        updated_at = GREATEST(updated_at, $4)
                    WHERE account_id = $1
                      AND key_id = $2
                      AND status = 'active'
                    RETURNING *
                    """,
                    principal.account_id,
                    key_id,
                    successor_key_id,
                    timestamp,
                )
                if row is None:
                    raise ManagedDocumentKeyConflictError(
                        "managed document key revocation lost its compare-and-swap"
                    )
                return _record(row)


def _aware_utc(value: datetime | None) -> datetime:
    selected = datetime.now(UTC) if value is None else value
    if selected.tzinfo is None:
        raise ValueError("timestamp must be timezone-aware")
    return selected.astimezone(UTC)


def _record(row: Any) -> ManagedWrappedKeyRecord:
    value = dict(row)
    return ManagedWrappedKeyRecord(
        account_id=value["account_id"],
        key_id=value["key_id"],
        key_kind=value["key_kind"],
        wrapping_key_id=value["wrapping_key_id"],
        wrapping_revision=value["wrapping_revision"],
        algorithm=value["algorithm"],
        wrapped_key=bytes(value["wrapped_key"]),
        wrapped_key_sha256=value["wrapped_key_sha256"],
        master_key_confirmation_hmac_sha256=(
            value["master_key_confirmation_hmac_sha256"]
        ),
        recovery_method=value["recovery_method"],
        status=value["status"],
        successor_key_id=value["successor_key_id"],
        created_at=value["created_at"],
        updated_at=value["updated_at"],
        revoked_at=value["revoked_at"],
    )


def _version_record(row: Any) -> ManagedWrappedKeyVersionRecord:
    value = dict(row)
    return ManagedWrappedKeyVersionRecord(
        account_id=value["account_id"],
        key_id=value["key_id"],
        key_kind=value["key_kind"],
        wrapping_key_id=value["wrapping_key_id"],
        wrapping_revision=value["wrapping_revision"],
        algorithm=value["algorithm"],
        wrapped_key=bytes(value["wrapped_key"]),
        wrapped_key_sha256=value["wrapped_key_sha256"],
        master_key_confirmation_hmac_sha256=(
            value["master_key_confirmation_hmac_sha256"]
        ),
        recovery_method=value["recovery_method"],
        created_at=value["created_at"],
    )


def _matches_mutation(row: Any, mutation: ManagedWrappedKeyMutation) -> bool:
    return (
        row["key_kind"] == mutation.key_kind
        and row["wrapping_key_id"] == mutation.wrapping_key_id
        and row["wrapping_revision"] == mutation.wrapping_revision
        and row["algorithm"] == mutation.algorithm
        and bytes(row["wrapped_key"]) == mutation.wrapped_key
        and row["wrapped_key_sha256"] == mutation.wrapped_key_sha256
        and row["master_key_confirmation_hmac_sha256"]
        == mutation.master_key_confirmation_hmac_sha256
        and row["recovery_method"] == mutation.recovery_method
    )


async def _store_version(
    connection: Any,
    *,
    account_id: UUID,
    mutation: ManagedWrappedKeyMutation,
    created_at: datetime,
) -> None:
    inserted = await connection.fetchrow(
        """
        INSERT INTO managed_document_key_versions (
            account_id, key_id, key_kind, wrapping_revision,
            wrapping_key_id, algorithm, wrapped_key,
            wrapped_key_sha256, master_key_confirmation_hmac_sha256,
            recovery_method, created_at
        ) VALUES (
            $1, $2, $3, $4,
            $5, $6, $7,
            $8, $9, $10, $11
        )
        ON CONFLICT (account_id, key_id, wrapping_revision) DO NOTHING
        RETURNING *
        """,
        account_id,
        mutation.key_id,
        mutation.key_kind,
        mutation.wrapping_revision,
        mutation.wrapping_key_id,
        mutation.algorithm,
        mutation.wrapped_key,
        mutation.wrapped_key_sha256,
        mutation.master_key_confirmation_hmac_sha256,
        mutation.recovery_method,
        created_at,
    )
    if inserted is not None:
        return
    existing = await connection.fetchrow(
        """
        SELECT *
        FROM managed_document_key_versions
        WHERE account_id = $1
          AND key_id = $2
          AND wrapping_revision = $3
        """,
        account_id,
        mutation.key_id,
        mutation.wrapping_revision,
    )
    if existing is None or not _matches_mutation(existing, mutation):
        raise ManagedDocumentKeyConflictError(
            "managed document key version conflicts with existing history"
        )
