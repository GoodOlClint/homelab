# Services VM Configurations
# These are the actual VM configurations for the services environment
# This file is tracked in git as it represents infrastructure configuration

locals {
  vm_configurations = [
    {
      name         = "docker"
      vlans        = ["vlan100", "vlan20"]
      cpu_cores    = 16
      memory_mb    = 65536 # 64GB
      disk_size_gb = 100
      needs_gpu    = true # GPU passthrough for container workloads
    },
    {
      name         = "plex"
      vlans        = ["vlan100", "vlan20"]
      cpu_cores    = 8
      memory_mb    = 16384
      disk_size_gb = 40
      needs_gpu    = true # GPU for hardware transcoding
    },
    {
      name         = "plex-services"
      vlans        = ["vlan100", "vlan20"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 256
    },
    {
      name         = "homebridge"
      vlans        = ["vlan100"]
      cpu_cores    = 6
      memory_mb    = 8192
      disk_size_gb = 20
    },
    {
      name         = "multicast-relay"
      vlans        = ["vlan100", "vlan120", "vlan121", "vlan130"] # Multi-VLAN for routing
      ip_offset    = 50                                           # Fixed IP for network routing
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "nvidia-licensing"
      vlans        = ["vlan100"]
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 20
    }
  ]
}
