# Terraform Provider Configuration for Services
# This configures the providers needed for VM creation and network management

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