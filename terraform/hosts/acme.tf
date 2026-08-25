# Node certs are certbot-issued by proxmox_host (ADR 0041); nothing here orders them. The
# provider verifies them against the Homelab Root CA the workstation trusts.
variable "insecure" {
  type        = bool
  default     = false
  description = "Skip API TLS verification — only while the nodes still serve self-signed certs"
}
