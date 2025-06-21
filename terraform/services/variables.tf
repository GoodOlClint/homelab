variable "virtual_environment_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox Virtual Environment API (example: https://host:port)"
}

variable "virtual_environment_password" {
  type        = string
  description = "The password for the Proxmox Virtual Environment API"
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

variable "nvidia_url" {
  description = "Url containing the Nvidia Grid driver to download into VMs"
  type        = string
}

variable "vlans" {
  description = "Static VLAN configuration overrides (optional when using Unifi integration)"
  type = map(object({
    vlan_id     = number
    bridge      = string
    subnet      = string                 # IPv4 subnet
    subnet_v6   = optional(string, null) # IPv6 subnet - if null, IPv6 is disabled for this VLAN
    mtu         = optional(number, 1500)
    description = optional(string, "")
  }))
  default = {} # Empty by default when using Unifi integration
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

variable "unifi_network_mapping" {
  description = "Mapping of VLAN names to Unifi network names"
  type = map(object({
    unifi_network_name = string
    bridge             = string
    description        = optional(string, "")
    mtu                = optional(number, 1500)
  }))
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

variable "domain_suffix" {
  type        = string
  description = "Domain suffix for VM FQDNs"
}