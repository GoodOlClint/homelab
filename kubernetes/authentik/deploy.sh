#!/usr/bin/env bash
# authentik on the cluster (ADR 0040 P5c): one tree, two realms.
#   deploy.sh internal   — namespace authentik, auth.<service domain> Ingress, Traefik forward-auth via the
#                          embedded outpost, OIDC providers for Grafana/Portainer/MeshCentral/PDM/PVE/PBS
#   deploy.sh external   — namespace authentik-ext, Service only (the Cloudflare tunnel route is a dashboard
#                          step), LDAP outpost for Jellyfin, family/admins groups, enrollment + recovery flows
#   deploy.sh            — both, internal first
# Each realm: server + worker (helm chart), Postgres on ceph-rbd, nightly pg_dumpall → PBS ns `databases`,
# secrets generated into Infisical /authentik resp. /authentik-ext on first run and delivered by InfisicalSecret.
source "$(dirname "$0")/../lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # PBS TZ ACME_EMAIL SERVICE_DOMAIN MEDIA_DOMAIN
export REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" TZ ACME_EMAIL
export PBS_REPOSITORY="backup@pbs!backup-token@${PBS}:synology"
export CHART_VERSION=2026.8.0
SUBST='${NS} ${HOST} ${DOMAIN} ${DOMAIN_RE} ${REGISTRY} ${HOST_API} ${PROJECT_ID} ${FOLDER} ${TZ} ${ACME_EMAIL} ${PBS_REPOSITORY} ${CHART_VERSION}'
sub() { envsubst "$SUBST"; }

API="$(inf_host_api)" TOK="$(inf_token)"
inf() { curl -sS "$API$1" -H "authorization: Bearer $TOK" -H 'content-type: application/json' "${@:2}"; }
ensure_folder() {
  inf "/v1/folders?workspaceId=$PROJECT_ID&environment=prod&path=/" | jq -e --arg n "$1" '.folders[] | select(.name==$n)' >/dev/null ||
    inf /v1/folders -d "$(jq -n --arg id "$PROJECT_ID" --arg n "$1" '{workspaceId:$id,environment:"prod",name:$n,path:"/"}')" >/dev/null
}
ensure_secret() { # key bytes comment — hex values only, so nothing downstream ever has to quote them
  [ "$(inf "/v3/secrets/raw/$1?workspaceId=$PROJECT_ID&environment=prod&secretPath=/$FOLDER" -o /dev/null -w '%{http_code}')" = 200 ] && return
  inf "/v3/secrets/raw/$1" -d "$(jq -n --arg id "$PROJECT_ID" --arg p "/$FOLDER" --arg v "$(openssl rand -hex "$2")" --arg c "$3" \
    '{workspaceId:$id,environment:"prod",secretPath:$p,secretValue:$v,secretComment:$c}')" >/dev/null && echo "generated /$FOLDER/$1"
}

helm repo add authentik https://charts.goauthentik.io >/dev/null 2>&1 || true
helm repo update authentik >/dev/null

realm() {
  local realm=$1
  case "$realm" in
    internal) export NS=authentik FOLDER=authentik HOST="auth.$SERVICE_DOMAIN" DOMAIN="$SERVICE_DOMAIN" ;;
    external) export NS=authentik-ext FOLDER=authentik-ext HOST="auth.$MEDIA_DOMAIN" DOMAIN="$MEDIA_DOMAIN" ;;
    *) echo "usage: deploy.sh [internal|external]" >&2; exit 1 ;;
  esac
  export DOMAIN_RE="${DOMAIN//./\\.}"
  ensure_folder "$FOLDER"
  ensure_secret secret_key 48 "authentik $realm: Django secret key"
  ensure_secret postgres_password 24 "authentik $realm: Postgres password"
  ensure_secret bootstrap_password 16 "authentik $realm: akadmin initial password"
  ensure_secret bootstrap_token 32 "authentik $realm: akadmin API token"
  if [ "$realm" = internal ]; then
    for app in grafana portainer meshcentral pdm pve pbs; do ensure_secret "${app}_oidc_client_secret" 32 "authentik internal: OIDC client secret for $app"; done
  else
    ensure_secret ldap_bind_password 24 "authentik external: LDAP outpost bind password (Jellyfin)"
  fi

  ns "$NS"
  kubectl create configmap authentik-blueprint -n "$NS" --dry-run=client -o yaml --from-file="blueprint.yaml=$HERE/blueprint-$realm.yaml" | sub | kubectl apply --server-side --force-conflicts -f -
  sub < "$HERE/pvc.yaml" | kubectl apply -f -
  sub < "$HERE/secrets.yaml" | kubectl apply -f -
  sub < "$HERE/secrets-$realm.yaml" | kubectl apply -f -
  sub < "$HERE/app.yaml" | kubectl apply -f -
  for i in $(seq 30); do kubectl -n "$NS" get secret authentik-secrets >/dev/null 2>&1 && break; sleep 2; done
  helm_apply authentik authentik/authentik "$NS" --version "$CHART_VERSION" -f <(sub < "$HERE/values.yaml")
  [ "$realm" = internal ] && sub < "$HERE/ingress.yaml" | kubectl apply -f -
  kubectl -n "$NS" rollout status deploy postgres authentik-server authentik-worker --timeout=600s
  # The worker applies mounted blueprints on its own schedule; apply now so a deploy is complete when it returns.
  for i in $(seq 12); do
    kubectl -n "$NS" exec deploy/authentik-worker -- ak apply_blueprint /blueprints/mounted/cm-authentik-blueprint/blueprint.yaml >"$SECRETS/authentik-$realm-blueprint.log" 2>&1 && break
    [ "$i" = 12 ] && { echo "blueprint apply failed — see $SECRETS/authentik-$realm-blueprint.log" >&2; exit 1; }; sleep 10
  done
  echo "authentik $realm: https://$HOST ($NS; akadmin password = Infisical /$FOLDER/bootstrap_password)"
}

for r in ${1:-internal external}; do realm "$r"; done
