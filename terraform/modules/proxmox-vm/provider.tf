# Terraform Provider Requirements for Proxmox VM Module
# This module requires these providers to be configured by the calling module

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox" # Proxmox VE provider for VM management
      version = "~> 0.78"
    }
    unifi = {
      source  = "ubiquiti-community/unifi" # Unifi Controller provider for network discovery
      version = "~> 0.41"
    }
    local = {
      source = "hashicorp/local" # Local file provider for SSH keys and outputs
    }
  }
  required_version = ">= 1.0"
}
