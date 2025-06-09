locals {
  docker_vlans = ["vlan100", "vlan120", "vlan20"]
  docker_interfaces = {
    for idx, vlan_key in local.docker_vlans : vlan_key => {
      vlan_id = var.vlans[vlan_key].vlan_id
      bridge  = var.vlans[vlan_key].bridge
      subnet  = var.vlans[vlan_key].subnet
      ip      = cidrhost(var.vlans[vlan_key].subnet, 51)
      gw      = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu     = try(var.vlans[vlan_key].mtu, 1500)
      dhcp    = true # Set to false for static, true for DHCP
    }
  }
}

resource "proxmox_virtual_environment_file" "docker-cloud-init" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: docker
    EOF
    file_name = "docker-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "dockerVM" {
  name      = "docker"
  node_name = var.virtual_environment_node

  agent {
    enabled = true
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = var.virtual_environment_storage
    file_id      = local.ubuntu_cloud_image_id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }

  initialization {
    datastore_id = var.virtual_environment_storage
    dynamic "ip_config" {
      for_each = local.docker_interfaces
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
    meta_data_file_id = proxmox_virtual_environment_file.docker-cloud-init.id
  }
  dynamic "network_device" {
    for_each = local.docker_interfaces
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan_id
      mtu     = network_device.value.mtu
    }
  }
  hostpci {
    device = "hostpci0"
    mapping = "Nvidia-GPU"
    mdev = "nvidia-256"
  }
}

output "docker_ipv4_address" {
  value = proxmox_virtual_environment_vm.dockerVM.ipv4_addresses[1][0]
}
