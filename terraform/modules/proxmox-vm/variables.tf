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

# Guest Configuration (VMs and LXCs — ADR 0003: LXC by default, VM where isolation demands)
variable "vm_configurations" {
  description = "Guest configuration mapping - list of VMs/LXCs to create with their specifications"
  type = list(object({
    name           = string                        # Unique guest name (used for hostname if hostname not specified)
    type           = optional(string, "vm")        # Guest type: "vm" or "lxc"
    node_name      = optional(string, null)        # Cluster node placement (null = module default node)
    ha             = optional(bool, false)         # Register as an HA resource (requires vm_id and Ceph-backed disk)
    vm_id          = optional(number, null)        # Explicit Proxmox VMID (also sets static management IP). null = auto-assign + DHCP on management VLAN.
    mgmt_ip_offset = optional(number, null)        # Override management IP offset (default: use vm_id). Decouples management IP from VMID.
    vlans          = list(string)                  # List of VLAN names to connect guest to (must exist in vlans variable)
    ip_offset      = optional(number, null)        # Static IP offset within VLAN subnet (null = DHCP; LXCs must be static — ADR 0003)
    ipv6_offset    = optional(number, null)        # Static IPv6 offset within VLAN subnet (null = SLAAC/auto)
    ipv6_mode      = optional(string, "auto")      # IPv6 mode: "static", "slaac", "disabled", or "auto"
    cpu_cores      = optional(number, 4)           # Number of CPU cores to assign
    cpu_type       = optional(string, "x86-64-v3") # CPU type/architecture (VM only)
    memory_mb      = optional(number, 4096)        # Memory in MB
    disk_size_gb   = optional(number, 10)          # Primary/rootfs disk size in GB
    disk_storage   = optional(string, null)        # Storage pool for disk (uses primary_disk_storage if null)
    hostname       = optional(string, null)        # Custom hostname (uses name if null)
    fqdn           = optional(string, null)        # Custom FQDN (uses name.domain_suffix if null)
    protected      = optional(bool, false)         # Proxmox guest protection — prevents accidental deletion
    # LXC-only options
    unprivileged = optional(bool, true)  # Unprivileged container (LXC only)
    nesting      = optional(bool, false) # Enable nesting (docker-on-LXC)
    keyctl       = optional(bool, false) # Enable keyctl (docker-on-LXC)
    devices = optional(list(object({     # Host device passthrough (e.g. /dev/dri for QuickSync)
      path = string
      uid  = optional(number, null)
      gid  = optional(number, null)
      mode = optional(string, null)
    })), [])
    # Detached data volume attachment (ADR 0015): name references var.data_volumes;
    # LXCs mount it at `path`, VMs get it attached as the next virtio disk (role formats/mounts it)
    data_volume = optional(object({
      name = string
      path = optional(string, "/data") # Mount path inside the guest (LXC only)
    }), null)
    # Additional disks (beyond the primary OS disk; VM only)
    extra_disks = optional(list(object({
      size_gb = number                 # Disk size in GB
      storage = optional(string, null) # Storage pool (uses primary_disk_storage if null)
    })), [])
    # Additional cloud-init or VM configuration options
    extra_config = optional(map(string), {})
  }))
}

# Pinned guest OS images (ADR 0016 — bumping these is the deliberate image roll)
variable "cloud_image" {
  description = "Pinned Ubuntu cloud image for VMs (ADR 0016: explicit version URL + checksum, never 'current')"
  type = object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha256")
  })
}

variable "lxc_template" {
  description = "Pinned LXC template for containers (ADR 0016)"
  type = object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha512")
  })
}

# Detached data volumes (ADR 0015): formatted CT volumes owned by a never-started
# holder container, so destroying any consuming guest never deletes the data.
# `index` fixes the mount-point slot on the holder — NEVER renumber an existing
# volume's index; that would remap live data volumes across mount slots.
variable "data_volumes" {
  description = "Map of detached data volumes: name => { index (stable slot, never renumber), size_gb, storage }"
  type = map(object({
    index   = number
    size_gb = number
    storage = optional(string, null) # Uses primary_disk_storage if null
  }))
  default = {}

  validation {
    condition     = length(distinct([for v in var.data_volumes : v.index])) == length(var.data_volumes)
    error_message = "data_volumes indices must be unique — they are stable mount-point slots on the holder container."
  }
}

variable "data_volume_holder_vmid" {
  type        = number
  description = "Reserved VMID for the never-started data-volume holder container (ADR 0015)"
  default     = 900
}

variable "unprotect" {
  type        = bool
  description = "Override all VM protection flags to false (for teardown)"
  default     = false
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

variable "services_vlan" {
  type        = string
  description = "VLAN key for services access (user-facing). Service IP is computed from ip_offset as cidrhost(services_subnet, ip_offset). Falls back to management IP when VM doesn't have this VLAN."
  default     = "vlan40"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers applied to all VM interfaces via cloud-init (sourced from network-data/vlans.yaml)"
  default     = []
}
