#!/usr/bin/env bash
# Rehearse the DR seed path against a DISPOSABLE local Infisical (cutover-week
# plan 1.4). Spins postgres+redis+infisical in throwaway containers, bootstraps
# an admin + project exactly like ansible/tasks/bootstrap_infisical_setup.yml
# (infisical bootstrap CLI), runs scripts/seed_infisical.sh against it with env
# overrides, and relies on the seed script's own hard verify. Everything is
# destroyed on exit. The real vault is never touched.
#
# Usage: bash scripts/rehearse_infisical_seed.sh
# Requires: docker, sops, infisical CLI, the real secrets.sops.yml DR export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT=8099
NET=infisical-rehearsal
PREFIX=infisical-rehearsal
# Default to the image production runs (rehearse against what you restore to).
# Override for testing upgrades: INFISICAL_IMAGE=infisical/infisical:vX.Y
INFISICAL_IMAGE="${INFISICAL_IMAGE:-infisical/infisical:latest}"

command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
command -v infisical >/dev/null || { echo "ERROR: infisical CLI not found"; exit 1; }

cleanup() {
    echo "--- tearing down disposable instance"
    docker rm -f "$PREFIX-app" "$PREFIX-db" "$PREFIX-redis" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup 2>/dev/null || true
docker network create "$NET" >/dev/null

# Throwaway credentials for a throwaway instance — random per run, never reused.
PG_PASS=$(openssl rand -hex 16)
ENC_KEY=$(openssl rand -hex 16)
AUTH_SECRET=$(openssl rand -base64 32)
ADMIN_EMAIL="rehearsal@example.invalid"
ADMIN_PASS=$(openssl rand -base64 18)

echo "--- starting disposable Infisical on :$PORT"
docker run -d --name "$PREFIX-db" --network "$NET" \
    -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_USER=infisical -e POSTGRES_DB=infisical \
    postgres:16-alpine >/dev/null
docker run -d --name "$PREFIX-redis" --network "$NET" redis:7-alpine >/dev/null
docker run -d --name "$PREFIX-app" --network "$NET" -p "$PORT:8080" \
    -e ENCRYPTION_KEY="$ENC_KEY" \
    -e AUTH_SECRET="$AUTH_SECRET" \
    -e DB_CONNECTION_URI="postgres://infisical:$PG_PASS@$PREFIX-db:5432/infisical" \
    -e REDIS_URL="redis://$PREFIX-redis:6379" \
    -e SITE_URL="http://localhost:$PORT" \
    "$INFISICAL_IMAGE" >/dev/null

echo -n "--- waiting for API"
for i in $(seq 1 60); do
    if curl -sf "http://localhost:$PORT/api/status" >/dev/null 2>&1; then
        echo " ready (${i}0s)"; break
    fi
    [ "$i" = 60 ] && { echo " TIMEOUT"; docker logs --tail 20 "$PREFIX-app"; exit 1; }
    sleep 10
done

echo "--- bootstrapping admin + org (infisical bootstrap CLI)"
BOOTSTRAP_JSON=$(infisical bootstrap \
    --domain="http://localhost:$PORT" \
    --email="$ADMIN_EMAIL" \
    --password="$ADMIN_PASS" \
    --organization=rehearsal 2>/dev/null)
ORG_ID=$(printf '%s' "$BOOTSTRAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['organization']['id'])")
[ -n "$ORG_ID" ] || { echo "ERROR: bootstrap returned no organization id"; exit 1; }

# The bootstrap identity's access token is rejected as over-max-age by current
# images (no exp claim; server-side TTL row quirk). Use the admin USER JWT via
# CLI login instead — same flow the ansible bootstrap uses for existing
# instances; the CLI handles Infisical's SRP login.
echo "--- logging in as admin user"
ADMIN_TOKEN=$(infisical login --method=user \
    --email="$ADMIN_EMAIL" --password="$ADMIN_PASS" \
    --organization-id="$ORG_ID" --domain="http://localhost:$PORT" \
    --plain --silent 2>/dev/null | tail -1)
[ -n "$ADMIN_TOKEN" ] || { echo "ERROR: admin user login failed"; exit 1; }

echo "--- creating rehearsal project"
# Body mirrors ansible/tasks/bootstrap_infisical_setup.yml (the known-working
# call); shouldCreateDefaultEnvs gives us the prod env the seed targets.
PROJECT_RESP=$(curl -s -X POST "http://localhost:$PORT/api/v1/projects" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d '{"projectName":"homelab-rehearsal","shouldCreateDefaultEnvs":true}')
PROJECT_ID=$(printf '%s' "$PROJECT_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get('project', d).get('id', ''))")
[ -n "$PROJECT_ID" ] || { echo "ERROR: project creation failed: $PROJECT_RESP"; exit 1; }

echo "--- running the real seed script against the disposable instance"
INFISICAL_API_URL="http://localhost:$PORT" \
INFISICAL_PROJECT_ID="$PROJECT_ID" \
INFISICAL_TOKEN="$ADMIN_TOKEN" \
    bash "$SCRIPT_DIR/seed_infisical.sh"

echo ""
echo "REHEARSAL PASSED — the DR export seeds cleanly into a fresh Infisical."
