# LXC containers + detached data volumes (WP3 — ADR 0003, ADR 0015)
#
# Guests with type = "lxc" become proxmox_virtual_environment_container resources,
# sharing the interface/IP/MAC builder in virtual_machines.tf so VMs and LXCs are
# configured identically at the network layer.
#
# Detached data volumes: a never-started "holder" container owns every data volume
# as a formatted CT mount-point volume. PVE guest destroy only deletes volumes owned
# by the destroyed VMID, so consuming guests rebuild freely while the data survives.
# (A CT holder — not a VM — because PVE formats CT volumes at creation; a VM-owned
# raw disk would arrive unformatted at an LXC mount point.)

locals {
  lxc_guests = { for vm in var.vm_configurations : vm.name => vm if vm.type == "lxc" }
  vm_guests  = { for vm in var.vm_configurations : vm.name => vm if vm.type == "vm" }

  # Stable slot order: sorted by the operator-assigned index (never renumber — see
  # variables.tf). NOT sorted by name: a later volume that sorts alphabetically
  # earlier would shift every existing mount_point slot and remap live data disks.
  # format("%08d") gives a fixed-width key so lexicographic sort == numeric sort.
  # State-migration note: if volumes ever existed under the old name-sorted code,
  # their indices must first be assigned to match the existing slot order.
  _data_volumes_by_index = {
    for name, v in var.data_volumes : format("%08d", v.index) => merge(v, { name = name })
  }
  data_volumes_ordered = [
    for k in sort(keys(local._data_volumes_by_index)) : local._data_volumes_by_index[k]
  ]
  # name => full volume ID ("<storage>:vm-<holder>-disk-<n>") read back from the holder.
  # bpg stores the PVE-resolved volume ID in state after create; if live testing at
  # Day-1 bring-up shows the config value echoed instead, switch to the deterministic
  # construction "<storage>:vm-${var.data_volume_holder_vmid}-disk-${slot+1}".
  data_volume_ids = length(var.data_volumes) > 0 ? {
    for i, v in local.data_volumes_ordered :
    v.name => proxmox_virtual_environment_container.data_volume_holder[0].mount_point[i].volume
  } : {}
}

# Never-started holder container that owns all detached data volumes (ADR 0015).
# Rebuilding any consuming guest never touches these volumes; destroying THIS
# resource destroys all fleet data — hence protection unless FORCE-unprotected.
resource "proxmox_virtual_environment_container" "data_volume_holder" {
  count = length(var.data_volumes) > 0 ? 1 : 0

  node_name     = var.virtual_environment_node
  vm_id         = var.data_volume_holder_vmid
  description   = "Detached data-volume holder (ADR 0015) — never started; guests attach these volumes by ID"
  started       = false
  start_on_boot = false
  protection    = var.unprotect ? false : true
  unprivileged  = true

  operating_system {
    template_file_id = local.lxc_template_id
    type             = "ubuntu"
  }

  # Minimal rootfs — exists only because a container must have one
  disk {
    datastore_id = var.primary_disk_storage
    size         = 2
  }

  # One formatted volume per entry, slot-stable by operator-assigned index.
  # backup=true puts every data volume in the holder's PBS job (crash-consistent DR).
  dynamic "mount_point" {
    for_each = local.data_volumes_ordered
    content {
      path   = "/vol/${mount_point.value.name}"
      volume = coalesce(mount_point.value.storage, var.primary_disk_storage)
      size   = "${mount_point.value.size_gb}G"
      backup = true
    }
  }
}

# media_idmap entries: PVE requires the id map to cover 0..65535 contiguously,
# so the 1:1 media range sits between two shifted segments (for both u and g).
locals {
  _media_idmap_segments = [
    { container_id = 0, host_id = 100000, size = var.media_idmap_uid },
    { container_id = var.media_idmap_uid, host_id = var.media_idmap_uid, size = var.media_idmap_size },
    {
      container_id = var.media_idmap_uid + var.media_idmap_size
      host_id      = 100000 + var.media_idmap_uid + var.media_idmap_size
      size         = 65536 - var.media_idmap_uid - var.media_idmap_size
    },
  ]
  media_idmap_entries = flatten([
    for t in ["u", "g"] : [for seg in local._media_idmap_segments : merge(seg, { type = t })]
  ])
}

