data "local_file" "ssh_public_key" {
  filename = "/Users/goodolclint/.ssh/id_ed25519.pub"
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node
  url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}


output "ansible_inventory_yaml" {
  value = yamlencode({
    all = {
      hosts = {
        dns             = { ansible_host = proxmox_virtual_environment_vm.dnsVM.ipv4_addresses[1][0] }
        proxmox_backup  = { ansible_host = proxmox_virtual_environment_vm.proxmoxBackupVM.ipv4_addresses[1][0] }
        openobserve     = { ansible_host = proxmox_virtual_environment_vm.openobserveVM.ipv4_addresses[1][0] }
      }
    }
  })
}