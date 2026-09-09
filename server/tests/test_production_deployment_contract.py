from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


SERVER_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SERVER_ROOT.parent


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
    assert (
        "NOOP_SAFETY_INCIDENT_TTL_SECONDS: ${NOOP_SAFETY_INCIDENT_TTL_SECONDS:-43200}"
    ) in compose
    assert "NOOP_SAFETY_ESCALATION_ROUNDS" in compose
    assert "NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS" in compose
    assert "NOOP_SAFETY_AUTOMATIC_PAGING_ENABLED" in compose
    assert "NOOP_SAFETY_APPROVED_FALL_DETECTORS" in compose
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
    assert "RUN apk upgrade --no-cache" in dockerfile
    assert "python -m pip uninstall --yes pip" in dockerfile
    assert "rm -rf /usr/local/lib/python3.12/ensurepip" in dockerfile
    assert "FROM scratch" in dockerfile
    assert "COPY --from=builder / /" in dockerfile


def test_gcp_runtime_is_private_pinned_and_migration_gated() -> None:
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )
    outputs = (REPOSITORY_ROOT / "infra" / "gcp" / "outputs.tf").read_text(
        encoding="utf-8"
    )
    variables = (REPOSITORY_ROOT / "infra" / "gcp" / "variables.tf").read_text(
        encoding="utf-8"
    )
    migration_script = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "run-migration.sh"
    ).read_text(encoding="utf-8")
    verifier = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "verify-private-runtime.sh"
    ).read_text(encoding="utf-8")

    assert 'ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"' in runtime
    assert "allAuthenticatedUsers" not in runtime
    assert runtime.count('member   = "allUsers"') == 1
    managed_api_binding = runtime.split(
        'resource "google_cloud_run_v2_service_iam_member" "managed_api_public"',
        maxsplit=1,
    )[1].split(
        'resource "google_cloud_run_v2_service" "managed_processor"',
        maxsplit=1,
    )[0]
    assert 'member   = "allUsers"' in managed_api_binding
    managed_processor = runtime.split(
        'resource "google_cloud_run_v2_service" "managed_processor"',
        maxsplit=1,
    )[1].split(
        'resource "google_cloud_run_v2_service_iam_member" '
        '"managed_processor_event_invoker"',
        maxsplit=1,
    )[0]
    assert 'ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"' in (
        managed_processor
    )
    assert "allUsers" not in managed_processor
    assert 'command = ["python"]' in runtime
    assert 'args    = ["-m", "app.migrate"]' in runtime
    migration = runtime.split(
        'resource "google_cloud_run_v2_job" "migrate"',
        maxsplit=1,
    )[1].split(
        'resource "google_cloud_run_v2_service" "api"',
        maxsplit=1,
    )[0]
    assert 'name  = "NOOP_SAFETY_WORKER_ENABLED"' in migration
    assert 'value = "false"' in migration
    assert 'name  = "NOOP_RUN_MIGRATIONS"' in runtime
    assert 'value = "false"' in runtime
    assert 'path = "/readyz"' in runtime
    assert "min_instance_count = 0" in runtime
    assert "max_instance_count = 2" in runtime
    assert "var.runtime_image != null" in variables
    assert "@sha256:" in variables
    assert 'variable "migration_image"' in variables
    assert "migration_image or runtime_image" in migration_script
    assert "hashlib.sha256(image.encode" in migration_script
    assert "local.migration_workloads_enabled" in runtime
    assert "image   = local.migration_image" in runtime
    assert 'resource "terraform_data" "migration_execution"' in runtime
    assert "triggers_replace = [local.migration_release_marker]" in runtime
    assert runtime.count("terraform_data.migration_execution,") == 5
    assert "NOOP_MIGRATION_RELEASE_MARKER" in runtime
    assert runtime.count('name  = "NOOP_RUNTIME_RELEASE"') == 6
    assert "value = local.migration_release_marker" in runtime
    assert runtime.count("value = local.runtime_release_marker") == 5
    assert 'output "migration_release_marker"' in outputs
    assert "successful migration execution" in verifier
    assert "Managed API has a broad invoker grant." in verifier
    assert "managed API digest-pinned image" in verifier
    assert 'variable "enable_managed_runtime"' in variables
    assert "var.enable_managed_runtime" in runtime
    assert "var.enable_managed_runtime" in variables
    assert "var.enable_public_managed_api" in runtime


