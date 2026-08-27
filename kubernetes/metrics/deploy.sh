#!/usr/bin/env bash
# Cluster metrics API. Talos calls --kubelet-insecure-tls unsuitable for production,
# so kubelet serves a CA-signed cert (rotate-server-certificates in talos.sh) and this
# approver signs the CSR — nothing built into Kubernetes approves kubelet-serving CSRs.
# Installing it also creates system:aggregated-metrics-reader, which is what grants the
# `view` ClusterRole (and so Headlamp) access to metrics.k8s.io.
source "$(dirname "$0")/../lib.sh"
NS=kube-system
HERE="$(cd "$(dirname "$0")" && pwd)"
export REGISTRY="registry.$(j .domain)"

helm repo add postfinance https://postfinance.github.io/kubelet-csr-approver >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update postfinance metrics-server >/dev/null 2>&1 || true

helm_apply kubelet-csr-approver postfinance/kubelet-csr-approver "$NS" -f <(envsubst < "$HERE/values-approver.yaml")
kubectl -n "$NS" rollout status deploy/kubelet-csr-approver --timeout=300s
helm_apply metrics-server metrics-server/metrics-server "$NS" -f <(envsubst < "$HERE/values-metrics-server.yaml")
kubectl -n "$NS" rollout status deploy/metrics-server --timeout=300s
kubectl top nodes
