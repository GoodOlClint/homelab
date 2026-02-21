# Infrastructure VM Configurations
# These VMs provide core infrastructure services like DNS, monitoring, and backup.
# This file is tracked in git as it represents infrastructure configuration

locals {
  vm_configurations = [
    {
      name         = "dns"
      vlans        = ["vlan10", "vlan100", "vlan20", "vlan110", "vlan120", "vlan121", "vlan130"]
      ip_offset    = 53 # Fixed IP .53 on service VLANs (e.g., vlan100=172.16.100.53)
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "adguard"
      vlans        = ["vlan10", "vlan100", "vlan40"] # vlan2 (DMZ) removed — decommissioned
      ip_offset    = 15 # .15 on service VLANs (vlan100=172.16.100.15, vlan40=172.16.40.15)
      cpu_cores    = 4
      memory_mb    = 2048
      disk_size_gb = 20
    },
    {
      name         = "openobserve"
      vlans        = ["vlan10", "vlan100"]
      cpu_cores    = 4
      memory_mb    = 16384 # Higher memory for log processing
      disk_size_gb = 50   # Storage for logs and metrics
    },
    {
      name         = "proxmox-backup"
      vlans        = ["vlan10", "vlan100", "vlan20"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 20
    },
    {
      name         = "unifi"
      vlans        = ["vlan10"]
      cpu_cores    = 4
      memory_mb    = 4096        # UniFi needs decent RAM for MongoDB
      disk_size_gb = 50          # Space for MongoDB + backups
    }
  ]
}
