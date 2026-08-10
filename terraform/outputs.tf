# Output for Ansible inventory (WP3: guests carry type + node for LXC-aware roles)
locals {
  # ansible_host follows the selected access plane (guest_access_plane):
  # management IPs pre-cutover, services IPs post-ADR-0017. vm_service_ips
  # already falls back to the management IP for guests without a services leg.
  inventory_ansible_host = {
    for vm_name, ip in module.vms.vm_management_ips :
    vm_name => var.guest_access_plane == "services" ? coalesce(module.vms.vm_service_ips[vm_name], ip) : ip
  }

  # Service-instance groups (ADR 0003 redundancy pairs): numbered instances
  # (adguard1/adguard2, dns1/dns2) auto-group under their base name so plays can
  # target `hosts: adguard` and cover every instance. A group is only emitted
  # when no host carries the bare base name — that keeps today's single-instance
  # fleet rendering identically and avoids Ansible host/group name collisions.
  # Convention for WP4: name redundant instances <base>1/<base>2, never <base>.
  _guest_base = {
    for vm_name in keys(module.vms.vm_management_ips) :
    vm_name => regex("^([a-z0-9-]*?)-?[0-9]*$", vm_name)[0]
  }
  inventory_groups = {
    for base in distinct(values(local._guest_base)) :
    base => {
      hosts = { for n, b in local._guest_base : n => {} if b == base }
    }
    if length([for n, b in local._guest_base : n if b == base]) > 1 || (
      length([for n, b in local._guest_base : n if b == base]) == 1 &&
      [for n, b in local._guest_base : n if b == base][0] != base
    )
  }
}

output "ansible_inventory_yaml" {
  value = yamlencode({
    all = merge(
      {
        hosts = {
          for vm_name, ip in module.vms.vm_management_ips : vm_name => {
            ansible_host = local.inventory_ansible_host[vm_name]
            service_ip   = module.vms.vm_service_ips[vm_name]
            guest_type   = module.vms.guest_types[vm_name]
            pve_node     = try(module.vms.vm_nodes[vm_name], null)
          }
        }
      },
      length(local.inventory_groups) > 0 ? { children = local.inventory_groups } : {}
    )
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
