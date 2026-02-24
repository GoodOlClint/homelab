#!/usr/bin/env bash
# One-time: Organize flat Infisical secrets into per-VM folders
# This copies secrets from / into scoped folders for per-VM agent access.
# Secrets at / are preserved for deploy-time backward compatibility.
#
# Usage: make infisical-organize

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
BOOTSTRAP_FILE="ansible/group_vars/bootstrap.sops.yml"
INFISICAL_ENV="prod"

if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: .venv not found. Run: make bootstrap-local"
    exit 1
fi

if ! command -v infisical &> /dev/null; then
    echo "ERROR: infisical CLI not found."
    exit 1
fi

# Read project ID from bootstrap config
PROJECT_ID=$("$VENV_PYTHON" -c "
import yaml
data = yaml.safe_load(open('$BOOTSTRAP_FILE'))
pid = data.get('bootstrap_config', {}).get('infisical_project_id', 'REPLACE_ME')
print('' if pid == 'REPLACE_ME' else pid)
")

if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: infisical_project_id not set in $BOOTSTRAP_FILE"
    exit 1
fi

# Common CLI flags
CLI_FLAGS="--env $INFISICAL_ENV --projectId $PROJECT_ID"

# Helper: create a folder if it doesn't exist
create_folder() {
    local folder_name="$1"
    local parent_path="${2:-/}"

    if infisical secrets folders create --name "$folder_name" --path "$parent_path" \
        $CLI_FLAGS > /dev/null 2>&1; then
        echo "  Created folder: ${parent_path%/}/$folder_name"
    else
        # Folder likely already exists — not an error
        true
    fi
}

# Helper: copy a secret from / to a folder path
# Tries the exact name first, then lowercase variant (auto-generated secrets
# from infisical_write_secret.yml are stored lowercase at /).
# Always writes to the destination folder with the requested (uppercase) name
# so Go templates can reference a consistent name.
copy_secret() {
    local secret_name="$1"
    local dest_path="$2"
    local lower_name
    lower_name=$(echo "$secret_name" | tr '[:upper:]' '[:lower:]')

    # Try exact name first, then lowercase variant
    local value=""
    local found_name=""
    value=$(infisical secrets get "$secret_name" --env "$INFISICAL_ENV" --path "/" \
        --projectId "$PROJECT_ID" --plain 2>/dev/null) || true

    if [ -n "$value" ]; then
        found_name="$secret_name"
    elif [ "$lower_name" != "$secret_name" ]; then
        value=$(infisical secrets get "$lower_name" --env "$INFISICAL_ENV" --path "/" \
            --projectId "$PROJECT_ID" --plain 2>/dev/null) || true
        if [ -n "$value" ]; then
            found_name="$lower_name"
        fi
    fi

    if [ -z "$value" ]; then
        echo "  SKIP: $secret_name (not found at /)"
        return
    fi

    # Set in destination folder with the uppercase name (for Go template consistency)
    if infisical secrets set "${secret_name}=${value}" --env "$INFISICAL_ENV" \
        --path "$dest_path" --projectId "$PROJECT_ID" > /dev/null 2>&1; then
        if [ "$found_name" != "$secret_name" ]; then
            echo "  OK:   $secret_name → $dest_path (found as $found_name at /)"
        else
            echo "  OK:   $secret_name → $dest_path"
        fi
    else
        echo "  FAIL: $secret_name → $dest_path (set command failed)"
    fi
}

echo "Organizing Infisical secrets into folders (project: $PROJECT_ID)..."
echo "Secrets at / are preserved for deploy-time backward compatibility."
echo ""

# Step 1: Create all folders first
echo "Creating folders..."
create_folder "shared"
create_folder "monitoring"
create_folder "plex"
create_folder "plex-services"
create_folder "infrastructure"
create_folder "docker"
echo ""

# /shared/ — cross-VM secrets (all agents read)
echo "=== /shared/ ==="
copy_secret "PBS_BACKUP_TOKEN" "/shared"
copy_secret "PBS_FINGERPRINT" "/shared"

# /monitoring/ — openobserve VM
echo ""
echo "=== /monitoring/ ==="
copy_secret "GRAFANA_ADMIN_PASSWORD" "/monitoring"
copy_secret "PROXMOX_TOKEN_VALUE" "/monitoring"
copy_secret "UNIFI_MONITORING_PASSWORD" "/monitoring"
copy_secret "PBS_API_TOKEN" "/monitoring"
copy_secret "PBS_MONITORING_TOKEN" "/monitoring"
copy_secret "OPENOBSERVE_ROOT_USER_PASS" "/monitoring"
copy_secret "SYNOLOGY_ADMIN_PASSWORD" "/monitoring"

# /plex/ — plex VM
echo ""
echo "=== /plex/ ==="
copy_secret "PLEX_TOKEN" "/plex"
copy_secret "PLEX_CERT_PFX_PASSWORD" "/plex"
copy_secret "PLEX_SMB_PASS" "/plex"
copy_secret "CLOUDFLARE_DNS_API_TOKEN" "/plex"

# /plex-services/ — plex-services VM
echo ""
echo "=== /plex-services/ ==="
copy_secret "POSTGRES_PASSWORD" "/plex-services"
copy_secret "CLOUDFLARED_TUNNEL_TOKEN" "/plex-services"
copy_secret "VALHEIM_SERVER_PASSWORD" "/plex-services"

# /infrastructure/ — dns, proxmox-backup, unifi VMs
echo ""
echo "=== /infrastructure/ ==="
copy_secret "BIND_TSIG_KEY_SECRET" "/infrastructure"
copy_secret "PBS_ADMIN_PASSWORD" "/infrastructure"
copy_secret "PBS_BACKUP_USER_PASSWORD" "/infrastructure"
copy_secret "UNIFI_ADMIN_PASSWORD" "/infrastructure"

# /docker/ — docker VM
echo ""
echo "=== /docker/ ==="
copy_secret "CLOUDFLARED_TUNNEL_TOKEN" "/docker"

echo ""
echo "Done! Secrets organized into folders."
echo "Root (/) secrets preserved for deploy-time infisical_login.yml."
echo ""
echo "VPS secrets intentionally left at / only (no agent — WireGuard circular dependency)."
echo ""
echo "Secrets marked SKIP need to be added to Infisical manually, then re-run this script."
