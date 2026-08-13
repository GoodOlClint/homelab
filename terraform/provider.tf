# Consolidated project managing all homelab VMs, SDN, and network infrastructure

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111" # WP3 floor: LXC container support + cluster features
    }
    local = {
      source = "hashicorp/local"
    }
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.29"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5"
}

provider "proxmox" {
  endpoint = var.virtual_environment_endpoint
  username = var.virtual_environment_username
  password = var.virtual_environment_password
  insecure = true # Allow self-signed certificates for local lab
  ssh {
    agent = true
  }
}

# UniFi lives in the SEPARATE terraform/unifi/ root (WP5): provider 0.55
# eagerly connects to the controller at plan time even with zero resources,
# which would break every routine fleet plan. Same split rationale as
# terraform/hosts/ (ADR-0002): a rarely-changing plane must not hold the
# fleet's plan hostage.

provider "vultr" {
  api_key = var.vultr_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
