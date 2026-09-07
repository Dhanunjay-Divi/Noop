#!/usr/bin/env python3
"""Provision the exact ownership PostgreSQL role and publish its secret safely."""

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
from collections import defaultdict
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator

import asyncpg


OWNERSHIP_TABLE_PRIVILEGES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("ownership_accounts", ("SELECT", "INSERT")),
    ("ownership_external_identities", ("SELECT", "INSERT")),
    ("ownership_terms_documents", ("SELECT",)),
    ("ownership_terms_acceptances", ("SELECT", "INSERT")),
    ("ownership_installations", ("SELECT", "INSERT")),
    ("ownership_bands", ("SELECT",)),
    ("ownership_possession_challenges", ("SELECT", "INSERT")),
    ("ownership_claim_requests", ("SELECT", "INSERT")),
    ("ownership_band_claims", ("INSERT",)),
    (
        "ownership_installation_authorizations",
        ("SELECT", "INSERT"),
    ),
    ("ownership_plan_selections", ("SELECT", "INSERT")),
    (
        "ownership_plan_selection_requests",
        ("SELECT", "INSERT"),
    ),
    ("ownership_events", ("INSERT",)),
)

OWNERSHIP_COLUMN_PRIVILEGES: tuple[
    tuple[str, str, tuple[str, ...]],
    ...,
] = (
    (
        "ownership_external_identities",
        "UPDATE",
        ("email_verified", "phone_verified", "last_seen_at"),
    ),
    (
        "ownership_installations",
        "UPDATE",
        (
            "device_key_fingerprint",
            "status",
            "last_seen_at",
            "revoked_at",
        ),
    ),
    (
        "ownership_bands",
        "UPDATE",
        (
            "status",
            "current_account_id",
            "claimed_at",
            "firmware_version",
            "updated_at",
        ),
    ),
    (
        "ownership_possession_challenges",
        "UPDATE",
        ("status", "consumed_at"),
    ),
    (
        "ownership_plan_selections",
        "UPDATE",
        ("selection", "request_id", "updated_at"),
    ),
)

OWNERSHIP_TABLE_PRIVILEGE_PAIRS = frozenset(
    (table, privilege)
    for table, privileges in OWNERSHIP_TABLE_PRIVILEGES
    for privilege in privileges
)
OWNERSHIP_COLUMN_PRIVILEGE_TRIPLES = frozenset(
    (table, column, privilege)
    for table, privilege, columns in OWNERSHIP_COLUMN_PRIVILEGES
    for column in columns
)

TABLE_PRIVILEGES = (
    "SELECT",
    "INSERT",
    "UPDATE",
    "DELETE",
    "TRUNCATE",
    "REFERENCES",
    "TRIGGER",
)
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
        raise ProvisioningError("Bootstrap database secret is invalid")
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


def exact_grant_statements(role: str) -> tuple[str, ...]:
    quoted_role = quote_identifier(role)
    table_grants = tuple(
        "GRANT "
        + ", ".join(privileges)
        + " ON TABLE public."
        + quote_identifier(table)
        + " TO "
        + quoted_role
        for table, privileges in OWNERSHIP_TABLE_PRIVILEGES
    )
    column_grants = tuple(
        "GRANT "
        + privilege
        + " ("
        + ", ".join(quote_identifier(column) for column in columns)
        + ") ON TABLE public."
        + quote_identifier(table)
        + " TO "
        + quoted_role
        for table, privilege, columns in OWNERSHIP_COLUMN_PRIVILEGES
    )
    return table_grants + column_grants


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


def access_secret(token: str, project: str, secret_id: str) -> str:
    project_path = urllib.parse.quote(project, safe="")
    secret_path = urllib.parse.quote(secret_id, safe="")
    value = api_request(
        token,
        "GET",
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{project_path}/secrets/{secret_path}/versions/latest:access",
    )
    payload = value.get("payload")
    encoded = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(encoded, str):
        raise ProvisioningError("Bootstrap database secret has no payload")
    try:
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ProvisioningError("Bootstrap database secret is invalid") from error


