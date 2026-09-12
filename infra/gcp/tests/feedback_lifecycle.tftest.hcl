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
    )
    error_message = "Feedback ingestion and lifecycle must remain disabled by default with 28-day retention."
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
      && length(google_cloud_run_v2_job.managed_lifecycle) == 1
    )
    error_message = "Feedback lifecycle draining must remain deployable while new ingestion is disabled."
  }
}
