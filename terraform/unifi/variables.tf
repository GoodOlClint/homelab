# TF_VAR_unifi_password is exported by the Makefile from bootstrap.sops.yml
# (unifi_admin_password). The non-secret values live in the gitignored
# vars.auto.tfvars (copy vars.auto.tfvars.example).
variable "unifi_username" {
  type        = string
  description = "Username for Unifi Controller API access"
}

variable "unifi_password" {
  type        = string
  description = "Password for Unifi Controller API access"
  sensitive   = true
}

variable "unifi_api_url" {
  type        = string
  description = "URL for Unifi Controller API (e.g., https://unifi.example.com:8443)"
}

variable "unifi_site" {
  type        = string
  description = "Unifi site name"
  default     = "default"
}
