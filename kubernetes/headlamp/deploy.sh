#!/usr/bin/env bash
# Read-only Kubernetes dashboard on the ingress (ADR 0035 pattern): image through
# Zot, wildcard cert from Traefik's default store, host published by external-dns.
source "$(dirname "$0")/../lib.sh"
NS=headlamp
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"
export DOMAIN="$SERVICE_DOMAIN" HOST="headlamp.$SERVICE_DOMAIN" REGISTRY="registry.$(j .domain)"

ns "$NS"
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null 2>&1 || true
helm repo update headlamp >/dev/null 2>&1 || true
helm_apply headlamp headlamp/headlamp "$NS" -f <(envsubst < "$HERE/values.yaml")
kubectl -n "$NS" rollout status deploy/headlamp --timeout=300s
echo "headlamp at https://$HOST (read-only, authentik forward-auth)"
