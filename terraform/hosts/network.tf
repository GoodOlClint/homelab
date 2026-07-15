# Host networking, applied AFTER the answer-file install, over the stable VLAN 30
# mgmt link. This project owns the X710 bond → VLAN-aware vmbr0 → the storage VLAN
# interface. It deliberately does NOT touch:
#   - the i226-V / VLAN 30 install+mgmt link (carries the API session)
#   - the ConnectX 25G ports (FRR OpenFabric mesh, WP2)
#   - the i226 corosync VLANs 31/32 (WP2)
# so a re-apply can never drop the interface Terraform is talking over.
#
# NOT provisioned here: the host mgmt IP (VLAN 30) + keepalived VIP. Adding a
# VLAN 30 IP on the bond while the i226-V install link already holds one would put
# two interfaces on 172.16.30.0/24 (rp_filter/asymmetric-ARP footgun), and this
# root runs over that very link (ADR-0002). WP2 (Ansible proxmox_host) re-homes
# mgmt to the bond and stands up the VIP on VLAN 30. See ADR-0008.

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

# Storage VLAN (20) — jumbo, NFS/PBS datastore to the Synology. Address only, no gateway
# (default route stays on the VLAN 30 install link; pfSense routes inter-VLAN replies).
resource "proxmox_network_linux_vlan" "storage" {
  for_each = var.nodes

  node_name = each.key
  name      = "vmbr0.${var.storage_vlan}"
  address   = each.value.storage_ip
  mtu       = var.storage_mtu
  comment   = "Storage VLAN ${var.storage_vlan} — jumbo NFS/PBS to NAS (terraform/hosts)"

  depends_on = [proxmox_network_linux_bridge.vmbr0]
}
