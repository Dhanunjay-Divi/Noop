mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/noop-database-test/serviceAccounts/noop-test@noop-database-test.iam.gserviceaccount.com"
      email = "noop-test@noop-database-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}

variables {
  project_id = "noop-database-test"
}

run "database_secret_containers_are_distinct" {
  command = plan

  assert {
    condition = (
      google_secret_manager_secret.migration_database_url.secret_id
      == "noop-staging-database-url"
      && google_secret_manager_secret.runtime_database_url.secret_id
      == "noop-staging-runtime-database-url"
      && google_secret_manager_secret.managed_api_database_url.secret_id
      == "noop-staging-managed-api-database-url"
      && google_secret_manager_secret.managed_processor_database_url.secret_id
      == "noop-staging-managed-processor-database-url"
      && google_secret_manager_secret.managed_lifecycle_database_url.secret_id
      == "noop-staging-managed-lifecycle-database-url"
      && google_secret_manager_secret.feedback_lifecycle_database_url.secret_id
      == "noop-staging-feedback-lifecycle-database-url"
      && length(toset([
        google_secret_manager_secret.migration_database_url.secret_id,
        google_secret_manager_secret.runtime_database_url.secret_id,
        google_secret_manager_secret.managed_api_database_url.secret_id,
        google_secret_manager_secret.managed_processor_database_url.secret_id,
        google_secret_manager_secret.managed_lifecycle_database_url.secret_id,
        google_secret_manager_secret.feedback_lifecycle_database_url.secret_id,
      ])) == 6
    )
    error_message = "Migration and every runtime profile must use a distinct Secret Manager container."
  }
}

run "migration_workload_requires_a_pinned_migration_secret_version" {
  command = plan

  variables {
    enable_managed_database = true
    migration_image         = "asia-south1-docker.pkg.dev/noop-database-test/noop/runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.migration_database_url_secret_version]
}

run "managed_workloads_require_each_pinned_runtime_secret_version" {
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
    migration_database_url_secret_version = "7"
    runtime_image                         = "asia-south1-docker.pkg.dev/noop-database-test/noop/runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    enable_managed_runtime                = true
  }

  expect_failures = [
    var.managed_api_database_url_secret_version,
    var.managed_processor_database_url_secret_version,
    var.managed_lifecycle_database_url_secret_version,
  ]
}

run "private_api_requires_its_pinned_runtime_secret_version" {
  command = plan

  variables {
    enable_managed_database               = true
    migration_database_url_secret_version = "7"
    runtime_image                         = "asia-south1-docker.pkg.dev/noop-database-test/noop/runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    enable_private_api                    = true
  }

  expect_failures = [var.runtime_database_url_secret_version]
}

run "feedback_lifecycle_requires_its_pinned_runtime_secret_version" {
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
    migration_database_url_secret_version         = "7"
    managed_api_database_url_secret_version       = "12"
    managed_processor_database_url_secret_version = "13"
    managed_lifecycle_database_url_secret_version = "14"
    runtime_image                                 = "asia-south1-docker.pkg.dev/noop-database-test/noop/runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    enable_managed_runtime                        = true
    enable_feedback_lifecycle                     = true
  }

  expect_failures = [var.feedback_lifecycle_database_url_secret_version]
}

