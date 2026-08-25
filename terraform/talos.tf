# Talos control-plane VMs (ADR 0031 build, ADR 0033 forks). Plain resources,
# not modules/proxmox-vm: Talos has no cloud-init, takes its config over its
# own API, and worklab's member rides a second PVE endpoint. No HA resource
# ever (two etcd members on one host = lost quorum).

provider "proxmox" {
  alias    = "worklab"
  endpoint = var.worklab_endpoint
  username = var.virtual_environment_username
  password = var.worklab_password
  insecure = true
  ssh {
    agent    = true
    username = "root"
  }
}

locals {
  talos_services_vlan = module.network.vlans["vlan40"]
  talos_ceph_vlan     = module.network.vlans["vlan20"]

  # offset doubles as the last octet on BOTH legs; VMID = 230 + index.
  talos_nodes = {
    talos-cp-a = { vm_id = 230, node_name = "ms-01a", offset = 61, worklab = false }
    talos-cp-b = { vm_id = 231, node_name = "ms-01b", offset = 62, worklab = false }
    talos-cp-w = { vm_id = 232, node_name = "pve", offset = 63, worklab = true }
  }
  talos_api_vip = cidrhost(local.talos_services_vlan.subnet, 60)

  talos_node_addrs = {
    for name, n in local.talos_nodes : name => {
      vm_id        = n.vm_id
      node_name    = n.node_name
      services_ip  = cidrhost(local.talos_services_vlan.subnet, n.offset)
      ceph_ip      = cidrhost(local.talos_ceph_vlan.subnet, n.offset)
      services_mac = format("52:54:00:%02x:00:%02x", n.vm_id - 200, local.talos_services_vlan.vlan_id)
      ceph_mac     = format("52:54:00:%02x:00:%02x", n.vm_id - 200, local.talos_ceph_vlan.vlan_id)
    }
  }
}

resource "proxmox_virtual_environment_download_file" "talos_worklab" {
  provider           = proxmox.worklab
  content_type       = "iso"
  datastore_id       = "local"
  node_name          = "pve"
  url                = var.cloud_images.talos.url
  file_name          = var.cloud_images.talos.file_name
  checksum           = var.cloud_images.talos.checksum
  checksum_algorithm = var.cloud_images.talos.checksum_algorithm
  overwrite          = true
  verify             = true
  upload_timeout     = 600
}

resource "proxmox_virtual_environment_download_file" "talos" {
  content_type       = "iso"
  datastore_id       = var.virtual_environment_storage
  node_name          = var.virtual_environment_node
  url                = var.cloud_images.talos.url
  file_name          = var.cloud_images.talos.file_name
  checksum           = var.cloud_images.talos.checksum
  checksum_algorithm = var.cloud_images.talos.checksum_algorithm
  overwrite          = true
  verify             = true
  upload_timeout     = 600
}

resource "proxmox_virtual_environment_vm" "talos_cp" {
  for_each = { for k, v in local.talos_node_addrs : k => v if !local.talos_nodes[k].worklab }

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = each.value.node_name
  on_boot   = true
  machine   = "q35"
  bios      = "seabios"
  tags      = ["talos", "control-plane"]

  agent { enabled = true }
  cpu {
    cores = 4
    type  = "host"
  }
  memory { dedicated = 8192 }
  operating_system { type = "l26" }

  disk {
    datastore_id = var.primary_disk_storage
    file_id      = proxmox_virtual_environment_download_file.talos.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }

  network_device {
    bridge      = local.talos_services_vlan.bridge
    mac_address = each.value.services_mac
  }
  network_device {
    bridge      = local.talos_ceph_vlan.bridge
    vlan_id     = local.talos_ceph_vlan.vlan_id
    mtu         = local.talos_ceph_vlan.mtu
    mac_address = each.value.ceph_mac
  }
}

# Temporary third member on worklab until the msi RMA (ADR 0031). VLAN 40 is
# tagged on vmbr0 (the only worklab bridge carrying it); VLAN 20 is the native
# VLAN of vmbr1's switch port, so that leg is untagged.
resource "proxmox_virtual_environment_vm" "talos_cp_worklab" {
  provider = proxmox.worklab
  for_each = { for k, v in local.talos_node_addrs : k => v if local.talos_nodes[k].worklab }

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = each.value.node_name
  on_boot   = true
  machine   = "q35"
  bios      = "seabios"
  tags      = ["talos", "control-plane"]

  agent { enabled = true }
  cpu {
    cores = 4
    type  = "host"
  }
  memory { dedicated = 8192 }
  operating_system { type = "l26" }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.talos_worklab.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }

  network_device {
    bridge      = "vmbr0"
    vlan_id     = local.talos_services_vlan.vlan_id
    mac_address = each.value.services_mac
  }
  network_device {
    bridge      = "vmbr1"
    mtu         = local.talos_ceph_vlan.mtu
    mac_address = each.value.ceph_mac
  }
}

output "talos_nodes" {
  description = "Talos control-plane addressing for kubernetes/talos (make talos-apply)"
  value = {
    api_vip     = local.talos_api_vip
    gateway     = cidrhost(local.talos_services_vlan.subnet, 1)
    prefix_len  = split("/", local.talos_services_vlan.subnet)[1]
    subnet      = local.talos_services_vlan.subnet
    dns_servers = module.network.dns_servers
    domain      = module.network.service_domain
    schematic   = regex("image/([0-9a-f]+)/", var.cloud_images.talos.url)[0]
    version     = regex("/(v[0-9.]+)/", var.cloud_images.talos.url)[0]
    nodes = {
      for name, n in local.talos_node_addrs : name => merge(n, {
        dhcp_ips = try(
          n.vm_id == 232 ? proxmox_virtual_environment_vm.talos_cp_worklab[name].ipv4_addresses : proxmox_virtual_environment_vm.talos_cp[name].ipv4_addresses,
          []
        )
      })
    }
  }
}
