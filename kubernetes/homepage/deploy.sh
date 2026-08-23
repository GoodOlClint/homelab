#!/usr/bin/env bash
# homepage on the cluster (ADR 0035): first ADR 0022 templated image ref, config
# translated from the old role templates with ${VAR} placeholders filled from
# the terraform inventory, secrets via InfisicalSecret, Ingress on Traefik.
source "$(dirname "$0")/../lib.sh"
NS=homepage
HERE="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="$(j .domain)"
export HOST="homepage.$DOMAIN" REGISTRY="registry.$DOMAIN" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" GATEWAY="$(j .gateway)"
export PVE_API="$(sed -n "s/^virtual_environment_endpoint *= *\"\([^\"]*\)\".*/\1/p" "$ROOT/terraform/vars.auto.tfvars")"
eval "$(inv_env)"   # PLEX PLEX_SERVICES OPENOBSERVE CONTROL PBS UNIFI INFISICAL DOCKER ADGUARD SYNOLOGY TZ HOST_ALIAS
export HOSTS="$HOST,$HOST_ALIAS"

ns "$NS"
kubectl create configmap homepage-config -n "$NS" --dry-run=client -o yaml \
  $(for f in "$HERE"/config/*.yaml; do printf -- '--from-file=%s=%s ' "$(basename "$f")" "$f"; done) \
  | envsubst | kubectl apply -f -
envsubst < "$HERE/secrets.yaml" | kubectl apply -f -
envsubst < "$HERE/app.yaml" | kubectl apply -f -
for s in homepage plex-services plex monitoring; do
  for i in $(seq 30); do kubectl -n "$NS" get secret "homepage-$s" >/dev/null 2>&1 && break; sleep 2; done
done
kubectl -n "$NS" rollout status deploy/homepage --timeout=300s
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for h in "$HOST" "$HOST_ALIAS"; do (cd "$ROOT" && make -s adguard-rewrite DOMAIN="$h" ANSWER="$LB"); done
echo "homepage at https://$HOST ($LB)"
