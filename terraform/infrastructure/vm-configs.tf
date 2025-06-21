# Infrastructure VM Configurations
# These VMs provide core infrastructure services like DNS, monitoring, and backup.
# This file is tracked in git as it represents infrastructure configuration

locals {
  vm_configurations = [
    {
      name         = "dns"
      vlans        = ["vlan100", "vlan20", "vlan110", "vlan120", "vlan121", "vlan130"]
      ip_offset    = 53 # Fixed IP .53 for DNS (port 53 reference)
      cpu_cores    = 2
      memory_mb    = 512 # Low memory for AdGuard Home DNS
      disk_size_gb = 10
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
