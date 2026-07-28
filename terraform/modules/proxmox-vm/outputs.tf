output "vm_ids" {
  description = "Map of guest names to their IDs (VMs and LXCs)"
  value = merge(
    { for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.id },
    { for ct_name, ct in proxmox_virtual_environment_container.containers : ct_name => ct.id },
  )
}

output "vm_names" {
  description = "Map of guest names (VMs and LXCs)"
  value = merge(
    { for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.name },
    { for ct_name, ct in proxmox_virtual_environment_container.containers : ct_name => ct_name },
  )
}

output "vm_ipv4_addresses" {
  description = "Map of VM names to their IPv4 addresses (VMs only — LXC IPs are static config)"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.ipv4_addresses
  }
}

output "vm_ipv6_addresses" {
  description = "Map of VM names to their IPv6 addresses (VMs only)"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.ipv6_addresses
  }
}

output "vm_nodes" {
  description = "Map of guest names to their Proxmox nodes"
  value = merge(
    { for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.node_name },
    { for ct_name, ct in proxmox_virtual_environment_container.containers : ct_name => ct.node_name },
  )
}

output "guest_types" {
  description = "Map of guest names to their type (vm | lxc)"
  value       = { for vm in var.vm_configurations : vm.name => vm.type }
}

output "data_volume_ids" {
  description = "Map of detached data-volume names to their PVE volume IDs (ADR 0015)"
  value       = local.data_volume_ids
}

output "vm_mac_addresses" {
  description = "Map of VM names to their MAC addresses (VMs only)"
  value = {
    for vm_name, vm in proxmox_virtual_environment_vm.vms : vm_name => vm.mac_addresses
  }
}

output "vm_management_ips" {
  description = "Map of VM names to their management IP"
  value       = local.vm_management_ips
}

output "vm_service_ips" {
  description = "Map of VM names to their service-facing IP (services VLAN if available, otherwise management IP)"
  value       = local.vm_service_ips
}

output "merged_vlans" {
  description = "Map of static VLAN configurations"
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
