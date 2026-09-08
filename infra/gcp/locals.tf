locals {
  prefix = "noop-${var.environment}"
  migration_image = (
    var.migration_image != null ? var.migration_image : var.runtime_image
  )
  migration_workloads_enabled = (
    var.enable_managed_database && local.migration_image != null
  )
  runtime_workloads_enabled = (
    var.enable_managed_database && var.runtime_image != null
  )
  migration_release_marker = (
    local.migration_image == null
    ? "disabled"
    : substr(sha256(local.migration_image), 0, 16)
  )
  runtime_release_marker = (
    var.runtime_image == null
    ? "disabled"
    : substr(sha256(var.runtime_image), 0, 16)
  )
  raw_bucket_name = coalesce(
    var.raw_bucket_name,
    "${var.project_id}-noop-raw-${var.environment}",
  )

  labels = {
    app         = "noop"
    environment = var.environment
    data_class  = "synthetic"
    managed_by  = "opentofu"
  }

  required_services = toset([
    "apikeys.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerscanning.googleapis.com",
    "firebase.googleapis.com",
    "firebaseappcheck.googleapis.com",
    "firebaseinstallations.googleapis.com",
    "fcm.googleapis.com",
    "iamcredentials.googleapis.com",
    "identitytoolkit.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "ondemandscanning.googleapis.com",
    "playintegrity.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "securetoken.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
}
