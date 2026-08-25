#!/usr/bin/env bash
# Traefik ingress controller (ADR 0035): one MetalLB IP at services offset 65,
# a Let's Encrypt wildcard (service + media domains) as the default TLS store, so app
# Ingresses carry no tls: block. Hostnames live on the service domain (ADR 0040,
# published by external-dns).
# ISSUER=letsencrypt-staging swaps the default cert to the staging CA (rate-limit-free rehearsal).
source "$(dirname "$0")/../lib.sh"
NS=traefik
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # SERVICE_DOMAIN MEDIA_DOMAIN
export DOMAIN="$SERVICE_DOMAIN" LB_IP="$(subnet_ip 65)" REGISTRY="registry.$(j .domain)" ISSUER="${ISSUER:-letsencrypt}"

helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
ns "$NS"
envsubst < "$HERE/certificate.yaml" | kubectl apply -f -
kubectl -n "$NS" wait --for=condition=Ready certificate/wildcard-tls --timeout=600s   # DNS-01 waits on propagation
helm_apply traefik traefik/traefik "$NS" -f <(envsubst < "$HERE/values.yaml") || true   # first pass can race its own CRDs
kubectl wait --for=condition=Established crd/tlsstores.traefik.io --timeout=60s >/dev/null
helm_apply traefik traefik/traefik "$NS" -f <(envsubst < "$HERE/values.yaml") >/dev/null
kubectl -n "$NS" rollout status deploy/traefik --timeout=300s
echo "ingress at $LB_IP (*.$DOMAIN + *.$MEDIA_DOMAIN via $ISSUER)"
