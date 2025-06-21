# Dynamic Network Configuration from Unifi Controller
# This file automatically discovers network settings from the Unifi Controller
# and creates VLAN configurations for VMs based on the unifi_network_mapping variable.
#
# How it works:
# 1. Fetches network data from Unifi Controller for each mapped network
# 2. Extracts VLAN ID, subnet, DHCP settings, and IPv6 configuration
# 3. Merges with any static VLAN overrides defined in variables
# 4. Provides this data to the VM module for network interface creation

# Fetch all networks from Unifi Controller
data "unifi_network" "networks" {
  for_each = var.unifi_network_mapping
  name     = each.value.unifi_network_name
}

# Create dynamic VLAN configuration from Unifi data
locals {
  # Build VLAN configuration from Unifi networks
  unifi_vlans = {
    for vlan_key, mapping in var.unifi_network_mapping : vlan_key => {
      vlan_id     = data.unifi_network.networks[vlan_key].vlan_id
      bridge      = mapping.bridge
      subnet      = data.unifi_network.networks[vlan_key].subnet
      subnet_v6   = data.unifi_network.networks[vlan_key].ipv6_static_subnet != "" ? data.unifi_network.networks[vlan_key].ipv6_static_subnet : null
      mtu         = try(mapping.mtu, 1500)
      description = mapping.description != "" ? mapping.description : data.unifi_network.networks[vlan_key].name

      # Additional Unifi-specific data
      domain_name         = data.unifi_network.networks[vlan_key].domain_name
      dhcp_enabled        = data.unifi_network.networks[vlan_key].dhcp_enabled
      dhcp_start          = data.unifi_network.networks[vlan_key].dhcp_start
      dhcp_stop           = data.unifi_network.networks[vlan_key].dhcp_stop
      dhcp_dns            = data.unifi_network.networks[vlan_key].dhcp_dns
      dhcp_v6_enabled     = data.unifi_network.networks[vlan_key].dhcp_v6_enabled
      dhcp_v6_dns         = data.unifi_network.networks[vlan_key].dhcp_v6_dns
      ipv6_interface_type = data.unifi_network.networks[vlan_key].ipv6_interface_type
      ipv6_ra_enable      = data.unifi_network.networks[vlan_key].ipv6_ra_enable
      ipv6_static_subnet  = data.unifi_network.networks[vlan_key].ipv6_static_subnet
      ipv6_pd_interface   = data.unifi_network.networks[vlan_key].ipv6_pd_interface
      ipv6_pd_prefixid    = data.unifi_network.networks[vlan_key].ipv6_pd_prefixid
    }
  }

  # Merge with any static VLAN overrides (for backwards compatibility)
  merged_vlans = merge(
    local.unifi_vlans,
    var.vlans # Static overrides take precedence
  )
}

# Output the discovered network configuration for debugging
output "discovered_networks" {
  value = {
    for vlan_key, network in local.unifi_vlans : vlan_key => {
      name           = data.unifi_network.networks[vlan_key].name
      vlan_id        = network.vlan_id
      subnet         = network.subnet
      subnet_v6      = network.subnet_v6
      dhcp_range     = "${network.dhcp_start} - ${network.dhcp_stop}"
      ipv6_type      = network.ipv6_interface_type
      ipv6_ra_enable = network.ipv6_ra_enable
      ipv6_static    = network.ipv6_static_subnet
      description    = network.description
    }
  }
  description = "Network configuration discovered from Unifi Controller"
}
