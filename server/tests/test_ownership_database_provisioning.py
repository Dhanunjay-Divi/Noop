from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "infra" / "gcp" / "scripts" / "configure-ownership-database.py"
LIFECYCLE_SOURCE_PATH = ROOT / "server" / "app" / "ownership_deletion_lifecycle.py"


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "configure_ownership_database",
        SCRIPT_PATH,
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def readiness_table_privileges() -> frozenset[tuple[str, str]]:
    source = (ROOT / "server" / "app" / "ownership_repository.py").read_text()
    values = source.split(
        "WITH ownership_table_allowed (table_name, privilege) AS (",
        1,
    )[1].split(
        "ownership_column_allowed (",
        1,
    )[0]
    return frozenset(
        re.findall(
            r"\(\s*'([^']+)'\s*,\s*'([A-Z]+)'\s*\)",
            values,
        )
    )


def readiness_column_privileges() -> frozenset[tuple[str, str, str]]:
    source = (ROOT / "server" / "app" / "ownership_repository.py").read_text()
    values = source.split(
        "ownership_column_allowed (",
        1,
    )[1].split(
        "ownership_privileges (privilege) AS (",
        1,
    )[0]
    return frozenset(
        (table, column, privilege)
        for table, column, privilege in re.findall(
            r"\(\s*'([^']+)',\s*'([^']+)',\s*'([A-Z]+)'\s*\)",
            values,
        )
    )


def lifecycle_readiness_table_privileges() -> frozenset[tuple[str, str]]:
    source = LIFECYCLE_SOURCE_PATH.read_text()
    values = source.split(
        "WITH allowed_table (table_name, privilege) AS (",
        1,
    )[1].split(
        "allowed_column (table_name, column_name, privilege) AS (",
        1,
    )[0]
    return frozenset(
        re.findall(
            r"\(\s*'([^']+)'\s*,\s*'([A-Z]+)'\s*\)",
            values,
        )
    )


def lifecycle_readiness_column_privileges() -> frozenset[tuple[str, str, str]]:
    source = LIFECYCLE_SOURCE_PATH.read_text()
    values = source.split(
        "allowed_column (table_name, column_name, privilege) AS (",
        1,
    )[1].split(
        "relation_privilege (privilege) AS (",
        1,
    )[0]
    return frozenset(
        (table, column, privilege)
        for table, column, privilege in re.findall(
            r"\(\s*'([^']+)',\s*'([^']+)',\s*'([A-Z]+)'\s*\)",
            values,
        )
    )


def test_provisioner_uses_the_exact_runtime_readiness_allowlist() -> None:
    script = load_script()

    assert script.OWNERSHIP_TABLE_PRIVILEGE_PAIRS == readiness_table_privileges()
    assert script.OWNERSHIP_COLUMN_PRIVILEGE_TRIPLES == readiness_column_privileges()
    assert all(
        privilege in {"SELECT", "INSERT"}
        for _, privilege in script.OWNERSHIP_TABLE_PRIVILEGE_PAIRS
    )
    assert not any(
        table == "ownership_entitlements"
        for table, _ in script.OWNERSHIP_TABLE_PRIVILEGE_PAIRS
    )
    assert all(
        privilege == "UPDATE"
        for _, _, privilege in script.OWNERSHIP_COLUMN_PRIVILEGE_TRIPLES
    )


def test_lifecycle_profile_matches_the_exact_coordination_readiness_allowlist() -> None:
    script = load_script()
    profile = script.OWNERSHIP_DELETION_LIFECYCLE_PROFILE
    table_privileges = frozenset(
        (table, privilege)
        for table, privileges in profile.table_privileges
        for privilege in privileges
    )
    column_privileges = frozenset(
        (table, column, privilege)
        for table, privilege, columns in profile.column_privileges
        for column in columns
    )

    assert table_privileges == lifecycle_readiness_table_privileges()
    assert column_privileges == lifecycle_readiness_column_privileges()
    assert table_privileges == {
        ("ownership_account_deletion_target_progress", "SELECT"),
        ("ownership_account_deletion_requests", "SELECT"),
        ("ownership_external_identities", "SELECT"),
    }
    assert all(
        table == "ownership_account_deletion_target_progress" and privilege == "UPDATE"
        for table, _, privilege in column_privileges
    )
    assert not any(
        restricted in table
        for table, _ in table_privileges
        for restricted in (
            "managed_",
            "band",
            "installation",
        )
    )


