# VM Configurations
# All homelab VMs defined in a single file, organized by function.
# vm_id: Explicit Proxmox VMID → static management IP derived from VMID
# ip_offset: Static IP on service/storage VLANs at given offset
# Omit vm_id for DHCP fallback on management VLAN (auto-assigned VMID).

locals {
  vm_configurations = concat(
    local.infrastructure_vms,
    local.services_vms,
  )

  # --- Infrastructure VMs ---
  # Core infrastructure services: DNS, monitoring, backup, network management
  infrastructure_vms = [
    {
      name         = "dns"
      vm_id        = 109
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 15
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "adguard"
      vm_id        = 102
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 53  # .53 on service VLANs
      ipv6_offset  = 53  # ::35 on service VLANs
      ipv6_mode    = "static"
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "openobserve"
      vm_id        = 103
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 103
      cpu_cores    = 4
      memory_mb    = 16384 # Higher memory for log processing
      disk_size_gb = 50    # Storage for logs and metrics
    },
    {
      name         = "proxmox-backup"
      vm_id        = 101
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 101
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 20
    },
    {
      name            = "unifi"
      vm_id           = 100
      mgmt_ip_offset  = 10 # static management IP (decoupled from VMID)
      vlans           = ["vlan10"]
      cpu_cores       = 4
      memory_mb       = 4096 # UniFi needs decent RAM for MongoDB
      disk_size_gb    = 50   # Space for MongoDB + backups
    },
    {
      name         = "infisical"
      vm_id        = 105
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 105
      cpu_cores    = 4
      memory_mb    = 4096 # PostgreSQL + Redis + Infisical server
      disk_size_gb = 30   # Database growth, audit logs
      protected    = true # Secrets store — protect from accidental deletion
    },
  ]

  # --- Services VMs ---
  # Application services: media, containers, home automation, licensing
  services_vms = [
    {
      name         = "docker"
      vm_id        = 104
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 104
      cpu_cores    = 16
      memory_mb    = 65536 # 64GB
      disk_size_gb = 100
      needs_gpu    = true # GPU passthrough for container workloads
    },
    {
      name         = "plex"
      vm_id        = 108
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 108
      cpu_cores    = 8
      memory_mb    = 32768
      disk_size_gb = 100
      needs_gpu    = true # GPU for hardware transcoding
    },
    {
      name         = "plex-services"
      vm_id        = 106
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 106
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 256
      extra_disks  = [{ size_gb = 100 }] # Scratch disk for SABnzbd par2 repair
    },
    {
      name         = "nvidia-licensing"
      vm_id        = 107
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 107
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "lancache"
      vm_id        = 110
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 110
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 20
    },
    {
      name         = "homepage"
      vm_id        = 111
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 111
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
    },
  ]
}
