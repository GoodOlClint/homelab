#!/usr/bin/env bash
# Export Infisical secrets back to YAML (backup/disaster recovery)
#
# Authenticates via Machine Identity (Universal Auth) using SOPS bootstrap
# credentials, exports secrets from each folder as JSON, then converts to
# a nested YAML structure via infisical_to_sops.py.
#
# Usage: make infisical-backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
BOOTSTRAP_FILE="$REPO_ROOT/ansible/group_vars/bootstrap.sops.yml"
INFISICAL_ENV="prod"
OUTPUT_FILE="$REPO_ROOT/infisical-backup.yml"

# Folders that match infisical_login.yml nested paths
FOLDERS=(monitoring plex plex-services homepage docker vps pfsense shared infrastructure)

if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: .venv not found. Run: make bootstrap-local"
    exit 1
fi

if ! command -v infisical &> /dev/null; then
    echo "ERROR: infisical CLI not found."
    exit 1
fi

# Read config from SOPS
PROJECT_ID=$(sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$BOOTSTRAP_FILE" 2>/dev/null)
INFISICAL_URL=$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$BOOTSTRAP_FILE" 2>/dev/null)
CLIENT_ID=$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$BOOTSTRAP_FILE" 2>/dev/null)
CLIENT_SECRET=$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$BOOTSTRAP_FILE" 2>/dev/null)

for var in PROJECT_ID INFISICAL_URL CLIENT_ID CLIENT_SECRET; do
    val="${!var}"
    if [ -z "$val" ] || [ "$val" = "REPLACE_ME" ]; then
        echo "ERROR: $var not set in $BOOTSTRAP_FILE"
        exit 1
    fi
done

DOMAIN="${INFISICAL_URL}/api"
CLI_FLAGS="--env $INFISICAL_ENV --projectId $PROJECT_ID --domain $DOMAIN"

echo "Backing up Infisical secrets..."

# Authenticate with universal auth
TOKEN=$(infisical login \
    --method=universal-auth \
    --client-id="$CLIENT_ID" \
    --client-secret="$CLIENT_SECRET" \
    --domain="$DOMAIN" \
    --silent --plain 2>/dev/null | tail -1)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to authenticate to Infisical"
    exit 1
fi

CLI_FLAGS="$CLI_FLAGS --token $TOKEN"

# Build a combined JSON object: {"/" : [...], "/folder": [...], ...}
# The Python script reads this to produce nested YAML.
{
    echo "{"

    # Root path
    echo "\"/$( echo '": ' )"
    infisical secrets --path / $CLI_FLAGS -o json 2>/dev/null
    echo ","

    # Each subfolder
    first=true
    for folder in "${FOLDERS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo "\"/$folder\": "
        # Folder may not exist — output empty array on failure
        infisical secrets --path "/$folder" $CLI_FLAGS -o json 2>/dev/null || echo "[]"
    done

    echo "}"
} | "$VENV_PYTHON" "$SCRIPT_DIR/infisical_to_sops.py" > "$OUTPUT_FILE"

count=$(grep -c ':' "$OUTPUT_FILE" 2>/dev/null || echo '?')
echo "Backup saved to $OUTPUT_FILE ($count entries)"
