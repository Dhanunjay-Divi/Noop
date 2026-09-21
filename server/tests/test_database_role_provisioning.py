from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import re
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import AsyncIterator

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "infra" / "gcp" / "scripts" / "configure-database-secret.py"
SHELL_PATH = ROOT / "infra" / "gcp" / "scripts" / "configure-runtime-secrets.sh"


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "configure_database_secret",
        SCRIPT_PATH,
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_migration_and_runtime_principals_and_secrets_are_distinct() -> None:
    script = load_script()

    assert script.MIGRATION_USER == "noop_migration"
    assert script.RUNTIME_USER == "noop_app_runtime"
    assert script.MIGRATION_USER != script.RUNTIME_USER
    assert script.MIGRATION_SECRET == "noop-staging-database-url"
    assert script.RUNTIME_SECRET == "noop-staging-runtime-database-url"
    assert script.MIGRATION_SECRET != script.RUNTIME_SECRET
    assert set(script.RUNTIME_PROFILE_USERS) == script.RUNTIME_PROFILES
    assert set(script.RUNTIME_PROFILE_SECRETS) == script.RUNTIME_PROFILES
    assert len(set(script.RUNTIME_PROFILE_USERS.values())) == len(
        script.RUNTIME_PROFILES
    )
    assert len(set(script.RUNTIME_PROFILE_SECRETS.values())) == len(
        script.RUNTIME_PROFILES
    )
    assert script.MIGRATION_USER not in script.RUNTIME_PROFILE_USERS.values()
    assert script.MIGRATION_SECRET not in script.RUNTIME_PROFILE_SECRETS.values()


def test_runtime_function_allowlist_matches_direct_server_calls() -> None:
    script = load_script()
    repository = (ROOT / "server" / "app" / "managed_repository.py").read_text(
        encoding="utf-8"
    )
    direct_calls = frozenset(
        match
        for match in re.findall(
            r"(?:SELECT|FROM)\s+(noop_[a-z0-9_]+)\s*\(",
            repository,
        )
    )

    assert direct_calls == script.RUNTIME_FUNCTIONS


def test_provisioning_manifest_matches_every_postgresql_migration() -> None:
    script = load_script()
    manifest = script.expected_migration_manifest()
    migration_dir = ROOT / "server" / "migrations"
    migrations = sorted(migration_dir.glob("*.sql"))
    overlay_dir = ROOT / "server" / "migrations-postgresql"
    overlays = sorted(overlay_dir.glob("*.sql"))

    canonical = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in migrations
    }
    postgresql = canonical | {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in overlays
    }

    assert manifest == postgresql
    assert canonical["001_init.sql"] != postgresql["001_init.sql"]


def test_runtime_provisioning_requires_the_exact_release_manifest() -> None:
    script = load_script()
    expected = script.expected_migration_manifest()

    class FakeConnection:
        async def fetchval(self, statement: str) -> bool:
            assert "to_regclass" in statement
            return True

        async def fetch(self, statement: str) -> list[dict[str, str]]:
            assert "noop_schema_migrations" in statement
            return [
                {"version": version, "checksum": checksum}
                for version, checksum in expected.items()
            ]

    asyncio.run(script.require_exact_migration_manifest(FakeConnection()))

    missing = dict(expected)
    missing.pop(next(reversed(missing)))

    class StaleConnection(FakeConnection):
        async def fetch(self, statement: str) -> list[dict[str, str]]:
            assert "noop_schema_migrations" in statement
            return [
                {"version": version, "checksum": checksum}
                for version, checksum in missing.items()
            ]

    with pytest.raises(
        script.ProvisioningError,
        match="migration manifest does not match",
    ):
        asyncio.run(script.require_exact_migration_manifest(StaleConnection()))


