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
    prefix = "landing-zone/workload"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  image = "${var.region}-docker.pkg.dev/${var.project_id}/landing-zone/demo:latest"

  labels = {
    managed-by  = "terraform"
    environment = var.environment
    project     = "landing-zone"
  }
}

# ─── Workload service account ─────────────────────────────────────────────────

resource "google_service_account" "demo" {
  account_id   = "landing-zone-demo"
  display_name = "Landing Zone Demo Service"
  description  = "Least-privilege SA for the demo Cloud Run service. No primitive roles."
}

# Minimal permissions — trace writing and metric reporting only
resource "google_project_iam_member" "demo_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.demo.email}"
}

resource "google_project_iam_member" "demo_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.demo.email}"
}

# ─── Cloud Run service ────────────────────────────────────────────────────────

resource "google_cloud_run_v2_service" "demo" {
  name     = "landing-zone-demo"
  location = var.region

  deletion_protection = false

  template {
    service_account = google_service_account.demo.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = local.image

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle = true
        startup_cpu_boost = true
      }

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 3
      }

      liveness_probe {
        http_get {
          path = "/health"
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  labels = local.labels
}

# Public access — intentional for portfolio showcase
# In a real deployment this would be restricted to internal or via IAP
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.demo.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
