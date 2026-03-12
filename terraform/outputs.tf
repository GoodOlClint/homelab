# Output for Ansible inventory
output "ansible_inventory_yaml" {
  value = yamlencode({
    all = {
      hosts = {
        for vm_name, ip in module.vms.vm_management_ips : vm_name => {
          ansible_host = ip
          service_ip   = module.vms.vm_service_ips[vm_name]
        }
      }
    }
  })
}

# Output VM management IPs for reference
output "vm_management_ips" {
  value = module.vms.vm_management_ips
}

# Output detailed VM information
output "vm_details" {
  value = {
    vm_ids            = module.vms.vm_ids
    vm_names          = module.vms.vm_names
    vm_ipv4_addresses = module.vms.vm_ipv4_addresses
    vm_ipv6_addresses = module.vms.vm_ipv6_addresses
    vm_nodes          = module.vms.vm_nodes
    vm_mac_addresses  = module.vms.vm_mac_addresses
    vm_management_ips = module.vms.vm_management_ips
    vm_service_ips    = module.vms.vm_service_ips
  }
}

# Output VLAN configurations for debugging
output "merged_vlans" {
  value = module.vms.merged_vlans
}

# Output VM interfaces for debugging
output "vm_interfaces" {
  value = module.vms.vm_interfaces
}

# ──────────────────────────────────────────────
# VPS WireGuard Relay Outputs
# ──────────────────────────────────────────────

output "vps_reserved_ip" {
  description = "VPS reserved IP address (stable across rebuilds)"
  value       = vultr_reserved_ip.vps.subnet
}

output "vps_instance_id" {
  description = "Vultr VPS instance ID"
  value       = vultr_instance.vps.id
}

output "vps_ipv6_address" {
  description = "VPS IPv6 address (changes on rebuild — not reserved)"
  value       = vultr_instance.vps.v6_main_ip
}
