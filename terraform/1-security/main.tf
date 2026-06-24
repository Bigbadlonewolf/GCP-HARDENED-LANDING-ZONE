terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    bucket = "mythical-cider-496423-h6-tf-state"
    prefix = "landing-zone/security"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    managed-by  = "terraform"
    environment = var.environment
    project     = "landing-zone"
  }
}

data "google_project" "current" {}
data "google_storage_project_service_account" "gcs_sa" {}

# ─── Cloud KMS ────────────────────────────────────────────────────────────────

resource "google_kms_key_ring" "landing_zone" {
  name     = "landing-zone-kr"
  location = var.region
}

resource "google_kms_crypto_key" "tf_state" {
  name            = "terraform-state-key"
  key_ring        = google_kms_key_ring.landing_zone.id
  rotation_period = "7776000s" # 90 days

  purpose = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }

  labels = local.labels
}

resource "google_kms_crypto_key" "audit_logs" {
  name            = "audit-logs-key"
  key_ring        = google_kms_key_ring.landing_zone.id
  rotation_period = "7776000s" # 90 days

  purpose = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }

  labels = local.labels
}

resource "google_kms_crypto_key" "app" {
  name            = "app-key"
  key_ring        = google_kms_key_ring.landing_zone.id
  rotation_period = "7776000s" # 90 days

  purpose = "ENCRYPT_DECRYPT"

  labels = local.labels
}

# GCS service agent needs KMS access to read/write encrypted buckets
resource "google_kms_crypto_key_iam_member" "gcs_tf_state" {
  crypto_key_id = google_kms_crypto_key.tf_state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

resource "google_kms_crypto_key_iam_member" "gcs_audit_logs" {
  crypto_key_id = google_kms_crypto_key.audit_logs.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

# ─── Audit log — GCS bucket ───────────────────────────────────────────────────

resource "google_storage_bucket" "audit_logs" {
  name          = "${var.project_id}-audit-logs"
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.audit_logs.id
  }

  # Move to Coldline after 1 year; delete after 7 years (PCI DSS 10.7)
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition { age = 2555 }
    action { type = "Delete" }
  }

  labels     = local.labels
  depends_on = [google_kms_crypto_key_iam_member.gcs_audit_logs]
}

# ─── Audit log — BigQuery dataset ────────────────────────────────────────────

resource "google_bigquery_dataset" "audit_logs" {
  dataset_id    = "audit_logs"
  friendly_name = "Landing Zone Audit Logs"
  description   = "Project audit logs exported for security analysis and incident response"
  location      = var.region

  # 7-year retention in ms
  default_table_expiration_ms = 220752000000

  delete_contents_on_destroy = false

  labels = local.labels
}

# ─── Log sinks ────────────────────────────────────────────────────────────────

resource "google_logging_project_sink" "audit_to_gcs" {
  name = "audit-to-gcs"
  destination = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"
  filter      = <<-EOT
    logName=~"(cloudaudit.googleapis.com%2Factivity|cloudaudit.googleapis.com%2Fdata_access|cloudaudit.googleapis.com%2Fsystem_event|cloudaudit.googleapis.com%2Fpolicy)"
  EOT

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "log_sink_gcs_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit_to_gcs.writer_identity
}

resource "google_logging_project_sink" "audit_to_bq" {
  name        = "audit-to-bigquery"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.audit_logs.dataset_id}"
  filter      = <<-EOT
    logName=~"(cloudaudit.googleapis.com%2Factivity|cloudaudit.googleapis.com%2Fdata_access|cloudaudit.googleapis.com%2Fsystem_event)"
  EOT

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "log_sink_bq_writer" {
  dataset_id = google_bigquery_dataset.audit_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.audit_to_bq.writer_identity
}

# ─── Data Access audit logs ───────────────────────────────────────────────────

resource "google_project_iam_audit_config" "all_services" {
  project = var.project_id
  service = "allServices"

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

# ─── Security monitoring — log-based metrics + alert policies ─────────────────

resource "google_logging_metric" "primitive_role_granted" {
  name   = "security/primitive-iam-role-granted"
  filter = <<-EOT
    protoPayload.methodName="SetIamPolicy"
    protoPayload.serviceData.policyDelta.bindingDeltas.role=("roles/owner" OR "roles/editor" OR "roles/viewer")
    protoPayload.serviceData.policyDelta.bindingDeltas.action="ADD"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    display_name = "Primitive IAM Role Granted"
  }
}

resource "google_monitoring_alert_policy" "primitive_role_granted" {
  display_name = "[CRITICAL] Primitive IAM role granted"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Primitive role (owner/editor/viewer) added"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.primitive_role_granted.name}\" resource.type=\"global\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  documentation {
    content   = "A primitive IAM role (owner/editor/viewer) was added to the project. Review and remove unless explicitly approved. These roles violate least-privilege and are caught by PCI DSS Req 7.2.5 and NIST AC-6."
    mime_type = "text/markdown"
  }

  notification_channels = []
}

resource "google_logging_metric" "public_member_granted" {
  name   = "security/public-iam-member-granted"
  filter = <<-EOT
    protoPayload.methodName="SetIamPolicy"
    protoPayload.serviceData.policyDelta.bindingDeltas.member=("allUsers" OR "allAuthenticatedUsers")
    protoPayload.serviceData.policyDelta.bindingDeltas.action="ADD"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    display_name = "Public IAM Member Granted"
  }
}

resource "google_monitoring_alert_policy" "public_member_granted" {
  display_name = "[CRITICAL] Public IAM member added"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "allUsers or allAuthenticatedUsers added to an IAM policy"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.public_member_granted.name}\" resource.type=\"global\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  documentation {
    content   = "allUsers or allAuthenticatedUsers was added to an IAM binding. This exposes resources to the public internet. Remove immediately unless this is an intentional public Cloud Run endpoint."
    mime_type = "text/markdown"
  }

  notification_channels = []
}

resource "google_logging_metric" "firewall_rule_changed" {
  name   = "security/firewall-rule-changed"
  filter = <<-EOT
    resource.type="gce_firewall_rule"
    protoPayload.methodName=~"(insert|patch|delete)$"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    display_name = "Firewall Rule Changed"
  }
}

resource "google_monitoring_alert_policy" "firewall_rule_changed" {
  display_name = "[WARNING] Firewall rule modified"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Firewall rule created, updated, or deleted"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.firewall_rule_changed.name}\" resource.type=\"global\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  documentation {
    content   = "A VPC firewall rule was created, modified, or deleted. Verify the change was made via Terraform (Cloud Build) and not via console. Unmanaged firewall changes violate the IaC-only policy."
    mime_type = "text/markdown"
  }

  notification_channels = []
}
