#!/usr/bin/env bash
# Zot pull-through registry (ADR 0022/0034): registry.<domain> on a MetalLB IP,
# TLS from the homelab-ca ClusterIssuer, blobs on a ceph-rbd PVC.
# `deploy.sh smoke` pulls busybox through it from a node (nodes trust the CA via
# `make talos-trust`); the workstation needs the CA in ~/.docker/certs.d/<host>/ca.crt.
source "$(dirname "$0")/../lib.sh"
NS=zot
HOST="registry.$(j .domain)"
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
helm_apply zot project-zot/zot "$NS" -f "$HERE/values.yaml"
kubectl -n "$NS" rollout status statefulset/zot --timeout=300s
LB=$(kubectl -n "$NS" get svc zot -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "registry at https://$HOST ($LB) — AdGuard rewrite:"
(cd "$ROOT" && make -s adguard-rewrite DOMAIN="$HOST" ANSWER="$LB")
