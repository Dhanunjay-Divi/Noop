resource "google_project_service" "required" {
  for_each = local.required_services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service_identity" "gcs" {
  provider = google-beta

  project = var.project_id
  service = "storage.googleapis.com"

  depends_on = [google_project_service.required["storage.googleapis.com"]]
}

resource "google_project_service_identity" "sqladmin" {
  provider = google-beta

  project = var.project_id
  service = "sqladmin.googleapis.com"

  depends_on = [google_project_service.required["sqladmin.googleapis.com"]]
}

data "google_storage_project_service_account" "gcs" {
  project = var.project_id

  depends_on = [google_project_service_identity.gcs]
}
