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
}