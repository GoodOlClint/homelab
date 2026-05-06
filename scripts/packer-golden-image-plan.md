# Plan: Add Packer Golden Image Builds

## Context

Fresh VM deployments are fragile and slow because cloud-init runs `package_update: true` + `package_upgrade: true` on first boot, holding the dpkg lock for 10-15+ minutes. Ansible races against this and unattended-upgrades, causing hangs (especially apt repo additions that prompt for interactive input on kernel/grub config). Packer pre-bakes a golden image with common packages/repos already installed so cloud-init only handles per-VM config (hostname, network, SSH keys) and Ansible can connect immediately.

The Terraform module already has `use_packer_template` support (clone block, auto-detection in `packer.tf`), but the archived Packer config removed cloud-init entirely — which would break per-VM network/hostname config. This plan keeps cloud-init in the image.

## Approach

### Phase 1: Packer build files

Create `packer/ubuntu-24.04/` (`.gitignore` already has entries for this path).

**`ubuntu-24.04.pkr.hcl`** — Main build, adapted from `archive/packer-20260216/`:
- `proxmox-iso` source with Ubuntu 24.04 Autoinstall
- `cloud_init = true` (NOT false — keeps cloud-init in template)
- Disk type `virtio` (not `scsi`) to match Terraform VM definitions
- Password auth to match Terraform provider (`provider.tf:33`)
- Template naming: `ubuntu-24.04-base-YYYYMMDD-HHMM` (matches `packer.tf` auto-detection)
- No bootstrap SSH key — cloud-init handles user/SSH on clone
- 3 provisioning scripts: `01-packages.sh`, `02-repos.sh`, `03-cleanup.sh`

**`variables.pkr.hcl`** — `proxmox_url`, `proxmox_username`, `proxmox_password` (sensitive), `proxmox_node`, `storage_pool`, `iso_storage_pool`, `iso_url`, `iso_checksum`, `network_bridge`, `ssh_password`

**`variables.auto.pkrvars.hcl.example`** — Example values (tracked)

**`http/user-data`** + **`http/meta-data`** — Ubuntu Autoinstall config

### Phase 2: Provisioning scripts

**`scripts/01-packages.sh`** — Common infra packages:
- `qemu-guest-agent`, `curl`, `wget`, `git`, `net-tools`, `dnsutils`, `iproute2`
- `nfs-common` (5+ roles), `python3`, `python3-pip`, `python3-venv`
- `parted`, `cloud-guest-utils`, `rsyslog`, `ca-certificates`, `gnupg`, `lsb-release`

**`scripts/02-repos.sh`** — APT repos + GPG keys + packages:
- Docker CE → `docker-ce`, `docker-ce-cli`, `containerd.io`, compose plugin
- Infisical CLI → `infisical`
- InfluxData → `telegraf`
- Proxmox Backup Client → `proxmox-backup-client`
- All services disabled by default (Ansible enables per-VM)

**`scripts/03-cleanup.sh`** — Template prep:
- Remove packer temp user, clean apt cache, purge snapd/lxd
- Truncate logs, clear machine-id, remove SSH host keys
- `cloud-init clean --logs --seed` (reset for fresh run on clone)

### Phase 3: Terraform changes

**`terraform/modules/proxmox-vm/virtual_machines.tf`** — 3 targeted edits:
- Line 113: `for_each = { for vm ... }` (remove `use_packer_template ? {} :`)
- Line 134: Same for `network_data`
- Line 226: `for_each = [1]` (remove `use_packer_template ? [] :`)

This means Packer clones ALSO get cloud-init initialization (hostname, network, SSH keys).

**`terraform/modules/proxmox-vm/templates/user-data.yaml.tmpl`**:
- Wrap `package_update`/`package_upgrade`/`packages` in `%{ if !skip_package_ops }`
- Pass `skip_package_ops = var.use_packer_template` from templatefile call

**Variable descriptions**: Update "no cloud-init" → "cloud-init still active for per-VM config"

### Phase 4: Makefile

```makefile
packer:
	cd packer/ubuntu-24.04 && \
		PKR_VAR_proxmox_password='$(call _read_secret,proxmox_password)' \
		packer init . && packer build .

packer-validate:
	cd packer/ubuntu-24.04 && \
		PKR_VAR_proxmox_password='$(call _read_secret,proxmox_password)' \
		packer init . && packer validate .
```

Add `packer init .` to `init` target.

### Phase 5: Documentation

- **CLAUDE.md**: Packer Conventions section
- **README.md**: Add `make packer` to targets, Packer to prerequisites

## Files

| File | Action |
|------|--------|
| `packer/ubuntu-24.04/ubuntu-24.04.pkr.hcl` | Create |
| `packer/ubuntu-24.04/variables.pkr.hcl` | Create |
| `packer/ubuntu-24.04/variables.auto.pkrvars.hcl.example` | Create |
| `packer/ubuntu-24.04/http/user-data` | Create |
| `packer/ubuntu-24.04/http/meta-data` | Create |
| `packer/ubuntu-24.04/scripts/01-packages.sh` | Create |
| `packer/ubuntu-24.04/scripts/02-repos.sh` | Create |
| `packer/ubuntu-24.04/scripts/03-cleanup.sh` | Create |
| `terraform/modules/proxmox-vm/virtual_machines.tf` | Modify (3 lines) |
| `terraform/modules/proxmox-vm/templates/user-data.yaml.tmpl` | Modify |
| `terraform/modules/proxmox-vm/variables.tf` | Modify (description) |
| `terraform/variables.tf` | Modify (description) |
| `Makefile` | Modify |
| `CLAUDE.md` | Modify |
| `README.md` | Modify |

## Key Design Decisions

1. **Keep cloud-init** — Unlike the archived Packer config which removed cloud-init, we keep it so Terraform can still inject per-VM hostname, network (static IPs, MAC-based interface naming, multi-VLAN policy routing), and SSH keys via cloud-init snippets at clone time.

2. **Pre-bake common packages only** — Service-specific packages (plexmediaserver, bind9, nvidia-container-toolkit, etc.) stay in Ansible roles. Only packages used by 3+ roles go in the image.

3. **Disable pre-installed services** — Docker, telegraf, etc. are installed but disabled. Ansible roles enable them per-VM as needed. This means VMs that don't need Docker don't have it running.

4. **MAC collision fix required first** — The `vm_random_ids` hash collision (plex/minio sharing random_id 151) must be fixed before Packer deployment. The vm_id-based formula in main.tf resolves this.

## Verification

1. `make packer-validate` — validates config
2. `make packer` — builds golden image on Proxmox
3. Set `use_packer_template = true` in `vars.auto.tfvars`
4. `make rebuild minio` — test on the broken minio VM
5. Verify: VM boots fast, cloud-init applies hostname/network/SSH, Ansible connects without dpkg lock waits
6. `make plan` — verify no unexpected changes to other VMs