def test_runtime_grants_are_dml_only_and_function_specific() -> None:
    script = load_script()
    statements = script.runtime_grant_statements(
        "noop_managed_api",
        profile="managed-api",
        relations=(
            "noop_schema_migrations",
            "daily_metrics",
            "managed_accounts",
            "managed_social_profiles",
            "feedback_reports",
            "ownership_accounts",
        ),
        sequences=(
            ("managed_social_profiles_id_seq", "managed_social_profiles"),
            ("daily_metrics_id_seq", "daily_metrics"),
        ),
        function_signatures={
            "noop_erase_managed_account_cloud_state": (
                'public."noop_erase_managed_account_cloud_state"'
                "(uuid, uuid, timestamptz)"
            ),
            "noop_managed_append_change": (
                'public."noop_managed_append_change"(uuid, character, text)'
            ),
        },
    )

    assert statements[0] == (
        'GRANT SELECT ON TABLE public.noop_schema_migrations TO "noop_managed_api"'
    )
    assert (
        "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "
        'public."managed_accounts" TO "noop_managed_api"'
    ) in statements
    assert (
        "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "
        'public."managed_social_profiles" TO "noop_managed_api"'
    ) in statements
    assert (
        "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "
        'public."feedback_reports" TO "noop_managed_api"'
    ) in statements
    assert not any("daily_metrics" in statement for statement in statements)
    assert not any("ownership_accounts" in statement for statement in statements)
    assert (
        "GRANT SELECT, UPDATE, USAGE ON SEQUENCE "
        'public."managed_social_profiles_id_seq" TO "noop_managed_api"'
    ) in statements
    assert not any("daily_metrics_id_seq" in statement for statement in statements)
    assert (
        "GRANT EXECUTE ON FUNCTION "
        'public."noop_erase_managed_account_cloud_state"'
        '(uuid, uuid, timestamptz) TO "noop_managed_api"'
    ) in statements
    assert (
        "GRANT EXECUTE ON FUNCTION "
        'public."noop_managed_append_change"'
        '(uuid, character, text) TO "noop_managed_api"'
    ) in statements
    assert all(statement.endswith('TO "noop_managed_api"') for statement in statements)
    assert all("CREATE" not in statement for statement in statements)
    assert all("ALTER" not in statement for statement in statements)
    assert all("DROP" not in statement for statement in statements)
    assert all("TRUNCATE" not in statement for statement in statements)
    assert all("REFERENCES" not in statement for statement in statements)
    assert all("TRIGGER" not in statement for statement in statements)


def test_runtime_profiles_separate_legacy_managed_feedback_and_ownership_data() -> None:
    script = load_script()
    relations = {
        "noop_schema_migrations",
        "daily_metrics",
        "installation_credentials",
        "managed_accounts",
        "managed_social_profiles",
        "feedback_reports",
        "ownership_accounts",
        "unified_managed_account_links",
    }

    allowed = {
        profile: {
            relation
            for relation in relations
            if script.runtime_profile_allows_relation(profile, relation)
        }
        for profile in script.RUNTIME_PROFILES
    }

    assert allowed["private-api"] == {
        "noop_schema_migrations",
        "daily_metrics",
        "installation_credentials",
    }
    assert allowed["managed-api"] == {
        "noop_schema_migrations",
        "installation_credentials",
        "managed_accounts",
        "managed_social_profiles",
        "feedback_reports",
        "unified_managed_account_links",
    }
    assert allowed["managed-processor"] == {
        "noop_schema_migrations",
        "installation_credentials",
        "managed_accounts",
        "managed_social_profiles",
        "unified_managed_account_links",
    }
    assert allowed["managed-lifecycle"] == allowed["managed-processor"]
    assert allowed["feedback-lifecycle"] == {
        "noop_schema_migrations",
        "feedback_reports",
    }
    assert all(
        "ownership_accounts" not in profile_relations
        for profile_relations in allowed.values()
    )


def test_runtime_verifier_covers_membership_ownership_and_ddl_boundaries() -> None:
    source = SCRIPT_PATH.read_text(encoding="utf-8")

    assert "AND NOT rolsuper" in source
    assert "AND NOT rolcreaterole" in source
    assert "AND NOT rolcreatedb" in source
    assert "AND NOT rolreplication" in source
    assert "AND NOT rolbypassrls" in source
    assert "AND NOT rolinherit" in source
    assert "FROM pg_auth_members" in source
    assert "FROM pg_class" in source
    assert "FROM pg_namespace" in source
    assert "FROM pg_proc" in source
    assert "FROM pg_database" in source
    assert "NOT has_database_privilege(current_database(), 'CREATE')" in source
    assert "NOT has_database_privilege(current_database(), 'TEMPORARY')" in source
    assert "NOT has_schema_privilege('public', 'CREATE')" in source
    assert "REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC" in source
    assert "Runtime database function uses security definer" in source


