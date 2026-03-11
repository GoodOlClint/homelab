#!/usr/bin/env bash
# Disaster recovery restore: SOPS backup → Infisical
# Restores secrets from `make infisical-backup` output to Infisical.
# NOT used during normal operation — only for DR scenarios.
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
pid = data.get('bootstrap_config', {}).get('infisical_project_id', 'REPLACE_ME')
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

# Walk the secrets structure:
#   - Flat string keys → seed to Infisical path /
#   - Nested dicts (keys starting with /) → seed each sub-key to that Infisical path
$DECRYPT_CMD | "$VENV_PYTHON" -c "
import yaml, sys, subprocess

data = yaml.safe_load(sys.stdin)
secrets = data.get('secrets', {})

if not secrets:
    print('No secrets found under secrets: key')
    sys.exit(1)

migrated = 0
skipped = 0

import json, urllib.request, os

api_url = os.environ.get('INFISICAL_API_URL', 'http://localhost:8080')
api_token = os.environ.get('INFISICAL_TOKEN', '')
created_folders = set()

def ensure_folder(folder_name):
    if folder_name in created_folders:
        return
    print(f'  Creating folder: /{folder_name}')
    body = json.dumps({
        'projectId': '$PROJECT_ID',
        'environment': '$INFISICAL_ENV',
        'name': folder_name,
        'path': '/'
    }).encode()
    req = urllib.request.Request(
        f'{api_url}/api/v2/folders',
        data=body,
        headers={
            'Authorization': f'Bearer {api_token}',
            'Content-Type': 'application/json'
        },
        method='POST'
    )
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        if 'already exists' not in err_body.lower() and e.code != 409:
            print(f'    WARNING: Failed to create folder /{folder_name}: {err_body}')
    created_folders.add(folder_name)

def seed(name, value, path):
    global migrated, skipped
    if value and str(value) != 'REPLACE_ME':
        print(f'  Seeding: {name} → {path}')
        result = subprocess.run([
            'infisical', 'secrets', 'set',
            f'{name}={value}',
            '--env', '$INFISICAL_ENV',
            '--path', path,
            '--projectId', '$PROJECT_ID'
        ], capture_output=True, text=True)
        if result.returncode == 0:
            migrated += 1
        else:
            print(f'    WARNING: Failed to set {name}: {result.stderr.strip()}')
    else:
        skipped += 1
        print(f'  Skipping: {name} (empty or REPLACE_ME)')

# Flat keys → path /
print('=== Root secrets (/) ===')
for key, value in secrets.items():
    if isinstance(value, dict):
        continue  # handled below
    seed(key, value, '/')

# Nested dicts → Infisical path (underscores become hyphens, prefixed with /)
for key, nested in secrets.items():
    if not isinstance(nested, dict):
        continue
    folder_name = key.replace('_', '-')
    infisical_path = '/' + folder_name
    print(f'\n=== Path: {infisical_path} ===')
    ensure_folder(folder_name)
    for sub_key, sub_value in nested.items():
        seed(sub_key, sub_value, infisical_path)

print(f'\nDone! Migrated: {migrated}, Skipped: {skipped}')
"
