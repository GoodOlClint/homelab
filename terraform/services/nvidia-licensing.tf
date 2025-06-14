locals {
  nvidia_licensing_vlans = ["vlan100"]
  nvidia_licensing_interfaces = {
    for idx, vlan_key in local.nvidia_licensing_vlans : vlan_key => {
      vlan_id   = var.vlans[vlan_key].vlan_id
      bridge    = var.vlans[vlan_key].bridge
      subnet    = var.vlans[vlan_key].subnet
      ip        = cidrhost(var.vlans[vlan_key].subnet, 50)
      gw        = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu       = try(var.vlans[vlan_key].mtu, 1500)
      dhcp      = "true"
      # Use a unique MAC address per VM and interface: 52:54:00:VMID:IDX:VLANID
      macaddress = format(
        "52:54:00:%02x:%02x:%02x",
        5, # unique per-VM id, change for each VM file
        idx,
        var.vlans[vlan_key].vlan_id % 256
      )
    }
  }
}

resource "proxmox_virtual_environment_file" "nvidia_licensing_user_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/user-data.yaml.tmpl", {
      hostname  = "nvidia-licensing"
      fqdn      = "nvidia-licensing.goodolclint.internal"
      username  = var.virtual_machine_username
      ssh_key   = trimspace(data.local_file.ssh_public_key.content)
      timezone  = var.virtual_machine_timezone
    })
    file_name = "nvidia-licensing-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "nvidia_licensing_network_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/network-data.yaml.tmpl", {
      interfaces = [
        for vlan_key, iface in local.nvidia_licensing_interfaces : {
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
    file_name = "nvidia-licensing-network-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "nvidia_licensing" {
  name      = "nvidia-licensing"
  node_name = var.virtual_environment_node

  agent {
    enabled = true
  }

  machine = "q35"

  cpu {
    cores = 2
    type = "x86-64-v3"
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.primary_disk_storage
    file_id      = local.ubuntu_cloud_image_id
    size         = 4 # 4GB
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
  }

  initialization {
    datastore_id = var.primary_disk_storage
    user_data_file_id = proxmox_virtual_environment_file.nvidia_licensing_user_data.id
    network_data_file_id = proxmox_virtual_environment_file.nvidia_licensing_network_data.id
  }

  dynamic "network_device" {
    for_each = local.nvidia_licensing_interfaces
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
      mtu         = network_device.value.mtu
      mac_address = network_device.value.macaddress
    }
  }
}

output "nvidia_licensing_ipv4_address" {
  value = proxmox_virtual_environment_vm.nvidia_licensing.ipv4_addresses[1][0]
}

