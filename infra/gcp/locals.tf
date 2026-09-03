locals {
  prefix = "noop-${var.environment}"
  runtime_workloads_enabled = (
    var.enable_managed_database && var.runtime_image != null
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
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerscanning.googleapis.com",
    "iamcredentials.googleapis.com",
    "identitytoolkit.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "ondemandscanning.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
}
