#!/usr/bin/env bash
# Restore a PBS `databases/infisical` dump into an Infisical stack (make infisical-restore).
# ADR 0039: the PBS dump (pg_dump -Fc + ENCRYPTION_KEY/AUTH_SECRET) is the vault's
# DR path — org, project, machine identities and the PKI root survive; the SOPS
# seed (make infisical-seed) cannot carry any of those.
#
#   HOST      SSH target (default: the inventory's infisical ansible_host)
#   SSH_USER  default goodolclint (the cloud-init user)
#   DIR       compose dir on HOST (default /opt/infisical). When it holds no
#             docker-compose.yml a throwaway stack is written there (rehearsal).
#   SNAPSHOT  host/infisical/<rfc3339> (default: newest in the namespace)
#
# PBS credentials come from secrets.sops.yml (the vault is down while it is being
# restored, so Infisical itself cannot be the source); the encryption material in
# the dump must match bootstrap.sops.yml or the restored rows are unreadable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"
SOPS_FILE="$REPO_ROOT/ansible/group_vars/secrets.sops.yml"
BOOTSTRAP_FILE="$REPO_ROOT/ansible/group_vars/bootstrap.sops.yml"
INVENTORY="$REPO_ROOT/ansible/inventory/vms.yaml"
SSH_USER="${SSH_USER:-goodolclint}"
DIR="${DIR:-/opt/infisical}"
SNAPSHOT="${SNAPSHOT:-}"

[ -x "$VENV_PYTHON" ] || { echo "ERROR: .venv not found. Run: make init"; exit 1; }
for cmd in sops ssh; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }; done
[ -f "$SOPS_FILE" ] || { echo "ERROR: $SOPS_FILE not found — run make infisical-backup while the vault is up"; exit 1; }

