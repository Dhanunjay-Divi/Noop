#!/usr/bin/env python3
"""Provision migration/runtime PostgreSQL roles and publish distinct secrets."""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import re
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator

import asyncpg


MIGRATION_USER = "noop_migration"
MIGRATION_SECRET = "noop-staging-database-url"
RUNTIME_PROFILES = frozenset(
    {
        "private-api",
        "managed-api",
        "managed-processor",
        "managed-lifecycle",
        "feedback-lifecycle",
    }
)
RUNTIME_PROFILE_USERS = {
    "private-api": "noop_app_runtime",
    "managed-api": "noop_managed_api",
    "managed-processor": "noop_managed_processor",
    "managed-lifecycle": "noop_managed_lifecycle",
    "feedback-lifecycle": "noop_feedback_lifecycle",
}
RUNTIME_PROFILE_SECRETS = {
    "private-api": "noop-staging-runtime-database-url",
    "managed-api": "noop-staging-managed-api-database-url",
    "managed-processor": "noop-staging-managed-processor-database-url",
    "managed-lifecycle": "noop-staging-managed-lifecycle-database-url",
    "feedback-lifecycle": "noop-staging-feedback-lifecycle-database-url",
}
RUNTIME_USER = RUNTIME_PROFILE_USERS["private-api"]
RUNTIME_SECRET = RUNTIME_PROFILE_SECRETS["private-api"]
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MIGRATION_MANIFEST_PATH = (
    REPOSITORY_ROOT / "server" / "backup" / "migration-manifest-postgresql.sha256"
)
RUNTIME_FUNCTIONS = frozenset(
    {
        "noop_erase_managed_account_cloud_state",
        "noop_managed_append_change",
    }
)
RUNTIME_PROFILE_FUNCTIONS = {
    "private-api": frozenset(),
    "managed-api": RUNTIME_FUNCTIONS,
    "managed-processor": frozenset({"noop_managed_append_change"}),
    "managed-lifecycle": RUNTIME_FUNCTIONS,
    "feedback-lifecycle": frozenset(),
}
TABLE_PRIVILEGES = ("SELECT", "INSERT", "UPDATE", "DELETE")
FORBIDDEN_TABLE_PRIVILEGES = ("TRUNCATE", "REFERENCES", "TRIGGER")
SEQUENCE_PRIVILEGES = ("SELECT", "UPDATE", "USAGE")
ROLE_IDENTIFIER = re.compile(r"^[a-z][a-z0-9_]{0,62}$")
RESOURCE_IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]{1,255}$")
PROJECT_IDENTIFIER = re.compile(r"^[a-z][a-z0-9-]{4,61}[a-z0-9]$")
REGION_IDENTIFIER = re.compile(r"^[a-z]+-[a-z]+[0-9]$")
INSTANCE_IDENTIFIER = re.compile(r"^[a-z][a-z0-9-]{0,96}[a-z0-9]$")


class ProvisioningError(RuntimeError):
    """A fixed, non-secret provisioning failure."""


class GoogleAPIError(ProvisioningError):
    def __init__(self, status_code: int) -> None:
        super().__init__(f"Google API request failed with HTTP {status_code}")
        self.status_code = status_code


@dataclass(frozen=True)
class DatabaseCredential:
    user: str
    password: str
    database: str


def require_match(value: str, pattern: re.Pattern[str], label: str) -> str:
    if not pattern.fullmatch(value):
        raise ProvisioningError(f"Invalid {label}")
    return value


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def parse_database_url(raw: str) -> DatabaseCredential:
    parsed = urllib.parse.urlsplit(raw)
    database = urllib.parse.unquote(parsed.path.removeprefix("/"))
    if (
        parsed.scheme not in {"postgres", "postgresql"}
        or not parsed.username
        or parsed.password is None
        or not database
        or "/" in database
        or parsed.fragment
    ):
        raise ProvisioningError("Database secret is invalid")
    return DatabaseCredential(
        user=urllib.parse.unquote(parsed.username),
        password=urllib.parse.unquote(parsed.password),
        database=database,
    )


def build_database_url(
    *,
    user: str,
    password: str,
    database: str,
    connection_name: str,
) -> str:
    return (
        "postgresql://"
        f"{urllib.parse.quote(user, safe='')}:"
        f"{urllib.parse.quote(password, safe='')}@/"
        f"{urllib.parse.quote(database, safe='')}?"
        + urllib.parse.urlencode(
            {"host": f"/cloudsql/{connection_name}"},
            quote_via=urllib.parse.quote,
        )
    )


