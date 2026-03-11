#!/usr/bin/env bash
# Phase 15: Purge root / and remove orphan copies from Infisical
# Run AFTER all other phases are deployed via `make apply`.
#
# Prerequisites: infisical CLI logged in with project access
# Usage: bash scripts/infisical_cleanup_root.sh

set -euo pipefail

echo "=== Phase 15: Infisical Cleanup ==="
echo ""

# Step 1: Delete all keys from root /
echo "--- Step 1: Purging root / ---"
root_keys=$(infisical secrets list --env prod --path / --format json | \
  python3 -c "import json,sys; [print(s['secretKey']) for s in json.load(sys.stdin)]" 2>/dev/null || true)

if [ -n "$root_keys" ]; then
  while IFS= read -r key; do
    echo "Deleting root key: $key"
    infisical secrets delete "$key" --env prod --path /
  done <<< "$root_keys"
else
  echo "Root is already empty."
fi

echo ""

# Step 2: Remove orphan copies from wrong folders
echo "--- Step 2: Removing orphan copies ---"

delete_if_exists() {
  local key=$1
  local path=$2
  if infisical secrets get "$key" --env prod --path "$path" &>/dev/null; then
    echo "Deleting $path/$key (orphan)"
    infisical secrets delete "$key" --env prod --path "$path"
  fi
}

delete_if_exists "VALHEIM_SERVER_PASSWORD" "/plex-services"
delete_if_exists "PBS_ADMIN_PASSWORD" "/infrastructure"
delete_if_exists "PBS_BACKUP_USER_PASSWORD" "/infrastructure"
delete_if_exists "wg_public_key" "/pfsense"

echo ""

# Step 3: Remove cross-reference copies from /homepage
echo "--- Step 3: Removing /homepage orphan copies ---"
for key in SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY PROWLARR_API_KEY \
           BAZARR_API_KEY TAUTULLI_API_KEY SABNZBD_API_KEY SEERR_API_KEY \
           PLEX_TOKEN GRAFANA_USERNAME GRAFANA_PASSWORD \
           PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET \
           PROXMOX_BACKUP_USERNAME PROXMOX_BACKUP_PASSWORD; do
  delete_if_exists "$key" "/homepage"
done

echo ""

# Step 4: Verify final state
echo "--- Step 4: Verification ---"
python3 -c "
import json, subprocess, sys

folders = ['shared', 'monitoring', 'plex', 'plex-services', 'docker', 'vps', 'pfsense', 'pbs', 'infrastructure', 'homepage']

# Check root
result = subprocess.run(['infisical', 'secrets', 'list', '--env', 'prod', '--path', '/', '--format', 'json'],
                       capture_output=True, text=True)
root_keys = json.loads(result.stdout) if result.returncode == 0 else []
if root_keys:
    print(f'WARNING: {len(root_keys)} keys still in root:')
    for k in root_keys:
        print(f'  {k[\"secretKey\"]}')
else:
    print('OK: root is empty')

# Check each folder
print()
for folder in folders:
    result = subprocess.run(['infisical', 'secrets', 'list', '--env', 'prod', '--path', f'/{folder}', '--format', 'json'],
                           capture_output=True, text=True)
    keys = json.loads(result.stdout) if result.returncode == 0 else []
    print(f'{folder}: {len(keys)} keys')
"

echo ""
echo "Phase 15 cleanup complete."
