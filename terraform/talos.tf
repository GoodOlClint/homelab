# Talos VMs of the services cluster (ADR 0031 build, ADR 0033 forks) and the
# ci cluster (ADR 0063), one map in talos-nodes.json. Plain resources,
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
  # null until the operator adds ci_runner to vlans.yaml; the ci nodes drop out of the plan until then.
  talos_ci_vlan = try(module.network.vlans["vlan${module.network.network_data.vlans.ci_runner.id}"], null)
  talos_cluster_vlans = {
    services = local.talos_services_vlan
    ci       = local.talos_ci_vlan
  }

  # talos-nodes.json is also read by the Makefile (per-cluster -target) and update-nodes.yml.
  # offset doubles as the last octet on every leg; only the services cluster has a Ceph leg.
  talos_nodes   = jsondecode(file("${path.module}/talos-nodes.json"))
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
      cluster    = n.cluster
      role       = n.role
      vm_id      = n.vm_id
      node_name  = n.node_name
      cores      = n.cores
      memory     = n.memory
      scratch_gb = n.scratch_gb
      bridge     = local.talos_cluster_vlans[n.cluster].bridge
      ip         = cidrhost(local.talos_cluster_vlans[n.cluster].subnet, n.offset)
      mac        = format("52:54:00:%02x:00:%02x", n.vm_id - 200, local.talos_cluster_vlans[n.cluster].vlan_id)
      ceph_ip    = n.cluster == "services" ? cidrhost(local.talos_ceph_vlan.subnet, n.offset) : null
      ceph_mac   = n.cluster == "services" ? format("52:54:00:%02x:00:%02x", n.vm_id - 200, local.talos_ceph_vlan.vlan_id) : null
    } if local.talos_cluster_vlans[n.cluster] != null
  }
}

moved {
  from = proxmox_virtual_environment_download_file.talos
  to   = proxmox_download_file.talos
}

resource "proxmox_download_file" "talos" {
  content_type       = "iso"
  datastore_id       = var.virtual_environment_storage
  node_name          = var.proxmox_nodes[0] # ms-01a is gone; cephfs is shared, so any member serves the image
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
  for_each = toset([for n in values(local.talos_node_addrs) : n.node_name if n.cluster == "services"])

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

  name                = each.key
  vm_id               = each.value.vm_id
  node_name           = each.value.node_name
  on_boot             = true
  machine             = "q35"
  bios                = "seabios"
  tags                = each.value.cluster == "services" ? ["talos", "control-plane"] : ["talos", each.value.cluster, each.value.role == "worker" ? "worker" : "control-plane"]
  hook_script_file_id = each.value.cluster == "services" ? proxmox_virtual_environment_file.talos_oom_hook[each.value.node_name].id : null

  agent { enabled = true }
  cpu {
    cores = each.value.cores
    type  = "host"
  }
  memory { dedicated = each.value.memory }
  operating_system { type = "l26" }

  disk {
    datastore_id = var.primary_disk_storage
    file_id      = proxmox_download_file.talos.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 40
  }
  # Unpack scratch on the node's own NVMe, never Ceph: a 400 MiB/s unpack stalled
  # etcd fsync on every member (2026-10-10). Talos mounts it at /var/mnt/scratch.
  dynamic "disk" {
    for_each = each.value.scratch_gb > 0 ? [each.value.scratch_gb] : []
    content {
      datastore_id = "local-zfs"
      interface    = "virtio1"
      iothread     = true
      discard      = "on"
      size         = disk.value
      file_format  = "raw"
      backup       = false
    }
  }

  network_device {
    bridge      = each.value.bridge
    mac_address = each.value.mac
  }
  dynamic "network_device" {
    for_each = each.value.ceph_mac == null ? [] : [each.value.ceph_mac]
    content {
      bridge      = local.talos_ceph_vlan.bridge
      vlan_id     = local.talos_ceph_vlan.vlan_id
      mtu         = local.talos_ceph_vlan.mtu
      mac_address = network_device.value
    }
  }

  lifecycle {
    ignore_changes = [disk[0].file_id]
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
      for name, n in local.talos_node_addrs : name => {
        vm_id        = n.vm_id
        node_name    = n.node_name
        services_ip  = n.ip
        ceph_ip      = n.ceph_ip
        services_mac = n.mac
        ceph_mac     = n.ceph_mac
        dhcp_ips     = try(proxmox_virtual_environment_vm.talos_cp[name].ipv4_addresses, [])
      } if n.cluster == "services"
    }
  }
}

# The CI cluster (ADR 0063): one leg on ci_runner, no VIP (the endpoint is the control-plane node),
# no Ceph leg. null until ci_runner exists in vlans.yaml. Each mac is what the DHCP reservation keys on.
output "talos_ci_nodes" {
  description = "Talos CI cluster addressing for kubernetes/talos (make talos-apply CLUSTER=ci)"
  value = local.talos_ci_vlan == null ? null : {
    cluster     = "ci"
    gateway     = cidrhost(local.talos_ci_vlan.subnet, 1)
    prefix_len  = split("/", local.talos_ci_vlan.subnet)[1]
    subnet      = local.talos_ci_vlan.subnet
    dns_servers = module.network.dns_servers
    domain      = module.network.service_domain
    schematic   = regex("image/([0-9a-f]+)/", var.cloud_images.talos.url)[0]
    version     = regex("/(v[0-9.]+)/", var.cloud_images.talos.url)[0]
    nodes = {
      for name, n in local.talos_node_addrs : name => {
        vm_id      = n.vm_id
        node_name  = n.node_name
        role       = n.role
        ip         = n.ip
        mac        = n.mac
        scratch_gb = n.scratch_gb
        dhcp_ips   = try(proxmox_virtual_environment_vm.talos_cp[name].ipv4_addresses, [])
      } if n.cluster == "ci"
    }
  }
}
