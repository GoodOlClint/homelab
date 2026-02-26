# Proxmox node/storage variables (provider credentials configured at root level)
variable "virtual_environment_node" {
  type        = string
  description = "The name of the node in the proxmox datacenter to perform actions against"
}

variable "virtual_environment_storage" {
  type        = string
  description = "The name of the storage in the proxmox datacenter"
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

# Storage variables
variable "primary_disk_storage" {
  type        = string
  description = "The storage backend for primary VM disks (e.g., iscsi-ssd-lvm)"
  default     = "iscsi-ssd-lvm"
}

# IPv6 Configuration
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

# VM Configuration
variable "vm_configurations" {
  description = "VM configuration mapping - list of VMs to create with their specifications"
  type = list(object({
    name         = string                        # Unique VM name (used for hostname if hostname not specified)
    vm_id           = optional(number, null)        # Explicit Proxmox VMID (also sets static management IP). null = auto-assign + DHCP on management VLAN.
    mgmt_ip_offset  = optional(number, null)        # Override management IP offset (default: use vm_id). Decouples management IP from VMID.
    vlans        = list(string)                  # List of VLAN names to connect VM to (must exist in vlans variable)
    ip_offset    = optional(number, null)        # Static IP offset within VLAN subnet (null = DHCP)
    ipv6_offset  = optional(number, null)        # Static IPv6 offset within VLAN subnet (null = SLAAC/auto)
    ipv6_mode    = optional(string, "auto")      # IPv6 mode: "static", "slaac", "disabled", or "auto"
    cpu_cores    = optional(number, 4)           # Number of CPU cores to assign
    cpu_type     = optional(string, "x86-64-v3") # CPU type/architecture
    memory_mb    = optional(number, 4096)        # Memory in MB
    disk_size_gb = optional(number, 10)          # Primary disk size in GB
    disk_storage = optional(string, null)        # Storage pool for disk (uses primary_disk_storage if null)
    hostname     = optional(string, null)        # Custom hostname (uses name if null)
    fqdn         = optional(string, null)        # Custom FQDN (uses name.domain_suffix if null)
    needs_gpu    = optional(bool, false)         # Enable GPU passthrough (requires gpu_mapping configuration)
    protected    = optional(bool, false)         # Proxmox VM protection — prevents accidental deletion
    # Additional cloud-init or VM configuration options
    extra_config = optional(map(string), {})
  }))
}

variable "unprotect" {
  type        = bool
  description = "Override all VM protection flags to false (for teardown)"
  default     = false
}

variable "gpu_mapping" {
  description = "GPU mapping configuration for VMs that need GPU passthrough (used when needs_gpu=true)"
  type = object({
    device  = string # PCI device name (e.g., "hostpci0")
    mapping = string # Proxmox GPU mapping name (configured in Proxmox GUI)
    mdev    = string # Mediated device type (for GPU sharing/virtualization)
  })
  default = {
    device  = "hostpci0"
    mapping = "Nvidia-GPU"
    mdev    = "nvidia-256"
  }
}

# Static VLAN configuration (required)
variable "vlans" {
  description = "Static VLAN configuration - defines all VLANs used by VMs"
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

# Module-specific variables
variable "ssh_public_key_path" {
  type        = string
  description = "Path to SSH public key file"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "virtual_machine_password_hash" {
  type        = string
  description = "Password hash for VM user account (optional - if not provided, password authentication will be disabled)"
  default     = null
  sensitive   = true
}

variable "create_cloud_image" {
  type        = bool
  description = "Whether to create/download the Ubuntu cloud image"
  default     = true
}

variable "domain_suffix" {
  type        = string
  description = "Domain suffix for VM FQDNs (sourced from vlans.yaml)"
}

# Packer template configuration
variable "use_packer_template" {
  type        = bool
  description = "Use Packer-built template instead of cloud image (no cloud-init)"
  default     = false
}

variable "packer_template_name" {
  type        = string
  description = "Name of Packer template to use (empty = auto-detect latest ubuntu-24.04-base-* template)"
  default     = ""
}

variable "packer_template_vm_id" {
  type        = number
  description = "Packer template VM ID for cloning (if null, will try auto-detection)"
  default     = null
}

variable "management_vlan" {
  type        = string
  description = "VLAN key for management access (SSH/Ansible). Management IP is computed from VMID as cidrhost(mgmt_subnet, vm_id)."
  default     = "vlan10"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers applied to all VM interfaces via cloud-init (sourced from network-data/vlans.yaml)"
  default     = []
}