@pytest.mark.parametrize("failure_stage", ("connect", "verify"))
def test_runtime_verification_failure_quarantines_role_before_secret_publish(
    monkeypatch: pytest.MonkeyPatch,
    failure_stage: str,
) -> None:
    script = load_script()
    events: list[tuple[str, str]] = []
    secret_published = False

    class FakeConnection:
        def __init__(self, name: str) -> None:
            self.name = name
            self.closed = False

        async def execute(self, statement: str) -> None:
            events.append((f"{self.name}.execute", statement))

        async def fetch(self, statement: str, role: str) -> list[dict[str, str]]:
            del statement, role
            events.append((f"{self.name}.fetch", "memberships"))
            return []

        async def close(self) -> None:
            self.closed = True

    migration_connection = FakeConnection("migration")
    runtime_connection = FakeConnection("runtime")
    connection_attempt = 0

    @asynccontextmanager
    async def fake_proxy(
        binary: str,
        connection_name: str,
    ) -> AsyncIterator[tuple[str, object]]:
        del binary, connection_name
        yield "/tmp/noop-test-proxy", object()

    async def fake_connect_with_retry(**kwargs: object) -> FakeConnection:
        nonlocal connection_attempt
        del kwargs
        connection_attempt += 1
        if connection_attempt == 1:
            return migration_connection
        if failure_stage == "connect":
            raise script.ProvisioningError("Runtime verification connection failed")
        return runtime_connection

    async def fake_provision_runtime_role(
        connection: FakeConnection,
        **kwargs: str,
    ) -> None:
        del connection, kwargs

    async def fake_verify_runtime_role(
        connection: FakeConnection,
        runtime_profile: str,
    ) -> None:
        del connection, runtime_profile
        raise script.ProvisioningError("Runtime verification failed")

    def fail_if_secret_is_published(*args: object, **kwargs: object) -> str:
        nonlocal secret_published
        del args, kwargs
        secret_published = True
        raise AssertionError("Runtime secret must not be published")

    monkeypatch.setattr(
        script,
        "access_secret_if_present",
        lambda _token, _project, secret: (
            "postgresql://noop_migration:private@/noop"
            if secret == script.MIGRATION_SECRET
            else None
        ),
    )
    monkeypatch.setattr(script, "cloud_sql_proxy", fake_proxy)
    monkeypatch.setattr(script, "connect_with_retry", fake_connect_with_retry)
    monkeypatch.setattr(
        script, "configure_cloud_sql_user", lambda *args, **kwargs: None
    )
    monkeypatch.setattr(script, "provision_runtime_role", fake_provision_runtime_role)
    monkeypatch.setattr(script, "verify_runtime_role", fake_verify_runtime_role)
    monkeypatch.setattr(script, "add_secret_version", fail_if_secret_is_published)

    args = SimpleNamespace(
        project="noop-staging",
        bootstrap_secret=script.MIGRATION_SECRET,
        migration_user=script.MIGRATION_USER,
        database="noop",
        proxy_binary="cloud-sql-proxy",
        connection_name="noop-staging:asia-south1:noop-staging-postgres",
        instance="noop-staging-postgres",
        user=script.RUNTIME_USER,
        secret=script.RUNTIME_SECRET,
        runtime_profile="private-api",
    )
    expected_message = (
        "Runtime verification connection failed"
        if failure_stage == "connect"
        else "Runtime verification failed"
    )

    with pytest.raises(script.ProvisioningError, match=expected_message):
        asyncio.run(script.configure_runtime(args, "token"))

    assert events[0][0] == "migration.execute"
    assert "WITH NOLOGIN" in events[0][1]
    assert events[1] == ("migration.fetch", "memberships")
    assert migration_connection.closed is True
    assert runtime_connection.closed is (failure_stage == "verify")
    assert secret_published is False


def test_runtime_secret_publish_failure_restores_previous_credential(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    script = load_script()
    configured_passwords: list[str] = []
    connected_credentials: list[object] = []

    class FakeConnection:
        def __init__(self) -> None:
            self.closed = False

        async def close(self) -> None:
            self.closed = True

    connections = [FakeConnection(), FakeConnection(), FakeConnection()]

    @asynccontextmanager
    async def fake_proxy(
        binary: str,
        connection_name: str,
    ) -> AsyncIterator[tuple[str, object]]:
        del binary, connection_name
        yield "/tmp/noop-test-proxy", object()

    async def fake_connect_with_retry(**kwargs: object) -> FakeConnection:
        connected_credentials.append(kwargs["credential"])
        return connections[len(connected_credentials) - 1]

    monkeypatch.setattr(
        script,
        "access_secret_if_present",
        lambda _token, _project, secret: (
            "postgresql://noop_app_runtime:old-runtime@/noop"
            if secret == script.RUNTIME_SECRET
            else "postgresql://noop_migration:migration@/noop"
        ),
    )
    monkeypatch.setattr(script, "cloud_sql_proxy", fake_proxy)
    monkeypatch.setattr(script, "connect_with_retry", fake_connect_with_retry)
    monkeypatch.setattr(
        script,
        "configure_cloud_sql_user",
        lambda _token, **kwargs: configured_passwords.append(kwargs["password"]),
    )
    monkeypatch.setattr(
        script,
        "provision_runtime_role",
        lambda *args, **kwargs: asyncio.sleep(0),
    )
    monkeypatch.setattr(
        script,
        "verify_runtime_role",
        lambda *args, **kwargs: asyncio.sleep(0),
    )
    monkeypatch.setattr(
        script,
        "add_secret_version",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            script.ProvisioningError("Secret publication failed")
        ),
    )

    async def unexpected_quarantine(*args: object, **kwargs: object) -> None:
        del args, kwargs
        raise AssertionError("Existing runtime role must be restored, not quarantined")

    monkeypatch.setattr(script, "quarantine_runtime_role", unexpected_quarantine)
    args = SimpleNamespace(
        project="noop-staging",
        bootstrap_secret=script.MIGRATION_SECRET,
        migration_user=script.MIGRATION_USER,
        database="noop",
        proxy_binary="cloud-sql-proxy",
        connection_name="noop-staging:asia-south1:noop-staging-postgres",
        instance="noop-staging-postgres",
        user=script.RUNTIME_USER,
        secret=script.RUNTIME_SECRET,
        runtime_profile="private-api",
    )

    with pytest.raises(script.ProvisioningError, match="publication failed"):
        asyncio.run(script.configure_runtime(args, "token"))

    assert len(configured_passwords) == 2
    assert configured_passwords[-1] == "old-runtime"
    assert [credential.password for credential in connected_credentials] == [
        "migration",
        configured_passwords[0],
        "old-runtime",
    ]
    assert all(connection.closed for connection in connections)


