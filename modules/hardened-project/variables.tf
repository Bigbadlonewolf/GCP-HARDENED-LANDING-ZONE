variable "project_id" {
  description = "GCP project ID to harden"
  type        = string
}

variable "team_name" {
  description = "Short name for the team (used in resource names and labels)"
  type        = string
}

variable "owner_email" {
  description = "Email of the team lead who owns this workspace"
  type        = string
}

variable "kms_region" {
  description = "Region for KMS key ring"
  type        = string
  default     = "us-central1"
}

variable "central_audit_bucket" {
  description = "Name of the central GCS audit log bucket (from the landing zone security layer)"
  type        = string
}

variable "environment" {
  description = "Environment label (prod, staging, dev)"
  type        = string
  default     = "prod"
}