def expected_migration_manifest() -> dict[str, str]:
    try:
        lines = MIGRATION_MANIFEST_PATH.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ProvisioningError("Migration manifest is unavailable") from error

    manifest: dict[str, str] = {}
    for line in lines:
        parts = line.split()
        if len(parts) != 2 or re.fullmatch(r"[0-9a-f]{64}", parts[0]) is None:
            raise ProvisioningError("Migration manifest is invalid")
        checksum, version = parts
        if (
            re.fullmatch(r"[0-9]{3}_[a-z0-9_]+\.sql", version) is None
            or version in manifest
        ):
            raise ProvisioningError("Migration manifest is invalid")
        manifest[version] = checksum
    if not manifest:
        raise ProvisioningError("Migration manifest is empty")
    return manifest


def google_token() -> str:
    try:
        token = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ProvisioningError("Google authentication is unavailable") from error
    if not token:
        raise ProvisioningError("Google authentication returned no token")
    return token


def api_request(
    token: str,
    method: str,
    url: str,
    payload: dict[str, object] | None = None,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if response.status == 204:
                return {}
            result = json.load(response)
            if not isinstance(result, dict):
                raise ProvisioningError("Google API returned an invalid response")
            return result
    except urllib.error.HTTPError as error:
        raise GoogleAPIError(error.code) from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise ProvisioningError("Google API request could not complete") from error


def secret_resource_url(project: str, secret_id: str) -> str:
    return (
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{urllib.parse.quote(project, safe='')}/secrets/"
        f"{urllib.parse.quote(secret_id, safe='')}"
    )


def require_secret_container(token: str, project: str, secret_id: str) -> None:
    try:
        api_request(token, "GET", secret_resource_url(project, secret_id))
    except GoogleAPIError as error:
        if error.status_code == 404:
            raise ProvisioningError(
                "Required Secret Manager container does not exist"
            ) from None
        raise


def access_secret_if_present(token: str, project: str, secret_id: str) -> str | None:
    try:
        result = api_request(
            token,
            "GET",
            f"{secret_resource_url(project, secret_id)}/versions/latest:access",
        )
    except GoogleAPIError as error:
        if error.status_code == 404:
            return None
        raise
    payload = result.get("payload")
    encoded = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(encoded, str):
        raise ProvisioningError("Database secret has no payload")
    try:
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ProvisioningError("Database secret is invalid") from error


def add_secret_version(
    token: str,
    *,
    project: str,
    secret_id: str,
    value: str,
) -> str:
    result = api_request(
        token,
        "POST",
        f"{secret_resource_url(project, secret_id)}:addVersion",
        {"payload": {"data": base64.b64encode(value.encode("utf-8")).decode("ascii")}},
    )
    version_name = result.get("name")
    if not isinstance(version_name, str):
        raise ProvisioningError("Secret Manager returned no version identifier")
    return version_name.rsplit("/", 1)[-1]


def wait_for_sql_operation(
    token: str,
    *,
    project: str,
    operation_name: str,
) -> None:
    operation_url = (
        "https://sqladmin.googleapis.com/sql/v1beta4/projects/"
        f"{urllib.parse.quote(project, safe='')}/operations/"
        f"{urllib.parse.quote(operation_name, safe='')}"
    )
    for _ in range(120):
        operation = api_request(token, "GET", operation_url)
        if operation.get("status") == "DONE":
            if operation.get("error"):
                raise ProvisioningError("Cloud SQL user operation failed")
            return
        time.sleep(2)
    raise ProvisioningError("Cloud SQL user operation timed out")


def configure_cloud_sql_user(
    token: str,
    *,
    project: str,
    instance: str,
    role: str,
    password: str,
) -> None:
    project_path = urllib.parse.quote(project, safe="")
    instance_path = urllib.parse.quote(instance, safe="")
    role_path = urllib.parse.quote(role, safe="")
    users_url = (
        "https://sqladmin.googleapis.com/sql/v1beta4/projects/"
        f"{project_path}/instances/{instance_path}/users"
    )
    users = api_request(token, "GET", users_url)
    names = {
        item.get("name") for item in users.get("items", []) if isinstance(item, dict)
    }
    payload: dict[str, object] = {"name": role, "password": password}
    if role in names:
        operation = api_request(
            token,
            "PUT",
            f"{users_url}?name={role_path}",
            payload,
        )
    else:
        operation = api_request(token, "POST", users_url, payload)
    operation_name = operation.get("name")
    if not isinstance(operation_name, str):
        raise ProvisioningError("Cloud SQL user operation returned no identifier")
    wait_for_sql_operation(
        token,
        project=project,
        operation_name=operation_name,
    )


@asynccontextmanager
async def cloud_sql_proxy(
    binary: str,
    connection_name: str,
) -> AsyncIterator[tuple[str, subprocess.Popen[bytes]]]:
    with tempfile.TemporaryDirectory(prefix="noop-database-roles-") as socket_root:
        process = subprocess.Popen(
            [
                binary,
                "--unix-socket",
                socket_root,
                connection_name,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            yield str(Path(socket_root) / connection_name), process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


async def connect_with_retry(
    *,
    socket_path: str,
    credential: DatabaseCredential,
    process: subprocess.Popen[bytes],
) -> asyncpg.Connection:
    for _ in range(30):
        if process.poll() is not None:
            raise ProvisioningError("Cloud SQL Auth Proxy stopped unexpectedly")
        try:
            return await asyncpg.connect(
                user=credential.user,
                password=credential.password,
                database=credential.database,
                host=socket_path,
                ssl=False,
                timeout=3,
                command_timeout=60,
                statement_cache_size=0,
            )
        except (OSError, asyncpg.PostgresError, TimeoutError):
            await asyncio.sleep(1)
    raise ProvisioningError("Cloud SQL connection timed out")


async def remove_role_memberships(
    connection: asyncpg.Connection,
    role: str,
) -> None:
    memberships = await connection.fetch(
        """
        SELECT parent.rolname
        FROM pg_auth_members membership
        JOIN pg_roles member
          ON member.oid = membership.member
        JOIN pg_roles parent
          ON parent.oid = membership.roleid
        WHERE member.rolname = $1
        """,
        role,
    )
    for membership in memberships:
        parent = membership["rolname"]
        if not isinstance(parent, str):
            raise ProvisioningError("Database role membership is invalid")
        await connection.execute(
            "REVOKE " + quote_identifier(parent) + " FROM " + quote_identifier(role)
        )


async def assert_role_owns_no_objects(
    connection: asyncpg.Connection,
    role: str,
) -> None:
    owns_objects = await connection.fetchval(
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_class
            WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = $1)
            UNION ALL
            SELECT 1
            FROM pg_namespace
            WHERE nspowner = (SELECT oid FROM pg_roles WHERE rolname = $1)
            UNION ALL
            SELECT 1
            FROM pg_proc
            WHERE proowner = (SELECT oid FROM pg_roles WHERE rolname = $1)
            UNION ALL
            SELECT 1
            FROM pg_database
            WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = $1)
        )
        """,
        role,
    )
    if owns_objects:
        raise ProvisioningError("Runtime role owns database objects")


async def require_migration_ownership(
    connection: asyncpg.Connection,
    migration_role: str,
) -> None:
    mismatches = await connection.fetchval(
        """
        SELECT (
            SELECT count(*)
            FROM pg_class candidate
            JOIN pg_namespace namespace
              ON namespace.oid = candidate.relnamespace
            JOIN pg_roles owner
              ON owner.oid = candidate.relowner
            WHERE namespace.nspname = 'public'
              AND candidate.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
              AND owner.rolname <> $1
        ) + (
            SELECT count(*)
            FROM pg_proc candidate
            JOIN pg_namespace namespace
              ON namespace.oid = candidate.pronamespace
            JOIN pg_roles owner
              ON owner.oid = candidate.proowner
            WHERE namespace.nspname = 'public'
              AND owner.rolname <> $1
        )
        """,
        migration_role,
    )
    if int(mismatches or 0) != 0:
        raise ProvisioningError(
            "Public schema objects are not owned by the migration role"
        )


async def provision_migration_role(
    connection: asyncpg.Connection,
    *,
    migration_role: str,
    database: str,
    legacy_role: str | None,
) -> None:
    quoted_migration = quote_identifier(migration_role)
    quoted_database = quote_identifier(database)
    async with connection.transaction():
        if legacy_role is not None and legacy_role != migration_role:
            await connection.execute(
                "REASSIGN OWNED BY "
                + quote_identifier(legacy_role)
                + " TO "
                + quoted_migration
            )
        await connection.execute(
            f"REVOKE CREATE, TEMPORARY ON DATABASE {quoted_database} FROM PUBLIC"
        )
        await connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        await connection.execute(f"ALTER SCHEMA public OWNER TO {quoted_migration}")
        await connection.execute(
            f"GRANT CONNECT ON DATABASE {quoted_database} TO {quoted_migration}"
        )
        await connection.execute(
            f"GRANT USAGE, CREATE ON SCHEMA public TO {quoted_migration}"
        )
        if legacy_role is not None and legacy_role != migration_role:
            await connection.execute(
                "ALTER ROLE "
                + quote_identifier(legacy_role)
                + " WITH NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE "
                + "NOREPLICATION NOBYPASSRLS"
            )
    await require_migration_ownership(connection, migration_role)


async def verify_migration_role(
    connection: asyncpg.Connection,
    migration_role: str,
) -> None:
    valid = await connection.fetchval(
        """
        SELECT current_user = $1
           AND has_database_privilege(current_database(), 'CONNECT')
           AND has_schema_privilege('public', 'USAGE')
           AND has_schema_privilege('public', 'CREATE')
           AND (
               SELECT owner.rolname = $1
               FROM pg_namespace namespace
               JOIN pg_roles owner ON owner.oid = namespace.nspowner
               WHERE namespace.nspname = 'public'
           )
        """,
        migration_role,
    )
    if valid is not True:
        raise ProvisioningError("Migration database role is not ready")
    await require_migration_ownership(connection, migration_role)


async def runtime_function_signatures(
    connection: asyncpg.Connection,
) -> dict[str, str]:
    rows = await connection.fetch(
        """
        SELECT candidate.proname,
               namespace.nspname,
               pg_get_function_identity_arguments(candidate.oid) AS arguments,
               candidate.prosecdef
        FROM pg_proc candidate
        JOIN pg_namespace namespace
          ON namespace.oid = candidate.pronamespace
        WHERE namespace.nspname = 'public'
          AND candidate.proname = ANY($1::text[])
        ORDER BY candidate.proname
        """,
        sorted(RUNTIME_FUNCTIONS),
    )
    names = [row["proname"] for row in rows]
    if len(names) != len(set(names)) or set(names) != RUNTIME_FUNCTIONS:
        raise ProvisioningError("Required runtime database functions are unavailable")
    if any(bool(row["prosecdef"]) for row in rows):
        raise ProvisioningError("Runtime database function uses security definer")
    return {
        str(row["proname"]): (
            quote_identifier(row["nspname"])
            + "."
            + quote_identifier(row["proname"])
            + "("
            + row["arguments"]
            + ")"
        )
        for row in rows
    }


def runtime_profile_allows_relation(profile: str, relation: str) -> bool:
    if profile not in RUNTIME_PROFILES:
        raise ProvisioningError("Unknown runtime database profile")
    if relation == "noop_schema_migrations":
        return True
    if profile == "private-api":
        return not relation.startswith(
            ("managed_", "feedback_", "ownership_", "unified_managed_")
        )
    if profile == "managed-api":
        return (
            relation.startswith(("managed_", "feedback_", "unified_managed_"))
            or relation == "installation_credentials"
        )
    if profile in {"managed-processor", "managed-lifecycle"}:
        return (
            relation.startswith(("managed_", "unified_managed_"))
            or relation == "installation_credentials"
        )
    return relation.startswith("feedback_")


async def runtime_relation_catalog(
    connection: asyncpg.Connection,
) -> tuple[str, ...]:
    rows = await connection.fetch(
        """
        SELECT candidate.relname
        FROM pg_class candidate
        JOIN pg_namespace namespace ON namespace.oid = candidate.relnamespace
        WHERE namespace.nspname = 'public'
          AND candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
        ORDER BY candidate.relname
        """
    )
    return tuple(str(row["relname"]) for row in rows)


async def runtime_sequence_catalog(
    connection: asyncpg.Connection,
) -> tuple[tuple[str, str], ...]:
    rows = await connection.fetch(
        """
        SELECT sequence.relname AS sequence_name,
               target.relname AS relation_name
        FROM pg_class sequence
        JOIN pg_namespace namespace
          ON namespace.oid = sequence.relnamespace
        JOIN pg_depend dependency
          ON dependency.objid = sequence.oid
         AND dependency.deptype IN ('a', 'i')
        JOIN pg_class target
          ON target.oid = dependency.refobjid
        WHERE namespace.nspname = 'public'
          AND sequence.relkind = 'S'
        ORDER BY sequence.relname
        """
    )
    return tuple(
        (str(row["sequence_name"]), str(row["relation_name"]))
        for row in rows
    )


def runtime_grant_statements(
    role: str,
    *,
    profile: str,
    relations: tuple[str, ...],
    sequences: tuple[tuple[str, str], ...],
    function_signatures: dict[str, str],
) -> tuple[str, ...]:
    quoted_role = quote_identifier(role)
    selected_relations = tuple(
        relation
        for relation in relations
        if runtime_profile_allows_relation(profile, relation)
    )
    if "noop_schema_migrations" not in selected_relations:
        raise ProvisioningError("Runtime migration manifest table is unavailable")
    if len(selected_relations) == 1:
        raise ProvisioningError("Runtime profile has no application relations")

    statements = [
        "GRANT SELECT ON TABLE public.noop_schema_migrations "
        f"TO {quoted_role}",
    ]
    statements.extend(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "
        + "public."
        + quote_identifier(relation)
        + f" TO {quoted_role}"
        for relation in selected_relations
        if relation != "noop_schema_migrations"
    )
    statements.extend(
        "GRANT SELECT, UPDATE, USAGE ON SEQUENCE "
        + "public."
        + quote_identifier(sequence)
        + f" TO {quoted_role}"
        for sequence, relation in sequences
        if runtime_profile_allows_relation(profile, relation)
    )
    statements.extend(
        f"GRANT EXECUTE ON FUNCTION {function_signatures[name]} TO {quoted_role}"
        for name in sorted(RUNTIME_PROFILE_FUNCTIONS[profile])
    )
    return tuple(statements)


async def quarantine_runtime_role(
    connection: asyncpg.Connection,
    role: str,
) -> None:
    try:
        await connection.execute(
            "ALTER ROLE "
            + quote_identifier(role)
            + " WITH NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE "
            + "NOREPLICATION NOBYPASSRLS"
        )
    except Exception as error:
        raise ProvisioningError(
            "Runtime database role could not be disabled"
        ) from error
    try:
        await remove_role_memberships(connection, role)
    except Exception as error:
        raise ProvisioningError(
            "Runtime database role quarantine could not be completed"
        ) from error


async def provision_runtime_role(
    connection: asyncpg.Connection,
    *,
    migration_role: str,
    runtime_role: str,
    runtime_profile: str,
    database: str,
) -> None:
    await require_exact_migration_manifest(connection)
    await require_migration_ownership(connection, migration_role)
    function_signatures = await runtime_function_signatures(connection)
    relations = await runtime_relation_catalog(connection)
    sequences = await runtime_sequence_catalog(connection)
    quoted_role = quote_identifier(runtime_role)
    quoted_database = quote_identifier(database)
    async with connection.transaction():
        await connection.execute(
            "ALTER ROLE "
            + quoted_role
            + " WITH LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE "
            + "NOREPLICATION NOBYPASSRLS"
        )
        await remove_role_memberships(connection, runtime_role)
        await assert_role_owns_no_objects(connection, runtime_role)
        await connection.execute(
            f"REVOKE CREATE, TEMPORARY ON DATABASE {quoted_database} FROM PUBLIC"
        )
        await connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        await connection.execute(
            f"REVOKE ALL PRIVILEGES ON DATABASE {quoted_database} FROM {quoted_role}"
        )
        await connection.execute(
            f"GRANT CONNECT ON DATABASE {quoted_database} TO {quoted_role}"
        )
        await connection.execute(
            f"REVOKE ALL PRIVILEGES ON SCHEMA public FROM {quoted_role}"
        )
        await connection.execute(f"GRANT USAGE ON SCHEMA public TO {quoted_role}")
        await connection.execute(
            "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM " + quoted_role
        )
        await connection.execute(
            "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM "
            + quoted_role
        )
        await connection.execute(
            "REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM "
            + quoted_role
        )
        await connection.execute(
            "REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC"
        )
        await connection.execute(
            "ALTER DEFAULT PRIVILEGES FOR ROLE "
            + quote_identifier(migration_role)
            + " IN SCHEMA public REVOKE ALL PRIVILEGES ON TABLES FROM "
            + quoted_role
        )
        await connection.execute(
            "ALTER DEFAULT PRIVILEGES FOR ROLE "
            + quote_identifier(migration_role)
            + " IN SCHEMA public REVOKE ALL PRIVILEGES ON SEQUENCES FROM "
            + quoted_role
        )
        await connection.execute(
            "ALTER DEFAULT PRIVILEGES FOR ROLE "
            + quote_identifier(migration_role)
            + " IN SCHEMA public REVOKE ALL PRIVILEGES ON FUNCTIONS FROM "
            + quoted_role
        )
        await connection.execute(
            "ALTER DEFAULT PRIVILEGES FOR ROLE "
            + quote_identifier(migration_role)
            + " IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"
        )
        for statement in runtime_grant_statements(
            runtime_role,
            profile=runtime_profile,
            relations=relations,
            sequences=sequences,
            function_signatures=function_signatures,
        ):
            await connection.execute(statement)


async def require_exact_migration_manifest(
    connection: asyncpg.Connection,
) -> None:
    available = await connection.fetchval(
        "SELECT to_regclass('public.noop_schema_migrations') IS NOT NULL"
    )
    if available is not True:
        raise ProvisioningError("Run the migration job before runtime provisioning")
    rows = await connection.fetch(
        "SELECT version, checksum FROM noop_schema_migrations"
    )
    applied = {
        str(row["version"]): str(row["checksum"]).strip()
        for row in rows
    }
    if applied != expected_migration_manifest():
        raise ProvisioningError(
            "Database migration manifest does not match this release"
        )


async def verify_runtime_role(
    connection: asyncpg.Connection,
    runtime_profile: str,
) -> None:
    role_is_bounded = await connection.fetchval(
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = current_user
              AND NOT rolsuper
              AND NOT rolcreaterole
              AND NOT rolcreatedb
              AND NOT rolreplication
              AND NOT rolbypassrls
              AND NOT rolinherit
        )
        AND NOT EXISTS (
            SELECT 1
            FROM pg_auth_members membership
            JOIN pg_roles member ON member.oid = membership.member
            WHERE member.rolname = current_user
        )
        AND has_database_privilege(current_database(), 'CONNECT')
        AND NOT has_database_privilege(current_database(), 'CREATE')
        AND NOT has_database_privilege(current_database(), 'TEMPORARY')
        AND has_schema_privilege('public', 'USAGE')
        AND NOT has_schema_privilege('public', 'CREATE')
        """
    )
    if role_is_bounded is not True:
        raise ProvisioningError("Runtime database role is not bounded")
    current_user = await connection.fetchval("SELECT current_user")
    if not isinstance(current_user, str):
        raise ProvisioningError("Runtime database principal is invalid")
    await assert_role_owns_no_objects(connection, current_user)

    relations = await connection.fetch(
        """
        SELECT candidate.relname,
               format('%I.%I', namespace.nspname, candidate.relname) AS name
        FROM pg_class candidate
        JOIN pg_namespace namespace ON namespace.oid = candidate.relnamespace
        WHERE namespace.nspname = 'public'
          AND candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
        ORDER BY candidate.relname
        """
    )
    for relation in relations:
        expected = (
            ("SELECT",)
            if relation["relname"] == "noop_schema_migrations"
            else (
                TABLE_PRIVILEGES
                if runtime_profile_allows_relation(
                    runtime_profile,
                    str(relation["relname"]),
                )
                else ()
            )
        )
        for privilege in TABLE_PRIVILEGES:
            granted = await connection.fetchval(
                "SELECT has_table_privilege($1, $2)",
                relation["name"],
                privilege,
            )
            if bool(granted) != (privilege in expected):
                raise ProvisioningError("Runtime database table grants are not bounded")
        for privilege in FORBIDDEN_TABLE_PRIVILEGES:
            if await connection.fetchval(
                "SELECT has_table_privilege($1, $2)",
                relation["name"],
                privilege,
            ):
                raise ProvisioningError("Runtime database role has a DDL-like grant")

    sequences = await connection.fetch(
        """
        SELECT format('%I.%I', namespace.nspname, sequence.relname) AS name,
               target.relname AS relation_name
        FROM pg_class sequence
        JOIN pg_namespace namespace ON namespace.oid = sequence.relnamespace
        JOIN pg_depend dependency
          ON dependency.objid = sequence.oid
         AND dependency.deptype IN ('a', 'i')
        JOIN pg_class target ON target.oid = dependency.refobjid
        WHERE namespace.nspname = 'public'
          AND sequence.relkind = 'S'
        ORDER BY sequence.relname
        """
    )
    for sequence in sequences:
        for privilege in SEQUENCE_PRIVILEGES:
            granted = await connection.fetchval(
                "SELECT has_sequence_privilege($1, $2)",
                sequence["name"],
                privilege,
            )
            expected = runtime_profile_allows_relation(
                runtime_profile,
                str(sequence["relation_name"]),
            )
            if bool(granted) != expected:
                raise ProvisioningError("Runtime sequence grants are not bounded")

    executable_functions = await connection.fetch(
        """
        SELECT candidate.proname, candidate.prosecdef
        FROM pg_proc candidate
        JOIN pg_namespace namespace ON namespace.oid = candidate.pronamespace
        WHERE namespace.nspname = 'public'
          AND has_function_privilege(candidate.oid, 'EXECUTE')
        """
    )
    executable_names = {row["proname"] for row in executable_functions}
    if executable_names != RUNTIME_PROFILE_FUNCTIONS[runtime_profile] or any(
        bool(row["prosecdef"]) for row in executable_functions
    ):
        raise ProvisioningError("Runtime database function grants are not bounded")


