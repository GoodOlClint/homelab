# Network module — reads canonical vlans.yaml (read-only, no SDN management)
module "network" {
  source          = "../modules/network"
  vlans_file_path = "${path.root}/../../network-data/vlans.yaml"
  manage_sdn      = false
}

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

  # VLAN configuration from canonical YAML
  vlans = module.network.vlans

  # DNS servers from canonical YAML
  dns_servers = module.network.dns_servers

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
        for vm_name, ip in module.services_vms.vm_management_ips : vm_name => {
          ansible_host = ip
        }
      }
    }
  })
}

# Output VM management IPs for reference
output "vm_management_ips" {
  value = module.services_vms.vm_management_ips
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
    vm_management_ips = module.services_vms.vm_management_ips
  }
}

output "merged_vlans" {
  value = module.services_vms.merged_vlans
}

# Output VM interfaces for debugging
output "vm_interfaces" {
  value = module.services_vms.vm_interfaces
}
