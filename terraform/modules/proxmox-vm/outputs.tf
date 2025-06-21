output "vm_ids" {
  description = "Map of VM names to their IDs"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.id
  }
}

output "vm_names" {
  description = "Map of VM names to their display names"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.name
  }
}

output "vm_ipv4_addresses" {
  description = "Map of VM names to their IPv4 addresses"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.ipv4_addresses
  }
}

output "vm_ipv6_addresses" {
  description = "Map of VM names to their IPv6 addresses"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.ipv6_addresses
  }
}

output "vm_nodes" {
  description = "Map of VM names to their Proxmox nodes"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.node_name
  }
}

output "vm_mac_addresses" {
  description = "Map of VM names to their MAC addresses"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.mac_addresses
  }
}

output "vm_vlan100_ips" {
  description = "Map of VM names to their VLAN 100 IP addresses"
  value       = local.vm_vlan100_ips
}

output "unifi_vlans" {
  description = "Map of VLAN configurations from Unifi"
  value       = local.unifi_vlans
}

output "merged_vlans" {
  description = "Map of merged VLAN configurations (Unifi + static overrides)"
  value       = local.merged_vlans
}

output "vm_interfaces" {
  description = "Map of VM interfaces configuration"
  value       = local.build_vm_interfaces
}

output "vm_user_data_files" {
  description = "Map of VM names to their user data file IDs"
  value = {
    for vm_name, file in proxmox_virtual_environment_file.user_data : vm_name => file.id
  }
}

output "vm_network_data_files" {
  description = "Map of VM names to their network data file IDs"
  value = {
    for vm_name, file in proxmox_virtual_environment_file.network_data : vm_name => file.id
  }
}
