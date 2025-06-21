# Multicast relay specific configuration
# This file handles the special configuration needed for the multicast-relay VM

locals {
  # Multicast relay configuration - only if multicast-relay VM exists
  multicast_vlan_relay_map = {
    vlan100 = ["vlan120", "vlan121"]
    vlan120 = ["vlan100"]
    vlan121 = ["vlan100", "vlan130"]
    vlan130 = ["vlan121"]
  }

  # Check if multicast-relay VM exists in the configuration
  has_multicast_relay = contains([for vm in local.vm_configurations : vm.name], "multicast-relay")

  # Build multicast interface filter for multicast-relay VM
  multicast_iffilter = local.has_multicast_relay ? {
    for vlan_key, iface in module.services_vms.vm_interfaces["multicast-relay"] :
    module.services_vms.merged_vlans[vlan_key].subnet => [
      for allowed_vlan in try(local.multicast_vlan_relay_map[vlan_key], []) :
      "eth_${allowed_vlan}"
      if contains(keys(module.services_vms.vm_interfaces["multicast-relay"]), allowed_vlan)
    ]
  } : {}
}

# Generate ifFilter.json file for multicast relay configuration
resource "local_file" "multicast_iffilter_json" {
  count = local.has_multicast_relay ? 1 : 0

  content  = jsonencode(local.multicast_iffilter)
  filename = "${path.module}/ifFilter.json"
}

# Output multicast configuration for debugging
output "multicast_iffilter" {
  description = "Multicast interface filter configuration for multicast-relay VM"
  value       = local.multicast_iffilter
}

output "has_multicast_relay" {
  description = "Whether multicast-relay VM is configured"
  value       = local.has_multicast_relay
}
