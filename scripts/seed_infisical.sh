#!/usr/bin/env bash
# One-time migration: SOPS secrets → Infisical
# Prerequisites: infisical CLI installed, logged in, project configured
#
# Usage: make infisical-seed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
SOPS_FILE="ansible/group_vars/secrets.sops.yml"
INFISICAL_ENV="prod"

if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: .venv not found. Run: make bootstrap-local"
    exit 1
fi

if [ ! -f "$SOPS_FILE" ]; then
    echo "ERROR: $SOPS_FILE not found. Nothing to migrate."
    exit 1
fi

if ! command -v infisical &> /dev/null; then
    echo "ERROR: infisical CLI not found. Install from https://infisical.com/docs/cli/overview"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo "ERROR: sops CLI not found. Install from https://github.com/getsops/sops"
    exit 1
fi

# Read Infisical project ID from bootstrap.sops.yml
BOOTSTRAP_FILE="ansible/group_vars/bootstrap.sops.yml"
PROJECT_ID=$("$VENV_PYTHON" -c "
import yaml
data = yaml.safe_load(open('$BOOTSTRAP_FILE'))
pid = data.get('bootstrap', {}).get('infisical_project_id', 'REPLACE_ME')
if pid == 'REPLACE_ME':
    print('')
else:
    print(pid)
")

if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: infisical_project_id not set in $BOOTSTRAP_FILE"
    echo "       Fill it in from the Infisical UI (Project Settings > Project ID)"
    exit 1
fi

echo "Migrating secrets from $SOPS_FILE to Infisical (env: $INFISICAL_ENV, project: $PROJECT_ID)..."
echo ""

# Decrypt SOPS file (or read plaintext if not encrypted)
if sops -d "$SOPS_FILE" > /dev/null 2>&1; then
    DECRYPT_CMD="sops -d $SOPS_FILE"
else
    echo "WARNING: $SOPS_FILE is not SOPS-encrypted, reading as plaintext"
    DECRYPT_CMD="cat $SOPS_FILE"
fi

# Iterate each key under 'secrets:'
$DECRYPT_CMD | "$VENV_PYTHON" -c "
import yaml, sys, subprocess

data = yaml.safe_load(sys.stdin)
secrets = data.get('secrets', {})

if not secrets:
    print('No secrets found under secrets: key')
    sys.exit(1)

migrated = 0
skipped = 0

for key, value in secrets.items():
    if value and str(value) != 'REPLACE_ME':
        print(f'  Seeding: {key}')
        result = subprocess.run([
            'infisical', 'secrets', 'set',
            f'{key.upper()}={value}',
            '--env', '$INFISICAL_ENV',
            '--path', '/',
            '--projectId', '$PROJECT_ID'
        ], capture_output=True, text=True)
        if result.returncode == 0:
            migrated += 1
        else:
            print(f'    WARNING: Failed to set {key}: {result.stderr.strip()}')
    else:
        skipped += 1
        print(f'  Skipping: {key} (empty or REPLACE_ME)')

print(f'\nDone! Migrated: {migrated}, Skipped: {skipped}')
"
