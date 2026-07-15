# terraform/hosts/ — host/cluster plane (ADR-0002)
# Separate state from the main terraform/ fleet project: this plane must exist
# before the VM fleet, changes rarely, and a host-networking apply that drops
# connectivity must not hold the fleet project's state hostage.

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111" # host networking (network_linux_bond/bridge/vlan), Ceph, SDN, IAM
    }
  }
  required_version = ">= 1.5"

  # Local state, deliberately separate from terraform/ (see ADR-0002).
  backend "local" {
    path = "terraform.tfstate"
  }
}
