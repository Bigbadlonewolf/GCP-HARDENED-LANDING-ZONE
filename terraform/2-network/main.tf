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
    prefix = "landing-zone/network"
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

# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "google_compute_network" "landing_zone" {
  name                    = "landing-zone-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Hardened VPC — no auto subnets, deny-all ingress by default"
}

# ─── Subnets ──────────────────────────────────────────────────────────────────

resource "google_compute_subnetwork" "private" {
  name          = "private-us-central1"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.landing_zone.id

  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─── Firewall rules ───────────────────────────────────────────────────────────

# Explicit deny-all ingress (makes posture visible in Security Command Center)
resource "google_compute_firewall" "deny_all_ingress" {
  name        = "deny-all-ingress"
  network     = google_compute_network.landing_zone.id
  direction   = "INGRESS"
  priority    = 65534
  description = "Deny all ingress by default. Explicit allow rules take higher priority."

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}

# Allow IAP for SSH — required for admin access without bastion
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "allow-iap-ssh"
  network     = google_compute_network.landing_zone.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Allow SSH only from Cloud IAP proxy. No direct internet SSH."

  target_tags = ["iap-ssh"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Cloud IAP source range — Google-managed, cannot be spoofed from internet
  source_ranges = ["35.235.240.0/20"]
}

# Allow internal traffic within the subnet
resource "google_compute_firewall" "allow_internal" {
  name        = "allow-internal"
  network     = google_compute_network.landing_zone.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Allow traffic between instances in the same VPC subnet"

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [google_compute_subnetwork.private.ip_cidr_range]
}

# Allow GCP health check probes (required for load balancers)
resource "google_compute_firewall" "allow_health_checks" {
  name        = "allow-health-checks"
  network     = google_compute_network.landing_zone.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Allow GCP load balancer health check probes"

  target_tags = ["load-balanced"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # GCP load balancer health check ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# Restrict egress — allow only Google APIs and internal, block everything else
resource "google_compute_firewall" "allow_egress_google_apis" {
  name        = "allow-egress-google-apis"
  network     = google_compute_network.landing_zone.id
  direction   = "EGRESS"
  priority    = 1000
  description = "Allow egress to Google API ranges only (Private Google Access)"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  # Google's global IP range for APIs
  destination_ranges = ["199.36.153.4/30", "199.36.153.8/30"]
}

resource "google_compute_firewall" "deny_all_egress" {
  name        = "deny-all-egress"
  network     = google_compute_network.landing_zone.id
  direction   = "EGRESS"
  priority    = 65534
  description = "Deny all egress by default. Only Google APIs allowed for private workloads."

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}
