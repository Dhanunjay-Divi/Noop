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
      && length(data.google_secret_manager_secret.ownership_deletion_lifecycle_database_url) == 0
      && length(google_secret_manager_secret_iam_member.managed_lifecycle_ownership_database_url) == 0
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

run "ownership_deletion_coordination_requires_its_separate_secret" {
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
    enable_managed_database                       = true
    migration_database_url_secret_version         = "1"
    runtime_database_url_secret_version           = "1"
    managed_api_database_url_secret_version       = "1"
    managed_processor_database_url_secret_version = "1"
    managed_lifecycle_database_url_secret_version = "1"
    runtime_image                                 = "asia-south1-docker.pkg.dev/noop-ownership-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ownership_database_url_secret_id              = "noop-ownership-database-url"
    enable_managed_runtime                        = true
    enable_ownership_runtime                      = true
    enable_ownership_deletion_coordination        = true
  }

  expect_failures = [var.enable_ownership_deletion_coordination]
}

run "managed_runtime_omits_ownership_coordination_when_disabled" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database                       = true
    migration_database_url_secret_version         = "1"
    runtime_database_url_secret_version           = "1"
    managed_api_database_url_secret_version       = "1"
    managed_processor_database_url_secret_version = "1"
    managed_lifecycle_database_url_secret_version = "1"
    runtime_image                                 = "asia-south1-docker.pkg.dev/noop-ownership-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_managed_runtime                        = true
  }

  assert {
    condition = (
      length(data.google_secret_manager_secret.ownership_deletion_lifecycle_database_url) == 0
      && length(google_secret_manager_secret_iam_member.managed_lifecycle_ownership_database_url) == 0
      && alltrue([
        for environment in google_cloud_run_v2_job.managed_lifecycle[0].template[0].template[0].containers[0].env :
        !contains(
          [
            "NOOP_OWNERSHIP_DELETION_COORDINATION_ENABLED",
            "NOOP_OWNERSHIP_LIFECYCLE_DATABASE_URL",
          ],
          environment.name,
        )
      ])
    )
    error_message = "Managed lifecycle must remain deployable without ownership coordination or its secret."
  }
}

run "migration_image_executes_without_runtime_rollout" {
  command = plan

  variables {
    enable_managed_database               = true
    enable_managed_runtime                = false
    enable_private_api                    = false
    migration_database_url_secret_version = "1"
    migration_image                       = "asia-south1-docker.pkg.dev/noop-ownership-test/noop/runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    runtime_image                         = null
  }

  assert {
    condition = (
      length(google_cloud_run_v2_job.migrate) == 1
      && length(terraform_data.migration_execution) == 1
      && length(google_cloud_run_v2_service.api) == 0
      && length(google_cloud_run_v2_service.managed_api) == 0
      && google_cloud_run_v2_job.migrate[0].template[0].template[0].containers[0].image
      == var.migration_image
      && terraform_data.migration_execution[0].triggers_replace[0]
      == substr(sha256(var.migration_image), 0, 16)
    )
    error_message = "A staged migration image must execute without rolling out runtime services."
  }
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
    enable_managed_database                             = true
    migration_database_url_secret_version               = "1"
    runtime_database_url_secret_version                 = "1"
    managed_api_database_url_secret_version             = "1"
    managed_processor_database_url_secret_version       = "1"
    managed_lifecycle_database_url_secret_version       = "1"
    runtime_image                                       = "asia-south1-docker.pkg.dev/noop-ownership-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ownership_database_url_secret_id                    = "noop-ownership-database-url"
    enable_ownership_runtime                            = true
    enable_managed_runtime                              = true
    enable_ownership_deletion_coordination              = true
    ownership_deletion_lifecycle_database_url_secret_id = "noop-ownership-lifecycle-database-url"
  }

  assert {
    condition = (
      length(google_service_account.ownership_api) == 1
      && length(google_project_iam_member.ownership_api_cloud_sql_client) == 1
      && length(google_secret_manager_secret_iam_member.ownership_api_database_url) == 1
      && length(data.google_secret_manager_secret.ownership_deletion_lifecycle_database_url) == 1
      && length(google_secret_manager_secret_iam_member.managed_lifecycle_ownership_database_url) == 1
      && length(google_cloud_run_v2_service.ownership_api) == 1
    )
    error_message = "Every guarded ownership runtime and IAM resource must be planned together."
  }

  assert {
    condition = anytrue([
      for environment in google_cloud_run_v2_job.managed_lifecycle[0].template[0].template[0].containers[0].env :
      environment.name == "NOOP_OWNERSHIP_DELETION_COORDINATION_ENABLED"
      && environment.value == "true"
    ])
    error_message = "Ownership deletion coordination must be explicitly enabled in the lifecycle job."
  }

  assert {
    condition = anytrue([
      for environment in google_cloud_run_v2_job.managed_lifecycle[0].template[0].template[0].containers[0].env :
      environment.name == "NOOP_OWNERSHIP_LIFECYCLE_DATABASE_URL"
      && environment.value_source[0].secret_key_ref[0].secret
      == data.google_secret_manager_secret.ownership_deletion_lifecycle_database_url[0].secret_id
    ])
    error_message = "Ownership deletion coordination must inject only the separate lifecycle database credential."
  }

  assert {
    condition = (
      google_secret_manager_secret_iam_member.managed_lifecycle_ownership_database_url[0].member
      == "serviceAccount:${google_service_account.managed_lifecycle.email}"
      && google_secret_manager_secret_iam_member.managed_lifecycle_ownership_database_url[0].secret_id
      == data.google_secret_manager_secret.ownership_deletion_lifecycle_database_url[0].secret_id
      && google_secret_manager_secret_iam_member.ownership_api_database_url[0].secret_id
      == data.google_secret_manager_secret.ownership_database_url[0].secret_id
    )
    error_message = "The lifecycle and ownership API credentials must stay separately bound."
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

  assert {
    condition = (
      terraform_data.migration_execution[0].triggers_replace[0]
      == substr(sha256(var.runtime_image), 0, 16)
    )
    error_message = "A runtime image rollout must execute its matching migration first."
  }
}
