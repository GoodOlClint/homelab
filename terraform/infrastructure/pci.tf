resource "proxmox_virtual_environment_hardware_mapping_pci" "nvidia_gpu" {
  comment = "This is a comment"
  name    = "Nvidia-GPU"
  # The actual map of devices.
  map = [
    {
      comment = "This is a device specific comment"
      id      = "10de:1eb0"
      # This is an optional attribute, but causes a mapping to be incomplete when not defined.
      iommu_group = 20
      node        = var.virtual_environment_node
      path        = "0000:01:00.0"
      # This is an optional attribute, but causes a mapping to be incomplete when not defined.
      subsystem_id = "10de:129f"
    },
  ]
  mediated_devices = true
}