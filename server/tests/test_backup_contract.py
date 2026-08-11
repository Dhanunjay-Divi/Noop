from __future__ import annotations

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
