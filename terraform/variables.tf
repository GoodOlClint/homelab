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

# ──────────────────────────────────────────────
# Pinned guest OS images (ADR 0016)
# Bumping these defaults IS the deliberate image roll: the commit shows the new
# version, plan shows exactly which guests replace, and the roll happens
# per-guest via `make rebuild <guest>`. Never point these at "current"/latest.
# ──────────────────────────────────────────────

variable "cloud_image" {
  description = "Pinned Ubuntu cloud image for VMs (explicit release + checksum — ADR 0016)"
  type = object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha256")
  })
  default = {
    url       = "https://cloud-images.ubuntu.com/noble/20260725/noble-server-cloudimg-amd64.img"
    file_name = "noble-server-cloudimg-amd64-20260725.img"
    checksum  = "d1940f7d69d343355e183dff1e08a59852d32e7309baa7a4bad8365b11b005ac"
  }
}

# Extra pinned images for guests that cannot run the fleet default (ADR 0025).
# PBS 4 is Debian-13-only; the rest of the fleet stays Ubuntu. A guest opts in
# with `image = "debian13"` in vm-configs.tf. Same roll discipline as
# cloud_image: bumping the pin here IS the deliberate roll for those guests.
variable "cloud_images" {
  description = "Additional pinned cloud images by name (ADR 0016 contract, ADR 0025 rationale)"
  type = map(object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha256")
  }))
  default = {
    # PVE's iso datastore rejects a .qcow2 extension, so file_name renames it
    # to .img on the way in — the payload is qcow2 either way.
    debian13 = {
      url                = "https://cloud.debian.org/images/cloud/trixie/20260810-2566/debian-13-genericcloud-amd64-20260810-2566.qcow2"
      file_name          = "debian-13-genericcloud-amd64-20260810.img"
      checksum           = "0ce1f1d675733027d3e17a4665cb95e1d7173bdf67fb8a87ff822ff5ee025bc2a90ecb270465ef395755e41c868b40072eb9ac493810196d9cf68f941afb93dc"
      checksum_algorithm = "sha512"
    }
  }
}

variable "lxc_template" {
  description = "Pinned LXC template for containers (explicit release + checksum — ADR 0016)"
  type = object({
    url                = string
    file_name          = string
    checksum           = string
    checksum_algorithm = optional(string, "sha512")
  })
  default = {
    url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    checksum  = "45c2978e6b97fe292ada95fe06834276015e5739a594db4de2fdfd830fa0c37942e8ae118fc1e32ffd9154b3f9378b592738b668ea3957db41f2907b86f219de"
  }
}

variable "proxmox_nodes" {
  description = "All cluster node names (SDN zones span these). Defaults to the single API node until the cluster cutover."
  type        = list(string)
  default     = null
}

variable "unprotect" {
  type        = bool
  description = "Override all VM protection flags to false (used by make clean FORCE=true)"
  default     = false
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

# Which plane carries SSH/Ansible access to guests (audit 2026-08-10 / ADR 0017).
# "management" = vlan10 IPs (the live dual-homed fleet). Flip to "services" in
# vars.auto.tfvars at cutover, when guests are single-homed on the services VLAN
# and vlan10 has zero guests — ansible_host then resolves to the services IP.
variable "guest_access_plane" {
  type        = string
  description = "Inventory access plane for ansible_host: management (pre-cutover) or services (ADR 0017 end state)"
  default     = "management"

  validation {
    condition     = contains(["management", "services"], var.guest_access_plane)
    error_message = "guest_access_plane must be \"management\" or \"services\"."
  }
}

# PVE backup jobs → PBS (B3, audit 2026-08-10). Empty until the WP4 fleet
# manifest lands. Storage id must be registered first: make backup-finalize.
# vmids are strings (bpg schema); all=true backs up every guest instead.
variable "backup_jobs" {
  description = "PVE backup jobs keyed by job id: schedule + PBS storage + guest selection + retention"
  type = map(object({
    schedule = string                       # e.g. "02:30" or "mon..fri 03:00"
    storage  = string                       # PVE storage id (backup-finalize registers "pbs")
    vmids    = optional(list(string), null) # explicit guest VMIDs (null with all=true = everything)
    all      = optional(bool, false)
    mode     = optional(string, "snapshot")
    # protected backups are exempt from pruning AND datastore retention —
    # default-on would grow storage until it fills. Reserve for deliberately
    # retained jobs.
    protected = optional(bool, false)
    prune_backups = optional(map(string), {
      keep-daily   = "7"
      keep-weekly  = "4"
      keep-monthly = "3"
    })
  }))
  default = {}

  validation {
    condition     = alltrue([for j in var.backup_jobs : (j.all || (j.vmids != null && length(j.vmids) > 0))])
    error_message = "each backup job needs vmids or all=true — an empty job silently backs up nothing."
  }

  validation {
    condition     = alltrue([for j in var.backup_jobs : !(j.all && j.vmids != null)])
    error_message = "all=true and vmids are mutually exclusive (bpg declares them conflicting)."
  }
}
