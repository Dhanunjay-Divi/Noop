from __future__ import annotations

import hashlib
import os
from pathlib import Path
from uuid import uuid4

import pytest

try:
    import asyncpg
except ModuleNotFoundError:
    asyncpg = None


SERVER_ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (
    SERVER_ROOT / "migrations" / "058_managed_social_communication_permissions.sql"
)
DATABASE_URL = os.getenv("NOOP_TEST_POSTGRESQL_DATABASE_URL") or os.getenv(
    "NOOP_TEST_DATABASE_URL"
)
COMMUNICATION_COLUMNS = (
    "messages_allowed",
    "photos_allowed",
    "audio_calls_allowed",
    "video_calls_allowed",
)


def test_communication_permissions_are_directional_default_off_and_fail_closed() -> (
    None
):
    sql = MIGRATION.read_text(encoding="utf-8")

    for field in COMMUNICATION_COLUMNS:
        assert (
            f"ADD COLUMN IF NOT EXISTS {field} boolean NOT NULL DEFAULT false"
        ) in sql

    validation = sql.split("DO $migration$", maxsplit=1)[1]
    for field in COMMUNICATION_COLUMNS:
        assert f"'{field}'" in validation

    assert "FROM pg_catalog.pg_attribute AS attribute" in validation
    assert "JOIN pg_catalog.pg_attrdef AS default_value" in validation
    assert "'pg_catalog.bool'::pg_catalog.regtype" in validation
    assert "attribute.attnotnull" in validation
    assert "attribute.atthasdef" in validation
    assert "attribute.attgenerated = ''" in validation
    assert "pg_catalog.pg_get_expr(" in validation
    assert ") = 'false';" in validation
    assert "IF NOT FOUND THEN" in validation
    assert "ERRCODE = 'check_violation'" in validation
    assert "Expected boolean NOT NULL DEFAULT false." in validation


def test_communication_permission_migration_is_pinned_in_both_manifests() -> None:
    digest = hashlib.sha256(MIGRATION.read_bytes()).hexdigest()
    expected = f"{digest}  058_managed_social_communication_permissions.sql"

    for name in (
        "migration-manifest.sha256",
        "migration-manifest-postgresql.sha256",
    ):
        manifest = (SERVER_ROOT / "backup" / name).read_text(encoding="utf-8")
        assert expected in manifest.splitlines()


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
async def test_communication_permission_migration_applies_and_is_idempotent() -> None:
    assert asyncpg is not None
    connection = await asyncpg.connect(DATABASE_URL)
    schema = f"managed_social_communication_{uuid4().hex}"
    sql = MIGRATION.read_text(encoding="utf-8")
    try:
        await connection.execute(f'CREATE SCHEMA "{schema}"')
        await connection.execute(f'SET search_path TO "{schema}"')
        await connection.execute(
            """
            CREATE TABLE managed_social_visibility (
                owner_profile_id uuid NOT NULL,
                messages_allowed boolean NOT NULL DEFAULT false
            )
            """
        )

        async with connection.transaction():
            await connection.execute(sql)
            await connection.execute(sql)

        rows = await connection.fetch(
            """
            SELECT
                attribute.attname AS column_name,
                attribute.atttypid =
                    'pg_catalog.bool'::pg_catalog.regtype AS is_boolean,
                attribute.attnotnull AS is_not_null,
                pg_catalog.pg_get_expr(
                    default_value.adbin,
                    default_value.adrelid,
                    true
                ) AS default_expression
            FROM pg_catalog.pg_attribute AS attribute
            LEFT JOIN pg_catalog.pg_attrdef AS default_value
              ON default_value.adrelid = attribute.attrelid
             AND default_value.adnum = attribute.attnum
            WHERE attribute.attrelid =
                'managed_social_visibility'::pg_catalog.regclass
              AND attribute.attname = ANY($1::text[])
            """,
            list(COMMUNICATION_COLUMNS),
        )
        actual = {
            row["column_name"]: (
                row["is_boolean"],
                row["is_not_null"],
                row["default_expression"],
            )
            for row in rows
        }
        assert actual == {
            column: (True, True, "false") for column in COMMUNICATION_COLUMNS
        }
    finally:
        await connection.execute("RESET search_path")
        await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        await connection.close()


MALFORMED_COLUMN_DEFINITIONS = tuple(
    pytest.param(column, definition, id=f"{column}-{case}")
    for column in COMMUNICATION_COLUMNS
    for case, definition in (
        ("wrong-type", "text NOT NULL DEFAULT 'false'"),
        ("nullable", "boolean DEFAULT false"),
        ("missing-default", "boolean NOT NULL"),
        ("default-true", "boolean NOT NULL DEFAULT true"),
    )
)


@pytest.mark.skipif(
    not DATABASE_URL or asyncpg is None,
    reason=(
        "PostgreSQL migration tests require asyncpg and "
        "NOOP_TEST_POSTGRESQL_DATABASE_URL or NOOP_TEST_DATABASE_URL"
    ),
)
@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("column_name", "column_definition"),
    MALFORMED_COLUMN_DEFINITIONS,
)
async def test_communication_permission_migration_rejects_malformed_columns(
    column_name: str,
    column_definition: str,
) -> None:
    assert asyncpg is not None
    connection = await asyncpg.connect(DATABASE_URL)
    schema = f"msc_invalid_{uuid4().hex}"
    sql = MIGRATION.read_text(encoding="utf-8")
    try:
        await connection.execute(f'CREATE SCHEMA "{schema}"')
        await connection.execute(f'SET search_path TO "{schema}"')
        await connection.execute(
            f"""
            CREATE TABLE managed_social_visibility (
                owner_profile_id uuid NOT NULL,
                {column_name} {column_definition}
            )
            """
        )

        with pytest.raises(
            asyncpg.CheckViolationError,
            match=(f"migration 058 schema validation failed for .*\\.{column_name}"),
        ):
            async with connection.transaction():
                await connection.execute(sql)

        columns = await connection.fetch(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = $1
              AND table_name = 'managed_social_visibility'
            """,
            schema,
        )
        assert {row["column_name"] for row in columns} == {
            "owner_profile_id",
            column_name,
        }
    finally:
        await connection.execute("RESET search_path")
        await connection.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        await connection.close()
