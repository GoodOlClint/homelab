locals {
  logcollector_vlans = ["vlan100"]
  logcollector_interfaces = {
    for idx, vlan_key in local.logcollector_vlans : vlan_key => {
      vlan_id = var.vlans[vlan_key].vlan_id
      bridge  = var.vlans[vlan_key].bridge
      subnet  = var.vlans[vlan_key].subnet
      ip      = cidrhost(var.vlans[vlan_key].subnet, 54)
      gw      = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu     = try(var.vlans[vlan_key].mtu, 1500)
      dhcp    = true # Set to false for static, true for DHCP
    }
  }
}

resource "proxmox_virtual_environment_file" "logcollector-cloud-init" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: logcollector
    EOF
    file_name = "logcollector-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "logcollectorVM" {
  name      = "logcollector"
  node_name = var.virtual_environment_node

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    sockets = 2
  }

  memory {
    dedicated = 16384
  }

  disk {
    datastore_id = var.virtual_environment_storage
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }

  initialization {
    datastore_id = var.virtual_environment_storage
    dynamic "ip_config" {
      for_each = local.logcollector_interfaces
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
    meta_data_file_id = proxmox_virtual_environment_file.logcollector-cloud-init.id
  }
  dynamic "network_device" {
    for_each = local.logcollector_interfaces
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan_id
      mtu     = network_device.value.mtu
    }
  }
}

output "logcollector_ipv4_address" {
  value = proxmox_virtual_environment_vm.logcollectorVM.ipv4_addresses[1][0]
}
