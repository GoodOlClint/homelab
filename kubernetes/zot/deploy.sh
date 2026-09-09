#!/bin/bash
# Zot pull-through registry (ADR 0022/0034): registry.<domain> on a MetalLB IP,
# TLS from the homelab-ca ClusterIssuer, blobs on a ceph-rbd PVC.
# `deploy.sh smoke` pulls busybox through it from a node (nodes trust the CA via
# `make talos-trust`); the workstation needs the CA in ~/.docker/certs.d/<host>/ca.crt.
source "$(dirname "$0")/../lib.sh"
NS=zot
HOST="registry.$(j .domain)"
DOMAIN="$(j .domain)"
ZOT_PUSH_USER=push
export HOST DOMAIN ZOT_PUSH_USER
HERE="$(cd "$(dirname "$0")" && pwd)"

smoke() {
  kubectl delete pod zot-smoke --ignore-not-found >/dev/null
  kubectl run zot-smoke --image="$HOST/docker.io/library/busybox:latest" --restart=Never --command -- sh -c 'echo hello-zot' >/dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/zot-smoke --timeout=180s >/dev/null
  kubectl logs zot-smoke | grep -q hello-zot && echo "registry smoke: PASS"
  kubectl delete pod zot-smoke >/dev/null
  kubectl -n "$NS" get pvc
}
[ "${1:-}" = smoke ] && { smoke; exit; }

helm repo add project-zot https://zotregistry.dev/helm-charts >/dev/null 2>&1 || true
helm repo update project-zot >/dev/null
ns "$NS"
HOST="$HOST" envsubst < "$HERE/certificate.yaml" | kubectl apply -f -
kubectl -n "$NS" wait --for=condition=Ready certificate/zot-tls --timeout=120s

# Anonymous PUSH was accepted until 2026-08-27 (no auth block at all), so anyone on the LAN
# could overwrite a tag the cluster pulls. Read stays anonymous — every node's containerd
# pulls unchanged and the on-demand sync still fills the mirror — and write now needs the
# htpasswd identity below. OIDC covers the web UI only; zot's own docs are explicit that
# CLI push/pull cannot use it, which is why the htpasswd user exists alongside.
FOLDER=infrastructure ensure_folder infrastructure >/dev/null
FOLDER=infrastructure ensure_secret zot_push_password 24 "Zot registry: push credential for $ZOT_PUSH_USER"
PUSH_PW=$(inf_get /infrastructure zot_push_password)
OIDC_SECRET=$(inf_get /authentik zot_oidc_client_secret)
kubectl create secret generic zot-secret -n "$NS" --dry-run=client -o yaml \
  --from-literal=htpasswd="$(htpasswd -nbB "$ZOT_PUSH_USER" "$PUSH_PW")" \
  --from-literal=oidc-credentials.json="{\"clientid\": \"zot\", \"clientsecret\": \"$OIDC_SECRET\"}" \
  | kubectl apply -f -

helm_apply zot project-zot/zot "$NS" -f <(envsubst < "$HERE/values.yaml")
kubectl -n "$NS" rollout status statefulset/zot --timeout=300s
LB=$(kubectl -n "$NS" get svc zot -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "registry at https://$HOST ($LB)"
