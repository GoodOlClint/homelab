# Proxmox SDN Zone and VNET management
# Only active when manage_sdn = true (infrastructure project)

# --- SDN VLAN Zones ---
# Each zone maps to a physical bridge on the Proxmox host

resource "proxmox_virtual_environment_sdn_zone_vlan" "zones" {
  for_each = var.manage_sdn ? local.sdn_zones_map : {}

  id     = each.key
  bridge = each.value.bridge
  mtu    = try(each.value.mtu, null)
  nodes  = [var.proxmox_node]
}

# --- SDN VNETs ---
# One VNET per switched VLAN (excludes WireGuard-only subnets)

resource "proxmox_virtual_environment_sdn_vnet" "vnets" {
  for_each = var.manage_sdn ? local.managed_vnets_map : {}

  id   = each.value.bridge # VNET ID = bridge name (e.g., "Mgmt", "Core")
  zone = each.value.sdn_zone
  tag  = each.value.id # VLAN tag

  depends_on = [proxmox_virtual_environment_sdn_zone_vlan.zones]
}

# --- SDN Applier ---
# Triggers Proxmox to apply pending SDN changes after zone/VNET modifications

resource "proxmox_virtual_environment_sdn_applier" "apply" {
  count = var.manage_sdn ? 1 : 0

  depends_on = [
    proxmox_virtual_environment_sdn_zone_vlan.zones,
    proxmox_virtual_environment_sdn_vnet.vnets,
  ]
}
