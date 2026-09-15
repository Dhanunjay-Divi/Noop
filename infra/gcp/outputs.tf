output "artifact_registry_repository" {
  description = "Regional immutable Docker repository."
  value       = google_artifact_registry_repository.containers.id
}

output "project_id" {
  description = "Configured synthetic staging project."
  value       = var.project_id
}

output "region" {
  description = "Configured staging region."
  value       = var.region
}

output "raw_bucket" {
  description = "Synthetic raw-chunk bucket. Do not upload real health data."
  value       = google_storage_bucket.raw_chunks.name
}

output "feedback_bucket" {
  description = "Private bounded-retention app-feedback bucket."
  value       = google_storage_bucket.feedback.name
}

output "builder_service_account" {
  description = "Dedicated Cloud Build identity."
  value       = google_service_account.builder.email
}

output "build_source_bucket" {
  description = "Short-retention source bucket for Cloud Build."
  value       = google_storage_bucket.build_source.name
}

output "raw_upload_topic" {
  description = "Storage finalize event topic."
  value       = google_pubsub_topic.raw_uploads.id
}

output "raw_processor_subscription" {
  description = "Storage-finalize processor subscription."
  value       = google_pubsub_subscription.raw_processor.id
}

output "raw_processor_dead_letter_subscription" {
  description = "Retained storage-finalize events that exhausted delivery."
  value       = google_pubsub_subscription.raw_processor_dead_letter.id
}

output "service_accounts" {
  description = "Runtime identities; no user-managed keys are created."
  value = {
    api       = google_service_account.api.email
    builder   = google_service_account.builder.email
    managed   = google_service_account.managed_api.email
    processor = google_service_account.processor.email
    migration = google_service_account.migration.email
    lifecycle = google_service_account.managed_lifecycle.email
    scheduler = google_service_account.managed_scheduler.email
    feedback_lifecycle = (
      var.enable_feedback_lifecycle
      ? google_service_account.feedback_lifecycle[0].email
      : null
    )
    feedback_scheduler = (
      var.enable_feedback_lifecycle
      ? google_service_account.feedback_scheduler[0].email
      : null
    )
    event = google_service_account.managed_event_invoker.email
  }
}

output "ownership_api" {
  description = "IAM-only first-party band ownership authority when enabled; possession verification remains unavailable."
  value = var.enable_ownership_runtime ? {
    name            = google_cloud_run_v2_service.ownership_api[0].name
    uri             = google_cloud_run_v2_service.ownership_api[0].uri
    service_account = google_service_account.ownership_api[0].email
    public          = false
  } : null
}

output "managed_identity" {
  description = "Synthetic Firebase app identifiers, or null while managed identity is disabled."
  value = var.enable_managed_identity ? {
    project_number        = data.google_project.current.number
    android_app_id        = google_firebase_android_app.staging[0].app_id
    android_package       = var.managed_android_package_name
    android_api_key_uid   = google_apikeys_key.managed_android[0].uid
    apple_app_id          = google_firebase_apple_app.staging[0].app_id
    apple_bundle_id       = var.managed_apple_bundle_id
    apple_api_key_uid     = google_apikeys_key.managed_apple[0].uid
    lookup_api_key_uid    = google_apikeys_key.managed_identity_lookup[0].uid
    sms_regions           = var.managed_sms_regions
    app_check_registered  = var.enable_managed_app_check
    auth_app_check_policy = var.managed_auth_app_check_enforcement
  } : null
}

output "public_managed_api" {
  description = "Firebase-authenticated synthetic NOOP+ endpoint, or null while disabled."
  value = var.enable_public_managed_api ? {
    name = google_cloud_run_v2_service.managed_api[0].name
    uri  = google_cloud_run_v2_service.managed_api[0].uri
  } : null
}

output "managed_api" {
  description = "IAM-only or public managed API endpoint when the managed runtime is enabled."
  value = var.enable_managed_runtime ? {
    name   = google_cloud_run_v2_service.managed_api[0].name
    uri    = google_cloud_run_v2_service.managed_api[0].uri
    public = var.enable_public_managed_api
  } : null
}

output "feedback_public_ready" {
  description = "True only when feedback ingestion is publicly reachable and every stack-owned feedback control is enabled."
  value = (
    var.enable_feedback_ingestion
    && var.enable_public_managed_api
    && var.enable_feedback_lifecycle
    && var.feedback_external_abuse_gate_approved
    && var.enable_managed_runtime
    && var.enable_managed_identity
    && var.enable_managed_app_check
    && var.managed_auth_app_check_enforcement == "ENFORCED"
    && var.enable_managed_database
    && var.runtime_image != null
    && var.feedback_capability_primary_key_version != var.feedback_capability_previous_key_version
    && contains(
      [
        "legacy",
        var.feedback_capability_primary_key_version,
        var.feedback_capability_previous_key_version,
      ],
      var.feedback_capability_write_version,
    )
  )
}

output "managed_lifecycle_job" {
  description = "Scheduled NOOP+ lifecycle job name when enabled."
  value = var.enable_managed_runtime ? (
    google_cloud_run_v2_job.managed_lifecycle[0].name
  ) : null
}

output "feedback_lifecycle_job" {
  description = "Independent feedback cleanup and retention job name when enabled."
  value = var.enable_feedback_lifecycle ? (
    google_cloud_run_v2_job.feedback_lifecycle[0].name
  ) : null
}

output "managed_processor" {
  description = "IAM-protected managed object processor when enabled."
  value = var.enable_managed_runtime ? {
    name = google_cloud_run_v2_service.managed_processor[0].name
    uri  = google_cloud_run_v2_service.managed_processor[0].uri
  } : null
}

output "bigquery_dataset" {
  description = "Synthetic derived-data dataset."
  value       = google_bigquery_dataset.analytics.id
}

output "runtime_ready" {
  description = "True only when the private API resource is enabled; mobile launch gates remain separate."
  value       = var.enable_private_api
}

output "managed_database" {
  description = "Synthetic staging database identity, or null when disabled."
  value = var.enable_managed_database ? {
    instance        = google_sql_database_instance.primary[0].name
    connection_name = google_sql_database_instance.primary[0].connection_name
    database        = google_sql_database.noop[0].name
  } : null
}

output "database_instance" {
  description = "Cloud SQL instance name, or null when disabled."
  value = var.enable_managed_database ? (
    google_sql_database_instance.primary[0].name
  ) : null
}

output "database_connection_name" {
  description = "Cloud SQL connector name, or null when disabled."
  value = var.enable_managed_database ? (
    google_sql_database_instance.primary[0].connection_name
  ) : null
}

output "migration_job" {
  description = "One-shot migration job name, or null until a migration or runtime image is selected."
  value = local.migration_workloads_enabled ? (
    google_cloud_run_v2_job.migrate[0].name
  ) : null
}

output "migration_release_marker" {
  description = "Non-secret marker binding the configured migration job to its immutable image."
  value = local.migration_workloads_enabled ? (
    local.migration_release_marker
  ) : null
}

output "private_api" {
  description = "IAM-protected internal API identity, or null when disabled."
  value = var.enable_private_api ? {
    name    = google_cloud_run_v2_service.api[0].name
    uri     = google_cloud_run_v2_service.api[0].uri
    ingress = google_cloud_run_v2_service.api[0].ingress
  } : null
}

output "private_api_name" {
  description = "Internal API service name, or null when disabled."
  value = var.enable_private_api ? (
    google_cloud_run_v2_service.api[0].name
  ) : null
}
