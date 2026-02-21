# Ubuntu 24.04 Packer Template

This directory contains Packer configuration for building Ubuntu 24.04 LTS base templates for Proxmox VE.

## Overview

The template creates a minimal Ubuntu 24.04 VM with:
- qemu-guest-agent pre-installed and enabled
- Common system packages (python3, curl, wget, vim, git, etc.)
- Basic security hardening
- **No cloud-init** (removed completely)
- Bootstrap ansible user with temporary SSH key for provisioning

## Bootstrap SSH Key

The `bootstrap_ssh_key` and `bootstrap_ssh_key.pub` files are **intentionally tracked in git**. These are NOT secrets:

- Used ONLY for Ansible's first connection after VM creation
- Removed automatically by the `vm_bootstrap` Ansible role
- Real SSH keys are injected by Ansible during bootstrap
- Temporary/bootstrap use only

**Do not use these keys for production or long-term access.**

## Quick Start

1. Copy example variables file:
   ```bash
   cp variables.auto.pkrvars.hcl.example variables.auto.pkrvars.hcl
   ```

2. Edit `variables.auto.pkrvars.hcl` with your Proxmox details:
   ```hcl
   proxmox_url      = "https://your-proxmox:8006/api2/json"
   proxmox_username = "root@pam!packer"
   proxmox_token    = "your-token-here"
   proxmox_node     = "pve"
   storage_pool     = "local-lvm"
   ```

3. Initialize Packer:
   ```bash
   packer init .
   ```

4. Validate configuration:
   ```bash
   packer validate -var-file=variables.auto.pkrvars.hcl .
   ```

5. Build template:
   ```bash
   packer build -var-file=variables.auto.pkrvars.hcl .
   ```

Or use the Makefile from the repository root:
```bash
make packer-validate
make packer-build
```

## Template Naming

Templates are automatically named with timestamps:
- Format: `ubuntu-24.04-base-YYYYMMDD-HHMM`
- Example: `ubuntu-24.04-base-20260215-1430`

This allows multiple versions to coexist in Proxmox.

## Build Process

1. **Download Ubuntu 24.04 ISO** from releases.ubuntu.com
2. **Create VM** in Proxmox with autoinstall
3. **Provision scripts**:
   - `01-setup.sh` - Install base packages, create ansible user
   - `02-qemu-guest-agent.sh` - Configure QEMU guest agent
   - `03-hardening.sh` - Basic security hardening
   - `04-remove-cloud-init.sh` - Remove cloud-init completely
   - `05-cleanup.sh` - Clean up and prepare template
4. **Inject bootstrap SSH key** for Ansible connectivity
5. **Convert to template** in Proxmox

Build time: Approximately 15-20 minutes

## Using the Template

### With Terraform

Set `use_packer_template = true` in your Terraform configuration:

```hcl
module "infrastructure_vms" {
  source = "../modules/proxmox-vm"

  use_packer_template = true
  # Will auto-detect latest template

  # ... other variables ...
}
```

### With Ansible

The template includes an `ansible` user with the bootstrap SSH key. Your Ansible configuration should:
1. Connect as `ansible` user initially (using `bootstrap_ssh_key`)
2. Run the `vm_bootstrap` role first
3. Bootstrap role creates real user and injects real SSH keys
4. Bootstrap role removes the temporary SSH key

See `ansible/roles/vm_bootstrap/` for the bootstrap role.

## Customization

### Adding Packages

Edit `scripts/01-setup.sh` and add packages to the `apt-get install` command.

### Changing Hardening

Edit `scripts/03-hardening.sh` to modify security settings.

### Storage Configuration

Modify the `storage.layout` in `http/user-data` for custom partitioning.

## Troubleshooting

### Build hangs at "Waiting for SSH"
- Check Proxmox firewall rules allow SSH from Packer host
- Verify network bridge configuration
- Check VM console in Proxmox GUI for errors

### Template not appearing
- Check Packer output for errors
- Verify storage pool has enough space
- Check Proxmox logs: `/var/log/pve/tasks/`

### SSH connection fails after template creation
- Ensure bootstrap SSH key was injected (check build output)
- Verify ansible user exists: check in Proxmox console
- Check SSH service is running in template

## Maintenance

### Rebuilding Templates

Templates should be rebuilt monthly to include latest security patches:
```bash
make packer-build
```

Old templates can be manually deleted from Proxmox GUI or via CLI.

### Updating Ubuntu Version

To update to a newer Ubuntu release:
1. Update `iso_url` in `variables.pkr.hcl`
2. Update `iso_checksum` (get from Ubuntu releases page)
3. Test build before production use

## Files

- `ubuntu-24.04.pkr.hcl` - Main Packer configuration
- `variables.pkr.hcl` - Variable definitions
- `variables.auto.pkrvars.hcl` - Local values (gitignored)
- `variables.auto.pkrvars.hcl.example` - Example values
- `bootstrap_ssh_key*` - Temporary SSH key for Ansible (tracked in git)
- `scripts/` - Provisioning scripts
- `http/` - Autoinstall configuration files

## Security Notes

- The packer build user is removed during cleanup
- Root SSH login is disabled
- SSH host keys are regenerated on first boot
- Machine-ID is cleared (regenerated on first boot)
- Bootstrap SSH key is temporary and removed by Ansible
- Template includes basic hardening (can be enhanced per-VM)

## License

Same as parent repository.
