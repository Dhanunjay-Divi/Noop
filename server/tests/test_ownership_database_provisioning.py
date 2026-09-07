from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "infra" / "gcp" / "scripts" / "configure-ownership-database.py"


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
    return frozenset(re.findall(r"\('([^']+)', '([A-Z]+)'\)", values))


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
