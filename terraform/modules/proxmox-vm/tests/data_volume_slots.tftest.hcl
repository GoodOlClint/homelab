# B1 regression test (audit 2026-08-10): detached data-volume mount slots must
# follow the operator-assigned `index`, never the map-key sort order. Volume
# names below sort alphabetically OPPOSITE to their indices, so the pre-fix
# name-sorted implementation puts "alpha" in slot 0 and this test fails.
#
# Run: cd terraform/modules/proxmox-vm && terraform init -backend=false && terraform test

mock_provider "proxmox" {}

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
    mike  = { index = 2, size_gb = 1 }
    alpha = { index = 3, size_gb = 1 }
  }
}

run "slots_follow_index_not_name" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_container.data_volume_holder[0].mount_point[0].path == "/vol/zulu"
    error_message = "slot 0 must be index 1 (zulu); name-sorted ordering put ${proxmox_virtual_environment_container.data_volume_holder[0].mount_point[0].path} there"
  }
  assert {
    condition     = proxmox_virtual_environment_container.data_volume_holder[0].mount_point[1].path == "/vol/mike"
    error_message = "slot 1 must be index 2 (mike)"
  }
  assert {
    condition     = proxmox_virtual_environment_container.data_volume_holder[0].mount_point[2].path == "/vol/alpha"
    error_message = "slot 2 must be index 3 (alpha)"
  }
}

# Adding a volume whose name sorts FIRST but whose index is highest must not
# disturb existing slots — the exact incident class B1 exists to prevent.
run "new_low_sorting_name_keeps_existing_slots" {
  command = plan

  variables {
    data_volumes = {
      zulu   = { index = 1, size_gb = 1 }
      mike   = { index = 2, size_gb = 1 }
      alpha  = { index = 3, size_gb = 1 }
      aaaaaa = { index = 4, size_gb = 1 } # sorts before every existing name
    }
  }

  assert {
    condition = (
      proxmox_virtual_environment_container.data_volume_holder[0].mount_point[0].path == "/vol/zulu" &&
      proxmox_virtual_environment_container.data_volume_holder[0].mount_point[1].path == "/vol/mike" &&
      proxmox_virtual_environment_container.data_volume_holder[0].mount_point[2].path == "/vol/alpha" &&
      proxmox_virtual_environment_container.data_volume_holder[0].mount_point[3].path == "/vol/aaaaaa"
    )
    error_message = "adding a low-sorting name must append at the next index slot, not remap existing slots"
  }
}

# Index gaps must be rejected outright: slot is list position after sort, so a
# gap means a later-added middle index would shift existing slots (Codex P1).
run "index_gap_rejected" {
  command = plan

  variables {
    data_volumes = {
      zulu = { index = 1, size_gb = 1 }
      mike = { index = 3, size_gb = 1 } # gap at 2
    }
  }

  expect_failures = [var.data_volumes]
}
