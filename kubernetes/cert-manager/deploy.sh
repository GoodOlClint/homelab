#!/usr/bin/env bash
# cert-manager + the internal CA `homelab-ca` (ADR 0039): an intermediate held in the
# cluster, signed by the Infisical internal root `Homelab Root CA` (Certificate Manager
# project `homelab-pki`, both created here if absent). Exports the ROOT to
# kubernetes/.secrets/homelab-ca.crt — that is what nodes and clients trust.
source "$(dirname "$0")/../lib.sh"
NS=cert-manager
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_CRT="$SECRETS/homelab-ca.crt"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
ns "$NS"
helm_apply cert-manager jetstack/cert-manager "$NS" --set crds.enabled=true --set global.leaderElection.namespace="$NS"   # helm_apply -n rejects the chart's kube-system leader-election objects
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do kubectl -n "$NS" rollout status deploy/$d --timeout=300s; done

API="$(inf_host_api)" TOK="$(inf_token)"
inf() { curl -sfS "$API$1" -H "authorization: Bearer $TOK" -H 'content-type: application/json' "${@:2}"; }
plus_years() { "$ROOT/.venv/bin/python3" -c "import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(days=365*$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }

PROJ=$(inf /v1/workspace | jq -r '.workspaces[] | select(.type=="cert-manager" and .name=="homelab-pki") | .id')
[ -n "$PROJ" ] || PROJ=$(inf /v2/workspace -d '{"projectName":"homelab-pki","type":"cert-manager","hasDeleteProtection":true}' | jq -r .project.id)
CA=$(inf "/v1/cert-manager/ca?projectId=$PROJ" | jq -r '.certificateAuthorities[] | select(.name=="homelab-root-ca") | .id')
[ -n "$CA" ] || CA=$(inf "/v1/cert-manager/ca/internal?projectId=$PROJ" -d "$(jq -n --arg na "$(plus_years 20)" --arg alg EC_secp384r1 '{name:"homelab-root-ca",status:"active",configuration:{type:"root",friendlyName:"Homelab Root CA",commonName:"Homelab Root CA",organization:"homelab",keyAlgorithm:$alg,keySource:"infisical",maxPathLength:1,notAfter:$na}}')" | jq -r .id)
inf "/v1/cert-manager/ca/internal/$CA/certificate" | jq -r .certificate > "$ROOT_CRT"
echo "root CA $CA exported to $ROOT_CRT"

# Re-sign only when the cluster's intermediate is not the root's child (absent, self-signed, or a rotated root).
if ! kubectl -n "$NS" get secret homelab-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl verify -CAfile "$ROOT_CRT" >/dev/null 2>&1; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  openssl ecparam -name prime256v1 -genkey -noout -out "$T/tls.key"
  openssl req -new -key "$T/tls.key" -subj /CN=homelab-ca -out "$T/csr.pem"
  inf "/v1/cert-manager/ca/internal/$CA/sign-intermediate" -d "$(jq -n --rawfile csr "$T/csr.pem" --arg na "$(plus_years 5)" '{csr:$csr,maxPathLength:0,notAfter:$na}')" | jq -r .certificate > "$T/tls.crt"
  kubectl -n "$NS" create secret generic homelab-ca --type=kubernetes.io/tls \
    --from-file=tls.key="$T/tls.key" --from-file=tls.crt="$T/tls.crt" --from-file=ca.crt="$ROOT_CRT" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "intermediate homelab-ca signed by the root"
fi
until kubectl apply -f "$HERE/issuer.yaml" 2>/dev/null; do sleep 5; done   # webhook readiness lags the rollout
kubectl wait --for=condition=Ready clusterissuer/homelab-ca --timeout=120s
