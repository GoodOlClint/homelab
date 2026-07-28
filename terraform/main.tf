# Network module — reads canonical vlans.yaml, manages SDN zones/VNETs
module "network" {
  source          = "./modules/network"
  vlans_file_path = "${path.root}/../network-data/vlans.yaml"
  manage_sdn      = true
  proxmox_node    = var.virtual_environment_node
}

# UniFi network module (WP5) — the new aggregation switch + migration-touched
# config (L2 VLANs corosync/ceph, port profiles, LACP, jumbo). Inert until the
# switch is adopted: flip manage_unifi=true, with the port bindings filled in
# network-data/local/unifi-ports.yaml (see unifi-ports.example.yaml).
module "unifi_network" {
  source = "./modules/unifi-network"
  count  = var.manage_unifi ? 1 : 0

  vlans_file_path = "${path.root}/../network-data/vlans.yaml"
  ports_file_path = "${path.root}/../network-data/local/unifi-ports.yaml"
}

# All VMs using the shared Proxmox VM module
module "vms" {
  source = "./modules/proxmox-vm"

  # Proxmox node/storage settings (provider credentials inherited from root)
  virtual_environment_node    = var.virtual_environment_node
  virtual_environment_storage = var.virtual_environment_storage
  primary_disk_storage        = var.primary_disk_storage

  # VM configurations
  vm_configurations = local.vm_configurations
  unprotect         = var.unprotect

  # Cloud-init settings
  virtual_machine_username      = var.virtual_machine_username
  virtual_machine_password_hash = var.virtual_machine_password_hash
  virtual_machine_timezone      = var.virtual_machine_timezone
  ssh_public_key_path           = var.ssh_public_key_path
  domain_suffix                 = module.network.domain_suffix

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

  # Packer template configuration
  use_packer_template  = var.use_packer_template
  packer_template_name = var.packer_template_name
}
