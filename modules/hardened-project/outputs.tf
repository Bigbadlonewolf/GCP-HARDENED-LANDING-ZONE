output "kms_key_ring_id" {
  description = "KMS key ring ID for this team's project"
  value       = google_kms_key_ring.team.id
}

output "data_key_id" {
  description = "KMS crypto key ID for encrypting team data"
  value       = google_kms_crypto_key.team_data.id
}

output "workload_sa_email" {
  description = "Least-privilege workload service account email"
  value       = google_service_account.workload.email
}

output "audit_sink_writer_identity" {
  description = "Log sink writer identity (needs objectCreator on central audit bucket)"
  value       = google_logging_project_sink.audit.writer_identity
}