def ensure_secret(
    token: str,
    *,
    project: str,
    region: str,
    secret_id: str,
) -> None:
    project_path = urllib.parse.quote(project, safe="")
    secret_path = urllib.parse.quote(secret_id, safe="")
    resource_url = (
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{project_path}/secrets/{secret_path}"
    )
    try:
        api_request(token, "GET", resource_url)
        return
    except GoogleAPIError as error:
        if error.status_code != 404:
            raise
    api_request(
        token,
        "POST",
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{project_path}/secrets?" + urllib.parse.urlencode({"secretId": secret_id}),
        {
            "replication": {
                "userManaged": {
                    "replicas": [{"location": region}],
                }
            },
            "labels": {
                "app": "noop",
                "environment": "staging",
                "purpose": "ownership",
            },
        },
    )


def add_secret_version(
    token: str,
    *,
    project: str,
    secret_id: str,
    value: str,
) -> str:
    project_path = urllib.parse.quote(project, safe="")
    secret_path = urllib.parse.quote(secret_id, safe="")
    result = api_request(
        token,
        "POST",
        "https://secretmanager.googleapis.com/v1/projects/"
        f"{project_path}/secrets/{secret_path}:addVersion",
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


def set_role_password(
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
    operation = api_request(
        token,
        "PUT",
        f"{users_url}?name={role_path}",
        {"name": role, "password": password},
    )
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
    with tempfile.TemporaryDirectory(prefix="noop-ownership-sql-") as socket_root:
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
                command_timeout=30,
                statement_cache_size=0,
            )
        except (OSError, asyncpg.PostgresError, TimeoutError):
            await asyncio.sleep(1)
    raise ProvisioningError("Cloud SQL connection timed out")


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
            FROM pg_database
            WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = $1)
        )
        """,
        role,
    )
    if owns_objects:
        raise ProvisioningError(
            "Ownership runtime role owns database objects and cannot be narrowed safely"
        )


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
            raise ProvisioningError("Ownership role membership is invalid")
        await connection.execute(
            "REVOKE " + quote_identifier(parent) + " FROM " + quote_identifier(role)
        )


async def remove_column_privileges(
    connection: asyncpg.Connection,
    role: str,
) -> None:
    rows = await connection.fetch(
        """
        SELECT table_name, column_name, privilege_type
        FROM information_schema.column_privileges
        WHERE grantee = $1
          AND table_schema = 'public'
        ORDER BY table_name, privilege_type, column_name
        """,
        role,
    )
    grouped: dict[tuple[str, str], list[str]] = defaultdict(list)
    for row in rows:
        grouped[(row["table_name"], row["privilege_type"])].append(row["column_name"])
    for (table, privilege), columns in grouped.items():
        if privilege not in {"SELECT", "INSERT", "UPDATE", "REFERENCES"}:
            raise ProvisioningError("Ownership role has an unsupported column grant")
        await connection.execute(
            "REVOKE "
            + privilege
            + " ("
            + ", ".join(quote_identifier(column) for column in columns)
            + ") ON TABLE public."
            + quote_identifier(table)
            + " FROM "
            + quote_identifier(role)
        )


async def provision_role(
    connection: asyncpg.Connection,
    *,
    role: str,
    database: str,
) -> None:
    required_tables = {table for table, _ in OWNERSHIP_TABLE_PRIVILEGES}
    present_tables = await connection.fetch(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = ANY($1::text[])
        """,
        sorted(required_tables),
    )
    present_names = {row["table_name"] for row in present_tables}
    if present_names != required_tables:
        raise ProvisioningError(
            "Ownership migration is incomplete; run the migration job first"
        )

    quoted_role = quote_identifier(role)
    quoted_database = quote_identifier(database)
    exists = await connection.fetchval(
        "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)",
        role,
    )
    async with connection.transaction():
        if not exists:
            await connection.execute(
                "CREATE ROLE "
                + quoted_role
                + " LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE "
                + "NOREPLICATION NOBYPASSRLS"
            )
        else:
            await connection.execute(
                "ALTER ROLE "
                + quoted_role
                + " WITH LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE "
                + "NOREPLICATION NOBYPASSRLS"
            )
        await assert_role_owns_no_objects(connection, role)
        await remove_role_memberships(connection, role)
        await remove_column_privileges(connection, role)
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
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
            "REVOKE ALL PRIVILEGES ON TABLES FROM " + quoted_role
        )
        await connection.execute(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
            "REVOKE ALL PRIVILEGES ON SEQUENCES FROM " + quoted_role
        )
        for statement in exact_grant_statements(role):
            await connection.execute(statement)


