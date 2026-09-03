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
  description = "Pull subscription reserved for the future processor."
  value       = google_pubsub_subscription.raw_processor.id
}

output "service_accounts" {
  description = "Runtime identities; no user-managed keys are created."
  value = {
    api       = google_service_account.api.email
    builder   = google_service_account.builder.email
    processor = google_service_account.processor.email
    migration = google_service_account.migration.email
  }
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
  description = "One-shot migration job name, or null until a runtime image is selected."
  value = local.runtime_workloads_enabled ? (
    google_cloud_run_v2_job.migrate[0].name
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
