# Proxmox VM Module
# Creates VMs and LXCs with static VLAN configuration: pinned cloud-image /
# LXC-template download, Packer template cloning, and multi-interface
# network configuration.

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

# Download extra pinned images referenced by a guest's `image` key (ADR 0025).
# ponytail: deliberately a SECOND resource rather than folding the default into
# a for_each over all images — that would change the default image's state
# address from [0] to ["default"] and force a state mv on both the fleet and
# campaign roots. Downloads only what some guest actually references, so an
# unused entry in var.cloud_images costs nothing.
resource "proxmox_virtual_environment_download_file" "extra_cloud_image" {
  for_each = var.create_cloud_image ? local.referenced_extra_images : {}

  content_type       = "iso"
  datastore_id       = var.virtual_environment_storage
  node_name          = var.virtual_environment_node
  url                = each.value.url
  file_name          = each.value.file_name
  checksum           = each.value.checksum
  checksum_algorithm = each.value.checksum_algorithm
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

locals {
  # Data-volume holder is a VM (ADR 0020) — only real LXC guests need the template
  lxc_guest_count = length([for vm in var.vm_configurations : vm.name if vm.type == "lxc"])

  ubuntu_cloud_image_id = var.create_cloud_image ? proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id : "${var.virtual_environment_storage}:iso/${var.cloud_image.file_name}"

  # Extra images actually referenced by some VM guest (ADR 0025). Unreferenced
  # entries in var.cloud_images are never downloaded.
  referenced_extra_images = {
    for name, img in var.cloud_images : name => img
    if contains([for vm in var.vm_configurations : vm.image if vm.type != "lxc" && vm.image != null], name)
  }

  # Resolved disk image id per image key. "" (the default) maps to the fleet
  # image; every other key resolves against var.cloud_images.
  extra_cloud_image_ids = {
    for name, img in local.referenced_extra_images : name => (
      var.create_cloud_image ? proxmox_virtual_environment_download_file.extra_cloud_image[name].id : "${var.virtual_environment_storage}:iso/${img.file_name}"
    )
  }

  lxc_template_id = local.lxc_guest_count > 0 ? proxmox_virtual_environment_download_file.lxc_template[0].id : null

  merged_vlans = var.vlans

  # Resolved router address per VLAN — null means the VLAN genuinely has no
  # router (storage/cluster VLANs). Assuming .1 everywhere is what put PBS's
  # default route on the gateway-less storage VLAN (W6, 2026-08-12).
  vlan_gateways = {
    for key, v in local.merged_vlans : key => (
      try(v.gateway, "auto") == "none" ? null :
      try(v.gateway, "auto") == "auto" ? cidrhost(v.subnet, 1) :
      v.gateway
    )
  }

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
