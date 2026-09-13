mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/noop-feedback-test/serviceAccounts/noop-test@noop-feedback-test.iam.gserviceaccount.com"
      email = "noop-test@noop-feedback-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}

variables {
  project_id = "noop-feedback-test"
}

run "feedback_is_disabled_and_bounded_by_default" {
  command = plan

  assert {
    condition = (
      !var.enable_feedback_ingestion
      && !var.enable_feedback_lifecycle
      && var.feedback_retention_days == 28
      && !output.feedback_public_ready
    )
    error_message = "Feedback must remain disabled, bounded, and not publicly ready by default."
  }
}

run "feedback_retention_rejects_more_than_28_days" {
  command = plan

  variables {
    feedback_retention_days = 29
  }

  expect_failures = [var.feedback_retention_days]
}

run "feedback_lifecycle_can_drain_with_ingestion_disabled" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database   = true
    runtime_image             = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime    = true
    enable_feedback_lifecycle = true
    enable_feedback_ingestion = false
  }

  assert {
    condition = (
      var.enable_feedback_lifecycle
      && !var.enable_feedback_ingestion
      && length(google_cloud_run_v2_job.feedback_lifecycle) == 1
    )
    error_message = "Feedback lifecycle draining must remain deployable while new ingestion is disabled."
  }

  assert {
    condition = anytrue([
      for environment in google_cloud_run_v2_job.feedback_lifecycle[0].template[0].template[0].containers[0].env :
      environment.name == "NOOP_FEEDBACK_LIFECYCLE_BATCH_SIZE" && environment.value == "20"
    ])
    error_message = "Feedback lifecycle must use the bounded dedicated batch size."
  }

  assert {
    condition = anytrue([
      for environment in google_cloud_run_v2_job.feedback_lifecycle[0].template[0].template[0].containers[0].env :
      environment.name == "NOOP_FEEDBACK_CLEANUP_CONFIRMATION_DELAY_SECONDS" && environment.value == "60"
    ])
    error_message = "Feedback lifecycle must retain a delayed absence-confirmation tombstone."
  }

  assert {
    condition = alltrue([
      for environment in google_cloud_run_v2_job.managed_lifecycle[0].template[0].template[0].containers[0].env :
      !startswith(environment.name, "NOOP_FEEDBACK_")
    ])
    error_message = "The general managed lifecycle job must not own feedback cleanup stages."
  }
}

run "feedback_lifecycle_rejects_an_invalid_drain_key_ring" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database                  = true
    runtime_image                            = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime                   = true
    enable_feedback_lifecycle                = true
    enable_feedback_ingestion                = false
    feedback_capability_primary_key_version  = "v1"
    feedback_capability_previous_key_version = "v1"
  }

  expect_failures = [var.enable_feedback_lifecycle]
}

run "feedback_ingestion_requires_external_abuse_gate" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database   = true
    runtime_image             = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime    = true
    enable_feedback_lifecycle = true
    enable_feedback_ingestion = true
  }

  expect_failures = [var.enable_feedback_ingestion]
}

run "feedback_ingestion_uses_drain_switch_and_pinned_key_versions" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database                             = true
    runtime_image                                       = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime                              = true
    enable_feedback_lifecycle                           = true
    enable_feedback_ingestion                           = true
    feedback_external_abuse_gate_approved               = true
    feedback_capability_primary_key_version             = "v2"
    feedback_capability_previous_key_version            = "v1"
    feedback_capability_write_version                   = "v2"
    feedback_capability_primary_secret_manager_version  = "7"
    feedback_capability_previous_secret_manager_version = "6"
  }

  assert {
    condition = alltrue([
      anytrue([
        for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
        environment.name == "NOOP_FEEDBACK_ENABLED" && environment.value == "true"
      ]),
      anytrue([
        for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
        environment.name == "NOOP_FEEDBACK_ACCEPTING_RESERVATIONS" && environment.value == "true"
      ]),
      anytrue([
        for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
        environment.name == "NOOP_FEEDBACK_CAPABILITY_WRITE_VERSION" && environment.value == "v2"
      ]),
    ])
    error_message = "Managed feedback must expose a separate reservation switch and explicit write key version."
  }

  assert {
    condition     = !var.enable_public_managed_api && !output.feedback_public_ready
    error_message = "Internal feedback ingestion must not be reported as publicly ready."
  }

  assert {
    condition = alltrue([
      for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
      environment.name != "NOOP_FEEDBACK_CAPABILITY_SECRET" || (
        environment.value_source[0].secret_key_ref[0].version == "7"
      )
    ])
    error_message = "The primary feedback capability secret must use its pinned Secret Manager version."
  }

  assert {
    condition = alltrue([
      for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
      environment.name != "NOOP_FEEDBACK_CAPABILITY_PREVIOUS_SECRET" || (
        environment.value_source[0].secret_key_ref[0].version == "6"
      )
    ])
    error_message = "The retained feedback capability secret must use its pinned Secret Manager version."
  }
}

run "public_managed_api_without_feedback_ingestion_is_not_feedback_ready" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database               = true
    runtime_image                         = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime                = true
    enable_feedback_lifecycle             = true
    enable_feedback_ingestion             = false
    enable_public_managed_api             = true
    feedback_external_abuse_gate_approved = true
  }

  assert {
    condition     = !output.feedback_public_ready
    error_message = "Public managed API invocation alone must not imply public feedback readiness."
  }
}

run "feedback_public_readiness_requires_ingestion_and_public_invocation" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database                             = true
    runtime_image                                       = "asia-south1-docker.pkg.dev/noop-feedback-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime                              = true
    enable_feedback_lifecycle                           = true
    enable_feedback_ingestion                           = true
    enable_public_managed_api                           = true
    feedback_external_abuse_gate_approved               = true
    feedback_capability_primary_key_version             = "v2"
    feedback_capability_previous_key_version            = "v1"
    feedback_capability_write_version                   = "v2"
    feedback_capability_primary_secret_manager_version  = "7"
    feedback_capability_previous_secret_manager_version = "6"
  }

  assert {
    condition     = output.feedback_public_ready
    error_message = "Public feedback readiness must require both ingestion and public invocation with all stack-owned controls."
  }
}