async def verify_role(connection: asyncpg.Connection) -> None:
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
            JOIN pg_roles member
              ON member.oid = membership.member
            WHERE member.rolname = current_user
        )
        AND has_schema_privilege('public', 'USAGE')
        AND NOT has_schema_privilege('public', 'CREATE')
        AND has_database_privilege(current_database(), 'CONNECT')
        AND NOT has_database_privilege(current_database(), 'CREATE')
        AND NOT EXISTS (
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
        )
        """
    )
    if not role_is_bounded:
        raise ProvisioningError("Ownership database role is not bounded")

    relations = await connection.fetch(
        """
        SELECT namespace.nspname, candidate.relname
        FROM pg_class candidate
        JOIN pg_namespace namespace
          ON namespace.oid = candidate.relnamespace
        WHERE candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND namespace.nspname <> 'information_schema'
          AND namespace.nspname !~ '^pg_'
        ORDER BY namespace.nspname, candidate.relname
        """
    )
    expected_tables = dict(OWNERSHIP_TABLE_PRIVILEGES)
    expected_columns = {
        (table, privilege): frozenset(columns)
        for table, privilege, columns in OWNERSHIP_COLUMN_PRIVILEGES
    }
    for relation in relations:
        schema = relation["nspname"]
        table = relation["relname"]
        relation_name = f"{quote_identifier(schema)}.{quote_identifier(table)}"
        actual_table: set[str] = set()
        for privilege in TABLE_PRIVILEGES:
            granted = await connection.fetchval(
                "SELECT has_table_privilege($1, $2)",
                relation_name,
                privilege,
            )
            if granted:
                actual_table.add(privilege)
        wanted_table = (
            set(expected_tables.get(table, ())) if schema == "public" else set()
        )
        if actual_table != wanted_table:
            raise ProvisioningError(
                "Ownership database role has an unexpected table privilege"
            )
        columns = await connection.fetch(
            """
            SELECT attribute.attname AS column_name
            FROM pg_attribute attribute
            WHERE attribute.attrelid = to_regclass($1)
              AND attribute.attnum > 0
              AND NOT attribute.attisdropped
            ORDER BY attribute.attnum
            """,
            relation_name,
        )
        for column in columns:
            column_name = column["column_name"]
            for privilege in ("SELECT", "INSERT", "UPDATE", "REFERENCES"):
                granted = await connection.fetchval(
                    "SELECT has_column_privilege($1, $2, $3)",
                    relation_name,
                    column_name,
                    privilege,
                )
                wanted = privilege in wanted_table or (
                    schema == "public"
                    and column_name
                    in expected_columns.get((table, privilege), frozenset())
                )
                if bool(granted) != wanted:
                    raise ProvisioningError(
                        "Ownership database role has an unexpected column privilege"
                    )

    sequences = await connection.fetch(
        """
        SELECT format('%I.%I', namespace.nspname, candidate.relname) AS name
        FROM pg_class candidate
        JOIN pg_namespace namespace
          ON namespace.oid = candidate.relnamespace
        WHERE candidate.relkind = 'S'
          AND namespace.nspname <> 'information_schema'
          AND namespace.nspname !~ '^pg_'
        """
    )
    for sequence in sequences:
        for privilege in SEQUENCE_PRIVILEGES:
            if await connection.fetchval(
                "SELECT has_sequence_privilege($1, $2)",
                sequence["name"],
                privilege,
            ):
                raise ProvisioningError(
                    "Ownership database role has an unexpected sequence privilege"
                )

    executable_security_definer = await connection.fetchval(
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_proc candidate
            JOIN pg_namespace namespace
              ON namespace.oid = candidate.pronamespace
            WHERE candidate.prosecdef
              AND namespace.nspname <> 'information_schema'
              AND namespace.nspname !~ '^pg_'
              AND has_function_privilege(candidate.oid, 'EXECUTE')
        )
        """
    )
    if executable_security_definer:
        raise ProvisioningError(
            "Ownership database role can execute a security-definer routine"
        )


