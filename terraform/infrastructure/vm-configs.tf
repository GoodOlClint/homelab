# Infrastructure VM Configurations
# These VMs provide core infrastructure services like DNS, monitoring, and backup.
# This file is tracked in git as it represents infrastructure configuration

locals {
  vm_configurations = [
    {
      name         = "dns"
      vlans        = ["vlan100", "vlan20", "vlan110", "vlan120", "vlan121", "vlan130"]
      ip_offset    = 53 # Fixed IP .53 for Bind9 DNS
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "adguard"
      vlans        = ["vlan2", "vlan100"]
      ip_offset    = 15 # .15 IP for AdGuard on dmz
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "openobserve"
      vlans        = ["vlan100"]
      cpu_cores    = 4
      memory_mb    = 8192 # Higher memory for log processing
      disk_size_gb = 50   # Storage for logs and metrics
    },
    {
      name         = "proxmox-backup"
      vlans        = ["vlan100", "vlan20"]
      cpu_cores    = 4
      memory_mb    = 4096
      disk_size_gb = 20
    }
  ]
}
