#!/usr/bin/env bash
# HISTORICAL: Migration complete 2026-02-18. Kept for reference.
# migrate-terraform-state.sh
#
# Migrates Terraform state from the old split projects (infrastructure/ and services/)
# into the consolidated terraform/ project.
#
# Safety:
#   - Works on COPIES of state files — originals are never modified
#   - Creates timestamped backups before any changes
#   - Dry-run mode available via --dry-run flag
#
# Usage:
#   cd /path/to/homelab
#   bash scripts/migrate-terraform-state.sh [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_STATE="$REPO_ROOT/terraform/infrastructure/terraform.tfstate"
SERVICES_STATE="$REPO_ROOT/terraform/services/terraform.tfstate"
NEW_STATE="$REPO_ROOT/terraform/terraform.tfstate"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$REPO_ROOT/terraform/.state-backups-$TIMESTAMP"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE — no state changes will be made ==="
    echo ""
fi

# --- Preflight checks ---

echo "=== Terraform State Migration ==="
echo "Repo root: $REPO_ROOT"
echo ""

if [[ ! -f "$INFRA_STATE" ]]; then
    echo "ERROR: Infrastructure state not found: $INFRA_STATE"
    exit 1
fi

if [[ ! -f "$SERVICES_STATE" ]]; then
    echo "ERROR: Services state not found: $SERVICES_STATE"
    exit 1
fi

if [[ -f "$NEW_STATE" ]]; then
    echo "WARNING: Consolidated state already exists at $NEW_STATE"
    echo "Remove it first if you want a fresh migration."
    exit 1
fi

# --- Create backups ---

echo "Creating backups in $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"
cp "$INFRA_STATE" "$BACKUP_DIR/infrastructure.tfstate"
cp "$SERVICES_STATE" "$BACKUP_DIR/services.tfstate"
echo "  Backed up infrastructure state"
echo "  Backed up services state"
echo ""

# --- Work on copies ---
# terraform state mv modifies the source state, so we work on copies

INFRA_COPY="$BACKUP_DIR/infra-work.tfstate"
SERVICES_COPY="$BACKUP_DIR/services-work.tfstate"

cp "$INFRA_STATE" "$INFRA_COPY"
cp "$SERVICES_STATE" "$SERVICES_COPY"

# --- Ensure terraform is initialized in new location ---

echo "Initializing Terraform in consolidated project..."
if [[ "$DRY_RUN" == false ]]; then
    (cd "$REPO_ROOT/terraform" && terraform init -input=false > /dev/null 2>&1) || {
        echo "WARNING: terraform init had issues (may need tfvars). Continuing with state migration..."
    }
fi
echo ""

# --- Helper function ---

move_resource() {
    local src_state="$1"
    local old_addr="$2"
    local new_addr="$3"

    if [[ "$DRY_RUN" == true ]]; then
        echo "  [DRY RUN] $old_addr -> $new_addr"
    else
        echo "  Moving: $old_addr -> $new_addr"
        terraform -chdir="$REPO_ROOT/terraform" state mv \
            -state="$src_state" \
            -state-out="$NEW_STATE" \
            "$old_addr" "$new_addr" 2>&1 | sed 's/^/    /'
    fi
}

# --- Migrate infrastructure resources ---

echo "=== Migrating infrastructure resources ==="

# Top-level PCI mapping (no rename needed)
move_resource "$INFRA_COPY" \
    "proxmox_virtual_environment_hardware_mapping_pci.nvidia_gpu" \
    "proxmox_virtual_environment_hardware_mapping_pci.nvidia_gpu"

# Cloud image
move_resource "$INFRA_COPY" \
    "module.infrastructure_vms.proxmox_virtual_environment_download_file.ubuntu_cloud_image[0]" \
    "module.vms.proxmox_virtual_environment_download_file.ubuntu_cloud_image[0]"

# Infrastructure VMs (5 VMs: dns, adguard, openobserve, proxmox-backup, unifi)
for VM in dns adguard openobserve proxmox-backup unifi; do
    move_resource "$INFRA_COPY" \
        "module.infrastructure_vms.proxmox_virtual_environment_vm.vms[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_vm.vms[\"$VM\"]"

    move_resource "$INFRA_COPY" \
        "module.infrastructure_vms.proxmox_virtual_environment_file.user_data[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_file.user_data[\"$VM\"]"

    move_resource "$INFRA_COPY" \
        "module.infrastructure_vms.proxmox_virtual_environment_file.network_data[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_file.network_data[\"$VM\"]"
done

echo ""

# --- Migrate services resources ---

echo "=== Migrating services resources ==="

# Services VMs (5 VMs: docker, plex, plex-services, homebridge, nvidia-licensing)
# Note: multicast-relay is being retired — skip it
for VM in docker plex plex-services homebridge nvidia-licensing; do
    move_resource "$SERVICES_COPY" \
        "module.services_vms.proxmox_virtual_environment_vm.vms[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_vm.vms[\"$VM\"]"

    move_resource "$SERVICES_COPY" \
        "module.services_vms.proxmox_virtual_environment_file.user_data[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_file.user_data[\"$VM\"]"

    move_resource "$SERVICES_COPY" \
        "module.services_vms.proxmox_virtual_environment_file.network_data[\"$VM\"]" \
        "module.vms.proxmox_virtual_environment_file.network_data[\"$VM\"]"
done

echo ""

# --- Summary ---

echo "=== Migration Summary ==="
if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN complete. No changes were made."
    echo ""
    echo "Resources that would be migrated:"
    echo "  Infrastructure: 1 PCI + 1 cloud image + 5 VMs × 3 resources = 17 resources"
    echo "  Services: 5 VMs × 3 resources = 15 resources"
    echo "  Total: 32 resources"
    echo ""
    echo "Skipped:"
    echo "  - multicast-relay VM and cloud-init files (being retired)"
    echo "  - data.local_file.ssh_public_key (data sources re-read automatically)"
    echo "  - module.network.* (SDN resources not yet in state — will be imported via import blocks)"
else
    echo "Backups stored in: $BACKUP_DIR"
    echo ""
    echo "New consolidated state: $NEW_STATE"
    RESOURCE_COUNT=$(terraform -chdir="$REPO_ROOT/terraform" state list 2>/dev/null | wc -l | tr -d ' ')
    echo "Resources in consolidated state: $RESOURCE_COUNT"
    echo ""
    echo "Next steps:"
    echo "  1. cd terraform && terraform plan"
    echo "     — Review the plan. Expect zero changes for existing VMs."
    echo "     — SDN resources will show as 'to be imported' (from import blocks)."
    echo "     — multicast-relay resources may show as 'to be destroyed' in the old state."
    echo "  2. If satisfied, destroy multicast-relay from the old services state:"
    echo "     cd terraform/services && terraform apply (to clean up multicast-relay)"
    echo "  3. Archive old directories"
fi
echo ""
echo "Done."
