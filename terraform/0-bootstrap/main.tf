terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # Bootstrap uses local state on first run.
  # After apply, migrate with:
  #   terraform init -migrate-state \
  #     -backend-config="bucket=${PROJECT_ID}-tf-state" \
  #     -backend-config="prefix=landing-zone/bootstrap"
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

# ─── APIs ────────────────────────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "run.googleapis.com",
    "bigquery.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ─── Terraform state bucket ───────────────────────────────────────────────────

resource "google_storage_bucket" "tf_state" {
  name          = "${var.project_id}-tf-state"
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { num_newer_versions = 20 }
    action { type = "Delete" }
  }

  labels     = local.labels
  depends_on = [google_project_service.apis]
}

# ─── CI/CD service account ────────────────────────────────────────────────────

resource "google_service_account" "cicd" {
  account_id   = "terraform-cicd"
  display_name = "Terraform CI/CD"
  description  = "Used by Cloud Build to plan and apply Terraform changes"
}

locals {
  cicd_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/storage.admin",
    "roles/cloudkms.admin",
    "roles/logging.admin",
    "roles/monitoring.admin",
    "roles/run.admin",
    "roles/bigquery.dataOwner",
    "roles/bigquery.jobUser",
    "roles/secretmanager.admin",
    "roles/artifactregistry.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ]
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset(local.cicd_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.cicd.email}"
}

# Allow Cloud Build default SA to impersonate the CI/CD SA
data "google_project" "current" {}

resource "google_service_account_iam_member" "cloudbuild_impersonate_cicd" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
  depends_on         = [google_project_service.apis]
}

# ─── Artifact Registry ────────────────────────────────────────────────────────

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "landing-zone"
  format        = "DOCKER"
  description   = "Container images for landing zone workloads"

  labels     = local.labels
  depends_on = [google_project_service.apis]
}
