#!/usr/bin/env bash
# homepage on the cluster (ADR 0035): first ADR 0022 templated image ref, config
# translated from the old role templates with ${VAR} placeholders filled from
# the terraform inventory, secrets via InfisicalSecret, Ingress on Traefik.
source "$(dirname "$0")/../lib.sh"
NS=homepage
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # PLEX CONTROL PBS UNIFI INFISICAL ADGUARD SYNOLOGY TZ SERVICE_DOMAIN HOST_ALIAS
export DOMAIN="$SERVICE_DOMAIN" HOST="homepage.$SERVICE_DOMAIN" REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" GATEWAY="$(j .gateway)"
export PVE_API="$(sed -n "s/^virtual_environment_endpoint *= *\"\([^\"]*\)\".*/\1/p" "$ROOT/terraform/vars.auto.tfvars")"
export HOSTS="$HOST,$HOST_ALIAS,homepage.$NS.svc.cluster.local"   # the svc name is the Kuma row (the ingress host sits behind forward-auth)

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
echo "homepage at https://$HOST (and https://$HOST_ALIAS)"
