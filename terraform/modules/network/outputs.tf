# Network module outputs

output "vlans" {
  description = "VLAN map in the format expected by the proxmox-vm module (excludes WireGuard-only VLANs)"
  value       = local.vlans
}

output "all_vlans" {
  description = "Complete VLAN map including WireGuard-only subnets (for firewall rules, documentation)"
  value       = local.all_vlans
}

output "dns_servers" {
  description = "DNS server list from the canonical YAML (for cloud-init templates)"
  value       = local.network_data.dns_servers
}

output "management_vlan_key" {
  description = "VLAN map key for the management VLAN (e.g., 'vlan10')"
  value       = "vlan${local.network_data.vlans[local.network_data.management_vlan].id}"
}

output "management_subnet" {
  description = "Management VLAN IPv4 subnet CIDR"
  value       = local.all_vlans["vlan${local.network_data.vlans[local.network_data.management_vlan].id}"].subnet
}

output "ipv6_prefix" {
  description = "Site IPv6 ULA prefix"
  value       = local.network_data.ipv6_prefix
}

output "domain_suffix" {
  description = "Site domain suffix"
  value       = local.network_data.domain_suffix
}

output "network_data" {
  description = "Raw parsed YAML data (for consumers that need full metadata like dhcp_enabled, client_isolation, etc.)"
  value       = local.network_data
}
