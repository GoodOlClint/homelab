#!/usr/bin/env bash
# cert-manager + the internal CA `homelab-ca` (ADR 0039): an intermediate held in the
# cluster, signed by the Infisical internal root `Homelab Root CA` (Certificate Manager
# project `homelab-pki`, both created here if absent). Exports the ROOT to
# kubernetes/.secrets/homelab-ca.crt — that is what nodes and clients trust.
# Plus the Let's Encrypt issuers (ADR 0040 P5b): DNS-01 via Cloudflare, token from Infisical
# /infrastructure through an InfisicalSecret — needs `make talos-infisical` first; without the
# operator the issuers are applied but stay NotReady until it lands.
source "$(dirname "$0")/../lib.sh"
NS=cert-manager
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_CRT="$SECRETS/homelab-ca.crt"
eval "$(inv_env)"   # ACME_EMAIL
export ACME_EMAIL HOST_API="$(inf_host_api)" PROJECT_ID="$(inf_project_id)"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
ns "$NS"
# DNS-01 self-check must ask public resolvers: AdGuard forwards the service zone to BIND, which never
# sees the _acme-challenge TXT (a deliberate, cert-manager-only exception to ADR 0012).
helm_apply cert-manager jetstack/cert-manager "$NS" --set crds.enabled=true --set global.leaderElection.namespace="$NS" \
  --set 'dns01RecursiveNameservers=1.1.1.1:53\,1.0.0.1:53' --set dns01RecursiveNameserversOnly=true   # helm_apply -n rejects the chart's kube-system leader-election objects
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do kubectl -n "$NS" rollout status deploy/$d --timeout=300s; done

API="$(inf_host_api)" TOK="$(inf_token)"
inf() { curl -sfS "$API$1" -H "authorization: Bearer $TOK" -H 'content-type: application/json' "${@:2}"; }
plus_years() { "$ROOT/.venv/bin/python3" -c "import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(days=365*$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }

PROJ=$(inf /v1/workspace | jq -r '.workspaces[] | select(.type=="cert-manager" and .name=="homelab-pki") | .id')
[ -n "$PROJ" ] || PROJ=$(inf /v2/workspace -d '{"projectName":"homelab-pki","type":"cert-manager","hasDeleteProtection":true}' | jq -r .project.id)
CA=$(inf "/v1/cert-manager/ca?projectId=$PROJ" | jq -r '.certificateAuthorities[] | select(.name=="homelab-root-ca") | .id')
[ -n "$CA" ] || CA=$(inf "/v1/cert-manager/ca/internal?projectId=$PROJ" -d "$(jq -n --arg na "$(plus_years 20)" --arg alg EC_secp384r1 '{name:"homelab-root-ca",status:"active",configuration:{type:"root",friendlyName:"Homelab Root CA",commonName:"Homelab Root CA",organization:"homelab",keyAlgorithm:$alg,keySource:"infisical",maxPathLength:1,notAfter:$na}}')" | jq -r .id)
inf "/v1/cert-manager/ca/internal/$CA/certificate" | jq -r .certificate > "$ROOT_CRT"
cat "$("$ROOT/.venv/bin/python3" -c 'import certifi; print(certifi.where())')" "$ROOT_CRT" > "$SECRETS/ca-bundle.pem"   # python trust on the workstation (ADR 0042)
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
until envsubst < "$HERE/issuer.yaml" | kubectl apply -f - 2>/dev/null; do sleep 5; done   # webhook readiness lags the rollout
kubectl wait --for=condition=Ready clusterissuer/homelab-ca --timeout=120s
if kubectl get crd infisicalsecrets.secrets.infisical.com >/dev/null 2>&1; then
  envsubst < "$HERE/secrets.yaml" | kubectl apply -f -
  for i in $(seq 30); do kubectl -n "$NS" get secret cloudflare-api-token >/dev/null 2>&1 && break; sleep 2; done
  kubectl wait --for=condition=Ready clusterissuer/letsencrypt clusterissuer/letsencrypt-staging --timeout=120s
else
  echo "Infisical operator absent: letsencrypt issuers stay NotReady until make talos-infisical, then re-run"
fi
