resource "google_kms_crypto_key" "cloud_sql" {
  count = var.enable_managed_database ? 1 : 0

  name                       = "${local.prefix}-cloud-sql"
  key_ring                   = google_kms_key_ring.health_data.id
  purpose                    = "ENCRYPT_DECRYPT"
  rotation_period            = "7776000s"
  destroy_scheduled_duration = "2592000s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "cloud_sql" {
  count = var.enable_managed_database ? 1 : 0

  crypto_key_id = google_kms_crypto_key.cloud_sql[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.sqladmin.email}"
}

resource "google_sql_database_instance" "primary" {
  count = var.enable_managed_database ? 1 : 0

  project             = var.project_id
  name                = "${local.prefix}-postgres"
  region              = var.region
  database_version    = "POSTGRES_16"
  encryption_key_name = google_kms_crypto_key.cloud_sql[0].id
  deletion_protection = true

  settings {
    tier                        = var.database_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    activation_policy           = "ALWAYS"
    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = true
    deletion_protection_enabled = true
    user_labels                 = local.labels

    backup_configuration {
      enabled                        = true
      location                       = var.region
      point_in_time_recovery_enabled = true
      start_time                     = "20:30"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7
      hour         = 21
      update_track = "stable"
    }
  }

  depends_on = [
    google_kms_crypto_key_iam_member.cloud_sql,
    google_project_service.required["sqladmin.googleapis.com"],
  ]
}

resource "google_sql_database" "noop" {
  count = var.enable_managed_database ? 1 : 0

  project  = var.project_id
  name     = "noop"
  instance = google_sql_database_instance.primary[0].name
}

resource "google_cloud_run_v2_job" "migrate" {
  count = local.runtime_workloads_enabled ? 1 : 0

  project             = var.project_id
  name                = "${local.prefix}-migrate"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.migration.email
      max_retries     = 0
      timeout         = "600s"

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.primary[0].connection_name]
        }
      }

      containers {
        image   = var.runtime_image
        command = ["python"]
        args    = ["-m", "app.migrate"]

        env {
          name  = "NOOP_DATABASE_ENGINE"
          value = "postgresql"
        }
        env {
          name  = "NOOP_DB_POOL_MIN_SIZE"
          value = "1"
        }
        env {
          name  = "NOOP_DB_POOL_MAX_SIZE"
          value = "1"
        }
        env {
          name  = "NOOP_SAFETY_WORKER_ENABLED"
          value = "false"
        }
        env {
          name = "NOOP_DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.database_url.secret_id
              version = "latest"
            }
          }
        }
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.migration_cloud_sql_client,
    google_secret_manager_secret_iam_member.migration_database_url,
    google_sql_database.noop,
  ]
}

