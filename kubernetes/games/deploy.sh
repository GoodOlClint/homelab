#!/bin/bash
# games stack on the cluster (ADR 0038): the crossplay Valheim server + its PlayFab status sidecar on a
# MetalLB UDP LB (services offset 67), one InfisicalSecret on /docker. Kiwix lives in kubernetes/kiwix.
source "$(dirname "$0")/../lib.sh"
NS=games
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # TZ SERVICE_DOMAIN
export DOMAIN="$SERVICE_DOMAIN" REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)" VALHEIM_IP="$(subnet_ip 67)"
export CONFIG_HASH="$(shasum -a 256 "$HERE/valheim-playfab-status.mjs" | cut -c1-16)"
SUBST='${REGISTRY} ${HOST_API} ${PROJECT_ID} ${DOMAIN} ${TZ} ${VALHEIM_IP} ${CONFIG_HASH}'
sub() { envsubst "$SUBST"; }



ns "$NS"
# SYS_NICE for the server process is outside PodSecurity baseline (same lift as metallb/ceph-csi).
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl create configmap valheim-status -n "$NS" --dry-run=client -o yaml --from-file="$HERE/valheim-playfab-status.mjs" | kubectl apply --server-side --force-conflicts -f -
sub < "$HERE/pvc.yaml" | kubectl apply -f -
sub < "$HERE/secrets.yaml" | kubectl apply -f -
sub < "$HERE/app.yaml" | kubectl apply -f -
for i in $(seq 30); do kubectl -n "$NS" get secret valheim-secrets >/dev/null 2>&1 && break; sleep 2; done
kubectl -n "$NS" rollout status deploy valheim --timeout=600s
echo "valheim UDP 2456-2458 on $VALHEIM_IP"
