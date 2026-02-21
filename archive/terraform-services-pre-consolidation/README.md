# Terraform Services for Homelab

This directory contains Terraform configuration files for provisioning and managing service VMs in a Proxmox Virtual Environment (PVE) homelab setup.

## Overview

This configuration creates service-focused VMs like Docker hosts, Plex servers, Homebridge, and other application services. It uses the shared `proxmox-vm` module for consistent VM creation and leverages Unifi Controller integration for dynamic network discovery.

## File Overview

### [VMs.tf](VMs.tf)
Defines the list of service VMs to be created with their specifications:
- **docker**: High-performance container host with GPU passthrough
- **plex**: Media server with GPU for hardware transcoding
- **plex-services**: Supporting services for Plex ecosystem
- **homebridge**: HomeKit bridge server
- **multicast-relay**: Network multicast routing between VLANs
- **nvidia-licensing**: NVIDIA vGPU license server

### [main.tf](main.tf)
- Instantiates the shared `proxmox-vm` module with service VM configurations
- Passes all required variables for VM creation and network setup
- Generates Ansible inventory output for configuration management

### [provider.tf](provider.tf)
Configures the required Terraform providers:
- **Proxmox**: For VM creation and management
- **Unifi**: For dynamic network discovery and VLAN configuration
- **Local**: For SSH key file access and inventory output

### [unifi-networks.tf](unifi-networks.tf)
- Discovers network configurations from Unifi Controller
- Maps VLAN names to actual network settings (VLAN IDs, subnets, DHCP ranges)
- Merges dynamic discovery with static overrides if needed

### [variables.tf](variables.tf)
Defines all input variables for the service VMs configuration including:
- Proxmox connection settings
- VM specifications and network mappings
- Cloud-init configuration
- GPU and IPv6 settings

## Usage

1. Configure variables in `vars.auto.tfvars`
2. Initialize Terraform: `terraform init`
3. Plan deployment: `terraform plan`
4. Apply configuration: `terraform apply`
5. Use generated Ansible inventory for VM configuration

## Network Integration

This configuration integrates with Unifi Controller to automatically discover:
- VLAN IDs and network ranges
- DHCP settings and DNS configuration
- IPv6 configuration where available

VMs are automatically assigned to appropriate VLANs based on their service requirements.
