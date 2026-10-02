mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/noop-required-services-test/serviceAccounts/noop-test@noop-required-services-test.iam.gserviceaccount.com"
      email = "noop-test@noop-required-services-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}
mock_provider "time" {}

variables {
  project_id = "noop-required-services-test"
}

run "iam_api_precedes_service_accounts_and_custom_roles" {
  command = plan

  assert {
    condition = contains(
      keys(google_project_service.required),
      "iam.googleapis.com",
    )
    error_message = "Fresh-project plans must enable the base IAM API."
  }

  assert {
    condition = (
      google_service_account.api.account_id == "noop-staging-api"
      && google_project_iam_custom_role.managed_object_reader.role_id == "noopManagedObjectReader"
    )
    error_message = "The IAM resources covered by the required-service dependency must remain planned."
  }

  assert {
    condition     = time_sleep.managed_object_role_propagation.create_duration == "60s"
    error_message = "Fresh-project custom roles must have an explicit propagation barrier before bucket IAM bindings."
  }
}
