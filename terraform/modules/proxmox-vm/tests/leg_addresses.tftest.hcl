# #13: an LXC leg with no address must fail the plan (ADR 0003, never DHCP a container) instead
# of rendering "/24", and a guest with no management leg gets no fabricated management address.
#
# Run: cd terraform/modules/proxmox-vm && terraform init -backend=false && terraform test

mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
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
  service_domain              = "test.internal"
  data_volumes                = {}
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
  vlans = {
    vlan30 = { vlan_id = 30, bridge = "vmbr0", subnet = "192.0.2.0/24", subnet_v6 = null }
    vlan40 = { vlan_id = 40, bridge = "vmbr0", subnet = "198.51.100.0/24", subnet_v6 = null }
  }
  management_vlan = "vlan30"
  services_vlan   = "vlan40"
  dns_servers     = ["192.0.2.1"]
}

run "lxc_leg_without_offset_fails" {
  command = plan

  variables {
    vm_configurations = [
      { name = "nolegip", type = "lxc", vm_id = 5102, mgmt_ip_offset = 12, vlans = ["vlan30", "vlan40"] }
    ]
  }

  expect_failures = [proxmox_virtual_environment_container.containers["nolegip"]]
}

run "no_management_leg_means_no_management_address" {
  command = plan

  variables {
    vm_configurations = [
      { name = "svc", type = "lxc", vm_id = 5103, ip_offset = 7, vlans = ["vlan40"] }
    ]
  }

  assert {
    condition     = local.vm_management_ips["svc"] == null
    error_message = "a guest with no management leg must not get a management-subnet address; got ${jsonencode(local.vm_management_ips["svc"])}"
  }
  assert {
    condition     = local.vm_service_ips["svc"] == "198.51.100.7"
    error_message = "service_ip must be the services leg; got ${jsonencode(local.vm_service_ips["svc"])}"
  }
}
