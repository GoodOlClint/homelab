# Services VMs using the shared Proxmox VM module
module "services_vms" {
  source = "../modules/proxmox-vm"

  # Proxmox connection settings
  virtual_environment_endpoint = var.virtual_environment_endpoint
  virtual_environment_password = var.virtual_environment_password
  virtual_environment_username = var.virtual_environment_username
  virtual_environment_node     = var.virtual_environment_node
  virtual_environment_storage  = var.virtual_environment_storage
  primary_disk_storage         = var.primary_disk_storage
  secondary_disk_storage       = var.secondary_disk_storage

  # VM configurations
  vm_configurations = local.vm_configurations

  # Cloud-init settings
  virtual_machine_username      = var.virtual_machine_username
  virtual_machine_password_hash = var.virtual_machine_password_hash
  virtual_machine_timezone      = var.virtual_machine_timezone
  ssh_public_key_path           = var.ssh_public_key_path
  domain_suffix                 = var.domain_suffix

  # IPv6 configuration
  ipv6_config = var.ipv6_config

  # Unifi configuration
  unifi_username        = var.unifi_username
  unifi_password        = var.unifi_password
  unifi_api_url         = var.unifi_api_url
  unifi_site            = var.unifi_site
  unifi_network_mapping = var.unifi_network_mapping

  # Static VLAN overrides (if any)
  vlans = var.vlans

  # GPU configuration
  gpu_mapping = var.gpu_mapping

  # Cloud image management
  create_cloud_image = var.create_cloud_image
}

# Output for Ansible inventory
output "ansible_inventory_yaml" {
  value = yamlencode({
    all = {
      hosts = {
        for vm_name in keys(module.services_vms.vm_vlan100_ips) : vm_name => {
          ansible_host = module.services_vms.vm_vlan100_ips[vm_name]
        }
      }
    }
  })
}

# Output VM VLAN 100 IPs for reference
output "vm_vlan100_ips" {
  value = module.services_vms.vm_vlan100_ips
}

# Output detailed VM information
output "vm_details" {
  value = {
    vm_ids            = module.services_vms.vm_ids
    vm_names          = module.services_vms.vm_names
    vm_ipv4_addresses = module.services_vms.vm_ipv4_addresses
    vm_ipv6_addresses = module.services_vms.vm_ipv6_addresses
    vm_nodes          = module.services_vms.vm_nodes
    vm_mac_addresses  = module.services_vms.vm_mac_addresses
    vm_vlan100_ips    = module.services_vms.vm_vlan100_ips
  }
}

# Output VLAN configurations for debugging
output "unifi_vlans" {
  value = module.services_vms.unifi_vlans
}

output "merged_vlans" {
  value = module.services_vms.merged_vlans
}

# Output VM interfaces for debugging
output "vm_interfaces" {
  value = module.services_vms.vm_interfaces
}
