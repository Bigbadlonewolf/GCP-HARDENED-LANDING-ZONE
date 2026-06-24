output "key_ring_id" {
  description = "KMS key ring ID"
  value       = google_kms_key_ring.landing_zone.id
}

output "app_key_id" {
  description = "KMS key ID for application secrets"
  value       = google_kms_crypto_key.app.id
}

output "audit_log_bucket" {
  description = "GCS bucket receiving audit logs"
  value       = google_storage_bucket.audit_logs.name
}

output "audit_log_dataset" {
  description = "BigQuery dataset for querying audit logs"
  value       = google_bigquery_dataset.audit_logs.dataset_id
}
