# Arc Pro B70 cards on msi, handed to guests by mapping name (ADR 0068).
locals {
  b70_cards = {
    "b70-0" = { path = "0000:03:00.0", iommu_group = 24 }
    "b70-1" = { path = "0000:07:00.0", iommu_group = 29 }
  }
}

resource "proxmox_hardware_mapping_pci" "b70" {
  for_each = local.b70_cards

  name = each.key
  map = [{
    node         = "msi"
    path         = each.value.path
    id           = "8086:e223"
    subsystem_id = "1849:6025"
    iommu_group  = each.value.iommu_group
  }]
}
