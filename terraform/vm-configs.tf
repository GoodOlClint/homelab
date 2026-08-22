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
    plex          = { index = 1, size_gb = 150 } # Library dir, 62 GB measured 2026-08-21
    plex_services = { index = 2, size_gb = 40 }  # arr configs 3 GB + postgres 0.6 GB + dumps, measured 2026-08-21
    openobserve   = { index = 3, size_gb = 100 } # OO stream 40 GB (db 1.8) + Prometheus TSDB 2.2 GB + Kuma/Grafana, measured 2026-08-21
    docker        = { index = 4, size_gb = 20 }  # Valheim config 0.5 GB + server/world backups 3.3 GB, measured 2026-08-21
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
    # docker-on-LXC. OpenObserve parquet + metadata.sqlite, the Prometheus TSDB,
    # Alertmanager state, Grafana and Uptime Kuma DBs all ride the data volume
    # (ADR 0015) under one mount; the rootfs holds only compose + config.
    {
      name         = "openobserve"
      type         = "lxc"
      node_name    = "ms-01b"
      vm_id        = 203 # old 103 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 103
      cpu_cores    = 4
      memory_mb    = 12288
      disk_size_gb = 20
      keyctl       = true
      data_volume  = { name = "openobserve", path = "/var/lib/monitoring" }
    },
    {
      name         = "proxmox-backup"
      vm_id        = 201 # old 101 + 100 (ADR 0028)
      node_name    = "ms-01b"
      vlans        = ["vlan10", "vlan40", "vlan20"] # vlan20 leg stays: the datastore is the Synology iSCSI LUN (ADR 0017 exception)
      ip_offset    = 101
      cpu_cores    = 4
      memory_mb    = 4096
      disk_size_gb = 20
      image        = "debian13" # PBS 4 is Debian-13-only (ADR 0025)
    },
    {
      name           = "unifi"
      vm_id          = 200 # old 100 + 100 (ADR 0028)
      mgmt_ip_offset = 10  # static management IP (decoupled from VMID)
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
      disk_size_gb = 20         # ISO + netboot initrd ≈ 6 GiB; all derived from the pinned ISO (ADR 0026)
      image        = "debian13" # proxmox-auto-install-assistant + signed shim/grub come from the Proxmox trixie repo
    },
  ]

  # --- Services VMs ---
  # Application services: media, containers, home automation, licensing
  services_vms = [
    # docker-on-LXC. Valheim config + world saves ride the data volume (ADR 0015);
    # the kiwix ZIM library (538 GB) stays on
    # NAS as node bind mounts (ADR 0017). No GPU: BOINC was decommissioned with
    # this rebuild (restorable from git history).
    {
      name         = "docker"
      type         = "lxc"
      node_name    = "ms-01a"
      vm_id        = 204 # old 104 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 104
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 32
      keyctl       = true
      data_volume  = { name = "docker", path = "/opt/docker" }
      bind_mounts = [
        { source = "/mnt/nas/docker/kiwix", path = "/mnt/kiwix", read_only = true },
      ]
    },
    # iGPU QuickSync via /dev/dri passthrough, by PCI path so it is the Intel
    # device on every node (msi's renderD128 is the Quadro); gids are the CT-side
    # render (991) and video (44) groups of the Ubuntu 26.04 template. Library on the plex
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
        { path = "/dev/dri/by-path/pci-0000:00:02.0-render", gid = 991 },
        { path = "/dev/dri/by-path/pci-0000:00:02.0-card", gid = 44 },
      ]
      data_volume = { name = "plex", path = "/var/lib/plexmediaserver" }
      bind_mounts = [
        { source = "/mnt/nas/plex/data/media", path = "/mnt/media", read_only = true },
      ]
    },
    # docker-on-LXC (nesting + keyctl). Configs, postgres data dir and the
    # pg_dump timer's output ride the data volume (ADR 0015); media is the
    # node's /mnt/nas/plex/data bind-mounted rw (ADR 0017) — the arrs write it.
    # SABnzbd's par2 scratch lives on the rootfs (/mnt/scratch).
    {
      name         = "plex-services"
      type         = "lxc"
      node_name    = "ms-01a"
      vm_id        = 206 # old 106 + 100 (ADR 0028)
      vlans        = ["vlan40"]
      ip_offset    = 106
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 64
      keyctl       = true
      media_idmap  = true
      data_volume  = { name = "plex_services", path = "/opt/plex-services" }
      bind_mounts = [
        { source = "/mnt/nas/plex/data", path = "/mnt/data" },
      ]
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
