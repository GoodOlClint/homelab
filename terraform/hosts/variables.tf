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
#   here — they belong to the FRR mesh + corosync ring1 (WP2), not this bond.
#
# services_ip / storage_ip: host IPs on the VLAN-aware vmbr0. No gateway on these
#   sub-interfaces — the host's single default route stays on the VLAN 30 install
#   link, and pfSense routes inter-VLAN replies (avoids a double default route).
variable "nodes" {
  type = map(object({
    bond_slaves = list(string) # e.g. ["nic2", "nic3"] — the two X710 ports, post-install
    services_ip = string       # VLAN 40 web-UI / API address, CIDR — e.g. "172.16.40.11/24"
    storage_ip  = string       # VLAN 20 storage address, CIDR (jumbo) — e.g. "172.16.20.11/24"
  }))
  description = "Per-node host-networking bindings. Real values live in the gitignored nodes.auto.tfvars."
}

variable "storage_vlan" {
  type    = number
  default = 20
}

variable "services_vlan" {
  type    = number
  default = 40
}

variable "storage_mtu" {
  type    = number
  default = 9000 # jumbo frames to the Synology (NFS/PBS datastore)
}
