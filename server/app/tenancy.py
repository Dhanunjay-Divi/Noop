from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Any, Protocol
from uuid import UUID


class InstallationNotFoundError(Exception):
    """Raised when an installation credential or owned device is absent."""


class InstallationConflictError(Exception):
    """Raised when enrollment, rotation, or ownership conflicts with stored state."""


def _device_matches_installation(device_id: str, installation_id: str) -> bool:
    components = device_id.split(":", 2)
    return (
        len(components) == 3
        and components[0] in {"ios", "android", "macos", "import", "other"}
        and components[1] == installation_id
        and bool(components[2])
    )


def _public_installation(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in row.items()
        if key not in {"token_hash", "last_rotation_token_hash"}
    }


class InstallationRepository(Protocol):
    async def coordination_now(self) -> datetime: ...

    async def shared_cutover_ready(self) -> bool: ...

    async def create_installation(
        self,
        *,
        installation_id: str,
        enrollment_id: str,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def installation_for_token(
        self, token_hash: str
    ) -> dict[str, Any] | None: ...

    async def list_installations(self) -> list[dict[str, Any]]: ...

    async def rotate_token(
        self,
        *,
        installation_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]: ...

    async def revoke_installation(
        self, *, installation_id: str, now: datetime
    ) -> dict[str, Any]: ...

    async def delete_installation(self, installation_id: str) -> dict[str, int]: ...

    async def claim_device(
        self,
        *,
        installation_id: str,
        device_id: str,
        now: datetime,
    ) -> None: ...

    async def owns_device(self, *, installation_id: str, device_id: str) -> bool: ...

    async def device_ids(
        self,
        installation_id: str,
        *,
        limit: int | None = None,
    ) -> list[str]: ...

    async def release_device(self, *, installation_id: str, device_id: str) -> None: ...


class MemoryInstallationRepository:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._installations: dict[str, dict[str, Any]] = {}
        self._enrollments: dict[str, str] = {}
        self._tokens: dict[str, str] = {}
        self._device_owners: dict[str, str] = {}

    async def coordination_now(self) -> datetime:
        return datetime.now(UTC)

    async def shared_cutover_ready(self) -> bool:
        async with self._lock:
            return all(
                owner in self._installations
                and _device_matches_installation(device_id, owner)
                for device_id, owner in self._device_owners.items()
            )

    async def create_installation(
        self,
        *,
        installation_id: str,
        enrollment_id: str,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            existing_id = self._enrollments.get(enrollment_id)
            existing = self._installations.get(existing_id or installation_id)
            if existing is not None:
                if (
                    existing["installation_id"] == installation_id
                    and existing["enrollment_id"] == enrollment_id
                    and existing["token_hash"] == token_hash
                    and existing["revoked_at"] is None
                ):
                    return _public_installation(existing)
                raise InstallationConflictError(
                    "installation or enrollment is already registered"
                )
            if token_hash in self._tokens:
                raise InstallationConflictError(
                    "installation credential is already registered"
                )
            row = {
                "installation_id": installation_id,
                "enrollment_id": enrollment_id,
                "token_hash": token_hash,
                "token_version": 1,
                "last_rotation_id": None,
                "last_rotation_token_hash": None,
                "created_at": now,
                "updated_at": now,
                "revoked_at": None,
            }
            self._installations[installation_id] = row
            self._enrollments[enrollment_id] = installation_id
            self._tokens[token_hash] = installation_id
            return _public_installation(row)

    async def installation_for_token(self, token_hash: str) -> dict[str, Any] | None:
        async with self._lock:
            installation_id = self._tokens.get(token_hash)
            row = self._installations.get(installation_id or "")
            if row is None or row["revoked_at"] is not None:
                return None
            return _public_installation(row)

    async def list_installations(self) -> list[dict[str, Any]]:
        async with self._lock:
            return [
                _public_installation(row)
                for row in sorted(
                    self._installations.values(),
                    key=lambda value: value["installation_id"],
                )
            ]

    async def rotate_token(
        self,
        *,
        installation_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._lock:
            row = self._installations.get(installation_id)
            if row is None or row["revoked_at"] is not None:
                raise InstallationNotFoundError("installation is not active")
            if (
                row["last_rotation_id"] == rotation_id
                and row["last_rotation_token_hash"] == token_hash
            ):
                return _public_installation(row)
            if row["token_version"] != expected_version:
                raise InstallationConflictError(
                    "installation token version has changed"
                )
            token_owner = self._tokens.get(token_hash)
            if token_owner is not None and token_owner != installation_id:
                raise InstallationConflictError(
                    "installation credential is already registered"
                )
            self._tokens.pop(row["token_hash"], None)
            row["token_hash"] = token_hash
            row["token_version"] += 1
            row["last_rotation_id"] = rotation_id
            row["last_rotation_token_hash"] = token_hash
            row["updated_at"] = now
            self._tokens[token_hash] = installation_id
            return _public_installation(row)

    async def revoke_installation(
        self, *, installation_id: str, now: datetime
    ) -> dict[str, Any]:
        async with self._lock:
            row = self._installations.get(installation_id)
            if row is None:
                raise InstallationNotFoundError("installation was not found")
            if row["revoked_at"] is None:
                self._tokens.pop(row["token_hash"], None)
                row["revoked_at"] = now
                row["updated_at"] = now
            return _public_installation(row)

    async def delete_installation(self, installation_id: str) -> dict[str, int]:
        async with self._lock:
            row = self._installations.pop(installation_id, None)
            if row is None:
                raise InstallationNotFoundError("installation was not found")
            self._tokens.pop(row["token_hash"], None)
            self._enrollments.pop(row["enrollment_id"], None)
            devices = [
                device_id
                for device_id, owner in self._device_owners.items()
                if owner == installation_id
            ]
            for device_id in devices:
                del self._device_owners[device_id]
            return {"installation_credentials": 1, "installation_devices": len(devices)}

    async def claim_device(
        self,
        *,
        installation_id: str,
        device_id: str,
        now: datetime,
    ) -> None:
        del now
        if not _device_matches_installation(device_id, installation_id):
            raise InstallationConflictError(
                "device identifier does not belong to this installation"
            )
        async with self._lock:
            row = self._installations.get(installation_id)
            if row is None or row["revoked_at"] is not None:
                raise InstallationNotFoundError("installation is not active")
            owner = self._device_owners.get(device_id)
            if owner is not None and owner != installation_id:
                raise InstallationConflictError(
                    "device is already owned by another installation"
                )
            self._device_owners[device_id] = installation_id

    async def owns_device(self, *, installation_id: str, device_id: str) -> bool:
        async with self._lock:
            return self._device_owners.get(device_id) == installation_id

    async def device_ids(
        self,
        installation_id: str,
        *,
        limit: int | None = None,
    ) -> list[str]:
        async with self._lock:
            device_ids = sorted(
                device_id
                for device_id, owner in self._device_owners.items()
                if owner == installation_id
            )
            return device_ids[:limit] if limit is not None else device_ids

    async def release_device(self, *, installation_id: str, device_id: str) -> None:
        async with self._lock:
            if self._device_owners.get(device_id) != installation_id:
                raise InstallationNotFoundError("owned device was not found")
            del self._device_owners[device_id]


class PostgresInstallationRepository:
    """Installation credentials and device ownership on the primary database pool."""

    def __init__(self, primary_repository: Any) -> None:
        self.primary_repository = primary_repository

    def _pool(self) -> Any:
        return self.primary_repository._require_pool()

    async def coordination_now(self) -> datetime:
        return await self._pool().fetchval("SELECT clock_timestamp()")

    async def shared_cutover_ready(self) -> bool:
        return bool(
            await self._pool().fetchval(
                """
                SELECT
                  NOT EXISTS (
                    SELECT 1
                    FROM devices d
                    LEFT JOIN installation_devices owner USING (device_id)
                    LEFT JOIN installation_credentials installation
                      USING (installation_id)
                    WHERE owner.device_id IS NULL
                       OR installation.installation_id IS NULL
                  )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM friend_profiles profile
                    LEFT JOIN installation_credentials installation
                      USING (installation_id)
                    WHERE installation.installation_id IS NULL
                  )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM safety_profiles profile
                    LEFT JOIN installation_credentials installation
                      USING (installation_id)
                    WHERE installation.installation_id IS NULL
                  )
                """
            )
        )

    async def create_installation(
        self,
        *,
        installation_id: str,
        enrollment_id: str,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    f"noop-installation:{installation_id}",
                )
                existing = await connection.fetchrow(
                    """
                    SELECT installation_id, enrollment_id, token_hash,
                           token_version, last_rotation_id,
                           last_rotation_token_hash, created_at, updated_at,
                           revoked_at
                    FROM installation_credentials
                    WHERE installation_id = $1 OR enrollment_id = $2
                    FOR UPDATE
                    """,
                    installation_id,
                    UUID(enrollment_id),
                )
                if existing is not None:
                    decoded = dict(existing)
                    if (
                        decoded["installation_id"] == installation_id
                        and str(decoded["enrollment_id"]) == enrollment_id
                        and decoded["token_hash"].strip() == token_hash
                        and decoded["revoked_at"] is None
                    ):
                        return _public_installation(decoded)
                    raise InstallationConflictError(
                        "installation or enrollment is already registered"
                    )
                try:
                    row = await connection.fetchrow(
                        """
                        INSERT INTO installation_credentials (
                            installation_id, enrollment_id, token_hash,
                            created_at, updated_at
                        ) VALUES ($1, $2, $3, $4, $4)
                        RETURNING installation_id, enrollment_id, token_version,
                                  last_rotation_id, created_at, updated_at,
                                  revoked_at
                        """,
                        installation_id,
                        UUID(enrollment_id),
                        token_hash,
                        now,
                    )
                except Exception as exc:
                    if getattr(exc, "sqlstate", None) == "23505":
                        raise InstallationConflictError(
                            "installation credential is already registered"
                        ) from exc
                    raise
        return _public_installation(dict(row))

    async def installation_for_token(self, token_hash: str) -> dict[str, Any] | None:
        row = await self._pool().fetchrow(
            """
            SELECT installation_id, enrollment_id, token_version,
                   last_rotation_id, created_at, updated_at, revoked_at
            FROM installation_credentials
            WHERE token_hash = $1 AND revoked_at IS NULL
            """,
            token_hash,
        )
        return _public_installation(dict(row)) if row is not None else None

    async def list_installations(self) -> list[dict[str, Any]]:
        rows = await self._pool().fetch(
            """
            SELECT installation_id, enrollment_id, token_version,
                   last_rotation_id, created_at, updated_at, revoked_at
            FROM installation_credentials
            ORDER BY installation_id
            """
        )
        return [_public_installation(dict(row)) for row in rows]

    async def rotate_token(
        self,
        *,
        installation_id: str,
        rotation_id: str,
        expected_version: int,
        token_hash: str,
        now: datetime,
    ) -> dict[str, Any]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                row = await connection.fetchrow(
                    """
                    SELECT installation_id, enrollment_id, token_hash,
                           token_version, last_rotation_id,
                           last_rotation_token_hash, created_at, updated_at,
                           revoked_at
                    FROM installation_credentials
                    WHERE installation_id = $1
                    FOR UPDATE
                    """,
                    installation_id,
                )
                if row is None or row["revoked_at"] is not None:
                    raise InstallationNotFoundError("installation is not active")
                if (
                    str(row["last_rotation_id"]) == rotation_id
                    and (row["last_rotation_token_hash"] or "").strip() == token_hash
                ):
                    return _public_installation(dict(row))
                if row["token_version"] != expected_version:
                    raise InstallationConflictError(
                        "installation token version has changed"
                    )
                try:
                    updated = await connection.fetchrow(
                        """
                        UPDATE installation_credentials
                        SET token_hash = $2,
                            token_version = token_version + 1,
                            last_rotation_id = $3,
                            last_rotation_token_hash = $2,
                            updated_at = $4
                        WHERE installation_id = $1
                        RETURNING installation_id, enrollment_id, token_version,
                                  last_rotation_id, created_at, updated_at,
                                  revoked_at
                        """,
                        installation_id,
                        token_hash,
                        UUID(rotation_id),
                        now,
                    )
                except Exception as exc:
                    if getattr(exc, "sqlstate", None) == "23505":
                        raise InstallationConflictError(
                            "installation credential is already registered"
                        ) from exc
                    raise
        return _public_installation(dict(updated))

    async def revoke_installation(
        self, *, installation_id: str, now: datetime
    ) -> dict[str, Any]:
        row = await self._pool().fetchrow(
            """
            UPDATE installation_credentials
            SET revoked_at = COALESCE(revoked_at, $2), updated_at = $2
            WHERE installation_id = $1
            RETURNING installation_id, enrollment_id, token_version,
                      last_rotation_id, created_at, updated_at, revoked_at
            """,
            installation_id,
            now,
        )
        if row is None:
            raise InstallationNotFoundError("installation was not found")
        return _public_installation(dict(row))

    async def delete_installation(self, installation_id: str) -> dict[str, int]:
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                devices = await connection.fetchval(
                    """
                    SELECT count(*) FROM installation_devices
                    WHERE installation_id = $1
                    """,
                    installation_id,
                )
                status = await connection.execute(
                    """
                    DELETE FROM installation_credentials
                    WHERE installation_id = $1
                    """,
                    installation_id,
                )
                if status == "DELETE 0":
                    raise InstallationNotFoundError("installation was not found")
        return {
            "installation_credentials": 1,
            "installation_devices": int(devices or 0),
        }

    async def claim_device(
        self,
        *,
        installation_id: str,
        device_id: str,
        now: datetime,
    ) -> None:
        try:
            status = await self._pool().execute(
                """
                INSERT INTO installation_devices (
                    installation_id, device_id, claimed_at
                )
                SELECT installation_id, $2, $3
                FROM installation_credentials
                WHERE installation_id = $1 AND revoked_at IS NULL
                ON CONFLICT (device_id) DO UPDATE
                SET installation_id = installation_devices.installation_id
                WHERE installation_devices.installation_id = EXCLUDED.installation_id
                """,
                installation_id,
                device_id,
                now,
            )
        except Exception as exc:
            if getattr(exc, "sqlstate", None) == "23514":
                raise InstallationConflictError(
                    "device identifier does not belong to this installation"
                ) from exc
            raise
        if status not in {"INSERT 0 1", "UPDATE 1"}:
            active = await self._pool().fetchval(
                """
                SELECT EXISTS (
                    SELECT 1 FROM installation_credentials
                    WHERE installation_id = $1 AND revoked_at IS NULL
                )
                """,
                installation_id,
            )
            if not active:
                raise InstallationNotFoundError("installation is not active")
            raise InstallationConflictError(
                "device is already owned by another installation"
            )

    async def owns_device(self, *, installation_id: str, device_id: str) -> bool:
        return bool(
            await self._pool().fetchval(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM installation_devices d
                    JOIN installation_credentials i USING (installation_id)
                    WHERE d.installation_id = $1
                      AND d.device_id = $2
                      AND i.revoked_at IS NULL
                )
                """,
                installation_id,
                device_id,
            )
        )

    async def device_ids(
        self,
        installation_id: str,
        *,
        limit: int | None = None,
    ) -> list[str]:
        rows = await self._pool().fetch(
            """
            SELECT d.device_id
            FROM installation_devices d
            WHERE d.installation_id = $1
            ORDER BY d.device_id
            LIMIT $2
            """,
            installation_id,
            limit,
        )
        return [str(row["device_id"]) for row in rows]

    async def release_device(self, *, installation_id: str, device_id: str) -> None:
        status = await self._pool().execute(
            """
            DELETE FROM installation_devices
            WHERE installation_id = $1 AND device_id = $2
            """,
            installation_id,
            device_id,
        )
        if status == "DELETE 0":
            raise InstallationNotFoundError("owned device was not found")