async def configure(args: argparse.Namespace) -> str:
    project = require_match(args.project, PROJECT_IDENTIFIER, "project")
    region = require_match(args.region, REGION_IDENTIFIER, "region")
    instance = require_match(args.instance, INSTANCE_IDENTIFIER, "instance")
    role = require_match(args.user, ROLE_IDENTIFIER, "database user")
    database = require_match(args.database, ROLE_IDENTIFIER, "database")
    source_secret = require_match(
        args.bootstrap_secret,
        RESOURCE_IDENTIFIER,
        "bootstrap secret",
    )
    destination_secret = require_match(
        args.secret,
        RESOURCE_IDENTIFIER,
        "ownership secret",
    )
    if args.connection_name != f"{project}:{region}:{instance}":
        raise ProvisioningError("Cloud SQL connection name does not match inputs")

    token = google_token()
    bootstrap_raw = access_secret(token, project, source_secret)
    bootstrap = parse_database_url(bootstrap_raw)
    bootstrap_raw = ""
    if bootstrap.database != database:
        raise ProvisioningError("Bootstrap database secret targets another database")

    generated_password = secrets.token_urlsafe(48)
    async with cloud_sql_proxy(
        args.proxy_binary,
        args.connection_name,
    ) as (socket_path, proxy):
        admin_connection = await connect_with_retry(
            socket_path=socket_path,
            credential=bootstrap,
            process=proxy,
        )
        try:
            await provision_role(
                admin_connection,
                role=role,
                database=database,
            )
        finally:
            await admin_connection.close()

        set_role_password(
            token,
            project=project,
            instance=instance,
            role=role,
            password=generated_password,
        )
        target = DatabaseCredential(
            user=role,
            password=generated_password,
            database=database,
        )
        target_connection = await connect_with_retry(
            socket_path=socket_path,
            credential=target,
            process=proxy,
        )
        try:
            await verify_role(target_connection)
        finally:
            await target_connection.close()

    ensure_secret(
        token,
        project=project,
        region=region,
        secret_id=destination_secret,
    )
    database_url = build_database_url(
        user=role,
        password=generated_password,
        database=database,
        connection_name=args.connection_name,
    )
    version = add_secret_version(
        token,
        project=project,
        secret_id=destination_secret,
        value=database_url,
    )
    database_url = ""
    generated_password = ""
    return version


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--connection-name", required=True)
    parser.add_argument("--database", default="noop")
    parser.add_argument("--user", default="noop_ownership")
    parser.add_argument(
        "--bootstrap-secret",
        default="noop-staging-database-url",
    )
    parser.add_argument(
        "--secret",
        default="noop-staging-ownership-database-url",
    )
    parser.add_argument("--proxy-binary", default="cloud-sql-proxy")
    parser.add_argument(
        "--confirm-runtime-disabled",
        action="store_true",
        help="Required acknowledgement that the ownership runtime is disabled.",
    )
    args = parser.parse_args()
    if not args.confirm_runtime_disabled:
        parser.error("--confirm-runtime-disabled is required")
    try:
        version = asyncio.run(configure(args))
    except ProvisioningError as error:
        parser.exit(1, f"Ownership database provisioning failed: {error}\n")
    except Exception:
        parser.exit(
            1,
            "Ownership database provisioning failed without exposing details. "
            "Verify the proxy, migration, IAM, and Secret Manager access.\n",
        )
    print(
        "Configured the least-privilege ownership database credential as "
        f"secret version {version}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
