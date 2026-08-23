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
  helm template "$rel" "$chart" -n "$n" --include-crds "$@" | sed "/^Pulled: /d;/^Digest: /d" | kubectl apply -n "$n" --server-side --force-conflicts -f -
}

inf_project_id() { sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$ROOT/ansible/group_vars/bootstrap.sops.yml"; }
# Infisical read for the grandfathered ARC one-offs (ADR 0035: runtime secrets are InfisicalSecret CRDs).
inf_get() { # path key
  local b="$ROOT/ansible/group_vars/bootstrap.sops.yml" dom cid csec proj tok
  dom="$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$b")/api"
  cid=$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$b")
  csec=$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$b")
  proj=$(sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$b")
  tok=$(infisical login --method=universal-auth --client-id="$cid" --client-secret="$csec" --domain="$dom" --silent --plain | tail -1)
  infisical secrets get "$2" --plain --env prod --projectId "$proj" --domain "$dom" --token "$tok" --path "$1"
}
inf_host_api() { printf '%s/api' "$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$ROOT/ansible/group_vars/bootstrap.sops.yml")"; }
# Fleet addresses for app configs: `export NAME=service_ip` per inventory guest (upper-snake), plus
# ADGUARD/BIND (the VIPs), SYNOLOGY, TZ and HOST_ALIAS (home.<services zone>) — eval the output.
inv_env() {
  "$ROOT/.venv/bin/python3" - "$ROOT" <<'PY'
import sys, yaml
r = sys.argv[1]
hosts = yaml.safe_load(open(f"{r}/ansible/inventory/vms.yaml"))["all"]["hosts"]
net = yaml.safe_load(open(f"{r}/network-data/vlans.yaml"))
g = yaml.safe_load(open(f"{r}/ansible/group_vars/all.yml"))
for h, v in hosts.items():
    print(f"export {h.upper().replace('-', '_')}={v['service_ip']}")
print(f"export PBS={hosts['proxmox-backup']['service_ip']}")
print(f"export ADGUARD={net['dns_server']['dns_ipv4']}")
print(f"export BIND={net['dns_server']['bind_ipv4']}")
print(f"export SYNOLOGY={g['synology_host']}")
print(f"export TZ={g['timezone']}")
print(f"export HOST_ALIAS=home.{net['vlans']['services']['domain_prefix']}.{net['domain_suffix']}")
PY
}
