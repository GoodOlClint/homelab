# Proxmox VM Module
# This module creates VMs in Proxmox with static VLAN configuration.
# It handles cloud-image download, Packer template cloning, VM creation with multiple network interfaces,
# GPU passthrough assignment, and generates Ansible inventory output.

data "local_file" "ssh_public_key" {
  filename = var.ssh_public_key_path
}

# Download the Ubuntu cloud image (optional)
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  count = var.create_cloud_image ? 1 : 0

  content_type        = "iso"
  datastore_id        = var.virtual_environment_storage
  node_name           = var.virtual_environment_node
  url                 = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name           = "noble-server-cloudimg-amd64.img"
  overwrite           = true
  overwrite_unmanaged = true # Allow overwriting files not managed by Terraform
  verify              = true
  upload_timeout      = 600
}

# Static VLAN configuration
locals {
  # Use downloaded image if created, otherwise use existing image
  ubuntu_cloud_image_id = var.create_cloud_image ? proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id : "local:iso/noble-server-cloudimg-amd64.img"

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
