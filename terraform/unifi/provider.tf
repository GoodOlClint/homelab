# UniFi controller provider — this root exists because the 0.55 provider
# eagerly connects at plan time, so it must never sit in the fleet project
# (same separate-plane rationale as terraform/hosts/, ADR-0002).
provider "unifi" {
  username = var.unifi_username
  password = var.unifi_password
  api_url  = var.unifi_api_url
  site     = var.unifi_site

  # Allow unverified TLS for local controllers
  allow_insecure = true
}
