#!/usr/bin/env bash
# Actions Runner Controller + per-repo scale sets (ADR 0032/0034). GitHub App
# creds come from Infisical /github-runner; the pool-scoped PVE token for the
# reaper from terraform/hosts. Runner pods are hostNetwork dind on talos-cp-a
# sharing one RWO cache PVC (PSProxmoxVE keeps tfstate + ISOs there across jobs).
source "$(dirname "$0")/../lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHARTS=oci://ghcr.io/actions/actions-runner-controller-charts
SYS=arc-systems; RUN=arc-runners

ns "$SYS"; ns "$RUN"
kubectl label namespace "$RUN" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
helm_apply arc "$CHARTS/gha-runner-scale-set-controller" "$SYS"
kubectl -n "$SYS" rollout status deploy/arc-gha-rs-controller --timeout=300s

if ! kubectl -n "$RUN" get secret github-app >/dev/null 2>&1; then
  kubectl -n "$RUN" create secret generic github-app \
    --from-literal=github_app_id="$(inf_get /github-runner github_app_id)" \
    --from-literal=github_app_installation_id="$(inf_get /github-runner github_app_installation_id)" \
    --from-literal=github_app_private_key="$(inf_get /github-runner github_app_private_key)"
fi
if ! kubectl -n "$RUN" get secret pve-ci-token >/dev/null 2>&1; then
  kubectl -n "$RUN" create secret generic pve-ci-token \
    --from-literal=token="$(cd "$ROOT/terraform/hosts" && terraform output -raw ci_api_token)"
fi
kubectl apply -f "$HERE/cache-pvc.yaml"
PVE_API=$(sed -n "s/^virtual_environment_endpoint *= *\"\([^\"]*\)\".*/\1/p" "$ROOT/terraform/vars.auto.tfvars") envsubst < "$HERE/reaper.yaml" | kubectl apply -f -

for set in psproxmoxve pbs-collection; do
  helm_apply "$set" "$CHARTS/gha-runner-scale-set" "$RUN" -f "$HERE/values-common.yaml" -f "$HERE/values-$set.yaml" \
    --set controllerServiceAccount.namespace="$SYS" --set controllerServiceAccount.name=arc-gha-rs-controller
done
kubectl -n "$RUN" get autoscalingrunnersets