def test_gcp_managed_identity_is_attested_and_uses_restricted_keys() -> None:
    identity = (REPOSITORY_ROOT / "infra" / "gcp" / "identity.tf").read_text(
        encoding="utf-8"
    )
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )
    variables = (REPOSITORY_ROOT / "infra" / "gcp" / "variables.tf").read_text(
        encoding="utf-8"
    )

    assert identity.count('resource "google_apikeys_key"') == 3
    assert "ios_key_restrictions" in identity
    assert "allowed_bundle_ids = [var.managed_apple_bundle_id]" in identity
    assert "android_key_restrictions" in identity
    assert "package_name     = var.managed_android_package_name" in identity
    assert (
        'sha1_fingerprint = lower(replace(allowed_applications.value, ":", ""))'
        in identity
    )
    assert identity.count('"identitytoolkit.googleapis.com",') == 2
    assert 'service = "identitytoolkit.googleapis.com"' in identity
    assert identity.count('"firebaseappcheck.googleapis.com",') == 2
    assert identity.count('"firebaseinstallations.googleapis.com",') == 2
    assert identity.count('"securetoken.googleapis.com",') == 2
    assert "google_firebase_app_check_app_attest_config" in identity
    assert "google_firebase_app_check_play_integrity_config" in identity
    assert 'service_id       = "identitytoolkit.googleapis.com"' in identity
    assert "enforcement_mode = var.managed_auth_app_check_enforcement" in identity
    assert 'default     = "com.noopapp.noop"' in variables
    assert 'default     = "com.noop.whoop.staging"' in variables
    assert 'var.managed_auth_app_check_enforcement == "ENFORCED"' in variables
    assert 'name  = "NOOP_MANAGED_PROJECT_ID"' in runtime
    assert "value = var.project_id" in runtime
    assert 'name  = "NOOP_MANAGED_PROJECT_NUMBER"' in runtime
    assert "value = data.google_project.current.number" in runtime
    assert 'name  = "NOOP_MANAGED_APPLE_APP_ID"' in runtime
    assert "value = google_firebase_apple_app.staging[0].app_id" in runtime
    assert 'name  = "NOOP_MANAGED_ANDROID_APP_ID"' in runtime
    assert "value = google_firebase_android_app.staging[0].app_id" in runtime


def test_gcp_managed_safety_push_is_private_encrypted_and_state_safe() -> None:
    iam = (REPOSITORY_ROOT / "infra" / "gcp" / "iam.tf").read_text(encoding="utf-8")
    locals_file = (REPOSITORY_ROOT / "infra" / "gcp" / "locals.tf").read_text(
        encoding="utf-8"
    )
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )
    configure_script = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "configure-runtime-secrets.sh"
    ).read_text(encoding="utf-8")

    assert '"fcm.googleapis.com"' in locals_file
    assert "cloudmessaging.messages.create" in iam
    assert "firebasecloudmessaging.admin" not in iam
    assert "var.enable_managed_runtime ? 1 : 0" in iam
    assert 'secret_id = "${local.prefix}-managed-push-token-secret"' in iam
    assert 'secret_id = "${local.prefix}-managed-push-token-previous-secret"' in iam
    assert "managed_api_push_token_secret" in iam
    assert "managed_lifecycle_push_token_secret" in iam
    assert "managed_api_push_token_previous_secret" in iam
    assert "managed_lifecycle_push_token_previous_secret" in iam
    assert 'name  = "NOOP_MANAGED_PUSH_ENABLED"' in runtime
    assert 'name  = "NOOP_MANAGED_PUSH_RETRY_ENABLED"' in runtime
    assert 'name = "NOOP_MANAGED_PUSH_TOKEN_SECRET"' in runtime
    assert 'name = "NOOP_MANAGED_PUSH_TOKEN_PREVIOUS_SECRET"' in runtime
    assert runtime.count('name  = "NOOP_MANAGED_PUSH_TOKEN_WRITE_VERSION"') == 2
    assert "value = var.managed_push_token_write_version" in runtime
    assert 'variable "managed_push_token_write_version"' in (
        REPOSITORY_ROOT / "infra" / "gcp" / "variables.tf"
    ).read_text(encoding="utf-8")
    assert "managed_api_push_sender" in runtime
    assert "managed_lifecycle_push_sender" in runtime
    assert "managed_api_push_token_secret" in runtime
    assert "managed_api_push_token_previous_secret" in runtime
    assert "managed_lifecycle_push_token_secret" in runtime
    assert "managed_lifecycle_push_token_previous_secret" in runtime
    assert "managed_push_token_secret=" in configure_script
    assert "managed_push_token_previous_secret=" in configure_script
    assert "openssl rand -hex 32" in configure_script
    assert "--data-file=-" in configure_script


