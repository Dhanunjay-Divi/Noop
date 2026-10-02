from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import uuid4

import pytest

from app.managed_identity import ManagedIdentityClaims
from app.unified_identity_authority import (
    PostgresUnifiedIdentityAuthorityRepository,
)


class _AsyncContext:
    def __init__(self, value: Any) -> None:
        self.value = value

    async def __aenter__(self) -> Any:
        return self.value

    async def __aexit__(self, *_args: object) -> None:
        return None


class _ManagedOnlyConnection:
    def __init__(self, claims: ManagedIdentityClaims) -> None:
        self.claims = claims
        self.principal_id = uuid4()
        self.account_id = uuid4()
        self.identity_id = uuid4()
        self.statements: list[str] = []

    def transaction(self) -> _AsyncContext:
        return _AsyncContext(None)

    def _record(self, statement: str) -> str:
        normalized = " ".join(statement.split())
        if "ownership_" in normalized:
            raise AssertionError("managed reconciliation accessed ownership SQL")
        self.statements.append(normalized)
        return normalized

    async def execute(self, statement: str, *_args: object) -> str:
        self._record(statement)
        return "OK"

    async def fetchval(self, statement: str, *_args: object) -> datetime:
        self._record(statement)
        return datetime.now(UTC)

    async def fetchrow(
        self,
        statement: str,
        *_args: object,
    ) -> dict[str, object] | None:
        normalized = self._record(statement)
        if (
            "FROM unified_account_principals" in normalized
            and "LEFT JOIN" not in normalized
        ):
            return {"principal_id": self.principal_id, "status": "active"}
        if "SELECT identity.account_id, identity.identity_id" in normalized:
            return {
                "account_id": self.account_id,
                "identity_id": self.identity_id,
            }
        if "SELECT identity.issuer," in normalized:
            return {
                "issuer": self.claims.issuer,
                "provider_tenant": self.claims.provider_tenant,
                "subject_hash": self.claims.subject_hash,
            }
        if "LEFT JOIN unified_managed_account_links" in normalized:
            return {
                "principal_id": self.principal_id,
                "status": "active",
                "managed_account_id": self.account_id,
                "managed_identity_id": self.identity_id,
            }
        raise AssertionError(f"unexpected fetchrow statement: {normalized}")

    async def fetch(
        self,
        statement: str,
        *_args: object,
    ) -> list[dict[str, object]]:
        normalized = self._record(statement)
        if "FROM unified_managed_account_links" in normalized:
            return []
        raise AssertionError(f"unexpected fetch statement: {normalized}")


class _ManagedOnlyPool:
    def __init__(self, connection: _ManagedOnlyConnection) -> None:
        self.connection = connection

    def acquire(self) -> _AsyncContext:
        return _AsyncContext(self.connection)


class _Primary:
    def __init__(self, pool: _ManagedOnlyPool) -> None:
        self._pool = pool


@pytest.mark.asyncio
async def test_managed_reconciliation_never_reads_ownership_relations() -> None:
    now = datetime.now(UTC)
    claims = ManagedIdentityClaims(
        issuer="https://securetoken.google.com/noop-synthetic-project",
        subject="managed-scope-subject",
        provider_tenant="",
        issued_at=now,
        auth_time=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
        email_verified=True,
        sign_in_provider="password",
    )
    connection = _ManagedOnlyConnection(claims)
    events: list[tuple[str, dict[str, object]]] = []
    repository = PostgresUnifiedIdentityAuthorityRepository(
        _Primary(_ManagedOnlyPool(connection)),  # type: ignore[arg-type]
        event_sink=lambda event, **fields: events.append((event, fields)),
    )

    principal = await repository.reconcile_managed_identity(claims)

    assert principal.principal_id == connection.principal_id
    assert principal.managed_account_id == connection.account_id
    assert principal.managed_identity_id == connection.identity_id
    assert principal.ownership_account_id is None
    assert principal.ownership_identity_id is None
    assert any("unified_account_principals" in sql for sql in connection.statements)
    assert all("ownership_" not in sql for sql in connection.statements)
    assert events == [
        (
            "unified_identity.reconciliation",
            {
                "service": "noop-identity-authority",
                "outcome": "reconciled",
                "scope": "managed",
                "managed_linked": True,
                "ownership_linked": False,
            },
        )
    ]
