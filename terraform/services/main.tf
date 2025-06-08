data "local_file" "ssh_public_key" {
  filename = "/Users/goodolclint/.ssh/id_ed25519.pub"
}

# Use the existing Ubuntu cloud image by filename, do not manage with Terraform

locals {
  ubuntu_cloud_image_id = "${var.virtual_environment_storage}:iso/noble-server-cloudimg-amd64.img"
}

output "ansible_inventory_yaml" {
  value = yamlencode({
    all = {
      hosts = {
        homebridge       = { ansible_host = proxmox_virtual_environment_vm.homebridgeVM.ipv4_addresses[1][0] }
        multicast_relay  = { ansible_host = proxmox_virtual_environment_vm.multicastVM.ipv4_addresses[1][0] }
        plex             = { ansible_host = proxmox_virtual_environment_vm.plexVM.ipv4_addresses[1][0] }
      }
    }
  })
}