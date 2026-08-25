#!/usr/bin/env bash
# Traefik ingress controller (ADR 0035): one MetalLB IP at services offset 65,
# a Let's Encrypt wildcard (service + media domains) as the default TLS store, so app
# Ingresses carry no tls: block; a homelab-ca cert for the legacy names sits beside it
# for SNI. Hostnames live on the service domain (ADR 0040, published by external-dns);
# the legacy .internal names 302 to their service-domain twin until P5e.
# ISSUER=letsencrypt-staging swaps the default cert to the staging CA (rate-limit-free rehearsal).
source "$(dirname "$0")/../lib.sh"
NS=traefik
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # SERVICE_DOMAIN MEDIA_DOMAIN SERVICES_ZONE
export DOMAIN="$SERVICE_DOMAIN" LEGACY_DOMAIN="$(j .domain)" LB_IP="$(subnet_ip 65)" REGISTRY="registry.$(j .domain)" ISSUER="${ISSUER:-letsencrypt}"
export LEGACY_RE="${LEGACY_DOMAIN//./\\.}"

helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
ns "$NS"
envsubst < "$HERE/certificate.yaml" | kubectl apply -f -
kubectl -n "$NS" wait --for=condition=Ready certificate/wildcard-tls certificate/legacy-tls --timeout=600s   # DNS-01 waits on propagation
helm_apply traefik traefik/traefik "$NS" -f <(envsubst < "$HERE/values.yaml") || true   # first pass can race its own CRDs
kubectl wait --for=condition=Established crd/tlsstores.traefik.io --timeout=60s >/dev/null
helm_apply traefik traefik/traefik "$NS" -f <(envsubst < "$HERE/values.yaml") >/dev/null
kubectl -n "$NS" rollout status deploy/traefik --timeout=300s
envsubst '${DOMAIN} ${LEGACY_DOMAIN} ${LEGACY_RE} ${SERVICES_ZONE}' < "$HERE/legacy-redirect.yaml" | kubectl apply -f -
echo "ingress at $LB_IP (*.$DOMAIN + *.$MEDIA_DOMAIN via $ISSUER; *.$LEGACY_DOMAIN redirects)"
