# Shared by kubernetes/*/deploy.sh: kubeconfig, nodes.json accessors, helm-template apply.
set -euo pipefail
K8S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$K8S/.." && pwd)"
export KUBECONFIG="$K8S/talos/.secrets/kubeconfig"
NODES="$K8S/talos/.secrets/nodes.json"
SECRETS="$K8S/.secrets"; mkdir -p "$SECRETS"
j() { jq -r "$1" "$NODES"; }
subnet_ip() { printf '%s.%s' "$(j .subnet | cut -d. -f1-3)" "$1"; }   # vlan40 offset -> address

ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
# ponytail: helm template | kubectl apply everywhere — helm's client cannot TLS-handshake this apiserver (ADR 0033).
helm_apply() { # release chart namespace [helm args...]
  local rel=$1 chart=$2 n=$3; shift 3
  helm template "$rel" "$chart" -n "$n" --include-crds "$@" | kubectl apply -n "$n" --server-side --force-conflicts -f -
}
