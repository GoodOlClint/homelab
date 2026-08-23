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
  helm template "$rel" "$chart" -n "$n" --include-crds "$@" | sed "/^Pulled: /d;/^Digest: /d" | kubectl apply --server-side --force-conflicts -f -
}

# Infisical read for one-off `kubectl create secret` paths (P3b; the general Infisical→k8s path is a P4 decision).
inf_get() { # path key
  local b="$ROOT/ansible/group_vars/bootstrap.sops.yml" dom cid csec proj tok
  dom="$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$b")/api"
  cid=$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$b")
  csec=$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$b")
  proj=$(sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$b")
  tok=$(infisical login --method=universal-auth --client-id="$cid" --client-secret="$csec" --domain="$dom" --silent --plain | tail -1)
  infisical secrets get "$2" --plain --env prod --projectId "$proj" --domain "$dom" --token "$tok" --path "$1"
}
