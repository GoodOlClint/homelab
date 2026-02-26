locals {
  # Determine which VLAN gets the default gateway for each VM:
  # - Single VLAN (management only): management gets the default route
  # - Multiple VLANs: first non-management VLAN gets the default route
  # - DHCP management (no vm_id): null — DHCP provides the gateway
  vm_gateway_vlans = {
    for vm_config in var.vm_configurations : vm_config.name => (
      coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) == null ? null :
      length(vm_config.vlans) == 1 ? vm_config.vlans[0] :
      [for v in vm_config.vlans : v if v != var.management_vlan][0]
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

        # Management VLAN: static from mgmt_ip_offset or vm_id (whichever is set), DHCP when neither
        # Other VLANs: static from ip_offset when set, DHCP when null
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
        gw = (
          vlan_key == var.management_vlan ? (
            coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) != null ? cidrhost(local.merged_vlans[vlan_key].subnet, 1) : null
          ) :
          vm_config.ip_offset != null ? cidrhost(local.merged_vlans[vlan_key].subnet, 1) : null
        )
        gw_v6 = null

        # This interface gets the default route (main routing table)
        # Other interfaces with gateways get source-based policy routes
        is_gateway = vlan_key == local.vm_gateway_vlans[vm_config.name]

        # Routing table number for policy routes (uses VLAN ID for uniqueness)
        routing_table = local.merged_vlans[vlan_key].vlan_id

        mtu = try(local.merged_vlans[vlan_key].mtu, 1500)

        # Management VLAN: DHCP only when neither vm_id nor mgmt_ip_offset is set
        dhcp = vlan_key == var.management_vlan ? (coalesce(vm_config.mgmt_ip_offset, vm_config.vm_id) == null) : (vm_config.ip_offset == null)

        # IPv6 RA - management VLAN always accepts RA; others follow existing logic
        accept_ra = (
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled" &&
          (vlan_key == var.management_vlan || vm_config.ipv6_offset == null || vm_config.ipv6_mode == "slaac")
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
}
# Generate cloud-init user data files for each VM (only when not using Packer)
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.use_packer_template ? {} : { for vm in var.vm_configurations : vm.name => vm }

  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/templates/user-data.yaml.tmpl", {
      hostname      = coalesce(each.value.hostname, each.value.name)
      fqdn          = coalesce(each.value.fqdn, "${each.value.name}.${var.domain_suffix}")
      username      = var.virtual_machine_username
      ssh_key       = trimspace(data.local_file.ssh_public_key.content)
      timezone      = var.virtual_machine_timezone
      password_hash = var.virtual_machine_password_hash
    })
    file_name = "${each.value.name}-user-data.yaml"
  }
}

# Generate cloud-init network data files for each VM (only when not using Packer)
resource "proxmox_virtual_environment_file" "network_data" {
  for_each = var.use_packer_template ? {} : { for vm in var.vm_configurations : vm.name => vm }

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
          is_primary    = vlan_entry.key == var.management_vlan # Management VLAN is primary for DHCP metric
          is_gateway    = vlan_entry.iface.is_gateway           # This interface gets the default route
          routing_table = vlan_entry.iface.routing_table         # VLAN ID used as policy routing table number
          subnet        = vlan_entry.iface.subnet != null ? vlan_entry.iface.subnet : ""  # For connected route in policy table
          dns_servers   = var.dns_servers
        }
      ]
    })
    file_name = "${each.value.name}-network-data.yaml"
  }
}

# Create VMs dynamically based on configuration
resource "proxmox_virtual_environment_vm" "vms" {
  for_each = { for vm in var.vm_configurations : vm.name => vm }

  name       = each.value.name
  vm_id      = each.value.vm_id # null = auto-assign by Proxmox
  node_name  = var.virtual_environment_node
  protection = var.unprotect ? false : each.value.protected

  # Dependencies are inferred from resource references in initialization block

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
    file_id      = local.vm_disk_source  # Only for cloud images, null for Packer
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.disk_size_gb
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

  # Ignore changes to cloud-init files - they only run on first boot
  # Updating templates will affect new VMs only, not existing ones
  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      initialization[0].network_data_file_id,
    ]
  }

  dynamic "network_device" {
    for_each = local.build_vm_interfaces[each.value.name]
    content {
      bridge      = network_device.value.bridge
      # Only set vlan_id for physical bridges (vmbr*), not for SDN VNETs
      vlan_id     = can(regex("^vmbr", network_device.value.bridge)) ? network_device.value.vlan_id : null
      mtu         = network_device.value.mtu
      mac_address = network_device.value.macaddress
    }
  }

  # Optional GPU passthrough
  dynamic "hostpci" {
    for_each = each.value.needs_gpu ? [1] : []
    content {
      device  = var.gpu_mapping.device
      mapping = var.gpu_mapping.mapping
      mdev    = var.gpu_mapping.mdev
    }
  }
}
