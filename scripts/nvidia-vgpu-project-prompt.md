# NVIDIA vGPU Driver Update Tool — Project Bootstrap Prompt

Use this prompt with Claude Code to bootstrap a standalone project that automates NVIDIA vGPU driver patching and deployment for a Proxmox homelab.

---

## Prompt

Create a CLI tool called `vgpu-update` that automates NVIDIA vGPU driver patching and deployment for a Proxmox homelab. The tool runs on macOS and uses Docker for Linux-native operations (patching/extracting `.run` files). It deploys to a Proxmox host and guest VMs via SSH.

### Background

I have a Proxmox hypervisor with an NVIDIA Quadro RTX 5000 GPU. The RTX 5000 doesn't natively support NVIDIA vGPU, so I use the community vGPU-Unlock-Patcher to clone vGPU profiles from the Quadro RTX 6000 (which shares the Turing architecture). The patched driver presents the GPU as a GRID RTX6000-1Q to VMs via mediated devices (mdev).

The current manual process is:
1. Download the NVIDIA vGPU KVM `.run` driver from a file server (nc.sloth.zip)
2. Clone vGPU-Unlock-Patcher and patch `patch.sh` to add RTX 5000 support
3. Run the patcher on a Linux machine to produce patched host and guest drivers
4. Uninstall the old host driver on Proxmox, reboot, install the new one, reboot again
5. Upload the patched guest `.deb` to a Synology NAS web server
6. Run Ansible to update guest drivers on VMs that use the GPU

This tool automates all of that.

### Commands

The tool should have three commands: `build`, `deploy`, and `update` (which chains the first two).

#### `build` — Patch drivers in Docker

**Input:** `--source-file <PATH>` (required) — path to a pre-downloaded NVIDIA vGPU KVM `.run` file.

**Steps:**
1. Validate the source file exists
2. Extract the driver version from the filename (pattern: `NVIDIA-Linux-x86_64-<VERSION>-vgpu-kvm.run` or similar — be flexible with the regex)
3. Clone or update `vGPU-Unlock-Patcher` from `https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher.git` into `${CACHE_DIR}/patcher/`
4. Patch `patch.sh` to add the RTX 5000 vcfgclone entry if not already present (see GPU Cloning Config below)
5. Build a Docker image from the Dockerfile (see Docker Build Environment below)
6. Run the patcher inside the Docker container:
   - Mount the `.run` file and patcher directory into the container
   - Execute the patcher to produce `vgpu-kvm` (host driver) and `grid` (guest driver) variants
   - Extract the guest `.deb` package from the patched GRID `.run` file using `--extract-only`
   - Copy artifacts out to a mounted output volume
7. Stage artifacts to `${CACHE_DIR}/<VERSION>/`:
   - `host-driver.run` — patched host driver
   - `nvidia-linux-grid-<BRANCH>_<VERSION>_amd64.deb` — patched guest driver .deb
8. Print a summary of what was built and where artifacts are staged

#### `deploy` — Deploy to Proxmox + Synology + VMs

**Input:** `--version <VER>` (required) — must match a previously built version in `${CACHE_DIR}/<VERSION>/`

**Phase A — Deploy guest driver to Synology:**
1. SCP the guest `.deb` to the Synology Web Station document root
2. Verify the file is accessible: `curl --insecure --head https://${SYNOLOGY_HOST}/<filename>.deb`
3. Update the homelab repo's `ansible/group_vars/all.yml`: replace the `nvidia_grid_driver_url` value with the new URL (use `sed` — the line format is `nvidia_grid_driver_url: "https://..."`)
4. Print the updated URL

**Phase B — Install host driver on Proxmox (interactive confirmation required):**
1. SSH to Proxmox and run pre-flight checks:
   - Current driver version: `cat /proc/driver/nvidia/version` or `nvidia-smi --version`
   - Kernel headers: `dpkg -l | grep pve-headers-$(uname -r)`
   - DKMS installed: `dpkg -l | grep dkms`
   - Disk space: `df -h /tmp`
2. Print pre-flight results and prompt: `"Ready to install host driver. This will shut down GPU VMs and reboot Proxmox twice. Continue? [y/N]"`
3. Gracefully shut down GPU VMs:
   - `qm shutdown <VMID> --timeout 120` for each GPU VM
   - Wait until `qm status <VMID>` shows "stopped" for all
4. Uninstall the current NVIDIA driver:
   - `nvidia-uninstall --silent` (or `/usr/bin/nvidia-uninstall --silent`)
   - If the uninstaller doesn't exist, try: `apt remove --purge -y 'nvidia-*'` as fallback
5. Reboot Proxmox (`reboot`), poll SSH every 15 seconds until it returns (timeout: 5 minutes)
6. SCP `host-driver.run` to Proxmox `/tmp/`
7. Install: `chmod +x /tmp/host-driver.run && /tmp/host-driver.run --dkms --no-questions`
8. Check for DKMS success: `dkms status | grep nvidia` — if no entry or status is "broken", print error and abort (do NOT reboot)
9. Reboot Proxmox again, poll SSH until it returns
10. Verify: `nvidia-smi` succeeds on host
11. Check mdev types: `mdevctl types | grep nvidia-256` — if missing, print warning about Terraform/pci.tf update needed
12. Start GPU VMs: `qm start <VMID>` for each, wait for SSH to become available (poll port 22, timeout 2 minutes per VM)

**Phase C — Update guest drivers on VMs:**
1. Run `make -C ${HOMELAB_REPO} ansible docker TAGS=nvidia` (the existing Ansible `nvidia` role handles version comparison, download from Synology, install, and VM reboot)
2. Run `make -C ${HOMELAB_REPO} ansible plex TAGS=nvidia`

