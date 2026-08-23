#!/usr/bin/env bash
# Talos control-plane lifecycle (ADR 0033). Inputs: .secrets/nodes.json from
# `make talos-build`; cluster secrets in Infisical /talos. Subcommands:
#   secrets   pull secrets.yaml + talosconfig from Infisical (generate + store on first run)
#   apply     render per-node configs and apply-config (maintenance nodes via DHCP, then by static IP)
#   bootstrap bootstrap etcd on the first node, fetch kubeconfig, wait for Ready
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEC="$HERE/.secrets"
NODES="$SEC/nodes.json"
BOOTSTRAP="$ROOT/ansible/group_vars/bootstrap.sops.yml"
CLUSTER=homelab
export TALOSCONFIG="$SEC/talosconfig"

need() { for c in "$@"; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done; }
need talosctl kubectl jq sops infisical
[ -f "$NODES" ] || { echo "run make talos-build first" >&2; exit 1; }

j() { jq -r "$1" "$NODES"; }
VIP=$(j .api_vip); GW=$(j .gateway); PLEN=$(j .prefix_len); SUBNET=$(j .subnet)
SCHEMATIC=$(j .schematic); VERSION=$(j .version)
NODE_NAMES=$(j '.nodes | keys[]')
ip_of() { j ".nodes[\"$1\"].services_ip"; }

infisical_token() {
  local dom cid csec
  dom="$(sops -d --extract '["bootstrap_config"]["infisical_url"]' "$BOOTSTRAP")/api"
  cid=$(sops -d --extract '["bootstrap"]["infisical_client_id"]' "$BOOTSTRAP")
  csec=$(sops -d --extract '["bootstrap"]["infisical_client_secret"]' "$BOOTSTRAP")
  PROJECT=$(sops -d --extract '["bootstrap_config"]["infisical_project_id"]' "$BOOTSTRAP")
  DOMAIN="$dom"
  TOKEN=$(infisical login --method=universal-auth --client-id="$cid" --client-secret="$csec" --domain="$dom" --silent --plain | tail -1)
  [ -n "$TOKEN" ] || { echo "infisical login failed" >&2; exit 1; }
}
inf() { infisical "$@" --env prod --projectId "$PROJECT" --domain "$DOMAIN" --token "$TOKEN" --path /talos; }

cmd_secrets() {
  infisical_token
  local existing
  existing=$(inf secrets get talos_secrets_yaml --plain 2>/dev/null || true)
  if [ -z "$existing" ]; then
    echo "generating cluster secrets -> Infisical /talos"
    infisical secrets folders create --name talos --path / --env prod --projectId "$PROJECT" --domain "$DOMAIN" --token "$TOKEN" >/dev/null 2>&1 || true
    talosctl gen secrets -o "$SEC/secrets.yaml" --force
    talosctl gen config "$CLUSTER" "https://$VIP:6443" --with-secrets "$SEC/secrets.yaml" \
      --output-types talosconfig -o "$SEC/talosconfig" --force
    inf secrets set "talos_secrets_yaml=$(base64 < "$SEC/secrets.yaml")" "talosconfig=$(base64 < "$SEC/talosconfig")" >/dev/null
  else
    printf '%s' "$existing" | base64 -d > "$SEC/secrets.yaml"
    inf secrets get talosconfig --plain | base64 -d > "$SEC/talosconfig"
  fi
  chmod 600 "$SEC"/secrets.yaml "$SEC"/talosconfig
  echo "secrets in $SEC"
}

render() {
  local n=$1 f="$SEC/$1.yaml" x
  x=$(jq -c --arg n "$n" '.nodes[$n] + {dns: .dns_servers[0]}' "$NODES")
  local smac cmac sip cip dns
  smac=$(jq -r .services_mac <<<"$x"); cmac=$(jq -r .ceph_mac <<<"$x")
  sip=$(jq -r .services_ip <<<"$x"); cip=$(jq -r .ceph_ip <<<"$x"); dns=$(jq -r .dns <<<"$x")
  cat > "$SEC/$n.patch.yaml" <<YAML
machine:
  kubelet:
    nodeIP:
      validSubnets: [$SUBNET]
  network:
    hostname: $n
    nameservers: [$dns]
    interfaces:
      - deviceSelector: {hardwareAddr: "$smac"}
        dhcp: false
        addresses: [$sip/$PLEN]
        routes: [{network: 0.0.0.0/0, gateway: $GW}]
        vip: {ip: $VIP}
      - deviceSelector: {hardwareAddr: "$cmac"}
        dhcp: false
        mtu: 9000
        addresses: [$cip/$PLEN]
cluster:
  etcd:
    advertisedSubnets: [$SUBNET]
---
apiVersion: v1alpha1
kind: HostnameConfig
\$patch: delete
YAML
  talosctl gen config "$CLUSTER" "https://$VIP:6443" --with-secrets "$SEC/secrets.yaml" \
    --install-image "factory.talos.dev/nocloud-installer/$SCHEMATIC:$VERSION" \
    --config-patch "@$HERE/patches/common.yaml" --config-patch "@$SEC/$n.patch.yaml" \
    --output-types controlplane -o "$f" --force >/dev/null
  echo "$f"
}

cmd_apply() {
  [ -f "$SEC/secrets.yaml" ] || cmd_secrets
  for n in $NODE_NAMES; do
    local f ip dhcp
    f=$(render "$n"); ip=$(ip_of "$n")
    if talosctl -n "$ip" -e "$ip" version --short >/dev/null 2>&1; then
      echo "$n: configured, re-applying at $ip"
      talosctl -n "$ip" -e "$ip" apply-config -f "$f"
    else
      dhcp=$(jq -r --arg n "$n" '.nodes[$n].dhcp_ips | flatten | map(select(startswith("127")|not)) | .[0] // empty' "$NODES")
      [ -n "$dhcp" ] || { echo "$n: no DHCP address in nodes.json — re-run make talos-build" >&2; exit 1; }
      echo "$n: maintenance mode at $dhcp -> $ip"
      talosctl -n "$dhcp" -e "$dhcp" apply-config --insecure -f "$f"
    fi
  done
  echo "waiting for Talos API on static addresses"
  for n in $NODE_NAMES; do
    ip=$(ip_of "$n"); until talosctl -n "$ip" -e "$ip" version --short >/dev/null 2>&1; do sleep 5; done; echo "$n up"
  done
}

cmd_bootstrap() {
  local first ip
  first=$(echo "$NODE_NAMES" | head -1); ip=$(ip_of "$first")
  talosctl config endpoint $(for n in $NODE_NAMES; do ip_of "$n"; done)
  talosctl config node "$ip"
  # `etcd members` blocks on an unbootstrapped node; the service state does not.
  if talosctl -n "$ip" service etcd 2>/dev/null | grep -q "STATE *Preparing"; then
    echo "bootstrapping etcd on $first"
    talosctl -n "$ip" bootstrap
  fi
  talosctl -n "$ip" health --wait-timeout 10m
  talosctl -n "$ip" kubeconfig "$SEC/kubeconfig" --force
  echo "export KUBECONFIG=$SEC/kubeconfig"
  KUBECONFIG="$SEC/kubeconfig" kubectl get nodes -o wide
  talosctl -n "$ip" etcd members
}

case "${1:-}" in
  secrets) cmd_secrets ;;
  apply) cmd_apply ;;
  bootstrap) cmd_bootstrap ;;
  *) echo "usage: $0 {secrets|apply|bootstrap}" >&2; exit 2 ;;
esac
