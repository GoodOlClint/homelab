# B1 regression test (audit 2026-08-10; reshaped for the ADR 0020 holder VM):
# each data volume's holder disk slot must follow the operator-assigned `index`
# (interface scsi<index-1>), never the map-key sort order, and appending or
# gapping indices must never move an existing volume's slot. Volume names below
# sort alphabetically OPPOSITE to their indices so name-ordered logic fails.
#
# Run: cd terraform/modules/proxmox-vm && terraform init -backend=false && terraform test

mock_provider "proxmox" {
  # The auto-generated mock id fails template_file_id's format validator in
  # apply-mode runs; both download resources share this shape harmlessly.
  mock_resource "proxmox_virtual_environment_download_file" {
    defaults = {
      id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    }
  }
}

variables {
  virtual_environment_node    = "testnode"
  ssh_public_key_path         = "./tests/fixtures/test_key.pub"
  virtual_environment_storage = "local"
  virtual_machine_username    = "test"
  domain_suffix               = "test.internal"
  vm_configurations           = []

  cloud_image = {
    url       = "https://example.invalid/noble.img"
    file_name = "noble.img"
    checksum  = "0000000000000000000000000000000000000000000000000000000000000000"
  }
  lxc_template = {
    url       = "https://example.invalid/noble.tar.zst"
    file_name = "noble.tar.zst"
    checksum  = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  }

  # Names deliberately reverse-alphabetical relative to index order.
  data_volumes = {
    zulu  = { index = 1, size_gb = 1 }
    mike  = { index = 2, size_gb = 2 }
    alpha = { index = 3, size_gb = 3 }
  }
}

run "slots_follow_index_not_name" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].interface == "scsi0"
    error_message = "index 1 (zulu) must sit at scsi0; got ${proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].interface}"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].size == 1
    error_message = "disk[0] must be zulu (1G) — name-sorted ordering would put alpha (3G) first"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[1].interface == "scsi1"
    error_message = "index 2 (mike) must sit at scsi1"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[2].interface == "scsi2"
    error_message = "index 3 (alpha) must sit at scsi2"
  }
}

# Adding a volume whose name sorts FIRST but whose index is highest must not
# disturb existing slots — the exact incident class B1 exists to prevent.
run "new_low_sorting_name_keeps_existing_slots" {
  command = plan

  variables {
    data_volumes = {
      zulu  = { index = 1, size_gb = 1 }
      mike  = { index = 2, size_gb = 2 }
      alpha = { index = 3, size_gb = 3 }
      aaron = { index = 4, size_gb = 4 }
    }
  }

  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].size == 1 && proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].interface == "scsi0"
    error_message = "appending aaron (index 4) must not move zulu off scsi0"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[3].interface == "scsi3" && proxmox_virtual_environment_vm.data_volume_holder[0].disk[3].size == 4
    error_message = "aaron (index 4) must land at scsi3"
  }
}

# Codex review regression (W1): appending a holder volume must NOT disturb an
# existing consumer. The old computed-key filter made the whole ref-map key set
# unknown mid-plan, turning existing consumers' mount_point.volume unknown —
# and container mount_points are ForceNew, so a full apply proposed replacing
# unrelated guests. Applies a consumer, then plans an append: the consumer's
# attach value must stay KNOWN (an unknown value fails these assertions).
run "append_apply_baseline" {
  command = apply

  variables {
    vlans = {
      vlan30 = { vlan_id = 30, bridge = "vmbr0", subnet = "192.0.2.0/24", subnet_v6 = null }
    }
    management_vlan = "vlan30"
    dns_servers     = ["192.0.2.1"]
    vm_configurations = [
      {
        name           = "consumer"
        type           = "lxc"
        vm_id          = 5101
        mgmt_ip_offset = 91
        vlans          = ["vlan30"]
        data_volume    = { name = "zulu" }
      }
    ]
  }
}

run "append_leaves_existing_consumer_known" {
  command = plan

  variables {
    vlans = {
      vlan30 = { vlan_id = 30, bridge = "vmbr0", subnet = "192.0.2.0/24", subnet_v6 = null }
    }
    management_vlan = "vlan30"
    dns_servers     = ["192.0.2.1"]
    vm_configurations = [
      {
        name           = "consumer"
        type           = "lxc"
        vm_id          = 5101
        mgmt_ip_offset = 91
        vlans          = ["vlan30"]
        data_volume    = { name = "zulu" }
      }
    ]
    data_volumes = {
      zulu  = { index = 1, size_gb = 1 }
      mike  = { index = 2, size_gb = 2 }
      alpha = { index = 3, size_gb = 3 }
      aaron = { index = 4, size_gb = 4 } # appended after baseline apply
    }
  }

  assert {
    condition     = proxmox_virtual_environment_container.containers["consumer"].mount_point[0].volume != ""
    error_message = "existing consumer's attach volume became unknown/empty during a holder append — replacement-cascade regression"
  }
  assert {
    condition     = output.data_volume_ids["zulu"] != null
    error_message = "existing volume's id must stay resolved during an append"
  }
}

# ADR 0020: gaps are allowed — a retired volume's index is never reused by
# shifting later volumes. Indices {1,3} must yield scsi0 + scsi2, no scsi1.
run "gap_keeps_slots_pinned" {
  command = plan

  variables {
    data_volumes = {
      zulu  = { index = 1, size_gb = 1 }
      alpha = { index = 3, size_gb = 3 }
    }
  }

  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[0].interface == "scsi0"
    error_message = "zulu (index 1) must stay at scsi0"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.data_volume_holder[0].disk[1].interface == "scsi2"
    error_message = "alpha (index 3) must stay at scsi2 across the gap — not slide to scsi1"
  }
}
