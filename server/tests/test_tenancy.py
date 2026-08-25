from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest

from app.tenancy import (
    InstallationConflictError,
    InstallationNotFoundError,
    MemoryInstallationRepository,
)


def _digest(character: str) -> str:
    return character * 64


@pytest.mark.asyncio
async def test_enrollment_is_retry_safe_and_tokens_are_never_returned() -> None:
    repository = MemoryInstallationRepository()
    now = datetime.now(UTC)
    installation_id = str(uuid4())
    enrollment_id = str(uuid4())

    first = await repository.create_installation(
        installation_id=installation_id,
        enrollment_id=enrollment_id,
        token_hash=_digest("a"),
        now=now,
    )
    replay = await repository.create_installation(
        installation_id=installation_id,
        enrollment_id=enrollment_id,
        token_hash=_digest("a"),
        now=now + timedelta(seconds=1),
    )

    assert first == replay
    assert first["token_version"] == 1
    assert "token_hash" not in first
    assert await repository.installation_for_token(_digest("a")) == first

    with pytest.raises(InstallationConflictError):
        await repository.create_installation(
            installation_id=installation_id,
            enrollment_id=str(uuid4()),
            token_hash=_digest("b"),
            now=now,
        )


@pytest.mark.asyncio
async def test_rotation_is_idempotent_versioned_and_revokes_old_token() -> None:
    repository = MemoryInstallationRepository()
    now = datetime.now(UTC)
    installation_id = str(uuid4())
    await repository.create_installation(
        installation_id=installation_id,
        enrollment_id=str(uuid4()),
        token_hash=_digest("a"),
        now=now,
    )
    rotation_id = str(uuid4())

    rotated = await repository.rotate_token(
        installation_id=installation_id,
        rotation_id=rotation_id,
        expected_version=1,
        token_hash=_digest("b"),
        now=now + timedelta(minutes=1),
    )
    replay = await repository.rotate_token(
        installation_id=installation_id,
        rotation_id=rotation_id,
        expected_version=1,
        token_hash=_digest("b"),
        now=now + timedelta(minutes=2),
    )

    assert rotated == replay
    assert rotated["token_version"] == 2
    assert await repository.installation_for_token(_digest("a")) is None
    assert await repository.installation_for_token(_digest("b")) == rotated
    with pytest.raises(InstallationConflictError):
        await repository.rotate_token(
            installation_id=installation_id,
            rotation_id=str(uuid4()),
            expected_version=1,
            token_hash=_digest("c"),
            now=now,
        )


@pytest.mark.asyncio
async def test_device_claims_are_exclusive_and_release_is_owner_scoped() -> None:
    repository = MemoryInstallationRepository()
    now = datetime.now(UTC)
    first = str(uuid4())
    second = str(uuid4())
    for index, installation_id in enumerate((first, second)):
        await repository.create_installation(
            installation_id=installation_id,
            enrollment_id=str(uuid4()),
            token_hash=_digest(chr(ord("a") + index)),
            now=now,
        )
    device_id = f"ios:{first}:noop-computed"

    await repository.claim_device(
        installation_id=first,
        device_id=device_id,
        now=now,
    )
    await repository.claim_device(
        installation_id=first,
        device_id=device_id,
        now=now,
    )

    assert await repository.owns_device(
        installation_id=first,
        device_id=device_id,
    )
    assert not await repository.owns_device(
        installation_id=second,
        device_id=device_id,
    )
    with pytest.raises(InstallationConflictError):
        await repository.claim_device(
            installation_id=second,
            device_id=device_id,
            now=now,
        )
    with pytest.raises(InstallationNotFoundError):
        await repository.release_device(
            installation_id=second,
            device_id=device_id,
        )

    await repository.release_device(
        installation_id=first,
        device_id=device_id,
    )
    assert await repository.device_ids(first) == []


@pytest.mark.asyncio
async def test_revoke_invalidates_token_and_hard_delete_removes_claims() -> None:
    repository = MemoryInstallationRepository()
    now = datetime.now(UTC)
    installation_id = str(uuid4())
    device_id = f"android:{installation_id}:strap"
    await repository.create_installation(
        installation_id=installation_id,
        enrollment_id=str(uuid4()),
        token_hash=_digest("a"),
        now=now,
    )
    await repository.claim_device(
        installation_id=installation_id,
        device_id=device_id,
        now=now,
    )

    await repository.revoke_installation(
        installation_id=installation_id,
        now=now + timedelta(minutes=1),
    )
    assert await repository.installation_for_token(_digest("a")) is None
    assert await repository.shared_cutover_ready() is True
    counts = await repository.delete_installation(installation_id)

    assert counts == {
        "installation_credentials": 1,
        "installation_devices": 1,
    }


def test_tenancy_migration_enforces_exclusive_scoped_device_ownership() -> None:
    migration = (
        Path(__file__).resolve().parents[1]
        / "migrations"
        / "010_installation_tenancy.sql"
    ).read_text(encoding="utf-8")

    assert "device_id text PRIMARY KEY" in migration
    assert "ON DELETE CASCADE" in migration
    assert "split_part(device_id, ':', 2) = installation_id" in migration
    assert "'import', 'other'" in migration
    assert "token_hash char(64) NOT NULL UNIQUE" in migration


def test_cutover_migration_backfills_and_maintains_future_ownership() -> None:
    migration = (
        Path(__file__).resolve().parents[1]
        / "migrations"
        / "012_tenancy_cutover_invariants.sql"
    ).read_text(encoding="utf-8")

    assert "noop_ensure_legacy_installation" in migration
    assert "SELECT DISTINCT split_part(device_id, ':', 2)" in migration
    assert "INSERT INTO installation_devices" in migration
    assert "AFTER INSERT ON devices" in migration
    assert "BEFORE INSERT ON friend_profiles" in migration
    assert "BEFORE INSERT ON safety_profiles" in migration
