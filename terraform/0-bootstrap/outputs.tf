output "state_bucket" {
  description = "GCS bucket holding Terraform remote state"
  value       = google_storage_bucket.tf_state.name
}

output "cicd_sa_email" {
  description = "CI/CD service account email"
  value       = google_service_account.cicd.email
}

output "artifact_registry_url" {
  description = "Docker registry URL prefix"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/landing-zone"
}

output "project_number" {
  description = "GCP project number"
  value       = data.google_project.current.number
}
