#!/usr/bin/env bash
# external-dns (ADR 0040): every Ingress host (and hostname-annotated Service) becomes an A
# record in the flat service zone over RFC 2136 against the BIND VIP — TSIG from Infisical
# /infrastructure through an InfisicalSecret, owner TXT records so it never touches the
# names Ansible's dns_records.yml pushes. `--rfc2136-tsig-axfr` needs BIND's allow-transfer by key.
source "$(dirname "$0")/../lib.sh"
NS=external-dns
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(inv_env)"   # BIND INTERNAL_ZONES_YAML
export REGISTRY="registry.$(j .domain)" HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)"

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
helm repo update external-dns >/dev/null
ns "$NS"
envsubst < "$HERE/secrets.yaml" | kubectl apply -f -
for i in $(seq 30); do kubectl -n "$NS" get secret external-dns-tsig >/dev/null 2>&1 && break; sleep 2; done
helm_apply external-dns external-dns/external-dns "$NS" -f <(envsubst '${REGISTRY} ${BIND} ${INTERNAL_ZONES_YAML}' < "$HERE/values.yaml")
kubectl -n "$NS" rollout status deploy/external-dns --timeout=300s
echo "external-dns → $BIND for zones: $INTERNAL_ZONES_YAML"
