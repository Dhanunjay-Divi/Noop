resource "google_service_account" "api" {
  project      = var.project_id
  account_id   = "${local.prefix}-api"
  display_name = "NOOP staging API"
  description  = "Private synthetic staging API identity"
}

resource "google_service_account" "managed_api" {
  project      = var.project_id
  account_id   = "${local.prefix}-managed-api"
  display_name = "NOOP+ staging managed API"
  description  = "Firebase-authenticated synthetic storage API"
}

resource "google_service_account" "ownership_api" {
  count = var.enable_ownership_runtime ? 1 : 0

  project      = var.project_id
  account_id   = "${local.prefix}-ownership"
  display_name = "NOOP Band ownership staging API"
  description  = "Identity and ownership authority without health-data access"
}

resource "google_service_account" "processor" {
  project      = var.project_id
  account_id   = "${local.prefix}-processor"
  display_name = "NOOP staging processor"
  description  = "Synthetic raw-chunk processing identity"
}

resource "google_service_account" "managed_lifecycle" {
  project      = var.project_id
  account_id   = "${local.prefix}-lifecycle"
  display_name = "NOOP+ staging lifecycle"
  description  = "Expires managed reservations and deletes retained objects"
}

resource "google_service_account" "managed_scheduler" {
  project      = var.project_id
  account_id   = "${local.prefix}-scheduler"
  display_name = "NOOP+ staging scheduler"
  description  = "Invokes the managed-storage lifecycle job"
}

resource "google_service_account" "managed_event_invoker" {
  project      = var.project_id
  account_id   = "${local.prefix}-event-invoker"
  display_name = "NOOP+ staging event invoker"
  description  = "Carries Pub/Sub OIDC identity to the managed processor"
}

resource "google_service_account" "migration" {
  project      = var.project_id
  account_id   = "${local.prefix}-migration"
  display_name = "NOOP staging migration"
  description  = "One-shot database migration identity"
}

resource "google_service_account" "builder" {
  project      = var.project_id
  account_id   = "${local.prefix}-builder"
  display_name = "NOOP staging image builder"
  description  = "Builds digest-pinned synthetic staging images"
}

resource "google_service_account_iam_member" "api_self_signer" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.api.email}"
}

resource "google_service_account_iam_member" "managed_api_self_signer" {
  service_account_id = google_service_account.managed_api.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_artifact_registry_repository_iam_member" "builder_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.containers.location
  repository = google_artifact_registry_repository.containers.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_storage_bucket_iam_member" "builder_source_reader" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_storage_bucket_iam_member" "builder_source_bucket_viewer" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.bucketViewer"
  member = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_service_usage" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_storage_bucket_iam_member" "api_raw_creator" {
  bucket = google_storage_bucket.raw_chunks.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.api.email}"
}

resource "google_storage_bucket_iam_member" "managed_api_raw_creator" {
  bucket = google_storage_bucket.raw_chunks.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_project_iam_custom_role" "managed_object_reader" {
  project     = var.project_id
  role_id     = "noopManagedObjectReader"
  title       = "NOOP managed exact object reader"
  description = "Read exact database-known managed objects without bucket listing"
  permissions = ["storage.objects.get"]
}

resource "google_storage_bucket_iam_member" "managed_api_raw_reader" {
  bucket = google_storage_bucket.raw_chunks.name
  role   = google_project_iam_custom_role.managed_object_reader.id
  member = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_project_iam_member" "api_cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "managed_api_cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_project_iam_custom_role" "managed_api_push_sender" {
  count = var.enable_managed_runtime ? 1 : 0

  project     = var.project_id
  role_id     = replace("${local.prefix}_fcm_sender", "-", "_")
  title       = "NOOP managed FCM sender"
  description = "Send opaque managed Safety references through FCM."
  permissions = [
    "cloudmessaging.messages.create",
    "resourcemanager.projects.get",
  ]
}

resource "google_project_iam_member" "managed_api_push_sender" {
  count = var.enable_managed_runtime ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.managed_api_push_sender[0].name
  member  = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_project_iam_member" "managed_lifecycle_push_sender" {
  count = var.enable_managed_runtime ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.managed_api_push_sender[0].name
  member  = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_project_iam_member" "ownership_api_cloud_sql_client" {
  count = var.enable_ownership_runtime ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.ownership_api[0].email}"
}

