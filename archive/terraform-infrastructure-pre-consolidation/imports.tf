# Import blocks for existing Proxmox SDN resources
# These allow Terraform to adopt pre-existing zones and VNETs without recreation.
# After the first successful apply, this file can be safely deleted.

# --- Existing SDN Zones ---

import {
  to = module.network.proxmox_virtual_environment_sdn_zone_vlan.zones["Homelab"]
  id = "Homelab"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_zone_vlan.zones["Storage"]
  id = "Storage"
}

# --- Existing SDN VNETs ---

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["management"]
  id = "Mgmt"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["storage"]
  id = "Storage"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["services"]
  id = "Services"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["core"]
  id = "Core"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["work"]
  id = "Work"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["iot"]
  id = "IoT"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["sonos"]
  id = "Sonos"
}

import {
  to = module.network.proxmox_virtual_environment_sdn_vnet.vnets["guest"]
  id = "Guest"
}

# New VNETs (no import needed — will be created):
# - Infra (infrastructure, VLAN 30)
# - Media (media, VLAN 50)
# - Vivint (vivint, VLAN 122)
