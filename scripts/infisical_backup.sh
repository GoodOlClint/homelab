#!/usr/bin/env bash
# Export ALL Infisical secrets → SOPS-encrypted DR backup (the ONLY export path).
#
# Authenticates via Machine Identity (Universal Auth) using SOPS bootstrap
# credentials, exports every folder as JSON, converts to the secrets.sops.yml
# structure via infisical_to_sops.py, encrypts with SOPS, and verifies the
# result decrypts. The previous export is kept at secrets.sops.yml.bak so a
# failed run can never destroy the only good backup.
#
# Round-trip contract: the output must restore via scripts/seed_infisical.sh
# (nested dict per folder → seeded to /<folder>, underscores→hyphens).
#
# Usage: make infisical-backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
BOOTSTRAP_FILE="$REPO_ROOT/ansible/group_vars/bootstrap.sops.yml"
INFISICAL_ENV="prod"
OUTPUT_FILE="$REPO_ROOT/ansible/group_vars/secrets.sops.yml"

# All Infisical folders — keep in lockstep with the CLAUDE.md
# "Infisical Folder Ownership" table. Root / is exported too (must be empty;
# any stray keys get captured rather than silently dropped).
FOLDERS=(shared monitoring plex plex-services homepage docker minio vps
         pfsense pbs infrastructure github-runner squid)

if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: .venv not found. Run: make init"
    exit 1
fi

for cmd in infisical sops; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: $cmd CLI not found."
        exit 1
    fi
done

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build {"/": [...], "/folder": [...], ...}. The CLI returns `null` for an
# empty folder and non-zero for a missing one — both become [].
{
    printf '{'
    sep=""
    for folder in "" "${FOLDERS[@]}"; do
        out=$(infisical secrets --path "/$folder" \
            --env "$INFISICAL_ENV" --projectId "$PROJECT_ID" \
            --domain "$DOMAIN" --token "$TOKEN" \
            -o json 2>/dev/null || true)
        [ -z "$out" ] || [ "$out" = "null" ] && out="[]"
        printf '%s"/%s": %s' "$sep" "$folder" "$out"
        sep=","
    done
    printf '}'
} > "$TMP/export.json"

# Convert; exits non-zero on zero total secrets (auth/CLI silently broken).
"$VENV_PYTHON" "$SCRIPT_DIR/infisical_to_sops.py" < "$TMP/export.json" > "$TMP/secrets.yml"

# Keep the previous encrypted export so a bad run can't destroy it.
if [ -f "$OUTPUT_FILE" ]; then
    cp "$OUTPUT_FILE" "$OUTPUT_FILE.bak"
fi

mv "$TMP/secrets.yml" "$OUTPUT_FILE"
sops --encrypt --in-place "$OUTPUT_FILE"

# Verify the artifact actually decrypts before calling it a backup.
if ! sops -d "$OUTPUT_FILE" > /dev/null; then
    echo "ERROR: encrypted backup does not decrypt — previous export preserved at $OUTPUT_FILE.bak"
    exit 1
fi

echo "Backup saved to $OUTPUT_FILE (encrypted, decrypt verified)"
