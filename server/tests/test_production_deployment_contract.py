from __future__ import annotations

from pathlib import Path


SERVER_ROOT = Path(__file__).resolve().parents[1]


def test_compose_separates_migrations_api_and_paging_worker() -> None:
    compose = (SERVER_ROOT / "compose.yaml").read_text(encoding="utf-8")

    assert "\n  migrate:\n" in compose
    assert 'command: ["python", "-m", "app.migrate"]' in compose
    assert "\n  api:\n" in compose
    assert 'NOOP_SAFETY_WORKER_ENABLED: "false"' in compose
    assert "\n  safety-worker:\n" in compose
    assert 'command: ["python", "-m", "app.safety_worker"]' in compose
    assert "stop_grace_period: ${NOOP_SAFETY_WORKER_STOP_GRACE_PERIOD:-45s}" in compose
    assert 'test: ["CMD", "python", "-m", "app.worker_health"]' in compose
    assert compose.count('NOOP_RUN_MIGRATIONS: "false"') == 2
    assert "<<: *noop-database-environment" in compose
    assert compose.count("\n  NOOP_API_TOKEN:") == 1
    assert "NOOP_MIGRATION_DATABASE_URL" in compose
    assert "NOOP_API_DATABASE_URL" in compose
    assert "NOOP_SAFETY_WORKER_DATABASE_URL" in compose
    assert "NOOP_RATE_LIMIT_PROVIDER_CALLBACK_PRE_AUTH_REQUESTS_PER_MINUTE" in compose
    assert "NOOP_RATE_LIMIT_PROVIDER_CALLBACK_REQUESTS_PER_MINUTE" in compose
    assert "NOOP_AUTH_MODE" in compose
    assert "NOOP_EXPORT_MAX_ROWS" in compose
    assert "NOOP_FORWARDED_ALLOW_IPS" in compose
    assert "NOOP_SAFETY_INCIDENT_RETENTION_DAYS" in compose
    assert "NOOP_SAFETY_CONTACT_RETENTION_DAYS" in compose
    backup = compose.split("\n  backup:\n", maxsplit=1)[1]
    assert "migrate:" in backup
    assert "condition: service_completed_successfully" in backup
    assert "NOOP_BACKUP_DB_USER" in backup
    assert "NOOP_BACKUP_DB_PASSWORD" in backup


def test_production_server_disables_raw_access_logs_with_signed_query_tokens() -> None:
    dockerfile = (SERVER_ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "--no-access-log" in dockerfile
    assert "NOOP_FORWARDED_ALLOW_IPS=127.0.0.1" in dockerfile
    assert '--forwarded-allow-ips \\"$NOOP_FORWARDED_ALLOW_IPS\\"' in dockerfile
    assert "--forwarded-allow-ips=127.0.0.1" not in dockerfile


def test_capacity_runbook_keeps_tenancy_and_evidence_gates_explicit() -> None:
    runbook = (SERVER_ROOT / "PRODUCTION_OPERATIONS.md").read_text(encoding="utf-8")

    assert "NOOP_AUTH_MODE=shared" in runbook
    assert "installation credential" in runbook
    assert "remains blocked" in runbook
    assert "NOOP_DB_STATEMENT_CACHE_SIZE=0" in runbook
    assert "NOOP_MIGRATION_DATABASE_URL" in runbook
    assert "NOOP_API_DATABASE_URL" in runbook
    assert "NOOP_SAFETY_WORKER_DATABASE_URL" in runbook
    assert "post-signature application budget" in runbook
    assert "NOOP_LOAD_ALLOW_WRITES=I_UNDERSTAND_THIS_IS_DESTRUCTIVE" in runbook
    assert "k6-mixed-adversarial.js" in runbook
    assert "zero accepted cross-tenant operations" in runbook
    assert "No run has been" in runbook
    assert "10,000-user capacity" in runbook
    assert "NOOP_FORWARDED_ALLOW_IPS" in runbook
    assert "cannot safely use arbitrary" in runbook
    assert "privacy-minimized NOOP-operated relay" in runbook
    assert "independently signed iOS builds" in runbook
    assert "A2P 10DLC" in runbook
    assert "Fall Response stays inert" in runbook


def test_capacity_script_is_fail_closed_and_has_latency_thresholds() -> None:
    script = (SERVER_ROOT / "load" / "k6-sync.js").read_text(encoding="utf-8")

    assert "I_UNDERSTAND_THIS_IS_DESTRUCTIVE" in script
    assert "NOOP_LOAD_RATE_LIMITS_RAISED" in script
    assert "NOOP_LOAD_SAMPLES_PER_SYNC" in script
    assert "NOOP_LOAD_CREDENTIALS_FILE" in script
    assert "`ios:${installationId}:load-${__VU}-strap`" in script
    assert 'dropped_iterations: ["count==0"]' in script
    assert 'http_req_failed: ["rate<0.001"]' in script
    assert '"p(95)<500"' in script
    assert '"p(99)<1000"' in script


def test_mixed_capacity_and_tenant_adversarial_script_is_fail_closed() -> None:
    script = (SERVER_ROOT / "load" / "k6-mixed-adversarial.js").read_text(
        encoding="utf-8"
    )

    assert "mixed_traffic" in script
    assert "tenant_adversarial" in script
    assert "I_CONFIRMED_THIS_TARGET_IS_DISPOSABLE" in script
    assert "I_UNDERSTAND_THIS_IS_DESTRUCTIVE" in script
    assert (
        "I_UNDERSTAND_CROSS_TENANT_DELETE_PROBES_CAN_DESTROY_A_BROKEN_TARGET" in script
    )
    assert 'isolation_violations: ["count==0"]' in script
    assert 'dropped_iterations: ["count==0"]' in script
    assert 'http_req_failed: ["rate<0.001"]' in script
    assert '"p(95)<500"' in script
    assert '"p(99)<1000"' in script
    assert "foreign_latest" in script
    assert "foreign_export" in script
    assert "foreign_delete" in script
    assert "forged_sync" in script
    assert "http.expectedStatuses(404)" in script
    assert "http.expectedStatuses(403)" in script
