# This module requires these providers to be configured by the calling module

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.111" # WP3 floor: LXC container support + cluster features
    }
    local = {
      source = "hashicorp/local"
    }
  }
  required_version = ">= 1.0"
}
