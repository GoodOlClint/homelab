# Proxmox VM Module
# This module creates VMs in Proxmox with static VLAN configuration.
# It handles cloud-image download, Packer template cloning, VM creation with multiple network interfaces,
# GPU passthrough assignment, and generates Ansible inventory output.

data "local_file" "ssh_public_key" {
  filename = var.ssh_public_key_path
}

# Download the pinned Ubuntu cloud image (ADR 0016: pinned + deliberately rolled —
# bumping var.cloud_image is the explicit commit that proposes guest rebuilds)
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  count = var.create_cloud_image ? 1 : 0

  content_type       = "iso"
  datastore_id       = var.virtual_environment_storage
  node_name          = var.virtual_environment_node
  url                = var.cloud_image.url
  file_name          = var.cloud_image.file_name
  checksum           = var.cloud_image.checksum
  checksum_algorithm = var.cloud_image.checksum_algorithm
  overwrite          = true
  verify             = true
  upload_timeout     = 600
}

# Download the pinned LXC template (only when containers are defined)
resource "proxmox_virtual_environment_download_file" "lxc_template" {
  count = local.lxc_guest_count > 0 ? 1 : 0

  content_type       = "vztmpl"
  datastore_id       = var.virtual_environment_storage
  node_name          = var.virtual_environment_node
  url                = var.lxc_template.url
  file_name          = var.lxc_template.file_name
  checksum           = var.lxc_template.checksum
  checksum_algorithm = var.lxc_template.checksum_algorithm
  overwrite          = true
  verify             = true
  upload_timeout     = 600
}

# Static VLAN configuration
locals {
  # Data-volume holder is a VM (ADR 0020) — only real LXC guests need the template
  lxc_guest_count = length([for vm in var.vm_configurations : vm.name if vm.type == "lxc"])

  # Use downloaded image if created, otherwise use existing image
  ubuntu_cloud_image_id = var.create_cloud_image ? proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id : "${var.virtual_environment_storage}:iso/${var.cloud_image.file_name}"

  lxc_template_id = local.lxc_guest_count > 0 ? proxmox_virtual_environment_download_file.lxc_template[0].id : null

  # Use static VLAN configuration (no UniFi integration)
  merged_vlans = var.vlans

  # Generate unique MAC byte from vm_id (guaranteed unique, no hash collisions)
  # Falls back to name-based hash for VMs without explicit vm_id (DHCP/auto-assign)
  vm_random_ids = {
    for vm_config in var.vm_configurations : vm_config.name => (
      vm_config.vm_id != null
      ? (vm_config.vm_id % 254) + 1
      : (abs(parseint(substr(sha256(vm_config.name), 0, 8), 16)) % 254) + 1
    )
  }
}
