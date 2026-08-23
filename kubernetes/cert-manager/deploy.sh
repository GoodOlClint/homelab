#!/usr/bin/env bash
# cert-manager + the self-signed internal CA `homelab-ca` (ADR 0034; placeholder
# for Infisical PKI). Exports the CA certificate to kubernetes/.secrets/homelab-ca.crt.
source "$(dirname "$0")/../lib.sh"
NS=cert-manager
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
ns "$NS"
helm_apply cert-manager jetstack/cert-manager "$NS" --set crds.enabled=true
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do kubectl -n "$NS" rollout status deploy/$d --timeout=300s; done
until kubectl apply -f "$(dirname "$0")/issuer.yaml" 2>/dev/null; do sleep 5; done   # webhook readiness lags the rollout
kubectl -n "$NS" wait --for=condition=Ready certificate/homelab-ca --timeout=120s
kubectl -n "$NS" get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$SECRETS/homelab-ca.crt"
echo "CA exported to $SECRETS/homelab-ca.crt"
