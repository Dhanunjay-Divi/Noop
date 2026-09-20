from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path


SERVER_ROOT = Path(__file__).resolve().parents[1]
BACKUP_ROOT = SERVER_ROOT / "backup"


def _run_script(script: str, *args: str, env: dict[str, str] | None = None):
    return subprocess.run(
        ["/bin/sh", str(BACKUP_ROOT / script), *args],
        env={**os.environ, **(env or {})},
        capture_output=True,
        text=True,
        check=False,
    )


def test_backup_and_restore_scripts_are_valid_posix_shell() -> None:
    for script in (
        "backup.sh",
        "backup-loop.sh",
        "backup-healthcheck.sh",
        "restore.sh",
        "restore-drill.sh",
        "restore-application-smoke.sh",
    ):
        result = subprocess.run(
            ["/bin/sh", "-n", str(BACKUP_ROOT / script)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr


def test_backup_fails_closed_before_dump_when_secret_is_missing(tmp_path: Path) -> None:
    result = _run_script(
        "backup.sh",
        env={
            "NOOP_BACKUP_DIRECTORY": str(tmp_path),
            "NOOP_BACKUP_PASSPHRASE_FILE": str(tmp_path / "missing-secret"),
        },
    )

    assert result.returncode == 78
    assert "passphrase file is required" in result.stderr
    assert not list(tmp_path.glob("*.dump*"))


def test_backup_rejects_a_short_secret_before_dump(tmp_path: Path) -> None:
    secret = tmp_path / "short-secret"
    secret.write_bytes(b"too-short")
    result = _run_script(
        "backup.sh",
        env={
            "NOOP_BACKUP_DIRECTORY": str(tmp_path),
            "NOOP_BACKUP_PASSPHRASE_FILE": str(secret),
        },
    )

    assert result.returncode == 78
    assert "at least 32 bytes" in result.stderr
    assert not list(tmp_path.glob("*.dump*"))


def test_restore_requires_explicit_destructive_confirmation(tmp_path: Path) -> None:
    encrypted = tmp_path / "noop-test.dump.gpg"
    encrypted.write_bytes(b"not-a-real-backup")

    result = _run_script("restore.sh", str(encrypted))

    assert result.returncode == 78
    assert "NOOP_RESTORE_CONFIRM=RESTORE_EMPTY_DATABASE" in result.stderr


def test_backup_contract_encrypts_before_publish_and_validates_before_restore() -> None:
    backup = (BACKUP_ROOT / "backup.sh").read_text(encoding="utf-8")
    restore = (BACKUP_ROOT / "restore.sh").read_text(encoding="utf-8")
    drill = (BACKUP_ROOT / "restore-drill.sh").read_text(encoding="utf-8")
    smoke = (BACKUP_ROOT / "restore-application-smoke.sql").read_text(encoding="utf-8")
    backup_image = (BACKUP_ROOT / "Dockerfile").read_text(encoding="utf-8")
    compose = (SERVER_ROOT / "compose.yaml").read_text(encoding="utf-8")

    assert "--symmetric" in backup
    assert "--cipher-algo AES256" in backup
    assert "passphrase-file" in backup
    assert "sha256sum" in backup
    assert "--no-privileges" not in backup
    assert "--no-privileges" not in restore
    assert backup.index("gpg ") < backup.index('mv "$encrypted_partial"')
    assert restore.index("sha256sum --check") < restore.index("pg_restore \\")
    assert restore.index("pg_restore --list") < restore.index("timescaledb_pre_restore")
    assert "timescaledb_post_restore" in restore
    assert "destination database must be empty" in restore
    assert "--clean" not in restore
    assert "noop_backup_passphrase" in compose
    assert "NOOP_BACKUP_SECRET_FILE" in compose
    assert "backup-healthcheck.sh" in compose
    for required_relation in (
        "safety_profiles",
        "safety_contacts",
        "safety_dispatches",
        "safety_deliveries",
        "safety_delivery_attempts",
        "safety_responses",
        "safety_incident_locations",
        "safety_runtime_controls",
        "safety_runtime_control_audit",
        "safety_worker_heartbeats",
        "safety_invitation_jobs",
        "safety_invitation_attempts",
        "safety_provider_rate_state",
        "safety_dispatch_tombstones",
        "installation_credentials",
        "installation_devices",
        "managed_accounts",
        "managed_social_profiles",
        "managed_documents",
        "managed_document_heads",
        "managed_account_change_sequences",
        "managed_change_events",
        "managed_document_contract_v2_readiness",
        "managed_safety_incidents",
        "managed_safety_page_quota_events",
        "managed_safety_locations",
        "managed_safety_push_deliveries",
    ):
        assert required_relation in drill
    assert "restore drill failed Safety control verification" in drill
    assert "restore-application-smoke.sh" in drill
    assert "restore-application-smoke.sh" in backup_image
    assert "restore-application-smoke.sql" in backup_image
    assert "migration-manifest.sha256" in backup_image
    assert "migration-manifest-postgresql.sha256" in backup_image
    assert "NOOP_DATABASE_ENGINE" in compose
    smoke_script = (BACKUP_ROOT / "restore-application-smoke.sh").read_text(
        encoding="utf-8"
    )
    assert "--file=- <<'SQL'" in smoke_script
    assert "btrim(checksum) = :'checksum'" in smoke_script
    assert "NOOP_RESTORE_APPLICATION_SMOKE_SQL" in smoke_script
    assert '--file="$smoke_sql"' in smoke_script
    assert (
        '--command="SELECT count(*) FROM noop_schema_migrations\n' not in smoke_script
    )
    assert "BEGIN READ ONLY" in smoke
    assert "010_installation_tenancy.sql" in smoke
    assert "011_safety_data_lifecycle.sql" in smoke
    assert "012_tenancy_cutover_invariants.sql" in smoke
    assert "013_safety_escalation_contract.sql" in smoke
    assert "034_managed_document_contract_v2_add.sql" in smoke
    assert "035_managed_document_plaintext_quarantine.sql" in smoke
    assert "036_managed_document_contract_v2_validate.sql" in smoke
    assert "037_managed_document_contract_v2_activate.sql" in smoke
    assert "038_managed_safety_band_sos.sql" in smoke
    assert "041_managed_safety_writer_compatibility.sql" in smoke
    assert "042_feedback_idempotency_tombstones.sql" in smoke
    assert "managed_document_contract_v2_readiness" in smoke
    assert "content contract activated before client readiness" in smoke
    assert "managed Safety quota writer compatibility is missing" in smoke
    assert "managed_safety_page_quota_trigger" in smoke
    assert "managed_social_profile_account_immutability" in smoke
    assert "managed_safety_incident_quota_immutability" in smoke
    assert "managed_safety_page_quota_incident_consistency" in smoke
    assert "managed document head does not match its current revision" in smoke
    assert "managed Safety quota provenance is inconsistent" in smoke
    assert "terminal managed Safety incident retained precise location" in smoke
    assert "Safety escalation round is outside its incident contract" in smoke
    assert "orphaned Safety queue rows were restored" in smoke
    assert "orphaned installation device ownership was restored" in smoke
    assert "profile without installation ownership was restored" in smoke
    assert "orphaned Safety replay tombstone was restored" in smoke


def test_restore_smoke_requires_feedback_tombstone_schema_contract() -> None:
    smoke = (BACKUP_ROOT / "restore-application-smoke.sql").read_text(encoding="utf-8")
    normalized_smoke = " ".join(smoke.split())

    assert "to_regclass('public.feedback_reports')" in smoke
    assert "feedback reports table is missing" in smoke
    for column_name, expected_type in (
        ("report_id", "uuid"),
        ("client_app_id", "text"),
        ("subject_hash", "character(64)"),
        ("principal_hash_version", "smallint"),
        ("principal_hash", "character(64)"),
        ("idempotency_hash", "character(64)"),
        ("request_hash", "character(64)"),
        ("platform", "text"),
        ("app_version", "text"),
        ("archive_bytes", "integer"),
        ("archive_sha256", "character(64)"),
        ("includes_user_note", "boolean"),
        ("includes_screenshot", "boolean"),
        ("receipt", "character varying(19)"),
        ("object_key", "text"),
        ("status", "text"),
        ("object_generation", "bigint"),
        ("created_at", "timestamp with time zone"),
        ("upload_expires_at", "timestamp with time zone"),
        ("completed_at", "timestamp with time zone"),
        ("retained_until", "timestamp with time zone"),
        ("deleted_at", "timestamp with time zone"),
        ("cleanup_after", "timestamp with time zone"),
        ("cleanup_phase", "text"),
        ("cleanup_claimed_at", "timestamp with time zone"),
        ("object_absence_confirmed_at", "timestamp with time zone"),
    ):
        assert f"('{column_name}', '{expected_type}'" in normalized_smoke
    assert "column_state.attnotnull IS DISTINCT FROM" in smoke
    assert "feedback reports runtime column contract is missing or invalid" in smoke
    for constraint_name in (
        "feedback_completion_consistent",
        "feedback_cleanup_phase_valid",
        "feedback_time_order",
        "feedback_cleanup_consistent",
        "feedback_cleanup_claim_consistent",
        "feedback_absence_confirmation_consistent",
        "feedback_reports_client_app_id_subject_hash_idempotency_has_key",
        "feedback_reports_principal_idempotency_unique",
        "feedback_reports_receipt_key",
        "feedback_reports_object_key_key",
    ):
        assert constraint_name in smoke
    assert (
        "feedback report runtime constraint is missing, unvalidated, or invalid"
        in smoke
    )
    assert "feedback_report_compatibility" in smoke
    assert "feedback_report_retire_idempotency" in smoke
    assert "noop_feedback_report_compatibility" in smoke
    assert "noop_feedback_report_retire_idempotency" in smoke
    assert "23::smallint" in smoke
    assert "11::smallint" in smoke
    assert "trigger_row.tgconstraint IS DISTINCT FROM 0::oid" in smoke
    assert "trigger_row.tgattr IS DISTINCT FROM ''::int2vector" in smoke
    assert "feedback report runtime trigger binding or shape is invalid" in smoke
    for index_name in (
        "feedback_reports_retention_idx",
        "feedback_reports_status_idx",
        "feedback_reports_subject_quota_idx",
        "feedback_reports_cleanup_v2_idx",
        "feedback_reports_principal_quota_idx",
        "feedback_reports_app_quota_idx",
    ):
        assert index_name in smoke
    assert "index_row.relnamespace = 'public'::regnamespace" in smoke
    assert "feedback report runtime index is missing or invalid" in smoke
    assert "to_regclass('public.feedback_idempotency_tombstones')" in smoke
    assert "044_feedback_idempotency_duration.sql" in smoke
    assert "045_ownership_account_deletion_progress.sql" in smoke
    assert "ownership_account_deletion_target_progress" in smoke
    assert "ownership_account_deletion_progress_due_idx" in smoke
    for constraint_name in (
        "ownership_account_deletion_target_progress_pkey",
        "ownership_account_deletion_progress_target_fk",
        "ownership_account_deletion_progress_managed_job_fk",
        "ownership_account_deletion_progress_state",
        "ownership_account_deletion_progress_blocker",
        "ownership_account_deletion_progress_state_blocker",
        "ownership_account_deletion_progress_attempts",
        "ownership_account_deletion_progress_version",
        "ownership_account_deletion_progress_lease_pair",
        "ownership_account_deletion_progress_retry_state",
        "ownership_account_deletion_progress_managed_target",
        "ownership_account_deletion_progress_failure_kind",
        "ownership_account_deletion_progress_completion_state",
    ):
        assert constraint_name in smoke
    assert "ownership_account_deletion_progress_guard" in smoke
    assert "noop_ownership_account_deletion_progress_guard" in smoke
    assert "ownership_account_deletion_progress_seed" in smoke
    assert "noop_ownership_account_deletion_progress_seed" in smoke
    assert "aclexplode(" in smoke
    assert "privilege.grantee = 0" in smoke
    assert "ownership deletion target progress is incomplete or orphaned" in smoke
    assert "JOIN pg_attribute column_state" in smoke
    assert "column_state.attnotnull" in smoke
    assert "('reserved_at', 'timestamp with time zone')" in smoke
    assert "('expires_at', 'timestamp with time zone')" in smoke
    for constraint_name in (
        "feedback_tombstone_client_app_id_bounded",
        "feedback_tombstone_principal_version_supported",
        "feedback_tombstone_principal_hash_format",
        "feedback_tombstone_idempotency_hash_format",
        "feedback_tombstone_time_order",
    ):
        assert constraint_name in smoke
    assert "feedback_idempotency_tombstones_pkey" in smoke
    assert "feedback_tombstone_normalize_expiry" in smoke
    assert "noop_feedback_tombstone_normalize_expiry" in smoke
    assert "noop_feedback_report_retire_idempotency" in smoke
    assert "trigger_row.tgtype = 23" in smoke
    assert "trigger_row.tgconstraint = 0::oid" in smoke
    assert "trigger_row.tgnargs = 0" in smoke
    assert "trigger_row.tgqual IS NULL" in smoke
    assert "trigger_row.tgoldtable IS NULL" in smoke
    assert "trigger_row.tgnewtable IS NULL" in smoke
    assert "trigger_row.tgattr::smallint[]" in smoke
    assert "ARRAY['reserved_at', 'expires_at']" in smoke
    assert "position('1080 hours' IN function_row.prosrc) > 0" in smoke
    assert "position('45 days' IN function_row.prosrc) = 0" in smoke
    assert (
        "PRIMARY KEY (client_app_id, principal_hash_version, principal_hash, "
        "idempotency_hash)"
    ) in smoke
    assert "feedback_idempotency_tombstones_expiry_idx" in smoke
    assert "JOIN pg_am access_method" in smoke
    assert "access_method.amname = 'btree'" in smoke
    assert "index_state.indisvalid" in smoke
    assert "index_state.indisready" in smoke
    assert "(expires_at, client_app_id, principal_hash, idempotency_hash)" in smoke
    for expected_definition in (
        "CHECK (char_length(client_app_id) >= 8 AND char_length(client_app_id) <= 256)",
        "CHECK (principal_hash_version = ANY (ARRAY[0, 1]))",
        "CHECK (principal_hash ~ '^[0-9a-f]{64}$'::text)",
        "CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'::text)",
        "CHECK (expires_at = (reserved_at + '1080:00:00'::interval) "
        "AND expires_at > reserved_at)",
    ):
        assert expected_definition in smoke
    assert (
        "feedback tombstone check constraint is missing, unvalidated, or invalid"
        in smoke
    )
    assert (
        "feedback tombstone lifecycle timestamp is missing, nullable, or not" in smoke
    )
    assert "feedback tombstone primary key is missing or invalid" in smoke
    assert "feedback tombstone expiry index is missing or invalid" in smoke

    drill = (BACKUP_ROOT / "restore-drill.sh").read_text(encoding="utf-8")
    assert "to_regclass('public.feedback_reports')" in drill
    assert "to_regclass(" in drill
    assert "'public.feedback_idempotency_tombstones'" in drill
    assert "'feedback_reports', (SELECT count(*) FROM feedback_reports)" in drill
    assert "'feedback_idempotency_tombstones'" in drill


def _manifest_entries(path: Path) -> dict[str, str]:
    return {
        version: checksum
        for checksum, version in (
            line.split()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    }


def test_restore_manifests_match_each_database_engine() -> None:
    migrations = SERVER_ROOT / "migrations"
    canonical = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(migrations.glob("*.sql"))
    }
    overlays = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (SERVER_ROOT / "migrations-postgresql").glob("*.sql")
    }
    postgresql = canonical | overlays

    assert _manifest_entries(BACKUP_ROOT / "migration-manifest.sha256") == canonical
    assert (
        _manifest_entries(BACKUP_ROOT / "migration-manifest-postgresql.sha256")
        == postgresql
    )
    assert canonical["001_init.sql"] != postgresql["001_init.sql"]


def test_restore_smoke_rejects_an_applied_checksum_mismatch(tmp_path: Path) -> None:
    manifest = tmp_path / "migration-manifest.sha256"
    manifest.write_text(f"{'a' * 64}  001_init.sql\n", encoding="utf-8")
    binary_directory = tmp_path / "bin"
    binary_directory.mkdir()
    fake_psql = binary_directory / "psql"
    fake_psql.write_text(
        """#!/bin/sh
case "$*" in
  *"SELECT count(*) FROM noop_schema_migrations;"*)
    printf '1\\n'
    ;;
  *)
    query=$(cat)
    case "$query" in
      *"WHERE version = :'version'"*)
        printf '0\\n'
        ;;
      *)
        exit 99
        ;;
    esac
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_psql.chmod(0o755)

    result = _run_script(
        "restore-application-smoke.sh",
        "restored_test",
        env={
            "NOOP_MIGRATION_MANIFEST_DIRECTORY": str(tmp_path),
            "PATH": f"{binary_directory}:{os.environ['PATH']}",
        },
    )

    assert result.returncode == 65
    assert "restored migration checksum mismatch: 001_init.sql" in result.stderr


def test_restore_smoke_selects_postgresql_overlay_manifest(tmp_path: Path) -> None:
    binary_directory = tmp_path / "bin"
    binary_directory.mkdir()
    calls = tmp_path / "psql-calls"
    fake_psql = binary_directory / "psql"
    expected_migration_count = len(
        _manifest_entries(BACKUP_ROOT / "migration-manifest-postgresql.sha256")
    )
    fake_psql.write_text(
        f"""#!/bin/sh
printf '%s\\n' "$*" >>"{calls}"
case "$*" in
  *"SELECT count(*) FROM noop_schema_migrations;"*)
    printf '{expected_migration_count}\\n'
    ;;
  *"--file=-"*)
    cat >/dev/null
    printf '1\\n'
    ;;
  *)
    exit 0
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_psql.chmod(0o755)

    result = _run_script(
        "restore-application-smoke.sh",
        "restored_test",
        env={
            "NOOP_DATABASE_ENGINE": "postgresql",
            "NOOP_MIGRATION_MANIFEST_DIRECTORY": str(BACKUP_ROOT),
            "PATH": f"{binary_directory}:{os.environ['PATH']}",
        },
    )

    assert result.returncode == 0, result.stderr
    invoked = calls.read_text(encoding="utf-8")
    postgresql_checksum = hashlib.sha256(
        (SERVER_ROOT / "migrations-postgresql" / "001_init.sql").read_bytes()
    ).hexdigest()
    canonical_checksum = hashlib.sha256(
        (SERVER_ROOT / "migrations" / "001_init.sql").read_bytes()
    ).hexdigest()
    assert postgresql_checksum in invoked
    assert canonical_checksum not in invoked


def test_restore_smoke_rejects_manifest_from_other_engine() -> None:
    result = _run_script(
        "restore-application-smoke.sh",
        "restored_test",
        env={
            "NOOP_DATABASE_ENGINE": "postgresql",
            "NOOP_MIGRATION_MANIFEST_DIRECTORY": str(BACKUP_ROOT),
            "NOOP_MIGRATION_MANIFEST": str(BACKUP_ROOT / "migration-manifest.sha256"),
        },
    )

    assert result.returncode == 66
    assert (
        "migration manifest does not match NOOP_DATABASE_ENGINE=postgresql"
        in result.stderr
    )
