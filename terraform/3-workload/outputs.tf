output "service_url" {
  description = "Public URL of the deployed demo service"
  value       = google_cloud_run_v2_service.demo.uri
}

output "service_account_email" {
  description = "Service account used by Cloud Run"
  value       = google_service_account.demo.email
}
