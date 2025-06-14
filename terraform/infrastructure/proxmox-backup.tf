locals {
  proxmox_backup_vlans = ["vlan100", "vlan20"]
  proxmox_backup_interfaces = {
    for idx, vlan_key in local.proxmox_backup_vlans : vlan_key => {
      vlan_id   = var.vlans[vlan_key].vlan_id
      bridge    = var.vlans[vlan_key].bridge
      subnet    = var.vlans[vlan_key].subnet
      ip        = cidrhost(var.vlans[vlan_key].subnet, 100)
      gw        = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu       = try(var.vlans[vlan_key].mtu, 1500)
      dhcp      = vlan_key == "vlan100" ? true : false
      macaddress = format(
        "52:54:00:%02x:%02x:%02x",
        11, # unique per-VM id
        idx,
        var.vlans[vlan_key].vlan_id % 256
      )
    }
  }
}

resource "proxmox_virtual_environment_file" "proxmox_backup_user_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/user-data.yaml.tmpl", {
      hostname  = "proxmox-backup"
      fqdn      = "proxmox-backup.goodolclint.internal"
      username  = var.virtual_machine_username
      ssh_key   = trimspace(data.local_file.ssh_public_key.content)
      timezone  = var.virtual_machine_timezone
    })
    file_name = "proxmox-backup-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "proxmox_backup_network_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/network-data.yaml.tmpl", {
      interfaces = [
        for vlan_key, iface in local.proxmox_backup_interfaces : {
          name       = "eth_${vlan_key}"
          mtu        = iface.mtu
          dhcp       = iface.dhcp
          address    = iface.ip != null ? iface.ip : ""
          prefix     = iface.subnet != null ? split("/", iface.subnet)[1] : ""
          gateway    = iface.gw != null ? iface.gw : ""
          macaddress = iface.macaddress != null ? iface.macaddress : ""
        }
      ]
    })
    file_name = "proxmox-backup-network-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "proxmoxBackupVM" {
  name      = "proxmox-backup"
  node_name = var.virtual_environment_node

  agent {
    enabled = true
  }

  machine = "q35"

  cpu {
    cores = 4
    sockets = 2
    type = "x86-64-v3"
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
    user_data_file_id = proxmox_virtual_environment_file.proxmox_backup_user_data.id
    network_data_file_id = proxmox_virtual_environment_file.proxmox_backup_network_data.id
  }
  dynamic "network_device" {
    for_each = local.proxmox_backup_interfaces
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
      mtu         = network_device.value.mtu
      mac_address = network_device.value.macaddress
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