async def configure_migration(args: argparse.Namespace, token: str) -> str:
    existing_raw = access_secret_if_present(token, args.project, args.secret)
    legacy = parse_database_url(existing_raw) if existing_raw is not None else None
    existing_raw = ""
    if legacy is not None and legacy.database != args.database:
        raise ProvisioningError("Existing migration secret targets another database")
    if legacy is not None and legacy.user != args.user:
        raise ProvisioningError(
            "Existing migration secret uses another principal; "
            "use an explicit principal-transition procedure"
        )

    password = secrets.token_hex(32)
    credential_rotated = False
    try:
        configure_cloud_sql_user(
            token,
            project=args.project,
            instance=args.instance,
            role=args.user,
            password=password,
        )
        credential_rotated = True
        target = DatabaseCredential(args.user, password, args.database)
        async with cloud_sql_proxy(args.proxy_binary, args.connection_name) as (
            socket_path,
            proxy,
        ):
            connection = await connect_with_retry(
                socket_path=socket_path,
                credential=target,
                process=proxy,
            )
            try:
                await provision_migration_role(
                    connection,
                    migration_role=args.user,
                    database=args.database,
                    legacy_role=None,
                )
                await verify_migration_role(connection, args.user)
            finally:
                await connection.close()

        database_url = build_database_url(
            user=args.user,
            password=password,
            database=args.database,
            connection_name=args.connection_name,
        )
        try:
            return add_secret_version(
                token,
                project=args.project,
                secret_id=args.secret,
                value=database_url,
            )
        finally:
            database_url = ""
    except Exception:
        if credential_rotated and legacy is not None:
            try:
                configure_cloud_sql_user(
                    token,
                    project=args.project,
                    instance=args.instance,
                    role=legacy.user,
                    password=legacy.password,
                )
            except Exception as rollback_error:
                raise ProvisioningError(
                    "Migration credential rotation failed and the previous "
                    "credential could not be restored"
                ) from rollback_error
        raise
    finally:
        password = ""