def test_private_staging_smoke_covers_managed_safety_without_real_push_targets() -> (
    None
):
    smoke = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "smoke-managed-runtime.py"
    ).read_text(encoding="utf-8")

    assert "self._exercise_safety()" in smoke
    assert "PASS three fictional phone OTP identities" in smoke
    assert "self._provision_pilot_claims()" in smoke
    assert '"noop_managed_pilot"' in smoke
    assert "account.pilot_claim_enabled = enabled" in smoke
    assert "account.managed_enrolled = True" in smoke
    assert smoke.index("account.managed_enrolled = True") < smoke.index(
        'boundary = response.get("product_boundary", {})'
    )
    assert "synthetic cleanup requires review" in smoke
    assert "if not cleanup_succeeded:" in smoke
    assert "managed {operation} request returned HTTP" in smoke
    assert "owner, outsider = self.accounts[:2]" in smoke
    assert "FAIL unexpected managed runtime smoke failure" in smoke
    assert "/v1/managed/safety/invites" in smoke
    assert "/v1/managed/safety/requests" in smoke
    assert "/v1/managed/safety/contacts" in smoke
    assert "/v1/managed/safety/incidents" in smoke
    assert "latest-only location" in smoke
    assert "/v1/managed/push/installations/current" not in smoke

    path = REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "smoke-managed-runtime.py"
    spec = importlib.util.spec_from_file_location("noop_managed_smoke_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    account = module.SyntheticAccount(
        phone="+16505550000",
        code="000000",
        platform="ios",
        installation_id="ios-staging-cleanup-test",
        installation_token="noopm_" + ("a" * 43),
        id_token="synthetic-token",
        local_id="synthetic-local-id",
    )
    runner = object.__new__(module.ManagedStagingSmoke)
    runner.accounts = [account]
    runner.access_token = "synthetic-access-token"
    runner.project_id = "noop-synthetic-test"
    runner.identity_config_changed = False
    runner.original_test_numbers = {}
    runner.debug_resource = ""

    def fail_identity_cleanup(*_args: object, **_kwargs: object) -> None:
        raise module.SmokeFailure("synthetic cleanup failure")

    runner._identity_admin_request = fail_identity_cleanup
    assert runner._best_effort_cleanup() is False
    assert account.local_id == "synthetic-local-id"


