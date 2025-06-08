locals {
  multicast_vlans = ["vlan100", "vlan120", "vlan121", "vlan130"]
  multicast_interfaces = {
      for idx, vlan_key in local.multicast_vlans : vlan_key => {
          vlan_id = var.vlans[vlan_key].vlan_id
          bridge  = var.vlans[vlan_key].bridge
          subnet  = var.vlans[vlan_key].subnet
          ip      = cidrhost(var.vlans[vlan_key].subnet, 50)
          gw      = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
          eth     = "eth${idx}"
          mtu     = try(var.vlans[vlan_key].mtu, 1500)
          dhcp    = false # Set to false for static, true for DHCP
      }
  }

  vlan_multicast_relay_map = {
    vlan100 = ["vlan120", "vlan121"]
    vlan120 = ["vlan100"]
    vlan121 = ["vlan100", "vlan130"]
    vlan130 = ["vlan121"]
  }

  # Build a map of subnet => list of ethX, using only allowed VLANs' interfaces (not self)
  multicast_iffilter = {
    for vlan_key, iface in local.multicast_interfaces :
      var.vlans[vlan_key].subnet => [
        for allowed in local.vlan_multicast_relay_map[vlan_key] : local.multicast_interfaces[allowed].eth
        if contains(keys(local.multicast_interfaces), allowed)
      ]
  }
}

resource "local_file" "multicast_iffilter_json" {
  content  = jsonencode(local.multicast_iffilter)
  filename = "${path.module}/ifFilter.json"
}

resource "proxmox_virtual_environment_file" "multicast-cloud-init" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: multicast-relay
    EOF
    file_name = "multicast-cloud-init.yaml"
  }
}
resource "proxmox_virtual_environment_vm" "multicastVM" {
  name      = "multicast-relay"
  node_name = var.virtual_environment_node

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 512
  }

  disk {
    datastore_id = var.virtual_environment_storage
    file_id      = local.ubuntu_cloud_image_id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 5
  }

  initialization {
    datastore_id = var.virtual_environment_storage
    dynamic "ip_config" {
      for_each = local.multicast_interfaces
      content {
        dynamic "ipv4" {
          for_each = [ip_config.value]
          content {
            address = ip_config.value.dhcp ? "dhcp" : "${ip_config.value.ip}/${split("/", ip_config.value.subnet)[1]}"
            gateway = ip_config.value.dhcp || ip_config.value.gw == null ? null : ip_config.value.gw
          }
        }
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.default-cloud-init.id
    meta_data_file_id = proxmox_virtual_environment_file.multicast-cloud-init.id
  }
  dynamic "network_device" {
    for_each = local.multicast_interfaces
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan_id
      mtu     = network_device.value.mtu
    }
  }
}

output "multicast_ipv4_address" {
  value = proxmox_virtual_environment_vm.multicastVM.ipv4_addresses[1][0]
}