# LXC guests (ADR 0003: static IPs only — never DHCP an LXC)
resource "proxmox_virtual_environment_container" "containers" {
  for_each = local.lxc_guests

  vm_id         = each.value.vm_id
  node_name     = coalesce(each.value.node_name, var.virtual_environment_node)
  protection    = var.unprotect ? false : each.value.protected
  unprivileged  = each.value.unprivileged
  started       = true
  start_on_boot = true

  operating_system {
    template_file_id = local.lxc_template_id
    type             = "ubuntu"
  }

  cpu {
    cores = each.value.cpu_cores
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = coalesce(each.value.disk_storage, var.primary_disk_storage)
    size         = each.value.disk_size_gb
  }

  features {
    nesting = each.value.nesting
    keyctl  = each.value.keyctl
  }

  # 1:1 media-range ownership for NAS bind mounts (ADR 0017; review P1)
  dynamic "idmap" {
    for_each = each.value.media_idmap ? local.media_idmap_entries : []
    content {
      type         = idmap.value.type
      container_id = idmap.value.container_id
      host_id      = idmap.value.host_id
      size         = idmap.value.size
    }
  }

  # Host device passthrough (e.g. /dev/dri/renderD128 for Plex QuickSync)
  dynamic "device_passthrough" {
    for_each = each.value.devices
    content {
      path = device_passthrough.value.path
      uid  = device_passthrough.value.uid
      gid  = device_passthrough.value.gid
      mode = device_passthrough.value.mode
    }
  }

  # Detached data volume attach (ADR 0015): existing volume ID, no size = attach not create
  dynamic "mount_point" {
    for_each = each.value.data_volume != null ? [each.value.data_volume] : []
    content {
      path   = mount_point.value.path
      volume = local.data_volume_ids[mount_point.value.name]
      backup = false # The holder's PBS job owns volume backup — never double-back-up
    }
  }

  # Host-path bind mounts (ADR 0017) — after data_volume, list order = slot
  # order, append-only. backup=false always: content lives on the NAS.
  dynamic "mount_point" {
    for_each = each.value.bind_mounts
    content {
      path      = mount_point.value.path
      volume    = mount_point.value.source
      read_only = mount_point.value.read_only
      shared    = mount_point.value.shared
      backup    = false
    }
  }

  # Same builder as VMs: identical VLANs, MACs, MTUs. Map iteration is lexicographic
  # by vlan key — ip_config blocks below MUST iterate the same map so slots line up.
  dynamic "network_interface" {
    for_each = local.build_vm_interfaces[each.value.name]
    content {
      name        = "eth_${network_interface.key}"
      bridge      = network_interface.value.bridge
      vlan_id     = can(regex("^vmbr", network_interface.value.bridge)) ? network_interface.value.vlan_id : null
      mtu         = network_interface.value.mtu
      mac_address = network_interface.value.macaddress
    }
  }

  initialization {
    hostname = coalesce(each.value.hostname, each.value.name)

    # One ip_config per network_interface, in the same (lexicographic) order.
    # Gateway only on the designated gateway VLAN. NOTE: source-based policy routes
    # for additional VLANs (the /32 routing-policy rule) cannot be expressed here —
    # multi-VLAN LXCs get them from Ansible at WP4.
    dynamic "ip_config" {
      for_each = local.build_vm_interfaces[each.value.name]
      content {
        ipv4 {
          address = "${ip_config.value.ip}/${split("/", ip_config.value.subnet)[1]}"
          gateway = ip_config.value.is_gateway ? ip_config.value.gw : null
        }
        dynamic "ipv6" {
          for_each = ip_config.value.ipv6 != null ? [1] : (ip_config.value.accept_ra ? [2] : [])
          content {
            address = ip_config.value.ipv6 != null ? "${ip_config.value.ipv6}/${split("/", ip_config.value.subnet_v6)[1]}" : "auto"
          }
        }
      }
    }

    dns {
      servers = var.dns_servers
    }

    # Root gets the SSH key; the standard user is created by Ansible (WP4 common role)
    user_account {
      keys = [trimspace(data.local_file.ssh_public_key.content)]
    }
  }
}

# HA registration for guests that opt in (requires explicit vm_id)
resource "proxmox_virtual_environment_haresource" "guests" {
  for_each = { for vm in var.vm_configurations : vm.name => vm if vm.ha }

  resource_id = "${each.value.type == "lxc" ? "ct" : "vm"}:${each.value.vm_id}"
  state       = "started"
  comment     = "Managed by Terraform (${each.value.name})"

  depends_on = [
    proxmox_virtual_environment_vm.vms,
    proxmox_virtual_environment_container.containers,
  ]
}
