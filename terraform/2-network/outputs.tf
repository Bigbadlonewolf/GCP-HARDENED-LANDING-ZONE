output "vpc_id" {
  description = "VPC network self-link"
  value       = google_compute_network.landing_zone.self_link
}

output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.landing_zone.name
}

output "private_subnet_id" {
  description = "Private subnet self-link"
  value       = google_compute_subnetwork.private.self_link
}

output "private_subnet_cidr" {
  description = "Private subnet CIDR range"
  value       = google_compute_subnetwork.private.ip_cidr_range
}
