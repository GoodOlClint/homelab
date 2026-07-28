# Provider credentials (exported as TF_VAR_* by the Makefile from bootstrap.sops.yml).
variable "virtual_environment_endpoint" {
  type        = string
  description = "PVE API endpoint. Bootstrap: the node's VLAN 30 mgmt URL. Steady state: the VLAN 40 VIP."
}

variable "virtual_environment_username" {
  type    = string
  default = "root@pam"
}

variable "virtual_environment_password" {
  type      = string
  sensitive = true
}

# --- Host networking, per node ---
#
# bond_slaves: the two X710 10G ports as pinned by the installer (nicN names).
#   These are ONLY known after a fresh answer-file install with all cards seated
#   (the installer pins every present NIC by MAC to /usr/local/lib/systemd/network/
#   50-pmx-nicN.link). Capture them post-install:
#     ls -1 /sys/class/net | while read n; do
#       ethtool -i "$n" 2>/dev/null | grep -q i40e && echo "$n"; done
#   The ConnectX 25G ports and the second i226 (ring1) are intentionally left out
#   here — they belong to the Ceph VLAN 21 link + corosync ring1 (WP2), not this bond.
#
# storage_ip: the host's VLAN 20 (jumbo) IP on the bond — the only host IP this
#   root provisions. No gateway on it: the host's default route stays on the
#   VLAN 30 install link, and pfSense routes inter-VLAN replies.
#
# NOT here (deliberately): the host mgmt IP (VLAN 30) + keepalived VIP. Host mgmt
#   arrives on the i226-V VLAN 30 install link, and this root runs OVER that link
#   (ADR-0002) so it must not add a second VLAN 30 IP on the bond — two interfaces
#   on the VLAN 30 subnet is the classic rp_filter/asymmetric-ARP footgun. WP2's
#   Ansible proxmox_host role re-homes mgmt from the i226-V to the bond (VLAN 30)
#   and stands up the VIP there, over a stable connection — see ADR-0008.
variable "nodes" {
  type = map(object({
    bond_slaves = list(string) # e.g. ["nic0", "nic1"] — the two X710 ports, post-install
    storage_ip  = string       # VLAN 20 storage address, CIDR (jumbo) — e.g. "<prefix>.20.11/24"
  }))
  description = "Per-node host-networking bindings. Real values live in the gitignored nodes.auto.tfvars."
}

variable "storage_vlan" {
  type    = number
  default = 20
}

variable "storage_mtu" {
  type    = number
  default = 9000 # jumbo frames to the Synology (NFS/PBS datastore)
}
