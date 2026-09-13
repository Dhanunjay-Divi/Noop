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
    smoke_script = (BACKUP_ROOT / "restore-application-smoke.sh").read_text(
        encoding="utf-8"
    )
    assert "--file=- <<'SQL'" in smoke_script
    assert "btrim(checksum) = :'checksum'" in smoke_script
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
    assert "managed_document_contract_v2_readiness" in smoke
    assert "content contract activated before client readiness" in smoke
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


def test_restore_manifest_matches_every_immutable_migration() -> None:
    entries = {}
    manifest = BACKUP_ROOT / "migration-manifest.sha256"
    for line in manifest.read_text(encoding="utf-8").splitlines():
        checksum, version = line.split()
        entries[version] = checksum

    migrations = SERVER_ROOT / "migrations"
    expected = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(migrations.glob("*.sql"))
    }

    assert entries == expected


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
            "NOOP_MIGRATION_MANIFEST": str(manifest),
            "PATH": f"{binary_directory}:{os.environ['PATH']}",
        },
    )

    assert result.returncode == 65
    assert "restored migration checksum mismatch: 001_init.sql" in result.stderr
