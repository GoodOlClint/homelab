terraform {
  required_version = ">= 1.0"
  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.55" # schema-verified for the unifi-network module (vlan/purpose attrs)
    }
  }
}