def test_migration_secret_publish_failure_restores_previous_credential(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    script = load_script()
    configured_passwords: list[str] = []

    class FakeConnection:
        async def close(self) -> None:
            return None

    @asynccontextmanager
    async def fake_proxy(
        binary: str,
        connection_name: str,
    ) -> AsyncIterator[tuple[str, object]]:
        del binary, connection_name
        yield "/tmp/noop-test-proxy", object()

    monkeypatch.setattr(
        script,
        "access_secret_if_present",
        lambda *args: "postgresql://noop_migration:old-migration@/noop",
    )
    monkeypatch.setattr(script, "cloud_sql_proxy", fake_proxy)
    monkeypatch.setattr(
        script,
        "connect_with_retry",
        lambda **kwargs: asyncio.sleep(0, result=FakeConnection()),
    )
    monkeypatch.setattr(
        script,
        "configure_cloud_sql_user",
        lambda _token, **kwargs: configured_passwords.append(kwargs["password"]),
    )
    monkeypatch.setattr(
        script,
        "provision_migration_role",
        lambda *args, **kwargs: asyncio.sleep(0),
    )
    monkeypatch.setattr(
        script,
        "verify_migration_role",
        lambda *args, **kwargs: asyncio.sleep(0),
    )
    monkeypatch.setattr(
        script,
        "add_secret_version",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            script.ProvisioningError("Secret publication failed")
        ),
    )
    args = SimpleNamespace(
        project="noop-staging",
        database="noop",
        proxy_binary="cloud-sql-proxy",
        connection_name="noop-staging:asia-south1:noop-staging-postgres",
        instance="noop-staging-postgres",
        user=script.MIGRATION_USER,
        secret=script.MIGRATION_SECRET,
    )

    with pytest.raises(script.ProvisioningError, match="publication failed"):
        asyncio.run(script.configure_migration(args, "token"))

    assert len(configured_passwords) == 2
    assert configured_passwords[-1] == "old-migration"


def test_database_url_round_trips_without_credential_arguments() -> None:
    script = load_script()
    url = script.build_database_url(
        user="noop_app_runtime",
        password="private:/?# value",
        database="noop",
        connection_name="noop-staging:asia-south1:noop-staging-postgres",
    )

    parsed = script.parse_database_url(url)
    assert parsed.user == "noop_app_runtime"
    assert parsed.password == "private:/?# value"
    assert parsed.database == "noop"
    source = SCRIPT_PATH.read_text(encoding="utf-8")
    assert "--password" not in source
    assert "PGPASSWORD" not in source


def test_operator_wrapper_requires_two_explicit_disabled_runtime_phases() -> None:
    shell = SHELL_PATH.read_text(encoding="utf-8")

    assert 'case "${database_phase}" in' in shell
    assert "migration|runtime" in shell
    assert '--role-kind="migration"' in shell
    assert '--role-kind="runtime"' in shell
    assert '--secret="${migration_database_secret}"' in shell
    assert '--secret="${database_secret}"' in shell
    for variable in (
        "runtime_database_secret",
        "managed_api_database_secret",
        "managed_processor_database_secret",
        "managed_lifecycle_database_secret",
        "feedback_lifecycle_database_secret",
    ):
        assert f'database_secret="${{{variable}}}"' in shell
    for profile in (
        "private-api",
        "managed-api",
        "managed-processor",
        "managed-lifecycle",
        "feedback-lifecycle",
    ):
        assert profile in shell
    assert "--confirm-runtime-disabled" in shell
    assert "--confirm-migrations-complete" in shell
    assert "NOOP_REQUIRED_NULL_OUTPUTS" in shell
    assert "--password" not in shell
    assert "--data-file=-" in shell
