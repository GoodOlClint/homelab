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

  # Detached data volumes (ADR 0015): the WP4 fleet rebuild populates this map.
  # `index` is the volume's permanent disk slot on the holder VM (ADR 0020) —
  # assign the next free number (1..31) and NEVER renumber an existing volume.
  data_volumes = {
    plex = { index = 1, size_gb = 150 } # Library dir, 62 GB measured 2026-08-21
  }

  # --- Infrastructure VMs ---
  # Core infrastructure services: DNS, monitoring, backup, network management
  infrastructure_vms = [
    # Authoritative pair (ADR 0003): dns1 is the zone primary, dns2 a secondary
    # fed by AXFR; keepalived holds the BIND VIP (vlans.yaml dns_server.bind_ipv4,
    # ip_offset 15). VMID = 200 + ip_offset (ADR 0029); 13/14 would collide with
    # github-runner/squid's old+100 slots.
    {
      name         = "dns1"
      type         = "lxc"
      node_name    = "ms-01a"
      vm_id        = 218
      vlans        = ["vlan40"]
      ip_offset    = 18
      cpu_cores    = 2
      memory_mb    = 1024
      disk_size_gb = 10
    },
    {
      name         = "dns2"
      type         = "lxc"
      node_name    = "ms-01b"
      vm_id        = 219
      vlans        = ["vlan40"]
      ip_offset    = 19
      cpu_cores    = 2
      memory_mb    = 1024
      disk_size_gb = 10
    },
    # Resolver pair (ADR 0003): keepalived holds the client-facing VIP
    # (vlans.yaml dns_server.dns_ipv4/dns_ipv6); IPv6 is SLAAC because a static
    # CT v6 address makes PVE write IPv6AcceptRA=false (no default route).
    {
      name         = "adguard1"
      type         = "lxc"
      node_name    = "ms-01a"
      vm_id        = 251
      vlans        = ["vlan40"]
      ip_offset    = 51
      resolver     = true
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
    },
    {
      name         = "adguard2"
      type         = "lxc"
      node_name    = "ms-01b"
      vm_id        = 252
      vlans        = ["vlan40"]
      ip_offset    = 52
      resolver     = true
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
    },
    {
      name         = "openobserve"
      vm_id        = 103
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 103
      cpu_cores    = 4
      memory_mb    = 12288 # Log processing and queries
      disk_size_gb = 100   # Storage for logs and metrics (bumped from 50: fleet-wide syslog shipping — DSM, pve/worklab hosts — grew OO stream data into the 85% alert; pair with a retention cap)
    },
    {
      name         = "proxmox-backup"
      vm_id        = 101
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 101
      cpu_cores    = 4
      memory_mb    = 4096
      disk_size_gb = 20
    },
    {
      name           = "unifi"
      vm_id          = 200 # old 100 + 100 (ADR 0028)
      mgmt_ip_offset = 10 # static management IP (decoupled from VMID)
      vlans          = ["vlan10"]
      cpu_cores      = 4
      memory_mb      = 4096 # UniFi needs decent RAM for MongoDB
      disk_size_gb   = 50   # Space for MongoDB + backups
    },
    {
      name         = "infisical"
      vm_id        = 205 # old 105 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 105
      cpu_cores    = 4
      memory_mb    = 4096 # PostgreSQL + Redis + Infisical server
      disk_size_gb = 30   # Database growth, audit logs
      protected    = true # Secrets store — protect from accidental deletion
    },
    {
      name         = "apt-cache"
      vm_id        = 116
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 116
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 100 # apt-cacher-ng cache — disposable derived state (ADR 0021), no data volume
    },
    {
      name         = "pxe"
      vm_id        = 117
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 117
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 20 # ISO + netboot initrd ≈ 6 GiB; all derived from the pinned ISO (ADR 0026)
      image        = "debian13" # proxmox-auto-install-assistant + signed shim/grub come from the Proxmox trixie repo
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
      cpu_cores    = 4
      memory_mb    = 16384 # 16GB — Valheim, BOINC (GPU), Kiwix, Doge-node
      disk_size_gb = 100
    },
    # iGPU QuickSync via /dev/dri passthrough; gids are the CT-side render (991)
    # and video (44) groups of the Ubuntu 26.04 template. Library on the plex
    # data volume (ADR 0015), media via the host's /mnt/nas/plex mount (ADR 0017).
    {
      name         = "plex"
      type         = "lxc"
      node_name    = "ms-01b"
      vm_id        = 208 # old 108 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 108
      cpu_cores    = 8
      memory_mb    = 16384
      disk_size_gb = 20
      media_idmap  = true
      devices = [
        { path = "/dev/dri/renderD128", gid = 991 },
        { path = "/dev/dri/card1", gid = 44 },
      ]
      data_volume = { name = "plex", path = "/var/lib/plexmediaserver" }
      bind_mounts = [
        { source = "/mnt/nas/plex/data/media", path = "/mnt/media", read_only = true },
      ]
    },
    {
      name         = "plex-services"
      vm_id        = 106
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 106
      cpu_cores    = 4
      memory_mb    = 4096
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
      memory_mb    = 4096
      disk_size_gb = 20
    },
    {
      name         = "homepage"
      type         = "lxc"
      vm_id        = 211 # old 111 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 111
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
    },
    {
      name         = "minio"
      vm_id        = 112
      vlans        = ["vlan10", "vlan40", "vlan20"]
      ip_offset    = 112
      cpu_cores    = 4
      memory_mb    = 4096
      disk_size_gb = 20
    },
    {
      name         = "github-runner"
      vm_id        = 113
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 113
      cpu_cores    = 4
      memory_mb    = 8192 # dotnet builds + Terraform
      disk_size_gb = 50   # Runner workspace, SDK caches, Terraform providers
    },
    {
      name         = "squid"
      vm_id        = 114
      vlans        = ["vlan10", "vlan40", "vlan140"]
      ip_offset    = 114
      cpu_cores    = 4    # 4 cores — one per SMP worker (see squid_workers)
      memory_mb    = 4096 # 4 GB — needed for TCP buffer pool with many parallel spliced downloads
      disk_size_gb = 20
    },
    {
      name         = "mcp"
      vm_id        = 115
      vlans        = ["vlan10", "vlan40"]
      ip_offset    = 115
      cpu_cores    = 4
      memory_mb    = 8192 # ChromaDB HNSW index operations
      disk_size_gb = 200  # Vector index storage
    },
  ]
}
