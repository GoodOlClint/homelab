variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL (e.g., https://proxmox.example.com:8006/api2/json)"
}

variable "proxmox_username" {
  type        = string
  description = "Proxmox API username (e.g., root@pam)"
}

variable "proxmox_token" {
  type        = string
  description = "Proxmox API token (use token instead of password for security)"
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name where template will be created"
}

variable "insecure_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification for self-signed certificates"
  default     = true
}

variable "iso_url" {
  type        = string
  description = "URL to Ubuntu 24.04 LTS ISO"
  default     = "https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 checksum of the ISO file"
  default     = "e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
}

variable "iso_storage_pool" {
  type        = string
  description = "Proxmox storage pool for ISO files"
  default     = "local"
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool for VM disk"
}

variable "network_bridge" {
  type        = string
  description = "Network bridge for VM (e.g., vmbr0)"
  default     = "vmbr0"
}

variable "ssh_password" {
  type        = string
  description = "Temporary SSH password for packer user during build"
  sensitive   = true
  default     = "packer"
}
