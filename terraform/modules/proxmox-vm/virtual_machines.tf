locals {
  # Determine which VLAN gets the default gateway for each VM:
  # - Single VLAN (management only): management gets the default route
  # - Multiple VLANs: first non-management VLAN THAT HAS A ROUTER
  # - No non-management VLAN has one: fall back to management, but ONLY if the
  #   guest actually has that leg and it has a router — otherwise null, which
  #   the precondition below rejects rather than shipping a routeless guest
  # - A guest with neither vm_id nor mgmt_ip_offset is NOT supported here: the
  #   coalesce below errors at plan time. That is pre-existing and loud, so it
  #   is left alone deliberately; do not read the DHCP-management wording in
  #   variables.tf as a working path (W6 review, 2026-08-12).
  #
  # The gateway filter is load-bearing, not defensive. PBS is the one guest with
  # a storage-VLAN leg, and VLAN 20 has no router. Today it survives only because
  # its list is [vlan10, vlan40, vlan20] with vlan10 as management, so vlan40 wins
  # the scan. At WP4 (ADR 0017) the vlan10 leg goes away and management becomes
  # vlan40, leaving [vlan40, vlan20] — the old "first non-management" rule then
  # picks vlan20 and the guest boots with a default route to a nonexistent router:
  # no package installs, no qemu-guest-agent, and terraform hangs waiting for the
  # agent to report an IP. Reproduced on worklab 2026-08-12 (W6).
  vm_gateway_vlans = {
    for vm_config in var.vm_configurations : vm_config.name => (
      coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) == null ? null :
      # The single-VLAN shortcut is gated on that VLAN actually having a router.
      # Ungated it defeated both preconditions: a lone gateway-less leg returned
      # itself, the precondition saw non-null and passed, and the guest booted
      # with no default route — which fails EXACTLY like the wrong-router case
      # this whole mechanism exists to stop (no internet → cloud-init packages
      # fail → qemu-guest-agent never installs → bpg hangs waiting for an agent
      # IP). "No route" and "route to nowhere" are the same outage.
      length(vm_config.vlans) == 1 ? (lookup(local.vlan_gateways, vm_config.vlans[0], null) != null ? vm_config.vlans[0] : null) :
      # The fallback must be a leg the guest HAS and that has a router. Falling
      # back to var.management_vlan unconditionally could name a VLAN absent
      # from vm_config.vlans, so no interface would match is_gateway and the
      # guest would boot with no default route and no diagnostic at all.
      try(
        [for v in vm_config.vlans : v if v != var.management_vlan && lookup(local.vlan_gateways, v, null) != null][0],
        contains(vm_config.vlans, var.management_vlan) && lookup(local.vlan_gateways, var.management_vlan, null) != null ? var.management_vlan : null
      )
    )
  }

  # Build VM interfaces configuration
  # Management VLAN: static IP based on vm_id when set, DHCP fallback when vm_id is null
  # Other VLANs: static IP from ip_offset, DHCP when ip_offset is null
  # Gateway VLAN gets default route; other static interfaces get source-based policy routes
  build_vm_interfaces = {
    for vm_config in var.vm_configurations : vm_config.name => {
      for idx, vlan_key in vm_config.vlans : vlan_key => {
        vlan_id   = local.merged_vlans[vlan_key].vlan_id
        bridge    = local.merged_vlans[vlan_key].bridge
        subnet    = local.merged_vlans[vlan_key].subnet
        subnet_v6 = local.merged_vlans[vlan_key].subnet_v6

        ip = (
          vlan_key == var.management_vlan ? (
            coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) != null ? cidrhost(local.merged_vlans[vlan_key].subnet, coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id)) : null
          ) :
          vm_config.ip_offset != null ? cidrhost(local.merged_vlans[vlan_key].subnet, vm_config.ip_offset) : null
        )

        # IPv6 configuration - static IPv6 only on non-management VLANs
        ipv6 = (
          vlan_key != var.management_vlan &&
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled" &&
          vm_config.ipv6_offset != null &&
          vm_config.ipv6_mode != "slaac"
        ) ? cidrhost(local.merged_vlans[vlan_key].subnet_v6, vm_config.ipv6_offset) : null

        # Gateway: set on ALL interfaces with static IPs (for policy routing)
        # The template determines whether it's the default route or a policy route
        # null on a gateway-less VLAN — the template then emits no route for this
        # leg, leaving only the kernel link route that same-subnet traffic uses.
        gw = (
          vlan_key == var.management_vlan ? (
            coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) != null ? local.vlan_gateways[vlan_key] : null
          ) :
          vm_config.ip_offset != null ? local.vlan_gateways[vlan_key] : null
        )
        gw_v6 = null

        # This interface gets the default route (main routing table)
        # Other interfaces with gateways get source-based policy routes
        is_gateway = vlan_key == local.vm_gateway_vlans[vm_config.name]

        # Routing table number for policy routes (uses VLAN ID for uniqueness)
        routing_table = local.merged_vlans[vlan_key].vlan_id

        mtu = try(local.merged_vlans[vlan_key].mtu, 1500)

        dhcp = vlan_key == var.management_vlan ? (coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) == null) : (vm_config.ip_offset == null)

        # IPv6 RA - accept on every v6-enabled interface unless v6 is explicitly disabled.
        # A static ipv6_offset does NOT imply "no RA": the router advertisement is the only
        # source of the IPv6 default route here, so suppressing it strands the interface in
        # its own /64. That stranded adguard (the sole static-offset VM) with no v6 route,
        # silently timing out every AAAA lookup and every reply to a GUA client.
        accept_ra = (
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled"
        ) ? true : false

        dhcp6 = false

        # Unique MAC per VM + VLAN (uses vlan_id instead of idx for stability across VLAN reordering)
        macaddress = format(
          "52:54:00:%02x:%02x:%02x",
          local.vm_random_ids[vm_config.name],
          floor(local.merged_vlans[vlan_key].vlan_id / 256),
          local.merged_vlans[vlan_key].vlan_id % 256
        )

        # Additional VLAN metadata
        dhcp_pool_start = try(local.merged_vlans[vlan_key].dhcp_start, null)
        dhcp_pool_stop  = try(local.merged_vlans[vlan_key].dhcp_stop, null)
      }
    }
  }

  # Management IP: mgmt_ip_offset > vm_id > actual VMID (fallback chain)
  # Explicit values avoid resource dependency — safe for -target operations
  vm_management_ips = {
    for vm_config in var.vm_configurations : vm_config.name =>
    cidrhost(
      local.merged_vlans[var.management_vlan].subnet,
      coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id, try(proxmox_virtual_environment_vm.vms[vm_config.name].vm_id, 0))
    )
  }

  # Service-facing IP: services VLAN leg, else management leg, else the guest's
  # first leg — a guest on neither plane (vlan30, ADR 0030) has no address on
  # the management subnet.
  vm_service_ips = {
    for vm_config in var.vm_configurations : vm_config.name =>
    contains(vm_config.vlans, var.services_vlan) && vm_config.ip_offset != null
    ? cidrhost(local.merged_vlans[var.services_vlan].subnet, vm_config.ip_offset)
    : (contains(vm_config.vlans, var.management_vlan) || vm_config.ip_offset == null
      ? local.vm_management_ips[vm_config.name]
    : cidrhost(local.merged_vlans[vm_config.vlans[0]].subnet, vm_config.ip_offset))
  }
}
# Generate cloud-init user data files for each VM (only when not using Packer)
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.use_packer_template ? {} : local.vm_guests

  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/templates/user-data.yaml.tmpl", {
      hostname       = coalesce(each.value.hostname, each.value.name)
      fqdn           = coalesce(each.value.fqdn, "${each.value.name}.${var.service_domain}")
      username       = var.virtual_machine_username
      ssh_key        = trimspace(data.local_file.ssh_public_key.content)
      timezone       = var.virtual_machine_timezone
      password_hash  = var.virtual_machine_password_hash
      apt_proxy_host = var.apt_proxy_host
      apt_proxy_port = var.apt_proxy_port
    })
    file_name = "${each.value.name}-user-data.yaml"
  }
}

