# Terraform Infrastructure for Homelab

This directory contains Terraform configuration files for provisioning and managing infrastructure resources in a Proxmox Virtual Environment (PVE) homelab setup.

## File Overview

### [cloud-init.tf](infrastructure/cloud-init.tf)
Defines a `proxmox_virtual_environment_file` resource to generate a default cloud-init configuration. This configures timezone, users, SSH keys, and installs the QEMU guest agent for VMs.

### [main.tf](infrastructure/main.tf)
- Loads the local SSH public key for use in cloud-init.
- Downloads the Ubuntu cloud image to be used as the base image for VMs.

### [multicast-relay.tf](infrastructure/multicast-relay.tf)
- Provisions a VM named `multicast-relay` with multiple network interfaces.
- Configures cloud-init metadata for the VM.
- Copies and executes a bootstrap script to install and configure the multicast relay service inside the VM.
- Outputs the VM's IPv4 address.

### [pci.tf](infrastructure/pci.tf)
Defines PCI hardware mappings, specifically for an Nvidia GPU, to enable passthrough or mediated device assignment to VMs.

### [provider.tf](infrastructure/provider.tf)
- Configures the required Terraform providers.
- Sets up the Proxmox provider with credentials and connection details.

### [variables.tf](infrastructure/variables.tf)
Declares all input variables used throughout the configuration, including Proxmox connection details, VM settings, and network definitions.

---

## Variable Files

- **vars.auto.tfvars**: Contains sensitive and environment-specific variable values (e.g., credentials, VM names, network configs).

---

## Scripts

- **scripts/installMulticast-Relay.sh**: Bash script used to install and configure the multicast relay service on the provisioned VM.

---

## Usage

1. Copy or create the necessary `.tfvars` files with your environment's values.
2. Run `terraform init` to initialize the working directory.
3. Run `terraform apply` to provision the infrastructure.

> **Note:** Sensitive files like `.tfvars` are excluded from version control via [.gitignore](.gitignore).

---

## Provider Lock File

- **.terraform.lock.hcl**: Automatically maintained by Terraform to ensure provider version consistency.
