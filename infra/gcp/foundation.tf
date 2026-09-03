resource "google_artifact_registry_repository" "containers" {
  project       = var.project_id
  location      = var.region
  repository_id = local.prefix
  description   = "Immutable NOOP synthetic staging container images"
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"
  labels        = local.labels

  docker_config {
    immutable_tags = true
  }

  depends_on = [google_project_service.required]
}

resource "google_kms_key_ring" "health_data" {
  project  = var.project_id
  name     = "${local.prefix}-health-data"
  location = var.region

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "raw_chunks" {
  name                       = "${local.prefix}-raw-chunks"
  key_ring                   = google_kms_key_ring.health_data.id
  purpose                    = "ENCRYPT_DECRYPT"
  rotation_period            = "7776000s"
  destroy_scheduled_duration = "2592000s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gcs_raw_chunks" {
  crypto_key_id = google_kms_crypto_key.raw_chunks.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_bucket" "raw_chunks" {
  project                     = var.project_id
  name                        = local.raw_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.raw_chunks.id
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.raw_retention_days
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_raw_chunks]
}

resource "google_storage_bucket" "build_source" {
  project                     = var.project_id
  name                        = "${var.project_id}-noop-build-${var.environment}"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 7
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_pubsub_topic" "raw_uploads" {
  project                    = var.project_id
  name                       = "${local.prefix}-raw-uploads"
  message_retention_duration = "86400s"
  labels                     = local.labels

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [google_project_service.required]
}

resource "google_pubsub_topic_iam_member" "gcs_raw_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.raw_uploads.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_notification" "raw_finalize" {
  bucket             = google_storage_bucket.raw_chunks.name
  payload_format     = "JSON_API_V1"
  topic              = google_pubsub_topic.raw_uploads.id
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "v1/"

  depends_on = [google_pubsub_topic_iam_member.gcs_raw_publisher]
}

resource "google_pubsub_subscription" "raw_processor" {
  project                    = var.project_id
  name                       = "${local.prefix}-raw-processor"
  topic                      = google_pubsub_topic.raw_uploads.id
  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  labels                     = local.labels

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

resource "google_bigquery_dataset" "analytics" {
  project                    = var.project_id
  dataset_id                 = "noop_${var.environment}"
  friendly_name              = "NOOP synthetic staging"
  description                = "Synthetic-only derived analytics; no mobile clients are connected."
  location                   = var.region
  delete_contents_on_destroy = false
  max_time_travel_hours      = 48
  labels                     = local.labels

  depends_on = [google_project_service.required]
}
