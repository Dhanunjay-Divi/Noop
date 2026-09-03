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