inv() { "$VENV_PYTHON" -c "import yaml,sys; print(yaml.safe_load(open('$INVENTORY'))['all']['hosts'][sys.argv[1]]['ansible_host'])" "$1"; }
HOST="${HOST:-$(inv infisical)}"
PBS_HOST="proxmox-backup.$("$VENV_PYTHON" -c "import yaml; print(yaml.safe_load(open('$REPO_ROOT/network-data/vlans.yaml'))['service_domain'])")"
PBS_PASSWORD=$(sops -d --extract '["secrets"]["shared"]["pbs_backup_token"]' "$SOPS_FILE")
ENCRYPTION_KEY=$(sops -d --extract '["bootstrap"]["infisical_encryption_key"]' "$BOOTSTRAP_FILE")
AUTH_SECRET=$(sops -d --extract '["bootstrap"]["infisical_auth_secret"]' "$BOOTSTRAP_FILE")
CLIENT_ID=$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$BOOTSTRAP_FILE")
CLIENT_SECRET=$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$BOOTSTRAP_FILE")
PROJECT_ID=$(sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$BOOTSTRAP_FILE")
for v in PBS_PASSWORD ENCRYPTION_KEY AUTH_SECRET CLIENT_ID CLIENT_SECRET PROJECT_ID; do
    [ -n "${!v}" ] && [ "${!v}" != "REPLACE_ME" ] || { echo "ERROR: $v is empty"; exit 1; }
done

echo "Restoring ${SNAPSHOT:-newest databases/infisical snapshot} into $SSH_USER@$HOST:$DIR"

# Secrets travel on the remote shell's stdin — never argv, never a file on the target.
{
    printf 'export PBS_REPOSITORY=%q PBS_PASSWORD=%q\n' \
        "backup@pbs!backup-token@${PBS_HOST}:synology" "$PBS_PASSWORD"
    printf 'EXPECT_KEY=%q EXPECT_AUTH=%q DIR=%q SNAPSHOT=%q CLIENT_ID=%q CLIENT_SECRET=%q PROJECT_ID=%q\n' \
        "$ENCRYPTION_KEY" "$AUTH_SECRET" "$DIR" "$SNAPSHOT" "$CLIENT_ID" "$CLIENT_SECRET" "$PROJECT_ID"
    cat <<'REMOTE'
set -euo pipefail
TMP=$(mktemp -d /tmp/infisical-restore.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
COMPOSE="$DIR/docker-compose.yml"

if [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(proxmox-backup-client snapshot list --ns databases --output-format json | python3 -c '
import json, sys, datetime
s = sorted((x for x in json.load(sys.stdin) if x["backup-type"] == "host" and x["backup-id"] == "infisical"), key=lambda x: x["backup-time"])
assert s, "no host/infisical snapshot in ns databases"
print("host/infisical/" + datetime.datetime.fromtimestamp(s[-1]["backup-time"], datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
fi
echo "snapshot: $SNAPSHOT"
proxmox-backup-client restore "$SNAPSHOT" infisical-backup.pxar "$TMP/dump" --ns databases >/dev/null
DUMP=$(ls "$TMP"/dump/infisical_*.dump)
ENV_FILE=$(ls "$TMP"/dump/encryption_material_*.env)
KEY=$(grep -m1 '^ENCRYPTION_KEY=' "$ENV_FILE" | cut -d= -f2-)
AUTH=$(grep -m1 '^AUTH_SECRET=' "$ENV_FILE" | cut -d= -f2-)
[ "$KEY" = "$EXPECT_KEY" ] || { echo "ERROR: the dump's ENCRYPTION_KEY differs from bootstrap.sops.yml — fix the bootstrap file first"; exit 1; }
[ "$AUTH" = "$EXPECT_AUTH" ] || { echo "ERROR: the dump's AUTH_SECRET differs from bootstrap.sops.yml — fix the bootstrap file first"; exit 1; }

[ -s "$TMP/dump/tls/cert.pem" ] && echo "dump carries tls/ (cert $(openssl x509 -in "$TMP/dump/tls/cert.pem" -noout -enddate | cut -d= -f2))"
if [ -f "$COMPOSE" ] && [ -s "$TMP/dump/tls/cert.pem" ] && docker compose -f "$COMPOSE" config --services 2>/dev/null | grep -qx caddy; then
    mkdir -p "$DIR/tls"
    install -m 0600 "$TMP/dump/tls/key.pem" "$DIR/tls/key.pem"
    install -m 0644 "$TMP/dump/tls/cert.pem" "$DIR/tls/cert.pem"
    RESTORED_TLS=1
fi
if [ ! -f "$COMPOSE" ]; then
    echo "no compose file in $DIR — writing a throwaway stack (rehearsal)"
    mkdir -p "$DIR/postgres" "$DIR/redis"
    PG_PASS=$(openssl rand -hex 16)
    cat > "$COMPOSE" <<EOF
services:
  infisical:
    image: infisical/infisical:latest
    container_name: infisical
    ports: ["8080:8080"]
    environment:
      - ENCRYPTION_KEY=$KEY
      - AUTH_SECRET=$AUTH
      - DB_CONNECTION_URI=postgres://infisical:$PG_PASS@postgres:5432/infisical
      - REDIS_URL=redis://redis:6379
      - SITE_URL=http://localhost:8080
    depends_on: {postgres: {condition: service_healthy}, redis: {condition: service_healthy}}
  postgres:
    image: postgres:16-alpine
    container_name: infisical-postgres
    environment: [POSTGRES_PASSWORD=$PG_PASS, POSTGRES_USER=infisical, POSTGRES_DB=infisical]
    volumes: ["$DIR/postgres:/var/lib/postgresql/data"]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U infisical"], interval: 5s, retries: 12}
  redis:
    image: redis:7-alpine
    container_name: infisical-redis
    healthcheck: {test: ["CMD-SHELL", "redis-cli ping | grep PONG"], interval: 5s, retries: 12}
EOF
    chmod 0600 "$COMPOSE"
fi

docker compose -f "$COMPOSE" up -d --wait postgres redis
docker compose -f "$COMPOSE" stop infisical 2>/dev/null || true
docker exec infisical-postgres psql -U infisical -d postgres -v ON_ERROR_STOP=1 -q \
    -c 'DROP DATABASE IF EXISTS infisical WITH (FORCE);' -c 'CREATE DATABASE infisical OWNER infisical;'
docker exec -i infisical-postgres pg_restore -U infisical -d infisical --no-owner --no-privileges --exit-on-error < "$DUMP"
ORGS=$(docker exec infisical-postgres psql -U infisical -d infisical -tAc 'select count(*) from organizations')
echo "restored: $ORGS organization(s)"
[ "$ORGS" -gt 0 ]
docker compose -f "$COMPOSE" up -d
if [ -n "${RESTORED_TLS:-}" ]; then
    docker compose -f "$COMPOSE" restart caddy
    echo "tls: restored the vault's certificate from the dump"
fi
UP=
for _ in $(seq 60); do
    curl -sf http://localhost:8080/api/status >/dev/null && { UP=1; break; }
    sleep 5
done
[ -n "$UP" ] || { echo "ERROR: /api/status never answered"; exit 1; }
echo "/api/status: 200"

# 8080 is localhost-only once the binding is https (ADR 0042), so the proof read runs here.
TOKEN=$(curl -sfS -X POST http://localhost:8080/api/v1/auth/universal-auth/login -H 'content-type: application/json' \
    -d "{\"clientId\":\"$CLIENT_ID\",\"clientSecret\":\"$CLIENT_SECRET\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')
[ -n "$TOKEN" ] || { echo "ERROR: universal-auth login failed against the restored vault"; exit 1; }
COUNT=$(curl -sfS "http://localhost:8080/api/v3/secrets/raw?workspaceId=$PROJECT_ID&environment=prod&secretPath=/shared" \
    -H "authorization: Bearer $TOKEN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["secrets"]))')
[ "$COUNT" -gt 0 ] || { echo "ERROR: /shared read back 0 secrets"; exit 1; }
echo "OK: identity login + /shared read ($COUNT secrets) on $(hostname)"
REMOTE
} | ssh -o BatchMode=yes "$SSH_USER@$HOST" sudo bash -s
