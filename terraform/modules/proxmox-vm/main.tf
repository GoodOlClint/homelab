# Proxmox VM Module
# This module creates VMs in Proxmox with dynamic network configuration from Unifi Controller.
# It handles cloud-image download, VM creation with multiple network interfaces,
# GPU passthrough assignment, and generates Ansible inventory output.

data "local_file" "ssh_public_key" {
  filename = var.ssh_public_key_path
}

# Download the Ubuntu cloud image (optional)
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  count = var.create_cloud_image ? 1 : 0

  content_type        = "iso"
  datastore_id        = var.virtual_environment_storage
  node_name           = var.virtual_environment_node
  url                 = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name           = "noble-server-cloudimg-amd64.img"
  overwrite           = true
  overwrite_unmanaged = true # Allow overwriting files not managed by Terraform
  verify              = true
  upload_timeout      = 600
}

# Fetch all networks from Unifi Controller
data "unifi_network" "networks" {
  for_each = var.unifi_network_mapping
  name     = each.value.unifi_network_name
}

# Create dynamic VLAN configuration from Unifi data
locals {
  # Use downloaded image if created, otherwise use existing image
  ubuntu_cloud_image_id = var.create_cloud_image ? proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id : "local:iso/noble-server-cloudimg-amd64.img"

  # Build VLAN configuration from Unifi networks
  unifi_vlans = {
    for vlan_key, mapping in var.unifi_network_mapping : vlan_key => {
      vlan_id = data.unifi_network.networks[vlan_key].vlan_id
      bridge  = mapping.bridge
      subnet  = data.unifi_network.networks[vlan_key].subnet
      # Handle IPv6 subnet based on Unifi configuration
      subnet_v6 = (
        # Use static subnet if provided
        data.unifi_network.networks[vlan_key].ipv6_static_subnet != "" ?
        data.unifi_network.networks[vlan_key].ipv6_static_subnet :
        # For PD (Prefix Delegation), generate subnet using VLAN ID if prefix ID not available
        (var.ipv6_config.enabled &&
          data.unifi_network.networks[vlan_key].ipv6_interface_type == "pd" &&
          data.unifi_network.networks[vlan_key].ipv6_pd_interface != "" ?
          (data.unifi_network.networks[vlan_key].ipv6_pd_prefixid != "" ?
            "${var.ipv6_config.base_prefix}${data.unifi_network.networks[vlan_key].ipv6_pd_prefixid}::/64" :
          cidrsubnet(var.ipv6_config.base_prefix, 16, data.unifi_network.networks[vlan_key].vlan_id)) :
          # For networks with RA enabled but no PD, use SLAAC-compatible subnet
          (var.ipv6_config.enabled &&
            data.unifi_network.networks[vlan_key].ipv6_ra_enable &&
            var.ipv6_config.base_prefix != "" ?
            cidrsubnet(var.ipv6_config.base_prefix, 16, data.unifi_network.networks[vlan_key].vlan_id) :
        null))
      )
      mtu         = try(mapping.mtu, 1500)
      description = mapping.description != "" ? mapping.description : data.unifi_network.networks[vlan_key].name

      # Additional Unifi-specific data
      domain_name         = data.unifi_network.networks[vlan_key].domain_name
      dhcp_enabled        = data.unifi_network.networks[vlan_key].dhcp_enabled
      dhcp_start          = data.unifi_network.networks[vlan_key].dhcp_start
      dhcp_stop           = data.unifi_network.networks[vlan_key].dhcp_stop
      dhcp_dns            = data.unifi_network.networks[vlan_key].dhcp_dns
      dhcp_v6_enabled     = data.unifi_network.networks[vlan_key].dhcp_v6_enabled
      dhcp_v6_dns         = data.unifi_network.networks[vlan_key].dhcp_v6_dns
      ipv6_interface_type = data.unifi_network.networks[vlan_key].ipv6_interface_type
      ipv6_ra_enable      = data.unifi_network.networks[vlan_key].ipv6_ra_enable
      ipv6_static_subnet  = data.unifi_network.networks[vlan_key].ipv6_static_subnet
      ipv6_pd_interface   = data.unifi_network.networks[vlan_key].ipv6_pd_interface
      ipv6_pd_prefixid    = data.unifi_network.networks[vlan_key].ipv6_pd_prefixid
    }
  }

  # Merge with any static VLAN overrides (for backwards compatibility)
  merged_vlans = merge(
    local.unifi_vlans,
    var.vlans # Static overrides take precedence
  )

  # Generate random VM IDs for MAC address uniqueness
  vm_random_ids = {
    for vm_config in var.vm_configurations : vm_config.name => (
      abs(parseint(substr(sha256(vm_config.name), 0, 8), 16)) % 254
    ) + 1
  }

  # Function to build VM interfaces configuration using dynamic VLAN data
  build_vm_interfaces = {
    for vm_config in var.vm_configurations : vm_config.name => {
      for idx, vlan_key in vm_config.vlans : vlan_key => {
        vlan_id   = local.merged_vlans[vlan_key].vlan_id
        bridge    = local.merged_vlans[vlan_key].bridge
        subnet    = local.merged_vlans[vlan_key].subnet
        subnet_v6 = local.merged_vlans[vlan_key].subnet_v6

        # Use static IPv4 if ip_offset is provided, otherwise use DHCP
        ip = vm_config.ip_offset != null ? cidrhost(local.merged_vlans[vlan_key].subnet, vm_config.ip_offset) : null

        # IPv6 configuration - use static IPv6 if conditions are met
        ipv6 = (
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled" &&
          vm_config.ipv6_offset != null &&
          vm_config.ipv6_mode != "slaac"
        ) ? cidrhost(local.merged_vlans[vlan_key].subnet_v6, vm_config.ipv6_offset) : null

        # IPv4 gateway (only for primary interface)
        gw = (idx == 0 && vm_config.ip_offset != null) ? cidrhost(local.merged_vlans[vlan_key].subnet, 1) : null

        # IPv6 gateway (only for primary interface with static IPv6)
        gw_v6 = (
          idx == 0 &&
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled" &&
          vm_config.ipv6_offset != null &&
          vm_config.ipv6_mode != "slaac"
        ) ? cidrhost(local.merged_vlans[vlan_key].subnet_v6, 1) : null

        mtu = try(local.merged_vlans[vlan_key].mtu, 1500)

        # IPv4 DHCP configuration
        dhcp = vm_config.ip_offset == null ? true : false

        # IPv6 Router Advertisement - use SLAAC if IPv6 subnet exists but not using static
        accept_ra = (
          var.ipv6_config.enabled &&
          local.merged_vlans[vlan_key].subnet_v6 != null &&
          vm_config.ipv6_mode != "disabled" &&
          (vm_config.ipv6_offset == null || vm_config.ipv6_mode == "slaac")
        ) ? true : false

        dhcp6 = false # Generally disable DHCPv6 in favor of SLAAC

        # Use a unique MAC address per VM and interface
        macaddress = format(
          "52:54:00:%02x:%02x:%02x",
          local.vm_random_ids[vm_config.name],
          idx,
          local.merged_vlans[vlan_key].vlan_id % 256
        )

        # Additional Unifi-sourced metadata
        unifi_network_name = try(data.unifi_network.networks[vlan_key].name, "unknown")
        dhcp_pool_start    = try(local.merged_vlans[vlan_key].dhcp_start, null)
        dhcp_pool_stop     = try(local.merged_vlans[vlan_key].dhcp_stop, null)
      }
    }
  }

  # Function to get VLAN 100 IP for each VM from their actual network interfaces
  vm_vlan100_ips = {
    for vm_config in var.vm_configurations : vm_config.name => try(flatten([
      for interface_ips in proxmox_virtual_environment_vm.vms[vm_config.name].ipv4_addresses :
      [for ip in interface_ips : ip
        if startswith(ip, "172.16.100.") && ip != "127.0.0.1"
      ]
    ])[0], "")
  }
}