resource "google_project_iam_member" "migration_cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.migration.email}"
}

resource "google_storage_bucket_iam_member" "processor_raw_reader" {
  bucket = google_storage_bucket.raw_chunks.name
  role   = google_project_iam_custom_role.managed_object_reader.id
  member = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_project_iam_custom_role" "managed_object_deleter" {
  project     = var.project_id
  role_id     = "noopManagedObjectDeleter"
  title       = "NOOP managed object lifecycle"
  description = "Read exact database-known objects for reconciliation and delete lifecycle claims"
  permissions = ["storage.objects.delete", "storage.objects.get"]
}

resource "google_storage_bucket_iam_member" "managed_lifecycle_raw_deleter" {
  bucket = google_storage_bucket.raw_chunks.name
  role   = google_project_iam_custom_role.managed_object_deleter.id
  member = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_project_iam_custom_role" "managed_identity_deleter" {
  project     = var.project_id
  role_id     = "noopManagedIdentityDeleter"
  title       = "NOOP managed identity deleter"
  description = "Delete Firebase Auth users only after managed account erasure completes"
  permissions = ["firebaseauth.users.delete"]
}

resource "google_project_iam_member" "managed_lifecycle_identity_deleter" {
  project = var.project_id
  role    = google_project_iam_custom_role.managed_identity_deleter.id
  member  = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_pubsub_subscription_iam_member" "processor_subscriber" {
  count = var.enable_managed_runtime ? 0 : 1

  project      = var.project_id
  subscription = google_pubsub_subscription.raw_processor.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_pubsub_topic_iam_member" "raw_dead_letter_forwarder" {
  project = var.project_id
  topic   = google_pubsub_topic.raw_uploads_dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_pubsub_subscription_iam_member" "raw_retry_forwarder" {
  project      = var.project_id
  subscription = google_pubsub_subscription.raw_processor.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_service_account_iam_member" "pubsub_event_token_creator" {
  service_account_id = google_service_account.managed_event_invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_secret_manager_secret" "bootstrap_admin_token" {
  project   = var.project_id
  secret_id = "${local.prefix}-bootstrap-admin-token"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "database_url" {
  project   = var.project_id
  secret_id = "${local.prefix}-database-url"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "managed_replay_secret" {
  project   = var.project_id
  secret_id = "${local.prefix}-managed-replay-secret"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "managed_push_token_secret" {
  project   = var.project_id
  secret_id = "${local.prefix}-managed-push-token-secret"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "api_admin_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.bootstrap_admin_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "api_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "managed_api_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_api.email}"
}

data "google_secret_manager_secret" "ownership_database_url" {
  count = var.enable_ownership_runtime ? 1 : 0

  project = var.project_id
  secret_id = (
    var.ownership_database_url_secret_id != null
    ? var.ownership_database_url_secret_id
    : "ownership-database-url-required"
  )
}

resource "google_secret_manager_secret_iam_member" "ownership_api_database_url" {
  count = var.enable_ownership_runtime ? 1 : 0

  project   = var.project_id
  secret_id = data.google_secret_manager_secret.ownership_database_url[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ownership_api[0].email}"
}

resource "google_secret_manager_secret_iam_member" "managed_api_replay_secret" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.managed_replay_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_secret_manager_secret_iam_member" "managed_api_push_token_secret" {
  count = var.enable_managed_runtime ? 1 : 0

  project   = var.project_id
  secret_id = google_secret_manager_secret.managed_push_token_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_api.email}"
}

resource "google_secret_manager_secret_iam_member" "managed_lifecycle_push_token_secret" {
  count = var.enable_managed_runtime ? 1 : 0

  project   = var.project_id
  secret_id = google_secret_manager_secret.managed_push_token_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_secret_manager_secret_iam_member" "processor_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_project_iam_member" "managed_lifecycle_cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_project_iam_member" "processor_cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.processor.email}"
}

resource "google_secret_manager_secret_iam_member" "managed_lifecycle_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_secret_manager_secret_iam_member" "managed_lifecycle_replay_secret" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.managed_replay_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.managed_lifecycle.email}"
}

resource "google_secret_manager_secret_iam_member" "migration_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.migration.email}"
}
