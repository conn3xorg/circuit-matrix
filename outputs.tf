output "service" {
  description = "The systemd service that runs Synapse on each host."
  value       = "matrix-synapse.service"
}

output "image" {
  description = "The Synapse image the hosts run."
  value       = "ghcr.io/element-hq/synapse:${var.synapse_version}"
}

output "local_url" {
  description = "Where Synapse listens on each host, for the reverse proxy in front of it."
  value       = local.local_url
}