# Generate cloud-init user data files for each VM
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = { for vm in var.vm_configurations : vm.name => vm }

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

# Generate cloud-init network data files for each VM
resource "proxmox_virtual_environment_file" "network_data" {
  for_each = { for vm in var.vm_configurations : vm.name => vm }

  content_type = "snippets"
  datastore_id = var.virtual_environment_storage
  node_name    = var.virtual_environment_node

  source_raw {
    data = templatefile("${path.module}/templates/network-data.yaml.tmpl", {
      interfaces = [
        for vlan_key, iface in local.build_vm_interfaces[each.value.name] : {
          name       = "eth_${vlan_key}"
          mtu        = iface.mtu
          dhcp       = iface.dhcp
          accept_ra  = iface.accept_ra
          dhcp6      = iface.dhcp6
          address    = iface.ip != null ? iface.ip : ""
          address_v6 = iface.ipv6 != null ? iface.ipv6 : ""
          prefix     = iface.subnet != null ? split("/", iface.subnet)[1] : ""
          prefix_v6  = iface.subnet_v6 != null ? split("/", iface.subnet_v6)[1] : ""
          gateway    = iface.gw != null ? iface.gw : ""
          gateway_v6 = iface.gw_v6 != null ? iface.gw_v6 : ""
          macaddress = iface.macaddress != null ? iface.macaddress : ""
          # Add DNS servers from Unifi data for static IPs
          dns_servers = !iface.dhcp ? concat(
            try(data.unifi_network.networks[vlan_key].dhcp_dns, ["172.16.100.53", "172.16.100.1"]),
            try(data.unifi_network.networks[vlan_key].dhcp_v6_dns != null ? data.unifi_network.networks[vlan_key].dhcp_v6_dns : [], [])
          ) : []
        }
      ]
    })
    file_name = "${each.value.name}-network-data.yaml"
  }
}

# Create VMs dynamically based on configuration
resource "proxmox_virtual_environment_vm" "vms" {
  for_each = { for vm in var.vm_configurations : vm.name => vm }

  name      = each.value.name
  node_name = var.virtual_environment_node

  # Explicit dependency to ensure cloud-init files are created first
  depends_on = [
    proxmox_virtual_environment_file.user_data,
    proxmox_virtual_environment_file.network_data
  ]

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
    file_id      = local.ubuntu_cloud_image_id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.disk_size_gb
  }

  initialization {
    datastore_id         = coalesce(each.value.disk_storage, var.primary_disk_storage)
    user_data_file_id    = proxmox_virtual_environment_file.user_data[each.key].id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
  }

  dynamic "network_device" {
    for_each = local.build_vm_interfaces[each.value.name]
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
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
