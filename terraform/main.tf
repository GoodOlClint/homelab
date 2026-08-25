# Network module — reads canonical vlans.yaml, manages SDN zones/VNETs
module "network" {
  source          = "./modules/network"
  vlans_file_path = "${path.root}/../network-data/vlans.yaml"
  manage_sdn      = true
  proxmox_nodes   = coalesce(var.proxmox_nodes, [var.virtual_environment_node])
}

locals {
  apt_cache = one([for v in local.vm_configurations : v if v.name == "apt-cache"])
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
  service_domain                = module.network.service_domain

  # The apt cache's address derived from its own guest definition (ADR 0021):
  # cloud-init cannot read the inventory, and the VM module cannot read its own
  # runtime addresses without a cycle.
  apt_proxy_host = local.apt_cache == null ? "" : cidrhost(module.network.vlans[local.apt_cache.vlans[0]].subnet, local.apt_cache.ip_offset)

  # IPv6 configuration
  ipv6_config = var.ipv6_config

  # VLAN configuration from canonical YAML
  vlans = module.network.vlans

  # DNS servers from canonical YAML
  dns_servers = module.network.dns_servers

  # Pinned guest OS images (ADR 0016)
  create_cloud_image = var.create_cloud_image
  cloud_image        = var.cloud_image
  cloud_images       = var.cloud_images # per-guest overrides (ADR 0025)
  lxc_template       = var.lxc_template

  # Detached data volumes (ADR 0015) — defined alongside the fleet in vm-configs.tf
  data_volumes = local.data_volumes

  # Packer template configuration
  use_packer_template  = var.use_packer_template
  packer_template_name = var.packer_template_name
}
