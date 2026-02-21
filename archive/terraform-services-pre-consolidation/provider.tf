# Terraform Provider Configuration for Services

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
    local = {
      source = "hashicorp/local"
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
