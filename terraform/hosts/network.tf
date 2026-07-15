# Host networking, applied AFTER the answer-file install, over the stable VLAN 30
# mgmt link. This project owns the X710 bond → VLAN-aware vmbr0 → storage/services
# VLAN interfaces. It deliberately does NOT touch:
#   - the i226-V / VLAN 30 install link (carries the API session + corosync ring0)
#   - the ConnectX 25G ports (FRR OpenFabric mesh, WP2)
#   - the second i226 (corosync ring1, WP2)
# so a re-apply can never drop the interface Terraform is talking over.

# X710 ×2 → LACP bond (802.3ad, layer3+4). MTU 9000 so the storage sub-if can be jumbo.
resource "proxmox_network_linux_bond" "bond0" {
  for_each = var.nodes

  node_name             = each.key
  name                  = "bond0"
  slaves                = each.value.bond_slaves
  bond_mode             = "802.3ad"
  bond_xmit_hash_policy = "layer3+4"
  mtu                   = var.storage_mtu
  comment               = "X710 LACP bond (terraform/hosts)"
}

# VLAN-aware bridge on the bond — carries guest VLANs + the host's own VLAN sub-ifs.
resource "proxmox_network_linux_bridge" "vmbr0" {
  for_each = var.nodes

  node_name  = each.key
  name       = "vmbr0"
  ports      = [proxmox_network_linux_bond.bond0[each.key].name]
  vlan_aware = true
  mtu        = var.storage_mtu
  comment    = "VLAN-aware bridge on the X710 bond (terraform/hosts)"
}

# Storage VLAN (20) — jumbo, NFS/PBS datastore to the Synology. Address only, no gateway.
resource "proxmox_network_linux_vlan" "storage" {
  for_each = var.nodes

  node_name = each.key
  name      = "vmbr0.${var.storage_vlan}"
  address   = each.value.storage_ip
  mtu       = var.storage_mtu
  comment   = "Storage VLAN ${var.storage_vlan} — jumbo NFS/PBS to NAS (terraform/hosts)"

  depends_on = [proxmox_network_linux_bridge.vmbr0]
}

# Services VLAN (40) — web UI / API / keepalived VIP subnet. Address only, no gateway
# (default route stays on the VLAN 30 install link; pfSense routes inter-VLAN replies).
resource "proxmox_network_linux_vlan" "services" {
  for_each = var.nodes

  node_name = each.key
  name      = "vmbr0.${var.services_vlan}"
  address   = each.value.services_ip
  comment   = "Services VLAN ${var.services_vlan} — web UI / API / VIP (terraform/hosts)"

  depends_on = [proxmox_network_linux_bridge.vmbr0]
}
