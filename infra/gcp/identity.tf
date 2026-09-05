resource "google_firebase_project" "managed" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project = var.project_id

  depends_on = [
    google_project_service.required["firebase.googleapis.com"],
    google_project_service.required["identitytoolkit.googleapis.com"],
  ]
}

resource "google_apikeys_key" "managed_apple" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project      = var.project_id
  name         = "${local.prefix}-apple"
  display_name = "NOOP iOS synthetic staging"

  restrictions {
    ios_key_restrictions {
      allowed_bundle_ids = [var.managed_apple_bundle_id]
    }

    dynamic "api_targets" {
      for_each = toset([
        "firebaseappcheck.googleapis.com",
        "firebaseinstallations.googleapis.com",
        "identitytoolkit.googleapis.com",
        "securetoken.googleapis.com",
      ])

      content {
        service = api_targets.value
      }
    }
  }

  depends_on = [google_project_service.required["apikeys.googleapis.com"]]
}

resource "google_apikeys_key" "managed_android" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project      = var.project_id
  name         = "${local.prefix}-android"
  display_name = "NOOP Android synthetic staging"

  restrictions {
    android_key_restrictions {
      dynamic "allowed_applications" {
        for_each = toset(var.managed_android_sha1_fingerprints)

        content {
          package_name     = var.managed_android_package_name
          sha1_fingerprint = lower(replace(allowed_applications.value, ":", ""))
        }
      }
    }

    dynamic "api_targets" {
      for_each = toset([
        "firebaseappcheck.googleapis.com",
        "firebaseinstallations.googleapis.com",
        "identitytoolkit.googleapis.com",
        "securetoken.googleapis.com",
      ])

      content {
        service = api_targets.value
      }
    }
  }

  depends_on = [google_project_service.required["apikeys.googleapis.com"]]
}

resource "google_apikeys_key" "managed_identity_lookup" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project      = var.project_id
  name         = "${local.prefix}-identity-lookup"
  display_name = "NOOP managed API Identity Toolkit lookup"

  restrictions {
    api_targets {
      service = "identitytoolkit.googleapis.com"
    }
  }

  depends_on = [google_project_service.required["apikeys.googleapis.com"]]
}

resource "google_firebase_android_app" "staging" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project      = var.project_id
  display_name = "NOOP Android synthetic staging"
  package_name = var.managed_android_package_name
  api_key_id   = google_apikeys_key.managed_android[0].uid
  sha1_hashes = [
    for fingerprint in var.managed_android_sha1_fingerprints :
    lower(replace(fingerprint, ":", ""))
  ]
  sha256_hashes = [
    for fingerprint in var.managed_android_sha256_fingerprints :
    lower(replace(fingerprint, ":", ""))
  ]
  deletion_policy = "PREVENT"

  depends_on = [google_firebase_project.managed]
}

resource "google_firebase_apple_app" "staging" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project         = var.project_id
  display_name    = "NOOP iOS synthetic staging"
  bundle_id       = var.managed_apple_bundle_id
  app_store_id    = "6804921246"
  api_key_id      = google_apikeys_key.managed_apple[0].uid
  deletion_policy = "PREVENT"

  depends_on = [google_firebase_project.managed]
}

resource "google_firebase_app_check_app_attest_config" "staging" {
  provider = google-beta
  count    = var.enable_managed_app_check ? 1 : 0

  project   = var.project_id
  app_id    = google_firebase_apple_app.staging[0].app_id
  token_ttl = "3600s"
}

resource "google_firebase_app_check_play_integrity_config" "staging" {
  provider = google-beta
  count    = var.enable_managed_app_check ? 1 : 0

  project   = var.project_id
  app_id    = google_firebase_android_app.staging[0].app_id
  token_ttl = "3600s"
}

resource "google_firebase_app_check_service_config" "authentication" {
  provider = google-beta
  count    = var.enable_managed_app_check ? 1 : 0

  project          = var.project_id
  service_id       = "identitytoolkit.googleapis.com"
  enforcement_mode = var.managed_auth_app_check_enforcement

  depends_on = [
    google_firebase_app_check_app_attest_config.staging,
    google_firebase_app_check_play_integrity_config.staging,
  ]
}

resource "google_identity_platform_config" "managed" {
  provider = google-beta
  count    = var.enable_managed_identity ? 1 : 0

  project                    = var.project_id
  autodelete_anonymous_users = true

  sign_in {
    anonymous {
      enabled = false
    }
    email {
      enabled           = false
      password_required = true
    }
    phone_number {
      enabled            = true
      test_phone_numbers = var.managed_test_phone_numbers
    }
  }

  sms_region_config {
    allowlist_only {
      allowed_regions = var.managed_sms_regions
    }
  }

  client {
    permissions {
      disabled_user_deletion = true
      disabled_user_signup   = false
    }
  }

  monitoring {
    request_logging {
      enabled = true
    }
  }

  depends_on = [google_firebase_project.managed]
}
