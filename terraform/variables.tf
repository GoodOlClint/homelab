variable "virtual_environment_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox Virtual Environment API (example: https://host:port)"
}

variable "virtual_environment_password" {
  type        = string
  description = "The password for the Proxmox Virtual Environment API"
  sensitive   = true
}

variable "virtual_environment_username" {
  type        = string
  description = "The username and realm for the Proxmox Virtual Environment API (example: root@pam)"
}

variable "virtual_environment_node" {
  type        = string
  description = "The name of the node in the proxmox datacenter to perform actions against"
}

variable "virtual_environment_storage" {
  type        = string
  description = "The name of the strorage in the proxmox datacenter"
}

variable "virtual_machine_timezone" {
  type        = string
  description = "The timezone to set for Virtual Machines via cloud-init"
  default     = "America/Chicago"
}

variable "virtual_machine_username" {
  type        = string
  description = "The username to add in Virtual Machines via cloud-init"
}

variable "virtual_machine_password_hash" {
  type        = string
  description = "Password hash for VM user account (optional - if not provided, password authentication will be disabled)"
  default     = null
  sensitive   = true
}

variable "ipv6_config" {
  description = "Global IPv6 configuration options"
  type = object({
    enabled            = optional(bool, true)   # Global IPv6 enable/disable
    auto_detect_prefix = optional(bool, false)  # Try to auto-detect RA prefixes
    fallback_to_slaac  = optional(bool, true)   # Use SLAAC if static config fails
    base_prefix        = optional(string, null) # Base prefix for manual subnets (e.g., "2600:8804:81c3::/48")
  })
  default = {
    enabled            = true
    auto_detect_prefix = false
    fallback_to_slaac  = true
    base_prefix        = null
  }
}

variable "gpu_mapping" {
  description = "GPU mapping configuration for VMs that need GPU passthrough"
  type = object({
    device  = string
    mapping = string
    mdev    = string
  })
  default = {
    device  = "hostpci0"
    mapping = "Nvidia-GPU"
    mdev    = "nvidia-256"
  }
}

variable "primary_disk_storage" {
  type        = string
  description = "The storage backend for primary VM disks (e.g., iscsi-ssd-lvm)"
  default     = "iscsi-ssd-lvm"
}

variable "secondary_disk_storage" {
  type        = string
  description = "The storage backend for secondary VM disks (e.g., iscsi-hdd-lvm)"
  default     = "iscsi-hdd-lvm"
}

# Unifi Controller Configuration
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
  description = "Unifi site name (default: 'default')"
  default     = "default"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key file"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "create_cloud_image" {
  type        = bool
  description = "Whether to create/download the Ubuntu cloud image"
  default     = true
}

# Packer template configuration
variable "use_packer_template" {
  type        = bool
  description = "Use Packer-built template instead of cloud image (no cloud-init)"
  default     = false
}

variable "packer_template_name" {
  type        = string
  description = "Name of Packer template to use (empty = auto-detect latest)"
  default     = ""
}

# ──────────────────────────────────────────────
# Vultr VPS Configuration
# ──────────────────────────────────────────────

variable "vultr_api_key" {
  type        = string
  description = "Vultr API key for VPS provisioning"
  sensitive   = true
}

variable "vps_region" {
  type        = string
  description = "Vultr region for VPS deployment"
  default     = "dfw"
}

variable "vps_plan" {
  type        = string
  description = "Vultr plan for VPS instance (vc2-1c-1gb = $5/mo: 1 vCPU, 1GB RAM, 1TB bandwidth)"
  default     = "vc2-1c-1gb"
}

variable "vps_label" {
  type        = string
  description = "Label for the VPS instance"
  default     = "wireguard-relay"
}

variable "vps_provisioning" {
  type        = bool
  description = "When true, opens SSH in Vultr firewall for initial provisioning. Set to false after first Ansible run."
  default     = false
}

# ──────────────────────────────────────────────
# Cloudflare Configuration
# ──────────────────────────────────────────────

variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token for DNS management"
  sensitive   = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for clintflix.tv"
}
