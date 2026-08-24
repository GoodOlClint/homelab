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
    plex_services = { index = 2, size_gb = 40 }  # retired with LXC 206 (ADR 0037, state moved to cluster PVCs); slot stays until the decommission sweep
    openobserve   = { index = 3, size_gb = 100 } # retired with LXC 203 (ADR 0036, history moved to cluster PVCs); slot stays until the decommission sweep
    docker        = { index = 4, size_gb = 20 }  # Valheim config 0.5 GB + server/world backups 3.3 GB, measured 2026-08-21
    control       = { index = 5, size_gb = 10 }  # MeshCentral data/files + Portainer state (ADR 0030)
  }

  # --- Infrastructure VMs ---
  # Core infrastructure services: DNS, monitoring, backup, network management
  infrastructure_vms = [
    # Authoritative pair (ADR 0003): dns1 is the zone primary, dns2 a secondary
    # fed by AXFR; keepalived holds the BIND VIP (vlans.yaml dns_server.bind_ipv4,
    # ip_offset 15). VMID = 200 + ip_offset (ADR 0029); 13/14 would collide with
    # squid's old+100 slot (github-runner 113 retired to ARC, ADR 0034).
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
    {
      name         = "proxmox-backup"
      vm_id        = 201 # old 101 + 100 (ADR 0028)
      node_name    = "ms-01b"
      # Hypervisor plane (ADR 0030) + the vlan20 leg for the Synology iSCSI LUN (ADR 0017 exception).
      # ip_offset 101 keeps the LUN-side address; on vlan30 it sits inside the DHCP pool (pfSense probes before leasing).
      vlans        = ["vlan30", "vlan20"]
      ip_offset    = 101
      cpu_cores    = 4
      memory_mb    = 4096
      disk_size_gb = 20
      image        = "debian13" # PBS 4 is Debian-13-only (ADR 0025)
    },
    # Out-of-band control plane (ADR 0030): MeshCentral + Portainer server on the
    # management VLAN; mgmt_ip_offset keeps it out of the DHCP pool.
    {
      name           = "control"
      type           = "lxc"
      node_name      = "ms-01b"
      vm_id          = 212
      mgmt_ip_offset = 12
      vlans          = ["vlan10"]
      cpu_cores      = 2
      memory_mb      = 2048
      disk_size_gb   = 10
      keyctl         = true
      data_volume    = { name = "control", path = "/opt/control" }
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
      vm_id        = 216 # old 116 + 100 (ADR 0028); hypervisor plane (ADR 0030)
      vlans        = ["vlan30"]
      ip_offset    = 16
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 100 # apt-cacher-ng cache — disposable derived state (ADR 0021), no data volume
    },
    # Human management pane for the cluster + worklab (ADR 0030); class S, no volume.
    {
      name         = "pdm"
      vm_id        = 220
      vlans        = ["vlan30"]
      ip_offset    = 20
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 20
      image        = "debian13"
    },
    {
      name         = "pxe"
      vm_id        = 217 # old 117 + 100 (ADR 0028); hypervisor plane (ADR 0030)
      vlans        = ["vlan30"]
      ip_offset    = 17
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
