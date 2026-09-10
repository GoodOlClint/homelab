#!/bin/bash
# Ceph CSI (RBD) on the Talos cluster against the PVE Ceph pool (ADR 0033).
# Reads fsid, monitors and the client.csi-rbd key from the first cluster node
# at deploy time. `deploy.sh smoke` runs the PVC write/read probe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export KUBECONFIG="$ROOT/kubernetes/talos/.secrets/kubeconfig"
NODE=$(ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ansible-inventory -i "$ROOT/ansible/inventory/proxmox.yaml" --list | jq -r '.proxmox.hosts[0] as $h | ._meta.hostvars[$h].ansible_host')
NS=ceph-csi

smoke() {
  kubectl delete -f "$HERE/smoke.yaml" --ignore-not-found >/dev/null
  kubectl apply -f "$HERE/smoke.yaml"
  kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/rbd-smoke --timeout=120s
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/rbd-smoke --timeout=180s
  kubectl logs rbd-smoke | grep -q hello-rbd || { echo "rbd smoke: FAIL" >&2; exit 1; }
echo "rbd smoke: PASS"
  kubectl delete -f "$HERE/smoke.yaml" >/dev/null
}
[ "${1:-}" = smoke ] && { smoke; exit; }

read -r FSID MONS KEY < <(ssh "root@$NODE" 'printf "%s %s %s\n" "$(ceph fsid)" "$(ceph mon dump -f json 2>/dev/null | jq -r "[.mons[].public_addrs.addrvec[] | select(.type==\"v1\") | .addr] | join(\",\")")" "$(ceph auth get-key client.csi-rbd)"')
helm repo add ceph-csi https://ceph.github.io/csi-charts >/dev/null 2>&1 || true
helm repo update ceph-csi >/dev/null
# ponytail: helm template + kubectl apply, not helm upgrade — helm 4.2.4's
# client times out on the TLS handshake to this apiserver while kubectl is fine.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
helm template ceph-csi-rbd ceph-csi/ceph-csi-rbd -n "$NS" --include-crds \
  -f "$HERE/values.yaml" \
  --set-json "csiConfig=[{\"clusterID\":\"$FSID\",\"monitors\":$(jq -cn --arg m "$MONS" '$m | split(",")')}]" \
  | kubectl apply -n "$NS" -f -
kubectl -n "$NS" create secret generic csi-rbd-secret --from-literal=userID=csi-rbd --from-literal=userKey="$KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
# reclaimPolicy is immutable on a StorageClass: recreate it when the policy differs (existing PVs are
# untouched by that), then converge every ceph-rbd PV to Retain — a pruned or mis-deleted PVC must never
# take its Ceph image with it (ADR 0048). Rebind procedure: docs/ceph-rbd-static-pv.md.
if [ "$(kubectl get sc ceph-rbd -o jsonpath='{.reclaimPolicy}' 2>/dev/null)" = Delete ]; then kubectl delete sc ceph-rbd; fi
CLUSTER_ID="$FSID" envsubst < "$HERE/storageclass.yaml" | kubectl apply -f -
for pv in $(kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="ceph-rbd" and .spec.persistentVolumeReclaimPolicy=="Delete") | .metadata.name'); do
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null && echo "pv/$pv -> Retain"
done
kubectl -n "$NS" rollout status ds/ceph-csi-rbd-nodeplugin --timeout=300s
kubectl -n "$NS" rollout status deploy/ceph-csi-rbd-provisioner --timeout=300s
