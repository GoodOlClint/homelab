# Terraform Provider Configuration
# Consolidated project managing all homelab VMs, SDN, and network infrastructure

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

# Unifi Controller provider configuration
provider "unifi" {
  username = var.unifi_username
  password = var.unifi_password
  api_url  = var.unifi_api_url
  site     = var.unifi_site

  # Allow unverified TLS for local controllers
  allow_insecure = true
}

# Vultr provider configuration (VPS relay)
provider "vultr" {
  api_key = var.vultr_api_key
}

# Cloudflare provider configuration (DNS management)
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