def test_mobile_managed_push_is_consent_gated_and_explicit() -> None:
    android_manifest = (
        REPOSITORY_ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    ).read_text(encoding="utf-8")
    android_service = (
        REPOSITORY_ROOT
        / "android"
        / "app"
        / "src"
        / "main"
        / "java"
        / "com"
        / "noop"
        / "managed"
        / "ManagedCloudService.kt"
    ).read_text(encoding="utf-8")
    ios_project = (REPOSITORY_ROOT / "project.yml").read_text(encoding="utf-8")
    ios_plist = (REPOSITORY_ROOT / "StrandiOS" / "Resources" / "Info.plist").read_text(
        encoding="utf-8"
    )
    ios_service = (
        REPOSITORY_ROOT / "StrandiOS" / "System" / "ManagedCloudService.swift"
    ).read_text(encoding="utf-8")

    firebase_provider = android_manifest.split(
        'android:name="com.google.firebase.provider.FirebaseInitProvider"',
        maxsplit=1,
    )[1].split("/>", maxsplit=1)[0]
    assert 'tools:node="remove"' in firebase_provider
    messaging_metadata = android_manifest.split(
        'android:name="firebase_messaging_auto_init_enabled"',
        maxsplit=1,
    )[1].split("/>", maxsplit=1)[0]
    assert 'android:value="false"' in messaging_metadata
    assert "messaging.isAutoInitEnabled = true" in android_service
    assert "messaging.isAutoInitEnabled = false" in android_service
    assert "FirebaseMessagingAutoInitEnabled: false" in ios_project
    assert "<key>FirebaseMessagingAutoInitEnabled</key>" in ios_plist
    assert (
        ios_plist.split(
            "<key>FirebaseMessagingAutoInitEnabled</key>",
            maxsplit=1,
        )[1]
        .lstrip()
        .startswith("<false/>")
    )
    assert "Messaging.messaging().isAutoInitEnabled = true" in ios_service
    assert "Messaging.messaging().isAutoInitEnabled = false" in ios_service


def test_gcp_managed_processor_accepts_only_authenticated_pubsub_push() -> None:
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )
    foundation = (REPOSITORY_ROOT / "infra" / "gcp" / "foundation.tf").read_text(
        encoding="utf-8"
    )

    processor = runtime.split(
        'resource "google_cloud_run_v2_service" "managed_processor"',
        maxsplit=1,
    )[1].split(
        'resource "google_cloud_run_v2_service_iam_member" '
        '"managed_processor_event_invoker"',
        maxsplit=1,
    )[0]
    invoker = runtime.split(
        'resource "google_cloud_run_v2_service_iam_member" '
        '"managed_processor_event_invoker"',
        maxsplit=1,
    )[1].split(
        'resource "google_cloud_run_v2_job" "managed_lifecycle"',
        maxsplit=1,
    )[0]

    assert 'ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"' in processor
    assert "allUsers" not in processor
    assert 'role     = "roles/run.invoker"' in invoker
    assert (
        'member   = "serviceAccount:${google_service_account.'
        'managed_event_invoker.email}"'
    ) in invoker
    assert (
        'push_endpoint = "${google_cloud_run_v2_service.'
        'managed_processor[0].uri}/v1/events/storage-finalized"'
    ) in foundation
    assert (
        "service_account_email = google_service_account.managed_event_invoker.email"
    ) in foundation
    assert (
        "audience              = google_cloud_run_v2_service.managed_processor[0].uri"
        in (foundation)
    )


def test_gcp_lifecycle_identity_can_only_delete_firebase_users() -> None:
    iam = (REPOSITORY_ROOT / "infra" / "gcp" / "iam.tf").read_text(encoding="utf-8")
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )

    role = iam.split(
        'resource "google_project_iam_custom_role" "managed_identity_deleter"',
        maxsplit=1,
    )[1].split(
        'resource "google_project_iam_member" "managed_lifecycle_identity_deleter"',
        maxsplit=1,
    )[0]
    assert 'permissions = ["firebaseauth.users.delete"]' in role
    assert "firebaseauth.users.get" not in role
    assert "roles/firebaseauth.admin" not in iam
    assert 'name  = "NOOP_MANAGED_PROJECT_ID"' in runtime
    assert "google_project_iam_member.managed_lifecycle_identity_deleter" in (runtime)