# Generate cloud-init network data files for each VM (only when not using Packer)
resource "proxmox_virtual_environment_file" "network_data" {
  for_each = var.use_packer_template ? {} : local.vm_guests

  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/templates/network-data.yaml.tmpl", {
      interfaces = [
        for idx, vlan_entry in [for vlan_key, iface in local.build_vm_interfaces[each.value.name] : { key = vlan_key, iface = iface }] : {
          name          = "eth_${vlan_entry.key}"
          mtu           = vlan_entry.iface.mtu
          dhcp          = vlan_entry.iface.dhcp
          accept_ra     = vlan_entry.iface.accept_ra
          dhcp6         = vlan_entry.iface.dhcp6
          address       = vlan_entry.iface.ip != null ? vlan_entry.iface.ip : ""
          address_v6    = vlan_entry.iface.ipv6 != null ? vlan_entry.iface.ipv6 : ""
          prefix        = vlan_entry.iface.subnet != null ? split("/", vlan_entry.iface.subnet)[1] : ""
          prefix_v6     = vlan_entry.iface.subnet_v6 != null ? split("/", vlan_entry.iface.subnet_v6)[1] : ""
          gateway       = vlan_entry.iface.gw != null ? vlan_entry.iface.gw : ""
          gateway_v6    = vlan_entry.iface.gw_v6 != null ? vlan_entry.iface.gw_v6 : ""
          macaddress    = vlan_entry.iface.macaddress != null ? vlan_entry.iface.macaddress : ""
          is_primary    = vlan_entry.key == var.management_vlan                          # Management VLAN is primary for DHCP metric
          is_gateway    = vlan_entry.iface.is_gateway                                    # This interface gets the default route
          routing_table = vlan_entry.iface.routing_table                                 # VLAN ID used as policy routing table number
          subnet        = vlan_entry.iface.subnet != null ? vlan_entry.iface.subnet : "" # For connected route in policy table
          dns_servers   = var.dns_servers
        }
      ]
    })
    file_name = "${each.value.name}-network-data.yaml"
  }
}

