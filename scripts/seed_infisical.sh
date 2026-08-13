#!/usr/bin/env bash
# Disaster recovery restore: SOPS backup → Infisical (make infisical-seed).
# Invariants: pure-API against a single endpoint (folders and secrets must
# never target different endpoints), secret values never on argv, and any
# failure exits non-zero — never warn-and-exit-0.
#
# Auth/endpoint resolution (env overrides exist for rehearsal against a
# disposable instance — see scripts/rehearse_infisical_seed.sh):
#   INFISICAL_API_URL    override; else bootstrap_config.infisical_url
#   INFISICAL_PROJECT_ID override; else bootstrap_config.infisical_project_id
#   INFISICAL_TOKEN      override (direct bearer); else universal-auth login
#                        with bootstrap.infisical_client_id/_client_secret
#
# Usage: make infisical-seed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
SOPS_FILE="$REPO_ROOT/ansible/group_vars/secrets.sops.yml"
BOOTSTRAP_FILE="$REPO_ROOT/ansible/group_vars/bootstrap.sops.yml"
INFISICAL_ENV="prod"

[ -x "$VENV_PYTHON" ] || { echo "ERROR: .venv not found. Run: make init"; exit 1; }
command -v sops >/dev/null || { echo "ERROR: sops CLI not found"; exit 1; }
[ -f "$SOPS_FILE" ] || { echo "ERROR: $SOPS_FILE not found. Nothing to restore."; exit 1; }
[ -f "$BOOTSTRAP_FILE" ] || { echo "ERROR: $BOOTSTRAP_FILE not found."; exit 1; }

# The DR artifact must be encrypted — a plaintext secrets.sops.yml is a leak,
# not an input format. (The old plaintext fallback is deliberately gone.)
sops -d "$SOPS_FILE" >/dev/null 2>&1 || {
    echo "ERROR: $SOPS_FILE is not SOPS-decryptable. Refusing a plaintext fallback."
    exit 1
}

sops_extract() {
    sops -d --extract "$1" "$BOOTSTRAP_FILE" 2>/dev/null || true
}

API_URL="${INFISICAL_API_URL:-$(sops_extract '["bootstrap_config"]["infisical_url"]')}"
PROJECT_ID="${INFISICAL_PROJECT_ID:-$(sops_extract '["bootstrap_config"]["infisical_project_id"]')}"

for v in API_URL PROJECT_ID; do
    val="${!v}"
    if [ -z "$val" ] || [ "$val" = "REPLACE_ME" ]; then
        echo "ERROR: $v unresolved (set the env override or fill bootstrap.sops.yml)"
        exit 1
    fi
done

echo "Restoring $SOPS_FILE → $API_URL (env: $INFISICAL_ENV, project: $PROJECT_ID)"

CLIENT_ID=""
CLIENT_SECRET=""
if [ -z "${INFISICAL_TOKEN:-}" ]; then
    CLIENT_ID=$(sops_extract '["bootstrap"]["infisical_client_id"]')
    CLIENT_SECRET=$(sops_extract '["bootstrap"]["infisical_client_secret"]')
fi

# Everything secret-bearing rides fd 3 / env into python — never argv. The
# decrypted YAML arrives on fd 3 because stdin already carries the program
# (heredoc); piping both through stdin silently drops the data.
INFISICAL_SEED_API_URL="$API_URL" \
    INFISICAL_SEED_PROJECT_ID="$PROJECT_ID" \
    INFISICAL_SEED_ENV="$INFISICAL_ENV" \
    INFISICAL_SEED_TOKEN="${INFISICAL_TOKEN:-}" \
    INFISICAL_SEED_CLIENT_ID="$CLIENT_ID" \
    INFISICAL_SEED_CLIENT_SECRET="$CLIENT_SECRET" \
    "$VENV_PYTHON" - 3< <(sops -d "$SOPS_FILE") <<'PY'
import json, os, sys, urllib.request, urllib.error, urllib.parse
import yaml