async def configure_runtime(args: argparse.Namespace, token: str) -> str:
    existing_raw = access_secret_if_present(
        token,
        args.project,
        args.secret,
    )
    existing = parse_database_url(existing_raw) if existing_raw is not None else None
    existing_raw = ""
    if existing is not None and (
        existing.user != args.user or existing.database != args.database
    ):
        raise ProvisioningError("Existing runtime secret has the wrong principal")

    bootstrap_raw = access_secret_if_present(
        token,
        args.project,
        args.bootstrap_secret,
    )
    if bootstrap_raw is None:
        raise ProvisioningError("Migration database secret has no enabled version")
    bootstrap = parse_database_url(bootstrap_raw)
    bootstrap_raw = ""
    if bootstrap.user != args.migration_user or bootstrap.database != args.database:
        raise ProvisioningError("Migration database secret has the wrong principal")

    password = secrets.token_hex(32)
    credential_rotated = False
    async with cloud_sql_proxy(args.proxy_binary, args.connection_name) as (
        socket_path,
        proxy,
    ):
        migration_connection = await connect_with_retry(
            socket_path=socket_path,
            credential=bootstrap,
            process=proxy,
        )
        try:
            configure_cloud_sql_user(
                token,
                project=args.project,
                instance=args.instance,
                role=args.user,
                password=password,
            )
            credential_rotated = True
            try:
                await provision_runtime_role(
                    migration_connection,
                    migration_role=args.migration_user,
                    runtime_role=args.user,
                    runtime_profile=args.runtime_profile,
                    database=args.database,
                )
                target = DatabaseCredential(args.user, password, args.database)
                runtime_connection = await connect_with_retry(
                    socket_path=socket_path,
                    credential=target,
                    process=proxy,
                )
                try:
                    await verify_runtime_role(
                        runtime_connection,
                        args.runtime_profile,
                    )
                finally:
                    await runtime_connection.close()
                database_url = build_database_url(
                    user=args.user,
                    password=password,
                    database=args.database,
                    connection_name=args.connection_name,
                )
                try:
                    return add_secret_version(
                        token,
                        project=args.project,
                        secret_id=args.secret,
                        value=database_url,
                    )
                finally:
                    database_url = ""
            except Exception:
                if credential_rotated and existing is not None:
                    try:
                        configure_cloud_sql_user(
                            token,
                            project=args.project,
                            instance=args.instance,
                            role=existing.user,
                            password=existing.password,
                        )
                        restored_connection = await connect_with_retry(
                            socket_path=socket_path,
                            credential=existing,
                            process=proxy,
                        )
                        try:
                            await verify_runtime_role(
                                restored_connection,
                                args.runtime_profile,
                            )
                        finally:
                            await restored_connection.close()
                    except Exception as rollback_error:
                        raise ProvisioningError(
                            "Runtime credential rotation failed and the previous "
                            "credential could not be restored"
                        ) from rollback_error
                else:
                    await quarantine_runtime_role(migration_connection, args.user)
                raise
        finally:
            await migration_connection.close()
            password = ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role-kind", choices=("migration", "runtime"), required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--connection-name", required=True)
    parser.add_argument("--database", default="noop")
    parser.add_argument("--user")
    parser.add_argument("--migration-user", default=MIGRATION_USER)
    parser.add_argument("--bootstrap-secret", default=MIGRATION_SECRET)
    parser.add_argument("--runtime-profile", choices=sorted(RUNTIME_PROFILES))
    parser.add_argument("--secret")
    parser.add_argument("--proxy-binary", default="cloud-sql-proxy")
    parser.add_argument(
        "--confirm-runtime-disabled",
        action="store_true",
        help="Required acknowledgement that API, processor, and lifecycle runtimes are disabled.",
    )
    parser.add_argument(
        "--confirm-migrations-complete",
        action="store_true",
        help="Required for runtime provisioning after the migration job succeeds.",
    )
    args = parser.parse_args()
    if not args.confirm_runtime_disabled:
        parser.error("--confirm-runtime-disabled is required")
    if args.role_kind == "runtime" and not args.confirm_migrations_complete:
        parser.error("--confirm-migrations-complete is required for runtime")
    if args.role_kind == "runtime" and args.runtime_profile is None:
        parser.error("--runtime-profile is required for runtime")
    if args.role_kind == "migration" and args.runtime_profile is not None:
        parser.error("--runtime-profile is only valid for runtime")

    args.project = require_match(args.project, PROJECT_IDENTIFIER, "project")
    args.region = require_match(args.region, REGION_IDENTIFIER, "region")
    args.instance = require_match(args.instance, INSTANCE_IDENTIFIER, "instance")
    args.database = require_match(args.database, ROLE_IDENTIFIER, "database")
    args.migration_user = require_match(
        args.migration_user,
        ROLE_IDENTIFIER,
        "migration database user",
    )
    default_user = (
        MIGRATION_USER
        if args.role_kind == "migration"
        else RUNTIME_PROFILE_USERS[args.runtime_profile]
    )
    default_secret = (
        MIGRATION_SECRET
        if args.role_kind == "migration"
        else RUNTIME_PROFILE_SECRETS[args.runtime_profile]
    )
    args.user = require_match(
        args.user or default_user,
        ROLE_IDENTIFIER,
        "database user",
    )
    args.bootstrap_secret = require_match(
        args.bootstrap_secret,
        RESOURCE_IDENTIFIER,
        "bootstrap secret",
    )
    args.secret = require_match(
        args.secret or default_secret,
        RESOURCE_IDENTIFIER,
        "database secret",
    )
    if args.connection_name != f"{args.project}:{args.region}:{args.instance}":
        parser.error("Cloud SQL connection name does not match inputs")
    if args.role_kind == "runtime" and args.user == args.migration_user:
        parser.error("Migration and runtime database users must be distinct")
    if args.role_kind == "runtime" and args.secret == args.bootstrap_secret:
        parser.error("Migration and runtime database secrets must be distinct")

    try:
        token = google_token()
        require_secret_container(token, args.project, args.secret)
        if args.role_kind == "runtime":
            require_secret_container(token, args.project, args.bootstrap_secret)
            version = asyncio.run(configure_runtime(args, token))
        else:
            version = asyncio.run(configure_migration(args, token))
    except ProvisioningError as error:
        parser.exit(1, f"Database role provisioning failed: {error}\n")
    except Exception:
        parser.exit(
            1,
            "Database role provisioning failed without exposing details. "
            "Verify the proxy, migration state, IAM, and Secret Manager access.\n",
        )
    print(
        f"Configured {args.role_kind} database credential as secret version {version}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
