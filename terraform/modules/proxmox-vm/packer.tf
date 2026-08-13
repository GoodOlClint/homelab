# Packer Template Detection and Selection

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
  packer_template_name = var.use_packer_template ? (
    var.packer_template_name != "" ?
    var.packer_template_name :
    try(data.proxmox_virtual_environment_vms.packer_templates[0].vms[0].name, null)
  ) : null

  # Cloning references the template by numeric VM ID, not name.
  packer_template_vm_id = var.use_packer_template ? (
    var.packer_template_vm_id != null ?
    var.packer_template_vm_id :
    try(data.proxmox_virtual_environment_vms.packer_templates[0].vms[0].vm_id, null)
  ) : null

  # Determine VM disk source per guest: cloud image only (Packer uses clone instead).
  # Used in virtual_machines.tf for the disk.file_id attribute. A guest's
  # `image` key selects an entry from var.cloud_images; null = fleet default.
  vm_disk_source_by_name = {
    for vm in var.vm_configurations : vm.name => (
      var.use_packer_template ? null : (
        # lookup(..., null) rather than [vm.image] so an undefined key surfaces
        # as the resource precondition in virtual_machines.tf, not an opaque
        # "invalid index".
        vm.image == null ? local.ubuntu_cloud_image_id : lookup(local.extra_cloud_image_ids, vm.image, null)
      )
    ) if vm.type != "lxc"
  }
}

# Output for debugging
output "packer_template_info" {
  description = "Information about the selected Packer template (if used)"
  value = var.use_packer_template ? {
    using_packer    = true
    template_name   = local.packer_template_name
    template_vm_id  = local.packer_template_vm_id
    auto_detected   = var.packer_template_name == ""
    templates_found = var.packer_template_name == "" ? try(length(data.proxmox_virtual_environment_vms.packer_templates[0].vms), 0) : null
    } : {
    using_packer = false
    using        = "cloud-init"
  }
}
