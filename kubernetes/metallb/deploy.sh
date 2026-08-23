#!/usr/bin/env bash
# MetalLB L2 on vlan40 (ADR 0034): pool = services offsets 64-79.
source "$(dirname "$0")/../lib.sh"
NS=metallb-system
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update metallb >/dev/null
ns "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
helm_apply metallb metallb/metallb "$NS" --set frrk8s.enabled=false --set speaker.frr.enabled=false --set speaker.ignoreExcludeLB=true
kubectl -n "$NS" rollout status deploy/metallb-controller --timeout=300s
kubectl -n "$NS" rollout status ds/metallb-speaker --timeout=300s
POOL_START=$(subnet_ip 64) POOL_END=$(subnet_ip 79) envsubst < "$(dirname "$0")/pool.yaml" | kubectl apply -f -
