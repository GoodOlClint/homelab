#!/bin/bash
# authentik external realm (ADR 0040 P5c, ADR 0049): auth.<media domain>, Service only (the Cloudflare tunnel
# route is a dashboard step), LDAP outpost for Jellyfin, family/admins groups, enrollment + recovery flows.
# Objects are Flux-owned (kubernetes/flux/apps/authentik-ext.yaml); this script is the in-app tail — secrets
# generated into Infisical /authentik-ext on first run, then the blueprint applied — until it moves into
# ansible/playbooks/kubernetes.yml (ADR 0048 WP7). The internal realm is `make ansible authentik`.
source "$(dirname "$0")/../lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
NS=authentik-ext FOLDER=authentik-ext

ensure_folder "$FOLDER"
ensure_secret secret_key 48 "authentik external: Django secret key"
ensure_secret postgres_password 24 "authentik external: Postgres password"
ensure_secret bootstrap_password 16 "authentik external: akadmin initial password"
ensure_secret bootstrap_token 32 "authentik external: akadmin API token"
ensure_secret ldap_bind_password 24 "authentik external: LDAP outpost bind password (Jellyfin)"

flux reconcile kustomization authentik-ext --with-source >/dev/null
kubectl -n "$NS" rollout status deploy postgres authentik-server authentik-worker --timeout=600s
# kubelet refreshes a mounted ConfigMap on its own sync period, so the worker can still hold the
# PREVIOUS blueprint when the rollout returns. Applying then silently re-applies stale content and
# the deploy reports success while the change never lands (hit 2026-08-28 anchoring redirect_uris).
_want=$(shasum -a 256 < "$HERE/blueprint-external.yaml" | cut -c1-16)
for i in $(seq 30); do
  _got=$(kubectl -n "$NS" exec deploy/authentik-worker -- python3 -c \
    "import hashlib;print(hashlib.sha256(open('/blueprints/mounted/cm-authentik-blueprint/blueprint.yaml','rb').read()).hexdigest()[:16])" 2>/dev/null || true)
  [ "$_want" = "$_got" ] && break
  [ "$i" = 30 ] && { echo "blueprint mount never caught up (want $_want, got ${_got:-none})" >&2; exit 1; }
  sleep 5
done
# The worker applies mounted blueprints on its own schedule; apply now so a deploy is complete when it returns.
for i in $(seq 12); do
  kubectl -n "$NS" exec deploy/authentik-worker -- ak apply_blueprint /blueprints/mounted/cm-authentik-blueprint/blueprint.yaml >"$SECRETS/authentik-external-blueprint.log" 2>&1 && break
  [ "$i" = 12 ] && { echo "blueprint apply failed — see $SECRETS/authentik-external-blueprint.log" >&2; exit 1; }; sleep 10
done
eval "$(inv_env)"
echo "authentik external: https://auth.$MEDIA_DOMAIN ($NS; akadmin password = Infisical /$FOLDER/bootstrap_password)"
