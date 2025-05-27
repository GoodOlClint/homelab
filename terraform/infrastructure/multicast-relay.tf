resource "proxmox_virtual_environment_file" "multicastVM" {
  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = <<-EOF
    #cloud-config
    local-hostname: ${var.multicast_vm_name}
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
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 5
  }

  initialization {
    datastore_id = var.virtual_environment_storage
    dynamic "ip_config" {
      for_each = var.multicast_vm_networks
      content {
        ipv4 {
          address = ip_config.value.ipv4
          gateway = ip_config.value.gateway
        }
      }
    }
    
    user_data_file_id = proxmox_virtual_environment_file.default-cloud-init.id
    meta_data_file_id = proxmox_virtual_environment_file.multicastVM.id
  }
  dynamic "network_device" {
    for_each = var.multicast_vm_networks
    content {
      bridge = network_device.value.bridge
      vlan_id = network_device.value.vlan
    }
  }

  connection {
   host = proxmox_virtual_environment_vm.multicastVM.ipv4_addresses[1][0] # IP address of the host where commands will run
   user = var.virtual_machine_username # User
   agent = true
   timeout = "3m"
 }
 
 # Deliver target file to remote host
 provisioner "file" {
   source   = "scripts/installMulticast-Relay.sh"
   destination = "/tmp/bootstrap.sh"
 }

 # Run command on the remote host
 provisioner "remote-exec" {
   inline = [
  "chmod +x /tmp/bootstrap.sh",
  "sh /tmp/bootstrap.sh",
   ]
 }

}

output "multicast_ipv4_address" {
  value = proxmox_virtual_environment_vm.multicastVM.ipv4_addresses[1][0]
}