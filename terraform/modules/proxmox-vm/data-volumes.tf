# Detached data volumes (ADR 0015, mechanism per ADR 0020).
#
# A single never-started, never-booted holder VM owns every data volume as a raw
# disk. PVE guest destroy only deletes volumes owned by the destroyed VMID, so
# consuming guests rebuild freely while the data survives. A VM (not a CT,
# ADR 0020): bpg appends VM disks in-place, while CT mount_point changes force
# holder replacement (upstream #1392). The cost is a one-time format step per
# volume — mkfs.ext4 + chown of the fs root to the consumer's mapped owner
# (100000:100000 for unprivileged CT root) — BEFORE its first consumer starts;
# PVE's CT-volume path used to do both implicitly.
#
# `index` is the stable disk slot (scsi<index-1>) — never renumber an existing
# volume's index. Gaps are allowed (a retired volume may leave one); only
# uniqueness is load-bearing — consumers resolve volumes from holder state,
# not list position.

locals {
  # Deterministic block order: sorted by operator-assigned index. Order only
  # affects config diff stability; the slot itself comes from the index.
  _data_volumes_by_index = {
    for name, v in var.data_volumes : format("%08d", v.index) => merge(v, { name = name })
  }
  data_volumes_ordered = [
    for k in sort(keys(local._data_volumes_by_index)) : local._data_volumes_by_index[k]
  ]

  # name => attach reference, resolved from the holder's COMPUTED disk attrs
  # (known-after-apply at first create — genuinely computed for VM disks, unlike
  # the CT mount_point read-back W1 disqualified). disk[i] pairs with
  # data_volumes_ordered[i] because the disk blocks are built from that list.
  # KEYS derive solely from var.data_volumes (statically known): filtering by
  # the computed path made the whole key set unknown during an append plan,
  # which turned EXISTING consumers' mount_point.volume unknown and — because
  # container mount_points are ForceNew — proposed replacing unrelated guests.
  # A just-appended volume carries a null path instead;
  # consumer preconditions reject attaching it before it materializes.
  data_volume_refs = {
    for i, v in local.data_volumes_ordered : v.name => {
      datastore_id      = proxmox_virtual_environment_vm.data_volume_holder[0].disk[i].datastore_id
      path_in_datastore = proxmox_virtual_environment_vm.data_volume_holder[0].disk[i].path_in_datastore
    }
  }

  # Legacy-shaped map ("<storage>:<volid>") for outputs/consumers that want one
  # string. NOTE the guard is only meaningful when path_in_datastore is KNOWN:
  # for a holder disk not yet created (same-apply new volume) the value is
  # UNKNOWN, not null, so `!= null` is unknown too and carries through — the
  # consumer preconditions then defer to apply and PASS once the disk exists.
  # This map therefore fails closed only for a genuinely null id (a consumer
  # referencing a volume whose holder disk is absent/removed). It does NOT and
  # cannot enforce the out-of-band mkfs+chown (ADR 0020) — Terraform can't see
  # it. The operative guard is procedural: apply the holder, format+chown, THEN
  # build the consumer (staged `make build` does the holder first). Never add a
  # data volume and its consumer in the same apply.
  data_volume_ids = {
    for name, ref in local.data_volume_refs :
    name => ref.path_in_datastore != null ? "${ref.datastore_id}:${ref.path_in_datastore}" : null
  }
}

# Never-started holder VM that owns all detached data volumes (ADR 0020).
# Destroying THIS resource destroys all fleet data — hence protection unless
# FORCE-unprotected. It must never gain an OS disk, network device, or
# started=true; it exists only as the volumes' lifecycle anchor.
resource "proxmox_virtual_environment_vm" "data_volume_holder" {
  count = length(var.data_volumes) > 0 ? 1 : 0

  name        = "data-volume-holder"
  node_name   = var.virtual_environment_node
  vm_id       = var.data_volume_holder_vmid
  description = "Detached data-volume holder (ADR 0015/0020) — never started; guests attach these volumes by ID"

  started    = false
  on_boot    = false
  protection = var.unprotect ? false : true

  # One raw disk per volume; slot pinned by index, not list position.
  dynamic "disk" {
    for_each = local.data_volumes_ordered
    content {
      datastore_id = coalesce(disk.value.storage, var.primary_disk_storage)
      interface    = "scsi${disk.value.index - 1}"
      file_format  = "raw"
      size         = disk.value.size_gb
      backup       = true # the holder's PBS job owns volume backup (B3)
    }
  }
}