def test_lifecycle_grants_are_column_limited_and_api_profile_is_unchanged() -> None:
    script = load_script()

    api_default = script.exact_grant_statements("noop_ownership")
    api_explicit = script.exact_grant_statements(
        "noop_ownership",
        profile=script.OWNERSHIP_API_PROFILE,
    )
    lifecycle = script.exact_grant_statements(
        "noop_ownership_lifecycle",
        profile=script.OWNERSHIP_DELETION_LIFECYCLE_PROFILE,
    )

    assert api_default == api_explicit
    assert script.OWNERSHIP_API_PROFILE.default_user == "noop_ownership"
    assert (
        script.OWNERSHIP_API_PROFILE.default_secret
        == "noop-staging-ownership-database-url"
    )
    assert len(lifecycle) == 4
    assert (
        sum(statement.startswith("GRANT SELECT ON TABLE") for statement in lifecycle)
        == 3
    )
    assert sum(statement.startswith("GRANT UPDATE (") for statement in lifecycle) == 1
    assert not any("GRANT UPDATE ON TABLE" in statement for statement in lifecycle)
    assert not any(
        privilege in statement
        for statement in lifecycle
        for privilege in (
            "INSERT",
            "DELETE",
            "TRUNCATE",
            "REFERENCES",
            "TRIGGER",
        )
    )
    assert not any('ON TABLE public."managed_' in statement for statement in lifecycle)
    assert not any(
        restricted in statement
        for statement in lifecycle
        for restricted in (
            'ON TABLE public."ownership_bands"',
            'ON TABLE public."ownership_installations"',
        )
    )


def test_separate_safe_shell_invocations_select_explicit_profiles() -> None:
    api_shell = (
        ROOT / "infra" / "gcp" / "scripts" / "configure-ownership-database.sh"
    ).read_text()
    lifecycle_shell = (
        ROOT
        / "infra"
        / "gcp"
        / "scripts"
        / "configure-ownership-deletion-lifecycle-database.sh"
    ).read_text()

    assert '--role-kind="api"' in api_shell
    assert '--user="noop_ownership"' in api_shell
    assert '--secret="noop-staging-ownership-database-url"' in api_shell
    assert "managed_lifecycle_job" not in api_shell
    assert '--role-kind="deletion-lifecycle"' in lifecycle_shell
    assert '--user="noop_ownership_lifecycle"' in lifecycle_shell
    assert '--secret="noop-staging-ownership-lifecycle-database-url"' in lifecycle_shell
    assert "output -json managed_lifecycle_job" in lifecycle_shell
    assert "--confirm-runtime-disabled" in lifecycle_shell
    assert "printf '%s'" not in lifecycle_shell


def test_grants_are_quoted_and_contain_no_unapproved_privilege() -> None:
    script = load_script()
    statements = script.exact_grant_statements("noop_ownership")

    assert len(statements) == (
        len(script.OWNERSHIP_TABLE_PRIVILEGES) + len(script.OWNERSHIP_COLUMN_PRIVILEGES)
    )
    assert all(statement.endswith('TO "noop_ownership"') for statement in statements)
    assert all("DELETE" not in statement for statement in statements)
    assert all("TRUNCATE" not in statement for statement in statements)
    assert all("REFERENCES" not in statement for statement in statements)
    assert all("TRIGGER" not in statement for statement in statements)
    assert any(
        statement.startswith(
            'GRANT UPDATE ("status", "current_account_id", "claimed_at", '
            '"firmware_version", "updated_at") ON TABLE '
            'public."ownership_bands"'
        )
        for statement in statements
    )
    assert not any(
        statement.startswith("GRANT UPDATE ON TABLE") for statement in statements
    )


def test_post_provision_verifier_covers_runtime_escalation_boundaries() -> None:
    source = SCRIPT_PATH.read_text()

    assert "AND NOT rolinherit" in source
    assert "NOT has_database_privilege(current_database(), 'CREATE')" in source
    assert "WHERE relowner = (" in source
    assert "WHERE nspowner = (" in source
    assert "WHERE datdba = (" in source
    assert "has_sequence_privilege" in source
    assert "candidate.prosecdef" in source
    assert "has_function_privilege(candidate.oid, 'EXECUTE')" in source


def test_database_url_round_trips_without_exposing_values_in_arguments() -> None:
    script = load_script()
    url = script.build_database_url(
        user="noop_ownership",
        password="private:/?# value",
        database="noop",
        connection_name="noop-staging:asia-south1:noop-primary",
    )

    parsed = script.parse_database_url(url)
    assert parsed.user == "noop_ownership"
    assert parsed.password == "private:/?# value"
    assert parsed.database == "noop"
    source = SCRIPT_PATH.read_text()
    assert "--password" not in source
    assert "PGPASSWORD" not in source
    assert "print(database_url" not in source
    assert "print(generated_password" not in source


@pytest.mark.parametrize(
    "value",
    [
        "Ownership-Role",
        "role with space",
        "role;drop table",
        "1ownership",
        "a" * 64,
    ],
)
def test_role_identifier_rejects_unsafe_values(value: str) -> None:
    script = load_script()

    with pytest.raises(script.ProvisioningError, match="Invalid database user"):
        script.require_match(
            value,
            script.ROLE_IDENTIFIER,
            "database user",
        )


def test_google_api_error_does_not_include_response_payload() -> None:
    script = load_script()
    error = script.GoogleAPIError(403)

    assert str(error) == "Google API request failed with HTTP 403"
    assert not hasattr(error, "response")
