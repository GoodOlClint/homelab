# Proxmox SDN Zone and VNET management

# --- SDN VLAN Zones ---
# Each zone maps to a physical bridge on the Proxmox host

resource "proxmox_sdn_zone_vlan" "zones" {
  for_each = local.sdn_zones_map

  id     = each.key
  bridge = each.value.bridge
  mtu    = try(each.value.mtu, null)
  nodes  = var.proxmox_nodes
}

# --- SDN VNETs ---
# One VNET per switched VLAN (excludes WireGuard-only subnets)

resource "proxmox_sdn_vnet" "vnets" {
  for_each = local.managed_vnets_map

  id   = each.value.bridge # VNET ID = bridge name (e.g., "Mgmt", "Core")
  zone = each.value.sdn_zone
  tag  = each.value.id # VLAN tag

  depends_on = [proxmox_sdn_zone_vlan.zones]
}

# --- SDN Applier ---
# Triggers Proxmox to apply pending SDN changes after zone/VNET modifications

resource "proxmox_sdn_applier" "apply" {
  depends_on = [
    proxmox_sdn_zone_vlan.zones,
    proxmox_sdn_vnet.vnets,
  ]

  # depends_on orders creation only; a later VNET add left the config pending
  # (Ci, 2026-08-22). Re-create the applier whenever a zone or VNET changes.
  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_vlan.zones,
      proxmox_sdn_vnet.vnets,
    ]
  }
}

# proxmox_virtual_environment_sdn_* are deprecated (removed in bpg v1.0); the applier also lost its count.
moved {
  from = proxmox_virtual_environment_sdn_zone_vlan.zones
  to   = proxmox_sdn_zone_vlan.zones
}

moved {
  from = proxmox_virtual_environment_sdn_vnet.vnets
  to   = proxmox_sdn_vnet.vnets
}

moved {
  from = proxmox_virtual_environment_sdn_applier.apply[0]
  to   = proxmox_sdn_applier.apply
}
