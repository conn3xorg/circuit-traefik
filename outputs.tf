output "static_config" {
  description = "The static configuration the circuit writes to /etc/traefik/traefik.yml."
  value       = local.static_yaml
}

output "dynamic_config" {
  description = "The routers and services the circuit writes to /etc/traefik/dynamic/conn3x.yml."
  value       = local.dynamic_yaml
}

output "version" {
  description = "The Traefik version the circuit installs."
  value       = var.traefik_version
}
