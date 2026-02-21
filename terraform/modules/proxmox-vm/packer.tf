# Packer Template Detection and Selection
# This file handles finding and selecting Packer-built VM templates

# Data source to find the latest Packer template
# Searches for templates matching pattern: ubuntu-24.04-base-YYYYMMDD-HHMM
data "proxmox_virtual_environment_vms" "packer_templates" {
  count     = var.use_packer_template && var.packer_template_name == "" ? 1 : 0
  node_name = var.virtual_environment_node

  filter {
    name   = "name"
    values = ["ubuntu-24.04-base-*"]
  }

  filter {
    name   = "template"
    values = [true]
  }
}

locals {
  # Determine which Packer template to use
  # Priority: 1) Explicit template name, 2) Auto-detected latest, 3) null if not using Packer
  packer_template_name = var.use_packer_template ? (
    var.packer_template_name != "" ?
      var.packer_template_name :
      try(data.proxmox_virtual_environment_vms.packer_templates[0].vms[0].name, null)
  ) : null

  # Get the VM ID for cloning (Packer templates use numeric VM IDs)
  # Priority: 1) Explicit VM ID variable, 2) Auto-detected, 3) null
  packer_template_vm_id = var.use_packer_template ? (
    var.packer_template_vm_id != null ?
      var.packer_template_vm_id :
      try(data.proxmox_virtual_environment_vms.packer_templates[0].vms[0].vm_id, null)
  ) : null

  # Determine VM disk source: cloud image only (Packer uses clone instead)
  # This is used in virtual_machines.tf for the disk.file_id attribute
  vm_disk_source = var.use_packer_template ? null : local.ubuntu_cloud_image_id
}

# Output for debugging
output "packer_template_info" {
  description = "Information about the selected Packer template (if used)"
  value = var.use_packer_template ? {
    using_packer       = true
    template_name      = local.packer_template_name
    template_vm_id     = local.packer_template_vm_id
    auto_detected      = var.packer_template_name == ""
    templates_found    = var.packer_template_name == "" ? try(length(data.proxmox_virtual_environment_vms.packer_templates[0].vms), 0) : null
  } : {
    using_packer = false
    using        = "cloud-init"
  }
}