**Phase D — Verify:**
1. SSH to each GPU VM and run:
   - `nvidia-smi` — confirm new driver version in output
   - `nvidia-smi -q | grep "License Status"` — confirm "Licensed" with valid "Expiry:"
2. Print final summary: host version, guest versions, license status

#### `update` — Full pipeline orchestrator

**Input:** `--source-file <PATH>` (required)

1. Run `build --source-file <PATH>`
2. Print build summary
3. Prompt: `"Build complete. Proceed to deployment? [y/N]"`
4. Extract version from the build output
5. Run `deploy --version <VER>`

### GPU Cloning Config

The Quadro RTX 5000 is not in vGPU-Unlock-Patcher's default supported list. The tool must patch `patch.sh` to add a vcfgclone entry that clones the Quadro RTX 6000's vGPU profiles to the RTX 5000.

```
Source (RTX 6000, TU102GL):  device 0x1E30, subsystem 0x12BA
Target (RTX 5000, TU104GL):  device 0x1EB0, subsystem 0x129F
```

The vcfgclone line to inject into `patch.sh`:
```bash
vcfgclone ${TARGET}/vgpuConfig.xml 0x1E30 0x12BA 0x1EB0 0x129F
```

This should be inserted into the existing vcfgclone block in `patch.sh` (near other Turing GPU entries like RTX 2080 Ti, RTX 2070 Super). Use `sed` or `grep` to check if the line already exists before inserting.

If the subsystem `0x129F` doesn't produce valid vGPU profiles, the user may need to try `0x0000` instead. Make this configurable.

### Docker Build Environment

The local workstation is macOS, but `.run` files are Linux ELF executables. All patching and extraction must happen inside a Docker container.

**Dockerfile** (create as `Dockerfile` in the project root):
```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
    git build-essential python3 cpio rpm2cpio \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
```

The build command should:
1. Build the image (or reuse cached): `docker build -t vgpu-patcher .`
2. Run with volume mounts:
   - Source `.run` file mounted read-only
   - Patcher repo mounted
   - Output directory mounted for artifacts
3. Inside the container, execute the patcher and extract the guest `.deb`

### Configuration

All deployment-specific values must be in a config file (not hardcoded). Use a YAML config file (`config.yaml`) with defaults that can be overridden:

```yaml
# Proxmox host
proxmox_host: "172.16.100.145"
proxmox_user: "root"

# Synology NAS (Web Station serves .deb files over HTTPS)
synology_host: "172.16.100.152"
synology_user: "admin"
synology_web_root: "/volume1/web"

# GPU VMs (Proxmox VMIDs)
gpu_vms:
  - name: "docker"
    vmid: 104
  - name: "plex"
    vmid: 108

# Homelab repo path (for updating group_vars and running make)
homelab_repo: "../homelab"

# vGPU-Unlock-Patcher
patcher_repo: "https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher.git"

# GPU cloning: source (RTX 6000) → target (RTX 5000)
vcfg_clone:
  src_devid: "0x1E30"
  src_subsys: "0x12BA"
  tgt_devid: "0x1EB0"
  tgt_subsys: "0x129F"

# mdev type to verify after host driver install
expected_mdev_type: "nvidia-256"

# Cache directory for build artifacts
cache_dir: "~/.cache/nvidia-vgpu"
```

Accept `--config <PATH>` flag to override the default config file location.

### Guest .deb Naming Convention

The homelab's existing Ansible `nvidia` role parses the driver URL with this regex to extract the version:
```
nvidia-linux-grid-[0-9]+_([0-9]+\.[0-9]+\.[0-9]+)_amd64\.deb
```

The `.deb` file uploaded to Synology MUST match this pattern. Example: `nvidia-linux-grid-580_580.65.05_amd64.deb`

The branch number is the major version (e.g., `580` from `580.65.05`, `550` from `550.144.03`).

### Current State (for reference)

- Current installed driver: 550.144.03
- Target driver: 580.65.05
- Current driver URL: `https://172.16.100.152/nvidia-linux-grid-550_550.144.03_amd64.deb`
- PCI device in Proxmox: `10de:1eb0`, subsystem `10de:129f`, IOMMU group 20
- mdev type: `nvidia-256`
- Patcher repo: `https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher.git`

### Implementation Notes

- Use Python 3 (with Click or argparse for CLI). Bash scripts are acceptable but Python is preferred for maintainability.
- Include a `README.md` with usage examples for all three commands.
- Include a `CLAUDE.md` with project conventions for future Claude Code sessions.
- Error messages should be actionable — tell the user what failed AND what to do about it.
- SSH operations should use the user's existing SSH keys/config (no password handling).
- All destructive operations (host driver uninstall, reboot, VM shutdown) require explicit confirmation.
- The tool should be idempotent where possible — re-running `build` with the same source file should skip if artifacts already exist (unless `--force` is passed). Re-running `deploy` should detect if the host is already at the target version and skip Phase B.
- Include `--dry-run` flag for `deploy` that shows what would happen without executing.
- Git-ignore the cache directory and any local config overrides.
- **Git discipline:** Run `git init` at the very start of the project. Make logical, incremental commits as you complete each piece of work (e.g., "Add Dockerfile and build environment", "Implement build command", "Implement deploy command", "Add config file support", "Add README and CLAUDE.md"). Do NOT save everything for one big commit at the end. When the project is complete, push to a new **private** GitHub repo (use `gh repo create <name> --private --source . --push`).
