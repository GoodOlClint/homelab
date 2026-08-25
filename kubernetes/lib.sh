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
inf_host_api() { printf '%s/api' "$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$ROOT/ansible/group_vars/bootstrap.sops.yml")"; }
# Universal-auth JWT for the fleet machine identity (bootstrap.sops.yml creds).
inf_token() {
  local b="$ROOT/ansible/group_vars/bootstrap.sops.yml"
  curl -sfS -X POST "$(inf_host_api)/v1/auth/universal-auth/login" -H 'content-type: application/json' \
    -d "$(jq -n --arg id "$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$b")" \
                --arg s "$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$b")" '{clientId:$id,clientSecret:$s}')" | jq -r .accessToken
}
# Infisical read for the grandfathered ARC one-offs (ADR 0035: runtime secrets are InfisicalSecret CRDs).
inf_get() { # path key
  infisical secrets get "$2" --plain --env prod --projectId "$(inf_project_id)" --domain "$(inf_host_api)" --token "$(inf_token)" --path "$1"
}
# Fleet addresses for app configs: `export NAME=service_ip` per inventory guest (upper-snake), plus
# ADGUARD/BIND (the VIPs), SYNOLOGY, TZ, the ADR 0040 domains (SERVICE_DOMAIN = every app hostname,
# MEDIA_DOMAIN, INTERNAL_ZONES, HOST_ALIAS = home.<service domain>) and the legacy SERVICES_ZONE — eval the output.
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
print(f"export SERVICE_DOMAIN={net['service_domain']}")
print(f"export MEDIA_DOMAIN={net['media_domain']}")
print(f"export INTERNAL_ZONES='{' '.join(net['internal_zones'])}'")
print(f"export INTERNAL_ZONES_YAML='{', '.join(net['internal_zones'])}'")
print(f"export HOST_ALIAS=home.{net['service_domain']}")
print(f"export SERVICES_ZONE={net['vlans']['services']['domain_prefix']}.{net['domain_suffix']}")
PY
}
