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
    image          = optional(string, null)        # Key in var.cloud_images (null = fleet default var.cloud_image). VM only — ADR 0025.
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
    nesting      = optional(bool, true)  # systemd >= 256 templates (Ubuntu 26.04) need it for networkd to bring up eth0; docker-on-LXC needs it too
    resolver     = optional(bool, false) # This guest IS a fleet resolver: keeps the public bootstrap failover in its CT nameserver list (ADR 0029)
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
    # Host-path bind mounts (ADR 0017: bulk storage reaches LXCs via host
    # mounts — the proxmox_host role mounts the NAS exports on every node).
    # Slot ordering: data_volume takes the first mount slot when present, then
    # bind_mounts in LIST ORDER — append-only, same never-reorder contract as
    # data_volumes indices. LXC only.
    bind_mounts = optional(list(object({
      source    = string # host path (e.g. /mnt/nas/media)
      path      = string # path inside the container
      read_only = optional(bool, false)
      shared    = optional(bool, true) # mark shared so migration checks pass (host role mounts it on every node)
    })), [])
    # Map the fleet media UID/GID range 1:1 into this unprivileged LXC so
    # bind-mounted NAS content stays writable under the ADR 0017 ownership
    # convention (without this, guest UID 2000 lands on host 102000). Requires
    # the node subuid/subgid delegation the proxmox_host role installs.
    media_idmap = optional(bool, false)
    # Additional disks (beyond the primary OS disk; VM only)
    extra_disks = optional(list(object({
      size_gb = number                 # Disk size in GB
      storage = optional(string, null) # Storage pool (uses primary_disk_storage if null)
    })), [])
    # Additional cloud-init or VM configuration options
    extra_config = optional(map(string), {})
  }))

  # `image` selects a VM cloud image. Containers build from var.lxc_template and
  # ignore it entirely, so an LXC carrying one would silently come up on the
  # wrong OS — the same failure the use_packer_template precondition exists to
  # stop. Caught here rather than in the container resource so both guest types
  # are covered by one rule.
  validation {
    condition     = alltrue([for vm in var.vm_configurations : vm.image == null || vm.type != "lxc"])
    error_message = "An LXC guest cannot set `image` — containers build from var.lxc_template. Roll that pin instead (ADR 0016/0025)."
  }
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

# Extra pinned images for guests that cannot run the fleet default (ADR 0025:
# PBS 4 is Debian-13-only while the rest of the fleet is Ubuntu). Same ADR 0016
# contract as cloud_image — explicit version URL + checksum, never 'current'.
# A guest opts in with `image = "<key>"`; omitting it keeps the fleet default.
variable "cloud_images" {
  description = "Additional pinned cloud images by name, for guests overriding the fleet default"
  type = map(object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha256")
  }))
  default = {}
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

# Detached data volumes (ADR 0015, holder VM per ADR 0020): raw disks owned by a
# never-started holder VM, so destroying any consuming guest never deletes the
# data. `index` pins the holder disk slot (scsi<index-1>) — NEVER renumber an
# existing volume's index. Gaps are allowed (retired volumes may leave one);
# consumers resolve volumes from holder state, not list position. Each new
# volume needs a one-time mkfs.ext4 + chown before its first consumer starts.
variable "data_volumes" {
  description = "Map of detached data volumes: name => { index (stable scsi slot, never renumber), size_gb, storage }"
  type = map(object({
    index   = number
    size_gb = number
    storage = optional(string, null) # Uses primary_disk_storage if null
  }))
  default = {}

  validation {
    condition     = length(distinct([for v in var.data_volumes : v.index])) == length(var.data_volumes)
    error_message = "data_volumes indices must be unique — they are stable disk slots on the holder VM."
  }

  # scsi0..scsi30 is PVE's SCSI slot range; index must be a whole number or the
  # derived interface name is garbage ("scsi0.5")
  validation {
    condition     = alltrue([for v in var.data_volumes : v.index >= 1 && v.index <= 31 && v.index == floor(v.index)])
    error_message = "data_volumes indices must be integers between 1 and 31 (holder VM scsi slots)."
  }
}

# Fleet media ownership range mapped by media_idmap guests (ADR 0017). Must
# match proxmox_host_media_idmap_start/size on the nodes.
variable "media_idmap_uid" {
  type        = number
  description = "First UID/GID of the fleet media range mapped 1:1 into media_idmap LXCs"
  default     = 2000
}

variable "media_idmap_size" {
  type        = number
  description = "Length of the fleet media UID/GID range"
  default     = 11
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

# Static VLAN configuration
variable "vlans" {
  description = "Static VLAN configuration - defines all VLANs used by VMs"
  type = map(object({
    vlan_id     = number
    bridge      = string
    subnet      = string                 # IPv4 subnet
    subnet_v6   = optional(string, null) # IPv6 subnet - if null, IPv6 is disabled for this VLAN
    mtu         = optional(number, 1500)
    description = optional(string, "")
    # Router on this VLAN. "auto" = first host address (.1); "none" = NO router
    # (storage/cluster VLANs have no gateway); anything else = literal address.
    # A VLAN with no gateway is skipped when choosing the default-route interface
    # and emits no route at all — see vm_gateway_vlans in virtual_machines.tf.
    gateway = optional(string, "auto")
  }))
  default = {}
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
  description = "cloud-init FQDN domain for the VM fleet — pinned like an OS image (ADR 0016): a change replaces every VM, so it moves to the service domain only with a deliberate roll"
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
