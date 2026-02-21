# Network Module — reads canonical vlans.yaml and computes derived values
#
# This module serves two purposes:
# 1. Outputs a VLAN map in the format expected by the proxmox-vm module
# 2. Optionally manages Proxmox SDN zones and VNETs (when manage_sdn = true)

locals {
  network_data = yamldecode(file(var.vlans_file_path))

  # Compute derived values for each VLAN that has a Proxmox bridge (excludes WireGuard-only)
  # Output format matches what terraform/modules/proxmox-vm expects for its `vlans` variable
  vlans = {
    for key, v in local.network_data.vlans : "vlan${v.id}" => {
      vlan_id     = v.id
      bridge      = v.bridge
      subnet      = try(v.subnet, "${local.network_data.ipv4_prefix}.${v.id}.0/24")
      subnet_v6   = try(v.ipv6_subnet, "${local.network_data.ipv6_prefix}:${format("%x", v.id)}::/64")
      mtu         = try(v.mtu, 1500)
      description = try(v.description, v.name)
    } if try(v.bridge, null) != null
  }

  # All VLANs including WireGuard (for reference/firewall use)
  all_vlans = {
    for key, v in local.network_data.vlans : "vlan${v.id}" => {
      vlan_id      = v.id
      name         = v.name
      bridge       = v.bridge
      sdn_zone     = v.sdn_zone
      subnet       = try(v.subnet, "${local.network_data.ipv4_prefix}.${v.id}.0/24")
      gateway      = try(v.gateway, cidrhost("${local.network_data.ipv4_prefix}.${v.id}.0/24", 1))
      subnet_v6    = try(v.ipv6_subnet, "${local.network_data.ipv6_prefix}:${format("%x", v.id)}::/64")
      mtu          = try(v.mtu, 1500)
      description  = try(v.description, v.name)
      domain       = try("${v.domain_prefix}.${local.network_data.domain_suffix}", null)
      is_wireguard = try(v.is_wireguard, false)
    }
  }

  # VNETs that need SDN management (have a bridge, not WireGuard)
  managed_vnets = {
    for key, v in local.network_data.vlans : key => v
    if try(v.bridge, null) != null && !try(v.is_wireguard, false)
  }

  # Typed maps for conditional for_each (avoids "inconsistent conditional result types" error)
  sdn_zones_map = { for k, v in local.network_data.sdn_zones : k => {
    bridge = v.bridge
    mtu    = try(v.mtu, null)
  } }

  managed_vnets_map = { for k, v in local.managed_vnets : k => {
    id       = v.id
    bridge   = v.bridge
    sdn_zone = v.sdn_zone
  } }
}