# Create VMs dynamically based on configuration (LXC guests live in containers.tf)
resource "proxmox_virtual_environment_vm" "vms" {
  for_each = local.vm_guests

  name       = each.value.name
  vm_id      = each.value.vm_id # null = auto-assign by Proxmox
  node_name  = coalesce(each.value.node_name, var.virtual_environment_node)
  protection = var.unprotect ? false : each.value.protected

  # Clone from Packer template (when using Packer)
  dynamic "clone" {
    for_each = var.use_packer_template ? [1] : []
    content {
      vm_id = local.packer_template_vm_id
    }
  }

  agent {
    enabled = true
  }

  machine = "q35"

  cpu {
    cores = each.value.cpu_cores
    type  = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = coalesce(each.value.disk_storage, var.primary_disk_storage)
    file_id      = local.vm_disk_source_by_name[each.value.name] # Only for cloud images, null for Packer
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.disk_size_gb
  }

  dynamic "disk" {
    for_each = each.value.extra_disks
    content {
      datastore_id = coalesce(disk.value.storage, var.primary_disk_storage)
      interface    = "virtio${disk.key + 1}"
      iothread     = true
      discard      = "on"
      cache        = "none"
      size         = disk.value.size_gb
      file_format  = "raw"
    }
  }

  # Detached data volume attach (ADR 0015/0020): existing holder-VM volume by
  # in-datastore path — this VM never owns it, so rebuilds leave the data intact.
  # Formatted+chowned once out-of-band (ADR 0020); the role mounts it directly.
  dynamic "disk" {
    for_each = each.value.data_volume != null ? [each.value.data_volume] : []
    content {
      datastore_id      = local.data_volume_refs[disk.value.name].datastore_id
      path_in_datastore = local.data_volume_refs[disk.value.name].path_in_datastore
      interface         = "virtio${1 + length(each.value.extra_disks)}"
      size              = var.data_volumes[disk.value.name].size_gb
      backup            = false # The holder's PBS job owns volume backup
    }
  }

  # Conditional cloud-init initialization (only when not using Packer)
  dynamic "initialization" {
    for_each = var.use_packer_template ? [] : [1]
    content {
      datastore_id         = coalesce(each.value.disk_storage, var.primary_disk_storage)
      user_data_file_id    = proxmox_virtual_environment_file.user_data[each.key].id
      network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
    }
  }

  # No lifecycle.ignore_changes on cloud-init file IDs (ADR 0016): a changed
  # snippet or image pin SHOWS as guest replacement in plan — that visibility is
  # the point. Rolls are deliberate, per-guest, via `make rebuild <guest>`.
  # The precondition mirrors containers.tf: fails closed on a genuinely-null
  # volid, but cannot enforce the out-of-band format for a same-apply new
  # volume (id is unknown, not null, at plan). Procedural gate: holder →
  # format+chown → consumer, never one apply (see data-volumes.tf).
  lifecycle {
    precondition {
      condition     = each.value.data_volume == null || local.data_volume_ids[each.value.data_volume.name] != null
      error_message = "Data volume for '${each.value.name}' is not materialized — apply the holder, format+chown it (ADR 0020), then build this guest."
    }
    precondition {
      condition     = each.value.image == null || contains(keys(var.cloud_images), each.value.image)
      error_message = "Guest '${each.value.name}' sets image = \"${coalesce(each.value.image, "none")}\", which is not a key in var.cloud_images (ADR 0025)."
    }
    # Packer mode clones a single module-wide template and ignores disk.file_id
    # entirely, so a per-guest image would be silently dropped — the guest would
    # come up on the Ubuntu template while the config claims otherwise. Fail
    # loudly instead; the two features are mutually exclusive by construction.
    precondition {
      condition     = each.value.image == null || !var.use_packer_template
      error_message = "Guest '${each.value.name}' sets image = \"${coalesce(each.value.image, "none")}\" but use_packer_template is true — Packer clones one template and cannot honour a per-guest image (ADR 0025)."
    }
    # A static guest with no resolvable gateway VLAN gets no default route and
    # no error — it just boots unreachable off-subnet. Fail at plan instead.
    precondition {
      condition     = local.vm_gateway_vlans[each.value.name] != null
      error_message = "Guest '${each.value.name}' has no VLAN with a router: every leg in ${jsonencode(each.value.vlans)} is gateway-less (or names a VLAN not defined in var.vlans) and the management VLAN '${var.management_vlan}' is not among them (or has no gateway either). It would boot with no default route."
    }
  }

  dynamic "network_device" {
    for_each = local.build_vm_interfaces[each.value.name]
    content {
      bridge = network_device.value.bridge
      # Only set vlan_id for physical bridges (vmbr*), not for SDN VNETs
      vlan_id     = can(regex("^vmbr", network_device.value.bridge)) ? network_device.value.vlan_id : null
      mtu         = network_device.value.mtu
      mac_address = network_device.value.macaddress
    }
  }
}
