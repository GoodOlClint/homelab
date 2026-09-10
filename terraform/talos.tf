# Talos control-plane VMs (ADR 0031 build, ADR 0033 forks). Plain resources,
# not modules/proxmox-vm: Talos has no cloud-init, takes its config over its
# own API. No HA resource ever (two etcd members on one host = lost quorum).
# The temporary worklab member (ADR 0031) retired 2026-09-08 when msi returned;
# the provider alias remains for any future worklab-hosted resource.

provider "proxmox" {
  alias    = "worklab"
  endpoint = var.worklab_endpoint
  username = var.virtual_environment_username
  password = var.worklab_password
  insecure = false # the endpoint serves a root-chained node cert (ADR 0041; proxmox-hosts.yml)
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
    talos-cp-a = { vm_id = 230, node_name = "ms-01a", offset = 61 }
    talos-cp-b = { vm_id = 231, node_name = "ms-01b", offset = 62 }
    talos-cp-c = { vm_id = 232, node_name = "msi", offset = 63 }
  }
  talos_api_vip = cidrhost(local.talos_services_vlan.subnet, 60)

  # Host memory pressure must never select a services-plane node: -1000 exempts
  # the kvm process from OOM selection, so the kernel takes the aggressor guest
  # instead (2026-08-31: a CI provision spike OOM-killed talos-cp-a).
  talos_oom_hook = <<-EOT
    #!/bin/bash
    vmid="$1"
    phase="$2"
    if [ "$phase" = "post-start" ]; then
      echo -1000 > "/proc/$(cat "/var/run/qemu-server/$vmid.pid")/oom_score_adj"
    fi
    exit 0
  EOT

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

# One copy per node on its local datastore: pve-guests autostarts the VM before
# pvestatd has mounted cephfs, and a hookscript on an unmounted datastore fails
# the start. The hookscript only fires on the next VM start, so a running VM
# needs the adj applied once by hand
# (echo -1000 > /proc/$(cat /var/run/qemu-server/<vmid>.pid)/oom_score_adj).
resource "proxmox_virtual_environment_file" "talos_oom_hook" {
  for_each = toset([for n in values(local.talos_node_addrs) : n.node_name])

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.key
  file_mode    = "0755"

  source_raw {
    data      = local.talos_oom_hook
    file_name = "talos-oom-protect.sh"
  }
}

# Orphaned since the worklab member retired (2026-09-09) — kept so a plan does
# not destroy another session's in-flight state object; retire it at merge time.
resource "proxmox_virtual_environment_file" "talos_oom_hook_worklab" {
  provider     = proxmox.worklab
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "pve"
  file_mode    = "0755"

  source_raw {
    data      = local.talos_oom_hook
    file_name = "talos-oom-protect.sh"
  }
}

resource "proxmox_virtual_environment_vm" "talos_cp" {
  for_each = local.talos_node_addrs

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = each.value.node_name
  on_boot   = true
  machine   = "q35"
  bios      = "seabios"
  tags      = ["talos", "control-plane"]
  hook_script_file_id = proxmox_virtual_environment_file.talos_oom_hook[each.value.node_name].id

  agent { enabled = true }
  cpu {
    cores = 6
    type  = "host"
  }
  memory { dedicated = 16384 }
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
        dhcp_ips = try(proxmox_virtual_environment_vm.talos_cp[name].ipv4_addresses, [])
      })
    }
  }
}