def test_gcp_managed_runtime_cannot_list_health_objects() -> None:
    iam = (REPOSITORY_ROOT / "infra" / "gcp" / "iam.tf").read_text(encoding="utf-8")

    reader = iam.split(
        'resource "google_project_iam_custom_role" "managed_object_reader"',
        maxsplit=1,
    )[1].split(
        'resource "google_storage_bucket_iam_member" "managed_api_raw_reader"',
        maxsplit=1,
    )[0]
    lifecycle = iam.split(
        'resource "google_project_iam_custom_role" "managed_object_deleter"',
        maxsplit=1,
    )[1].split(
        'resource "google_storage_bucket_iam_member" "managed_lifecycle_raw_deleter"',
        maxsplit=1,
    )[0]

    assert 'permissions = ["storage.objects.get"]' in reader
    assert '"storage.objects.get"' in lifecycle
    assert '"storage.objects.delete"' in lifecycle
    assert "storage.objects.list" not in reader
    assert "storage.objects.list" not in lifecycle
    assert "roles/storage.objectViewer" not in iam
    assert iam.count("google_project_iam_custom_role.managed_object_reader.id") == 2


def test_gcp_database_has_staging_recovery_and_encryption_guards() -> None:
    runtime = (REPOSITORY_ROOT / "infra" / "gcp" / "runtime.tf").read_text(
        encoding="utf-8"
    )

    assert 'database_version    = "POSTGRES_16"' in runtime
    assert "encryption_key_name = google_kms_crypto_key.cloud_sql[0].id" in runtime
    assert "deletion_protection = true" in runtime
    assert "deletion_protection_enabled = true" in runtime
    assert "point_in_time_recovery_enabled = true" in runtime
    assert "transaction_log_retention_days = 7" in runtime
    assert 'ssl_mode     = "ENCRYPTED_ONLY"' in runtime


def test_gcp_secrets_stay_out_of_opentofu_state() -> None:
    infrastructure = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (REPOSITORY_ROOT / "infra" / "gcp").glob("*.tf")
    )
    configure_script = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "configure-runtime-secrets.sh"
    ).read_text(encoding="utf-8")
    database_helper = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "configure-database-secret.py"
    ).read_text(encoding="utf-8")

    assert "google_secret_manager_secret_version" not in infrastructure
    assert "secret_data" not in infrastructure
    assert "--password=" not in configure_script
    assert "secrets.token_hex(32)" in database_helper
    assert "password" not in database_helper.split("parser.add_argument", maxsplit=1)[1]
    assert "--data-file=-" in configure_script


def test_gcp_provider_charges_user_adc_quota_to_the_managed_project() -> None:
    providers = (REPOSITORY_ROOT / "infra" / "gcp" / "versions.tf").read_text(
        encoding="utf-8"
    )

    assert providers.count("billing_project       = var.project_id") == 2
    assert providers.count("user_project_override = true") == 2


def test_gcp_custom_builder_uses_the_regional_short_retention_log_bucket() -> None:
    iam = (REPOSITORY_ROOT / "infra" / "gcp" / "iam.tf").read_text(encoding="utf-8")
    locals_file = (REPOSITORY_ROOT / "infra" / "gcp" / "locals.tf").read_text(
        encoding="utf-8"
    )
    build_script = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "build-runtime-image.sh"
    ).read_text(encoding="utf-8")

    assert 'role   = "roles/storage.objectAdmin"' in iam
    assert 'role   = "roles/storage.bucketViewer"' in iam
    assert '--gcs-log-dir="gs://${source_bucket}/logs"' in build_script
    assert '"containerscanning.googleapis.com"' in locals_file
    assert '"ondemandscanning.googleapis.com"' in locals_file


def test_gcp_runtime_scan_is_digest_scoped_and_fails_on_material_findings() -> None:
    scan_script = (
        REPOSITORY_ROOT / "infra" / "gcp" / "scripts" / "scan-runtime-image.sh"
    ).read_text(encoding="utf-8")

    assert "api@sha256:" in scan_script
    assert "--remote" in scan_script
    assert '"effectiveSeverity"' in scan_script
    assert '{"CRITICAL", "HIGH"}' in scan_script
    assert "raise SystemExit(1)" in scan_script


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
