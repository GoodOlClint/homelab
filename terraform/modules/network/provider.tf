terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.78"
    }
  }
  required_version = ">= 1.5" # Import blocks require TF 1.5+
}
