# Proxmox VM Terraform Module

This is a reusable Terraform module for creating VMs in Proxmox Virtual Environment with integrated Unifi network discovery and flexible configuration options.

## Features

- **Dynamic Network Discovery**: Automatically discovers VLAN configurations from Unifi Controller
- **Multi-VLAN Support**: Assigns VMs to multiple VLANs with proper IP configuration
- **GPU Passthrough**: Configurable GPU passthrough for VMs that need graphics acceleration
- **Cloud-Init Integration**: Automated VM provisioning with SSH keys and initial configuration
- **IPv6 Support**: Flexible IPv6 configuration with SLAAC, static, or disabled modes
- **Ansible Integration**: Generates inventory output for automated configuration management

## Usage

```hcl
module "my_vms" {
  source = "./modules/proxmox-vm"

  # Proxmox connection
  virtual_environment_endpoint = "https://proxmox.example.com:8006"
  virtual_environment_username = "root@pam"
  virtual_environment_password = var.proxmox_password

  # VM configurations
  vm_configurations = [
    {
      name         = "web-server"
      vlans        = ["vlan100"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 50
    }
  ]

  # Network mapping
  unifi_network_mapping = {
    "vlan100" = {
      unifi_network_name = "Core"
      bridge            = "vmbr0"
    }
  }

  # Unifi Controller access
  unifi_username = var.unifi_username
  unifi_password = var.unifi_password
  unifi_api_url  = "https://unifi.example.com:8443"
}
```

## File Structure

### [main.tf](main.tf)
Core module logic including:
- VM resource definitions
- Network interface creation
- GPU passthrough configuration
- Cloud-init setup

### [variables.tf](variables.tf)
Input variable definitions with detailed documentation for:
- VM specifications and network configuration
- Provider connection settings  
- GPU and IPv6 configuration options

### [outputs.tf](outputs.tf)
Module outputs including:
- VM IP addresses and network information
- Ansible inventory data
- VLAN and network configuration details

### [provider.tf](provider.tf)
Required provider versions for:
- Proxmox VE provider
- Unifi Controller provider
- Local file provider

## VM Configuration Options

Each VM in `vm_configurations` supports:

- **name**: Unique VM identifier
- **vlans**: List of VLANs to connect to
- **ip_offset**: Static IP offset (optional, uses DHCP if null)
- **cpu_cores/memory_mb/disk_size_gb**: Resource allocation
- **needs_gpu**: Enable GPU passthrough
- **ipv6_mode**: IPv6 configuration ("static", "slaac", "disabled", "auto")

## Network Integration

The module automatically:
1. Queries Unifi Controller for network configurations
2. Maps VLAN names to actual network settings
3. Creates appropriate VM network interfaces
4. Configures static IPs or DHCP as specified
5. Handles IPv6 configuration based on network capabilities

## GPU Passthrough

For VMs with `needs_gpu = true`, the module:
- Assigns the configured GPU mapping
- Sets up mediated device (mdev) for GPU sharing
- Configures PCI passthrough settings

This enables hardware acceleration for containers, media transcoding, or other GPU workloads.