run "private_runtimes_cannot_read_the_migration_credential" {
  command = plan

  variables {
    enable_managed_identity            = true
    enable_managed_app_check           = true
    managed_auth_app_check_enforcement = "ENFORCED"
    managed_android_sha1_fingerprints  = ["00112233445566778899AABBCCDDEEFF00112233"]
    managed_android_sha256_fingerprints = [
      "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
    ]
    enable_managed_database                        = true
    migration_database_url_secret_version          = "7"
    runtime_database_url_secret_version            = "11"
    managed_api_database_url_secret_version        = "12"
    managed_processor_database_url_secret_version  = "13"
    managed_lifecycle_database_url_secret_version  = "14"
    feedback_lifecycle_database_url_secret_version = "15"
    runtime_image                                  = "asia-south1-docker.pkg.dev/noop-database-test/noop/runtime@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    enable_private_api                             = true
    enable_managed_runtime                         = true
    enable_feedback_lifecycle                      = true
  }

  assert {
    condition = anytrue([
      for environment in google_cloud_run_v2_job.migrate[0].template[0].template[0].containers[0].env :
      environment.name == "NOOP_DATABASE_URL"
      && environment.value_source[0].secret_key_ref[0].secret
      == google_secret_manager_secret.migration_database_url.secret_id
      && environment.value_source[0].secret_key_ref[0].version
      == var.migration_database_url_secret_version
    ])
    error_message = "The migration job must use only the pinned migration credential."
  }

  assert {
    condition = alltrue([
      anytrue([
        for environment in google_cloud_run_v2_service.api[0].template[0].containers[0].env :
        environment.name == "NOOP_DATABASE_URL"
        && environment.value_source[0].secret_key_ref[0].secret
        == google_secret_manager_secret.runtime_database_url.secret_id
        && environment.value_source[0].secret_key_ref[0].version
        == var.runtime_database_url_secret_version
      ]),
      anytrue([
        for environment in google_cloud_run_v2_service.managed_api[0].template[0].containers[0].env :
        environment.name == "NOOP_DATABASE_URL"
        && environment.value_source[0].secret_key_ref[0].secret
        == google_secret_manager_secret.managed_api_database_url.secret_id
        && environment.value_source[0].secret_key_ref[0].version
        == var.managed_api_database_url_secret_version
      ]),
      anytrue([
        for environment in google_cloud_run_v2_service.managed_processor[0].template[0].containers[0].env :
        environment.name == "NOOP_DATABASE_URL"
        && environment.value_source[0].secret_key_ref[0].secret
        == google_secret_manager_secret.managed_processor_database_url.secret_id
        && environment.value_source[0].secret_key_ref[0].version
        == var.managed_processor_database_url_secret_version
      ]),
      anytrue([
        for environment in google_cloud_run_v2_job.managed_lifecycle[0].template[0].template[0].containers[0].env :
        environment.name == "NOOP_DATABASE_URL"
        && environment.value_source[0].secret_key_ref[0].secret
        == google_secret_manager_secret.managed_lifecycle_database_url.secret_id
        && environment.value_source[0].secret_key_ref[0].version
        == var.managed_lifecycle_database_url_secret_version
      ]),
      anytrue([
        for environment in google_cloud_run_v2_job.feedback_lifecycle[0].template[0].template[0].containers[0].env :
        environment.name == "NOOP_DATABASE_URL"
        && environment.value_source[0].secret_key_ref[0].secret
        == google_secret_manager_secret.feedback_lifecycle_database_url.secret_id
        && environment.value_source[0].secret_key_ref[0].version
        == var.feedback_lifecycle_database_url_secret_version
      ]),
    ])
    error_message = "Every API, processor, and lifecycle workload must use its own pinned runtime credential."
  }

  assert {
    condition = (
      google_secret_manager_secret_iam_member.migration_database_url.secret_id
      == google_secret_manager_secret.migration_database_url.secret_id
      && google_secret_manager_secret_iam_member.api_database_url.secret_id
      == google_secret_manager_secret.runtime_database_url.secret_id
      && google_secret_manager_secret_iam_member.managed_api_database_url.secret_id
      == google_secret_manager_secret.managed_api_database_url.secret_id
      && google_secret_manager_secret_iam_member.processor_database_url.secret_id
      == google_secret_manager_secret.managed_processor_database_url.secret_id
      && google_secret_manager_secret_iam_member.managed_lifecycle_database_url.secret_id
      == google_secret_manager_secret.managed_lifecycle_database_url.secret_id
      && google_secret_manager_secret_iam_member.feedback_lifecycle_database_url[0].secret_id
      == google_secret_manager_secret.feedback_lifecycle_database_url.secret_id
    )
    error_message = "Secret Manager IAM must isolate migration access and every runtime identity."
  }

  assert {
    condition = (
      !var.enable_public_managed_api
      && length(google_cloud_run_v2_service_iam_member.managed_api_public) == 0
    )
    error_message = "Credential separation must not enable public managed traffic."
  }
}
