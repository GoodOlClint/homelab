locals {
  proxmox_backup_vlans = ["vlan100", "vlan20"]
  proxmox_backup_interfaces = {
    for idx, vlan_key in local.proxmox_backup_vlans : vlan_key => {
      vlan_id = var.vlans[vlan_key].vlan_id
      bridge  = var.vlans[vlan_key].bridge
      subnet  = var.vlans[vlan_key].subnet
      ip      = cidrhost(var.vlans[vlan_key].subnet, 100)
      gw      = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu     = try(var.vlans[vlan_key].mtu, 1500)
      dhcp    = vlan_key == "vlan100" ? true : false
    }
  }
}

resource "proxmox_virtual_environment_file" "proxmox-backup-cloud-init" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: proxmox-backup
    EOF
    file_name = "proxmox-backup-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "proxmoxBackupVM" {
  name      = "proxmox-backup"
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
    datastore_id = var.primary_disk_storage
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 100
  }

  initialization {
    datastore_id = var.primary_disk_storage
    dynamic "ip_config" {
      for_each = local.proxmox_backup_interfaces
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
    meta_data_file_id = proxmox_virtual_environment_file.proxmox-backup-cloud-init.id
  }
  dynamic "network_device" {
    for_each = local.proxmox_backup_interfaces
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan_id
      mtu     = network_device.value.mtu
    }
  }

  connection {
    host = proxmox_virtual_environment_vm.proxmoxBackupVM.ipv4_addresses[1][0]
    user = var.virtual_machine_username
    agent = true
    timeout = "3m"
  }
}

output "proxmox_backup_ipv4_address" {
  value = proxmox_virtual_environment_vm.proxmoxBackupVM.ipv4_addresses[1][0]
}
