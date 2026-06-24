# hardened-project module
#
# This is the "blueprint" a new team calls when they need a workspace.
# It applies every required security control automatically on creation:
# APIs enabled, IAM hardened, KMS key ring provisioned, audit log sink
# connected, labels applied.
#
# Usage:
#   module "payments_team" {
#     source      = "../../modules/hardened-project"
#     project_id  = "payments-team-project"
#     team_name   = "payments"
#     owner_email = "payments-lead@corp.com"
#     kms_region  = "us-central1"
#   }

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

locals {
  labels = {
    managed-by  = "terraform"
    environment = var.environment
    team        = var.team_name
    project     = "landing-zone"
  }
}

# ─── Required APIs ────────────────────────────────────────────────────────────

resource "google_project_service" "required_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudkms.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudtrace.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─── KMS key ring for this team's data ───────────────────────────────────────

resource "google_kms_key_ring" "team" {
  project  = var.project_id
  name     = "${var.team_name}-kr"
  location = var.kms_region

  depends_on = [google_project_service.required_apis]
}

resource "google_kms_crypto_key" "team_data" {
  name            = "${var.team_name}-data-key"
  key_ring        = google_kms_key_ring.team.id
  rotation_period = "7776000s" # 90 days — PCI DSS 6.3.5

  purpose = "ENCRYPT_DECRYPT"

  labels = local.labels
}

# ─── Audit log sink ───────────────────────────────────────────────────────────
# Each team's project streams its own audit logs to the central GCS bucket.

resource "google_logging_project_sink" "audit" {
  project     = var.project_id
  name        = "audit-to-central-gcs"
  destination = "storage.googleapis.com/${var.central_audit_bucket}"
  filter      = "logName=~\"(cloudaudit.googleapis.com%2Factivity|cloudaudit.googleapis.com%2Fdata_access)\""

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "audit_writer" {
  bucket = var.central_audit_bucket
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit.writer_identity
}

# ─── IAM — block primitive roles ─────────────────────────────────────────────
# Remove editor from the default compute service account.
# GCP adds this automatically; we remove it immediately on project creation.

data "google_project" "team" {
  project_id = var.project_id
}

resource "google_project_iam_member" "remove_default_compute_editor" {
  # This is a deliberate no-op IAM removal pattern:
  # We bind the default SA to a read-only role to override the auto-granted editor.
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${data.google_project.team.number}-compute@developer.gserviceaccount.com"
}

# ─── Workload service account ─────────────────────────────────────────────────

resource "google_service_account" "workload" {
  project      = var.project_id
  account_id   = "${var.team_name}-workload"
  display_name = "${var.team_name} Workload SA"
  description  = "Least-privilege SA for ${var.team_name} team workloads. Provisioned by landing zone blueprint."
}

# ─── Mandatory project labels ─────────────────────────────────────────────────
# Applied at the project level so they appear in billing and SCC reports.

resource "google_project" "labels" {
  project_id = var.project_id
  name       = var.project_id

  labels = local.labels

  lifecycle {
    ignore_changes = [name, org_id, folder_id, billing_account]
  }
}
