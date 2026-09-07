mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/noop-ownership-test/serviceAccounts/noop-test@noop-ownership-test.iam.gserviceaccount.com"
      email = "noop-test@noop-ownership-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}

variables {
  project_id = "noop-ownership-test"
}

run "ownership_is_disabled_by_default" {
  command = plan

  assert {
    condition     = !var.enable_ownership_identity
    error_message = "Ownership identity must remain disabled by default."
  }

  assert {
    condition     = !var.enable_ownership_runtime
    error_message = "The ownership runtime must remain disabled by default."
  }

  assert {
    condition = (
      length(google_service_account.ownership_api) == 0
      && length(google_project_iam_member.ownership_api_cloud_sql_client) == 0
      && length(google_secret_manager_secret_iam_member.ownership_api_database_url) == 0
      && length(google_cloud_run_v2_service.ownership_api) == 0
    )
    error_message = "Default planning must not create ownership runtime or IAM resources."
  }

  assert {
    condition     = output.ownership_api == null
    error_message = "The default ownership runtime output must be null."
  }
}

run "ownership_runtime_requires_every_guard" {
  command = plan

  variables {
    enable_ownership_runtime = true
  }

  expect_failures = [var.enable_ownership_runtime]
}

run "ownership_runtime_is_iam_only_when_every_guard_is_present" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_ownership_identity          = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database          = true
    runtime_image                    = "asia-south1-docker.pkg.dev/noop-ownership-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ownership_database_url_secret_id = "noop-ownership-database-url"
    enable_ownership_runtime         = true
  }

  assert {
    condition = (
      length(google_service_account.ownership_api) == 1
      && length(google_project_iam_member.ownership_api_cloud_sql_client) == 1
      && length(google_secret_manager_secret_iam_member.ownership_api_database_url) == 1
      && length(google_cloud_run_v2_service.ownership_api) == 1
    )
    error_message = "Every guarded ownership runtime and IAM resource must be planned together."
  }

  assert {
    condition = (
      google_cloud_run_v2_service.ownership_api[0].template[0].service_account
      == google_service_account.ownership_api[0].email
      && google_service_account.ownership_api[0].account_id
      != google_service_account.managed_api.account_id
    )
    error_message = "Ownership must use its own runtime identity."
  }

  assert {
    condition = (
      output.ownership_api != null
      && !output.ownership_api.public
      && length(google_cloud_run_v2_service_iam_member.managed_api_public) == 0
    )
    error_message = "The guarded ownership plan must remain IAM-only with no public invoker."
  }
}