api = os.environ["INFISICAL_SEED_API_URL"].rstrip("/")
project = os.environ["INFISICAL_SEED_PROJECT_ID"]
env_slug = os.environ["INFISICAL_SEED_ENV"]

def call(method, path, body, token=None):
    req = urllib.request.Request(
        f"{api}/api{path}", method=method,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r), None
    except urllib.error.HTTPError as e:
        return None, (e.code, e.read()[:300].decode(errors="replace"))
    except urllib.error.URLError as e:
        return None, (0, str(e))

token = os.environ.get("INFISICAL_SEED_TOKEN") or None
if not token:
    cid = os.environ.get("INFISICAL_SEED_CLIENT_ID", "")
    csec = os.environ.get("INFISICAL_SEED_CLIENT_SECRET", "")
    if not cid or not csec or cid == "REPLACE_ME":
        sys.exit("ERROR: no INFISICAL_TOKEN and no universal-auth credentials in bootstrap.sops.yml")
    login, err = call("POST", "/v1/auth/universal-auth/login",
                      {"clientId": cid, "clientSecret": csec})
    if err:
        sys.exit(f"ERROR: universal-auth login failed against {api}: {err}")
    token = login["accessToken"]

with os.fdopen(3) as _data_fd:
    data = yaml.safe_load(_data_fd)
secrets = (data or {}).get("secrets") or {}
if not secrets:
    sys.exit("ERROR: no secrets found under the 'secrets:' key")

failures, migrated, skipped, verified = [], 0, 0, 0

def ensure_folder(name):
    _, err = call("POST", "/v2/folders",
                  {"projectId": project, "environment": env_slug,
                   "name": name, "path": "/"}, token)
    if err and err[0] not in (400, 409):
        failures.append(f"folder /{name}: {err}")

def upsert(name, value, path):
    global migrated, skipped
    if not value or str(value) == "REPLACE_ME":
        skipped += 1
        return
    body = {"workspaceId": project, "environment": env_slug,
            "secretPath": path, "secretValue": str(value),
            "secretComment": "Restored by make infisical-seed"}
    _, err = call("POST", f"/v3/secrets/raw/{name}", body, token)
    if err and err[0] == 400:
        _, err = call("PATCH", f"/v3/secrets/raw/{name}", body, token)
    if err:
        failures.append(f"{path}/{name}: {err}")
    else:
        migrated += 1

flat = {k: v for k, v in secrets.items() if not isinstance(v, dict)}
nested = {k: v for k, v in secrets.items() if isinstance(v, dict)}

for k, v in flat.items():
    upsert(k, v, "/")

for key, sub in nested.items():
    folder = key.replace("_", "-")
    print(f"  /{folder}: {len(sub)} secrets")
    ensure_folder(folder)
    for k, v in (sub or {}).items():
        upsert(k, v, f"/{folder}")

# Verify: every non-skipped key must read back at its path.
def list_names(path):
    req = urllib.request.Request(
        f"{api}/api/v3/secrets/raw?workspaceId={project}&environment={env_slug}"
        f"&secretPath={urllib.parse.quote(path, safe='')}",
        headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return {s["secretKey"] for s in json.load(r).get("secrets", [])}
    except Exception as e:
        failures.append(f"verify-list {path}: {e}")
        return set()

expected = {"/": {k for k, v in flat.items() if v and str(v) != "REPLACE_ME"}}
for key, sub in nested.items():
    expected[f"/{key.replace('_', '-')}"] = {
        k for k, v in (sub or {}).items() if v and str(v) != "REPLACE_ME"}
for path, names in expected.items():
    if not names:
        continue
    present = list_names(path)
    missing = names - present
    verified += len(names - missing)
    for m in missing:
        failures.append(f"verify: {path}/{m} not present after seed")

print(f"\nSeeded: {migrated}, Skipped (empty/REPLACE_ME): {skipped}, Verified: {verified}")
if failures:
    print(f"\nFAILED ({len(failures)}):", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)
print("All seeded secrets verified present.")
PY