resource "google_cloud_run_v2_service" "api" {
  count = var.enable_private_api ? 1 : 0

  project             = var.project_id
  name                = "${local.prefix}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = false

  template {
    service_account                  = google_service_account.api.email
    timeout                          = "120s"
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.primary[0].connection_name]
      }
    }

    containers {
      image = var.runtime_image

      ports {
        container_port = 8080
      }

      env {
        name  = "NOOP_DATABASE_ENGINE"
        value = "postgresql"
      }
      env {
        name  = "NOOP_AUTH_MODE"
        value = "single_owner"
      }
      env {
        name  = "NOOP_RUN_MIGRATIONS"
        value = "false"
      }
      env {
        name  = "NOOP_DASHBOARD_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_SAFETY_WORKER_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_DB_POOL_MIN_SIZE"
        value = "1"
      }
      env {
        name  = "NOOP_DB_POOL_MAX_SIZE"
        value = "4"
      }
      env {
        name  = "NOOP_RETENTION_DAYS"
        value = "30"
      }
      env {
        name = "NOOP_DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "NOOP_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.bootstrap_admin_token.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 2
        period_seconds        = 2
        failure_threshold     = 30

        http_get {
          path = "/readyz"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 2
        period_seconds        = 10
        failure_threshold     = 3

        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.migrate,
    google_project_iam_member.api_cloud_sql_client,
    google_secret_manager_secret_iam_member.api_admin_token,
    google_secret_manager_secret_iam_member.api_database_url,
  ]
}

resource "google_cloud_run_v2_service" "managed_api" {
  count = var.enable_managed_runtime ? 1 : 0

  project  = var.project_id
  name     = "${local.prefix}-managed-api"
  location = var.region
  # The service URL is IAM-only until enable_public_managed_api adds the
  # allUsers invoker. Application-level Firebase/App Check auth remains active.
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.managed_api.email
    timeout                          = "120s"
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.primary[0].connection_name]
      }
    }

    containers {
      image   = var.runtime_image
      command = ["sh", "-c"]
      args = [
        "exec uvicorn app.managed_main:app --host 0.0.0.0 --port 8080 --no-access-log",
      ]

      ports {
        container_port = 8080
      }

      env {
        name  = "NOOP_DATABASE_ENGINE"
        value = "postgresql"
      }
      env {
        name  = "NOOP_RUN_MIGRATIONS"
        value = "false"
      }
      env {
        name  = "NOOP_DASHBOARD_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_SAFETY_WORKER_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_DB_POOL_MIN_SIZE"
        value = "1"
      }
      env {
        name  = "NOOP_DB_POOL_MAX_SIZE"
        value = "6"
      }
      env {
        name  = "NOOP_RATE_LIMIT_ORIGIN_REQUESTS_PER_MINUTE"
        value = "12000"
      }
      env {
        name  = "NOOP_MANAGED_STORAGE_ENABLED"
        value = "true"
      }
      env {
        name  = "NOOP_MANAGED_ENTITLEMENT_MODE"
        value = var.managed_entitlement_mode
      }
      env {
        name  = "NOOP_MANAGED_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "NOOP_MANAGED_PROJECT_NUMBER"
        value = data.google_project.current.number
      }
      env {
        name  = "NOOP_MANAGED_IDENTITY_API_KEY"
        value = google_apikeys_key.managed_identity_lookup[0].key_string
      }
      env {
        name  = "NOOP_MANAGED_APPLE_APP_ID"
        value = google_firebase_apple_app.staging[0].app_id
      }
      env {
        name  = "NOOP_MANAGED_ANDROID_APP_ID"
        value = google_firebase_android_app.staging[0].app_id
      }
      env {
        name  = "NOOP_MANAGED_APP_CHECK_CACHE_SECONDS"
        value = "21600"
      }
      env {
        name  = "NOOP_MANAGED_RAW_BUCKET"
        value = google_storage_bucket.raw_chunks.name
      }
      env {
        name  = "NOOP_MANAGED_SIGNER_EMAIL"
        value = google_service_account.managed_api.email
      }
      env {
        name  = "NOOP_MANAGED_HOME_REGION"
        value = var.region
      }
      env {
        name  = "NOOP_MANAGED_RESIDENCY_POLICY_VERSION"
        value = "synthetic-v1"
      }
      env {
        name  = "NOOP_MANAGED_DEFAULT_PLAN_CODE"
        value = "noop_plus_staging"
      }
      env {
        name  = "NOOP_MANAGED_DEFAULT_PLAN_REVISION"
        value = "1"
      }
      env {
        name  = "NOOP_MANAGED_CONSENT_POLICY_KIND"
        value = "managed_storage"
      }
      env {
        name  = "NOOP_MANAGED_CONSENT_POLICY_VERSION"
        value = "synthetic-v1"
      }
      env {
        name  = "NOOP_MANAGED_CONSENT_POLICY_SHA256"
        value = "e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef"
      }
      env {
        name = "NOOP_DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "NOOP_MANAGED_REPLAY_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.managed_replay_secret.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 2
        period_seconds        = 2
        failure_threshold     = 30

        http_get {
          path = "/readyz"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 2
        period_seconds        = 10
        failure_threshold     = 3

        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.migrate,
    google_project_iam_member.managed_api_cloud_sql_client,
    google_secret_manager_secret_iam_member.managed_api_database_url,
    google_secret_manager_secret_iam_member.managed_api_replay_secret,
    google_storage_bucket_iam_member.managed_api_raw_creator,
    google_storage_bucket_iam_member.managed_api_raw_reader,
    google_service_account_iam_member.managed_api_self_signer,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "managed_api_public" {
  count = var.enable_public_managed_api ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.managed_api[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service" "ownership_api" {
  count = var.enable_ownership_runtime ? 1 : 0

  project  = var.project_id
  name     = "${local.prefix}-ownership-api"
  location = var.region
  # The first-party mobile client must not receive this URL until an approved
  # supplier verifier replaces the fail-closed runtime and every public gate
  # passes. IAM remains the only Cloud Run invoker in this stack.
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.ownership_api[0].email
    timeout                          = "30s"
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.primary[0].connection_name]
      }
    }

    containers {
      image   = var.runtime_image
      command = ["sh", "-c"]
      args = [
        "exec uvicorn app.ownership_main:app --host 0.0.0.0 --port 8080 --no-access-log",
      ]

      ports {
        container_port = 8080
      }

      env {
        name  = "NOOP_DATABASE_ENGINE"
        value = "postgresql"
      }
      env {
        name  = "NOOP_RUN_MIGRATIONS"
        value = "false"
      }
      env {
        name  = "NOOP_DASHBOARD_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_SAFETY_WORKER_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_DB_POOL_MIN_SIZE"
        value = "1"
      }
      env {
        name  = "NOOP_DB_POOL_MAX_SIZE"
        value = "4"
      }
      env {
        name  = "NOOP_RATE_LIMIT_ORIGIN_REQUESTS_PER_MINUTE"
        value = "600"
      }
      env {
        name  = "NOOP_OWNERSHIP_SERVICE_ENABLED"
        value = "true"
      }
      env {
        name  = "NOOP_OWNERSHIP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "NOOP_OWNERSHIP_PROJECT_NUMBER"
        value = data.google_project.current.number
      }
      env {
        name  = "NOOP_OWNERSHIP_IDENTITY_API_KEY"
        value = google_apikeys_key.managed_identity_lookup[0].key_string
      }
      env {
        name  = "NOOP_OWNERSHIP_APPLE_APP_ID"
        value = google_firebase_apple_app.staging[0].app_id
      }
      env {
        name  = "NOOP_OWNERSHIP_ANDROID_APP_ID"
        value = google_firebase_android_app.staging[0].app_id
      }
      env {
        name  = "NOOP_OWNERSHIP_APP_CHECK_CACHE_SECONDS"
        value = "21600"
      }
      env {
        name = "NOOP_DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.ownership_database_url[0].secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 2
        period_seconds        = 2
        failure_threshold     = 30

        http_get {
          path = "/readyz"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 2
        period_seconds        = 10
        failure_threshold     = 3

        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.migrate,
    google_project_iam_member.ownership_api_cloud_sql_client,
    google_secret_manager_secret_iam_member.ownership_api_database_url,
  ]
}

resource "google_cloud_run_v2_service" "managed_processor" {
  count = var.enable_managed_runtime ? 1 : 0

  project             = var.project_id
  name                = "${local.prefix}-managed-processor"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = false

  template {
    service_account                  = google_service_account.processor.email
    timeout                          = "300s"
    max_instance_request_concurrency = 4

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.primary[0].connection_name]
      }
    }

    containers {
      image   = var.runtime_image
      command = ["sh", "-c"]
      args = [
        "exec uvicorn app.managed_processor_main:app --host 0.0.0.0 --port 8080 --no-access-log",
      ]

      ports {
        container_port = 8080
      }

      env {
        name  = "NOOP_DATABASE_ENGINE"
        value = "postgresql"
      }
      env {
        name  = "NOOP_RUN_MIGRATIONS"
        value = "false"
      }
      env {
        name  = "NOOP_DASHBOARD_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_SAFETY_WORKER_ENABLED"
        value = "false"
      }
      env {
        name  = "NOOP_DB_POOL_MIN_SIZE"
        value = "1"
      }
      env {
        name  = "NOOP_DB_POOL_MAX_SIZE"
        value = "6"
      }
      env {
        name  = "NOOP_RATE_LIMIT_ORIGIN_REQUESTS_PER_MINUTE"
        value = "12000"
      }
      env {
        name  = "NOOP_MANAGED_RAW_BUCKET"
        value = google_storage_bucket.raw_chunks.name
      }
      env {
        name  = "NOOP_MANAGED_SIGNER_EMAIL"
        value = google_service_account.processor.email
      }
      env {
        name = "NOOP_DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 2
        period_seconds        = 2
        failure_threshold     = 30

        http_get {
          path = "/readyz"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 2
        period_seconds        = 10
        failure_threshold     = 3

        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.migrate,
    google_project_iam_member.processor_cloud_sql_client,
    google_secret_manager_secret_iam_member.processor_database_url,
    google_storage_bucket_iam_member.processor_raw_reader,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "managed_processor_event_invoker" {
  count = var.enable_managed_runtime ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.managed_processor[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.managed_event_invoker.email}"
}

resource "google_cloud_run_v2_job" "managed_lifecycle" {
  count = var.enable_managed_runtime ? 1 : 0

  project             = var.project_id
  name                = "${local.prefix}-managed-lifecycle"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.managed_lifecycle.email
      max_retries     = 1
      timeout         = "1200s"

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.primary[0].connection_name]
        }
      }

      containers {
        image   = var.runtime_image
        command = ["python"]
        args    = ["-m", "app.managed_lifecycle"]

        env {
          name  = "NOOP_DATABASE_ENGINE"
          value = "postgresql"
        }
        env {
          name  = "NOOP_RUN_MIGRATIONS"
          value = "false"
        }
        env {
          name  = "NOOP_SAFETY_WORKER_ENABLED"
          value = "false"
        }
        env {
          name  = "NOOP_DB_POOL_MIN_SIZE"
          value = "1"
        }
        env {
          name  = "NOOP_DB_POOL_MAX_SIZE"
          value = "6"
        }
        env {
          name  = "NOOP_MANAGED_RAW_BUCKET"
          value = google_storage_bucket.raw_chunks.name
        }
        env {
          name  = "NOOP_MANAGED_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "NOOP_MANAGED_SIGNER_EMAIL"
          value = google_service_account.managed_lifecycle.email
        }
        env {
          name = "NOOP_DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.database_url.secret_id
              version = "latest"
            }
          }
        }
        env {
          name = "NOOP_MANAGED_REPLAY_SECRET"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.managed_replay_secret.secret_id
              version = "latest"
            }
          }
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.migrate,
    google_project_iam_member.managed_lifecycle_cloud_sql_client,
    google_secret_manager_secret_iam_member.managed_lifecycle_database_url,
    google_secret_manager_secret_iam_member.managed_lifecycle_replay_secret,
    google_storage_bucket_iam_member.managed_lifecycle_raw_deleter,
    google_project_iam_member.managed_lifecycle_identity_deleter,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "managed_lifecycle_scheduler" {
  count = var.enable_managed_runtime ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.managed_lifecycle[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.managed_scheduler.email}"
}

resource "google_cloud_scheduler_job" "managed_lifecycle" {
  count = var.enable_managed_runtime ? 1 : 0

  project          = var.project_id
  region           = var.region
  name             = "${local.prefix}-managed-lifecycle"
  description      = "Expire reservations and enforce managed object retention"
  schedule         = "*/5 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "320s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "10s"
    max_backoff_duration = "300s"
    max_doublings        = 3
  }

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.managed_lifecycle[0].name}:run"

    oauth_token {
      service_account_email = google_service_account.managed_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_cloud_run_v2_job_iam_member.managed_lifecycle_scheduler,
    google_project_service.required["cloudscheduler.googleapis.com"],
  ]
}
