# Terraform Provider Configuration
# Consolidated project managing all homelab VMs, SDN, and network infrastructure

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox" # Proxmox VE provider for VM management
      version = "~> 0.111"    # WP3 floor: LXC container support + cluster features
    }
    local = {
      source = "hashicorp/local" # Local file provider for SSH keys and outputs
    }
    vultr = {
      source  = "vultr/vultr" # Vultr provider for VPS relay
      version = "~> 2.29"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare" # Cloudflare provider for DNS management
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5"
}

# Proxmox VE provider configuration
provider "proxmox" {
  endpoint = var.virtual_environment_endpoint
  username = var.virtual_environment_username
  password = var.virtual_environment_password
  insecure = true # Allow self-signed certificates for local lab
  ssh {
    agent = true # Use SSH agent for authentication
  }
}

# UniFi lives in the SEPARATE terraform/unifi/ root (WP5): provider 0.55
# eagerly connects to the controller at plan time even with zero resources,
# which would break every routine fleet plan. Same split rationale as
# terraform/hosts/ (ADR-0002): a rarely-changing plane must not hold the
# fleet's plan hostage.

# Vultr provider configuration (VPS relay)
provider "vultr" {
  api_key = var.vultr_api_key
}

# Cloudflare provider configuration (DNS management)
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
