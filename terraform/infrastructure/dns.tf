locals {
  dns_vlans = ["vlan100", "vlan110", "vlan120", "vlan121", "vlan130", "vlan20"]
  dns_interfaces = {
    for idx, vlan_key in local.dns_vlans : vlan_key => {
      vlan_id   = var.vlans[vlan_key].vlan_id
      bridge    = var.vlans[vlan_key].bridge
      subnet    = var.vlans[vlan_key].subnet
      ip        = cidrhost(var.vlans[vlan_key].subnet, 53)
      gw        = idx == 0 ? cidrhost(var.vlans[vlan_key].subnet, 1) : null
      mtu       = try(var.vlans[vlan_key].mtu, 1500)
      dhcp      = false
      macaddress = format(
        "52:54:00:%02x:%02x:%02x",
        10, # unique per-VM id
        idx,
        var.vlans[vlan_key].vlan_id % 256
      )
    }
  }
}

resource "proxmox_virtual_environment_file" "dns-cloud-init" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: dns
    EOF

    file_name = "dns-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "dns_user_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/user-data.yaml.tmpl", {
      hostname  = "dns"
      fqdn      = "dns.goodolclint.internal"
      username  = var.virtual_machine_username
      ssh_key   = trimspace(data.local_file.ssh_public_key.content)
      timezone  = var.virtual_machine_timezone
    })

    file_name = "dns-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "dns_network_data" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/network-data.yaml.tmpl", {
      interfaces = [
        for vlan_key, iface in local.dns_interfaces : {
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

    file_name = "dns-network-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "dnsVM" {
  name      = "dns"
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
    dedicated = 512
  }

  disk {
    datastore_id = var.primary_disk_storage
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 5
  }

  initialization {
    datastore_id = var.primary_disk_storage
    user_data_file_id = proxmox_virtual_environment_file.dns_user_data.id
    network_data_file_id = proxmox_virtual_environment_file.dns_network_data.id
  }
  dynamic "network_device" {
    for_each = local.dns_interfaces
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
      mtu         = network_device.value.mtu
      mac_address = network_device.value.macaddress
    }
  }
}

output "dns_ipv4_address" {
  value = proxmox_virtual_environment_vm.dnsVM.ipv4_addresses[1][0]
}
