# Proxmox provider for the host/cluster plane.
#
# endpoint: during first bring-up point this at the node being configured over
# the STABLE 2.5G mgmt link (VLAN 30, set by the answer file) — never over the
# X710 bond this project is about to (re)configure. Once keepalived is up (WP2)
# repoint at the VLAN 40 VIP. Credentials come from the Makefile via TF_VAR_*.

provider "proxmox" {
  endpoint = var.virtual_environment_endpoint
  username = var.virtual_environment_username
  password = var.virtual_environment_password
  insecure = var.insecure # false: node certs chain to the Homelab Root CA (ADR 0041); TF_VAR_insecure=true only for the first ACME order

  ssh {
    agent = true
  }
}
