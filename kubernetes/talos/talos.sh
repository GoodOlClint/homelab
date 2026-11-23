#!/bin/bash
# /bin/bash, not env bash: homebrew bash 5.3.15 deadlocks in this script's render()
# heredoc (blocked in heredoc_write); macOS system bash 3.2 and Linux bash run it fine.
# Talos lifecycle (ADR 0033) for both clusters (ADR 0063). CLUSTER=services (default) or ci
# selects the inventory (<secrets dir>/nodes.json from `make talos-build CLUSTER=…`), the
# secrets directory and the Infisical folder (/talos, /talos-ci). Subcommands:
#   secrets   pull secrets.yaml + talosconfig from Infisical (generate + store on first run)
#   apply     render per-node configs and apply-config (maintenance nodes via DHCP, then by static IP)
#   bootstrap bootstrap etcd on the first control-plane node, fetch kubeconfig, wait for Ready
#   render    render per-node configs into the secrets directory, apply nothing
#   close-join (ci) rotate the join token so only the control plane holds a valid one
#   print     print what CLUSTER resolves to, write nothing
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER=${CLUSTER:-services}
case "$CLUSTER" in
  services) TALOS_CLUSTER=homelab; SEC="$HERE/.secrets"; INF_PATH=/talos ;;
  ci) TALOS_CLUSTER=ci; SEC="$HERE/.secrets/ci"; INF_PATH=/talos-ci ;;
  *) echo "unknown CLUSTER '$CLUSTER' (services|ci)" >&2; exit 2 ;;
esac
NODES="$SEC/nodes.json"
BOOTSTRAP="$ROOT/ansible/group_vars/bootstrap.sops.yml"
# Pinned like the Talos image (ADR 0016): a newer talosctl client defaults to a
# Kubernetes too new for the running Talos; rolls with `talosctl upgrade-k8s`.
K8S_VERSION=1.36.2
export TALOSCONFIG="$SEC/talosconfig"

need() { for c in "$@"; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done; }
j() { jq -r "$1" "$NODES"; }
ip_of() { j ".nodes[\"$1\"] | .services_ip // .ip"; }
role_of() { j ".nodes[\"$1\"].role // \"controlplane\""; }

# The services inventory (talos_nodes output) carries no cluster or role field: absent = services, controlplane.
load_inventory() {
  [ -f "$NODES" ] || { echo "run make talos-build CLUSTER=$CLUSTER first" >&2; exit 1; }
  jq -e '.nodes | length > 0' "$NODES" >/dev/null 2>&1 || { echo "$NODES lists no nodes (for ci: is ci_runner in vlans.yaml?)" >&2; exit 1; }
  local recorded n
  recorded=$(j '.cluster // "services"')
  [ "$recorded" = "$CLUSTER" ] || { echo "$NODES is the '$recorded' inventory, not '$CLUSTER'" >&2; exit 1; }
  VIP=$(j '.api_vip // empty'); GW=$(j .gateway); PLEN=$(j .prefix_len); SUBNET=$(j .subnet)
  SCHEMATIC=$(j .schematic); VERSION=$(j .version)
  NODE_NAMES=${NODE_NAMES:-$(j '.nodes | keys[]')}
  for n in $NODE_NAMES; do
    jq -e --arg n "$n" '.nodes | has($n)' "$NODES" >/dev/null || { echo "$n is not a $CLUSTER node" >&2; exit 1; }
  done
  CP_NAMES=$(for n in $NODE_NAMES; do [ "$(role_of "$n")" = controlplane ] && echo "$n"; done || true)
  local ep=$VIP
  [ -n "$ep" ] || ep=$(ip_of "$(j '[.nodes | to_entries[] | select((.value.role // "controlplane") == "controlplane") | .key][0]')")
  ENDPOINT="https://$ep:6443"
}

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
inf() { infisical "$@" --env prod --projectId "$PROJECT" --domain "$DOMAIN" --token "$TOKEN" --path "$INF_PATH"; }

cmd_secrets() {
  infisical_token
  local existing rc
  existing=$(inf secrets get talos_secrets_yaml --plain 2>"$SEC/.inf.err") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -qi 'not found' "$SEC/.inf.err"; then
    echo "infisical read of $INF_PATH/talos_secrets_yaml failed (rc=$rc) — refusing to generate over a possibly live cluster PKI" >&2
    cat "$SEC/.inf.err" >&2; exit 1
  fi
  if [ -z "$existing" ]; then
    echo "generating cluster secrets -> Infisical $INF_PATH"
    infisical secrets folders create --name "${INF_PATH#/}" --path / --env prod --projectId "$PROJECT" --domain "$DOMAIN" --token "$TOKEN" >/dev/null 2>&1 || true
    talosctl gen secrets -o "$SEC/secrets.yaml" --force
    talosctl gen config "$TALOS_CLUSTER" "$ENDPOINT" --with-secrets "$SEC/secrets.yaml" \
      --output-types talosconfig -o "$SEC/talosconfig" --force
    inf secrets set "talos_secrets_yaml=$(base64 < "$SEC/secrets.yaml")" "talosconfig=$(base64 < "$SEC/talosconfig")" >/dev/null
  else
    printf '%s' "$existing" | base64 -d > "$SEC/secrets.yaml"
    inf secrets get talosconfig --plain | base64 -d > "$SEC/talosconfig"
  fi
  chmod 600 "$SEC"/secrets.yaml "$SEC"/talosconfig
  echo "secrets in $SEC"
}

patch_services() {
  local n=$1 x
  x=$(jq -c --arg n "$n" '.nodes[$n] + {dns: .dns_servers[0]}' "$NODES")
  local smac cmac sip cip dns
  smac=$(jq -r .services_mac <<<"$x"); cmac=$(jq -r .ceph_mac <<<"$x")
  sip=$(jq -r .services_ip <<<"$x"); cip=$(jq -r .ceph_ip <<<"$x"); dns=$(jq -r .dns <<<"$x")
  cat > "$SEC/$n.patch.yaml" <<YAML
machine:
  kubelet:
    # Kubelet serves a CA-signed cert instead of a self-signed one, so metrics-server
    # verifies it rather than running --kubelet-insecure-tls. Needs the CSR approver:
    # nothing built into Kubernetes approves kubelet-serving CSRs.
    extraArgs:
      rotate-server-certificates: "true"
    nodeIP:
      validSubnets: [$SUBNET]
  disks:
    - device: /dev/vdb
      partitions:
        - mountpoint: /var/mnt/scratch
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
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
---
apiVersion: v1alpha1
kind: HostnameConfig
\$patch: delete
YAML
}

# One NIC, no VIP, no Ceph leg, etcd metrics left on localhost. No rotate-server-certificates:
# the ci cluster runs no kubelet-serving CSR approver, so the kubelet would never get a cert.
patch_ci() {
  local n=$1 role=$2 p="$SEC/$1.patch.yaml" mac ip dns scratch
  mac=$(j ".nodes[\"$n\"].mac"); ip=$(ip_of "$n"); dns=$GW   # pfSense's resolver on the VLAN (ADR 0064)
  scratch=$(j ".nodes[\"$n\"].scratch_gb // 0")
  cat > "$p" <<YAML
machine:
  kubelet:
    nodeIP:
      validSubnets: [$SUBNET]
  network:
    hostname: $n
    nameservers: [$dns]
    interfaces:
      - deviceSelector: {hardwareAddr: "$mac"}
        dhcp: false
        addresses: [$ip/$PLEN]
        routes: [{network: 0.0.0.0/0, gateway: $GW}]
YAML
  if [ "$scratch" -gt 0 ]; then
    cat >> "$p" <<YAML
  disks:
    - device: /dev/vdb
      partitions:
        - mountpoint: /var/mnt/scratch
YAML
  fi
  if [ "$role" = controlplane ]; then
    cat >> "$p" <<YAML
cluster:
  etcd:
    advertisedSubnets: [$SUBNET]
YAML
  fi
  cat >> "$p" <<'YAML'
---
apiVersion: v1alpha1
kind: HostnameConfig
$patch: delete
YAML
  # The worker runs job code (ADR 0062): from it, the control plane answers only the Talos
  # and Kubernetes APIs. etcd and the kubelet stay reachable from the node's own address.
  if [ "$role" = controlplane ]; then
    cat >> "$p" <<YAML
---
apiVersion: v1alpha1
kind: NetworkDefaultActionConfig
ingress: block
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: talos-and-kubernetes-api
portSelector:
  ports: [6443, 50000, 50001]
  protocol: tcp
ingress:
  - subnet: 0.0.0.0/0
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: flannel-vxlan
portSelector:
  ports: [4789]
  protocol: udp
ingress:
  - subnet: $SUBNET
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: etcd-and-kubelet-self
portSelector:
  ports: [2379, 2380, 10250]
  protocol: tcp
ingress:
  - subnet: $ip/32
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: host-dns-from-pods
portSelector:
  ports: [53]
  protocol: udp
ingress:
  - subnet: 10.0.0.0/8
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: host-dns-from-pods-tcp
portSelector:
  ports: [53]
  protocol: tcp
ingress:
  - subnet: 10.0.0.0/8
YAML
  fi
}

render() {
  local n=$1 f="$SEC/$1.yaml" role
  role=$(role_of "$n")
  if [ "$CLUSTER" = services ]; then patch_services "$n"; else patch_ci "$n" "$role"; fi
  local trust=()
  if [ "$CLUSTER" = services ] && [ -f "$HERE/../.secrets/homelab-ca.crt" ]; then   # internal CA for the Zot registry (ADR 0034)
    printf 'machine:\n  registries:\n    config:\n      registry.%s:\n        tls:\n          ca: %s\n' \
      "$(j .domain)" "$(base64 < "$HERE/../.secrets/homelab-ca.crt" | tr -d '\n')" > "$SEC/trust.patch.yaml"
    trust=(--config-patch "@$SEC/trust.patch.yaml")
  fi
  talosctl gen config "$TALOS_CLUSTER" "$ENDPOINT" --with-secrets "$SEC/secrets.yaml" \
    --talos-version "$VERSION" --kubernetes-version "$K8S_VERSION" \
    --install-image "factory.talos.dev/nocloud-installer/$SCHEMATIC:$VERSION" \
    --config-patch "@$HERE/patches/common.yaml" --config-patch "@$SEC/$n.patch.yaml" ${trust[@]+"${trust[@]}"} \
    --output-types "$role" -o "$f" --force >/dev/null
  echo "$f"
}

cmd_render() {
  [ -f "$SEC/secrets.yaml" ] || { echo "no $SEC/secrets.yaml — make talos-secrets CLUSTER=$CLUSTER" >&2; exit 1; }
  for n in $NODE_NAMES; do render "$n"; done
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
      [ -n "$dhcp" ] || { echo "$n: no DHCP address in $NODES — re-run make talos-build CLUSTER=$CLUSTER" >&2; exit 1; }
      echo "$n: maintenance mode at $dhcp -> $ip"
      for i in $(seq 36); do   # the DHCP lease shows before the maintenance API listens
        talosctl -n "$dhcp" -e "$dhcp" apply-config --insecure -f "$f" && break
        [ "$i" = 36 ] && { echo "$n: maintenance API at $dhcp never answered" >&2; exit 1; }; sleep 5
      done
    fi
  done
  echo "waiting for Talos API on static addresses"
  for n in $NODE_NAMES; do
    ip=$(ip_of "$n")
    for i in $(seq 120); do talosctl -n "$ip" -e "$ip" version --short >/dev/null 2>&1 && break; [ "$i" = 120 ] && { echo "$n: Talos API at $ip not up after 10 min" >&2; exit 1; }; sleep 5; done
    echo "$n up"
  done
  if [ "$CLUSTER" = ci ] && [ -f "$SEC/kubeconfig" ] && [ "$NODE_NAMES" != "$CP_NAMES" ]; then cmd_close_join; fi
}

cmd_bootstrap() {
  local first ip eps=()
  [ -n "$CP_NAMES" ] || { echo "no control-plane node in NODE_NAMES" >&2; exit 1; }
  first=$(echo "$CP_NAMES" | head -1); ip=$(ip_of "$first")
  for n in $CP_NAMES; do eps+=("$(ip_of "$n")"); done
  talosctl config endpoint "${eps[@]}"
  talosctl config node "$ip"
  # `etcd members` blocks on an unbootstrapped node; the service state does not.
  local etcd_state
  etcd_state=$(talosctl -n "$ip" service etcd 2>/dev/null || true)
  if grep -q "STATE *Preparing" <<<"$etcd_state"; then
    echo "bootstrapping etcd on $first"
    talosctl -n "$ip" bootstrap
  fi
  talosctl -n "$ip" health --wait-timeout 10m
  talosctl -n "$ip" kubeconfig "$SEC/kubeconfig" --force
  echo "export KUBECONFIG=$SEC/kubeconfig"
  KUBECONFIG="$SEC/kubeconfig" kubectl get nodes -o wide
  talosctl -n "$ip" etcd members
  if [ "$CLUSTER" = ci ]; then cmd_close_join; fi
}

# The CI worker runs job code, and a valid join token lets its holder enrol as any node,
# the control plane included (the nodeclient CSR auto-approval is not name-bound). Once every
# node is Ready, rotate the token in the bundle, give the new one to the control plane only,
# and delete every other bootstrap-token Secret: the worker keeps a dead token. Talos only
# creates missing manifests, so a deleted token Secret does not come back.
cmd_close_join() {
  [ "$CLUSTER" = ci ] || { echo "close-join is for CLUSTER=ci only" >&2; exit 2; }
  local kc="$SEC/kubeconfig" new id n cps all stale old code
  [ -f "$kc" ] || { echo "no $kc — make talos-bootstrap CLUSTER=ci first" >&2; exit 1; }
  all=$(j '.nodes | keys[]')
  cps=$(j '[.nodes | to_entries[] | select((.value.role // "controlplane") == "controlplane") | .key][]')
  for n in $all; do   # a rebuilt node has no Node object until its kubelet registers
    for i in $(seq 120); do KUBECONFIG="$kc" kubectl get node "$n" >/dev/null 2>&1 && break
      [ "$i" = 120 ] && { echo "$n never registered" >&2; exit 1; }; sleep 5; done
    KUBECONFIG="$kc" kubectl wait --for=condition=Ready "node/$n" --timeout=10m
  done
  old=$(KUBECONFIG="$kc" kubectl -n kube-system get secret --field-selector type=bootstrap.kubernetes.io/token \
    -o go-template='{{range .items}}{{index .data "token-id" | base64decode}}.{{index .data "token-secret" | base64decode}}{{"\n"}}{{end}}')
  new="$(openssl rand -hex 3).$(openssl rand -hex 8)"; id=${new%%.*}
  NEW_TOKEN="$new" perl -pi -e 's/^(\s+bootstraptoken:\s+).*/$1$ENV{NEW_TOKEN}/' "$SEC/secrets.yaml"
  infisical_token
  inf secrets set "talos_secrets_yaml=$(base64 < "$SEC/secrets.yaml")" >/dev/null
  for n in $cps; do talosctl -n "$(ip_of "$n")" -e "$(ip_of "$n")" apply-config -f "$(render "$n")"; done
  for i in $(seq 60); do KUBECONFIG="$kc" kubectl -n kube-system get secret "bootstrap-token-$id" >/dev/null 2>&1 && break
    [ "$i" = 60 ] && { echo "bootstrap-token-$id never appeared; old tokens left in place" >&2; exit 1; }; sleep 5; done
  stale=$(KUBECONFIG="$kc" kubectl -n kube-system get secret -o name --field-selector type=bootstrap.kubernetes.io/token)
  stale=$(grep -v "/bootstrap-token-$id\$" <<<"$stale" || true)
  [ -z "$stale" ] || KUBECONFIG="$kc" kubectl -n kube-system delete $stale
  for t in $old; do
    for i in $(seq 24); do   # the API server restarts on the new config and drops deleted tokens from its cache
      code=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" "$ENDPOINT/api" || true)
      [ "$code" = 401 ] && break; sleep 5
    done
    [ "$code" = 401 ] || { echo "join token ${t%%.*} still authenticates (HTTP $code)" >&2; exit 1; }
    echo "join token ${t%%.*} rejected (401)"
  done
  for i in $(seq 60); do KUBECONFIG="$kc" kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 5; done
  echo "join closed: bootstrap-token-$id is held by the control plane only"
}

cmd_print() {
  echo "cluster:        $CLUSTER"
  echo "talos cluster:  $TALOS_CLUSTER"
  echo "inventory:      $NODES"
  echo "secrets dir:    $SEC"
  echo "infisical path: $INF_PATH"
  echo "talosconfig:    $TALOSCONFIG"
  echo "kubeconfig:     $SEC/kubeconfig"
  if [ -f "$NODES" ]; then
    load_inventory
    echo "endpoint:       $ENDPOINT"
    echo "nodes:          $(echo "$NODE_NAMES" | tr '\n' ' ')"
  else
    echo "endpoint:       (no inventory yet)"
  fi
}

case "${1:-}" in
  print) need jq; cmd_print; exit 0 ;;
  secrets|apply|bootstrap|render|close-join) need talosctl kubectl jq sops infisical; load_inventory ;;
  *) echo "usage: CLUSTER={services|ci} $0 {secrets|apply|bootstrap|render|close-join|print}" >&2; exit 2 ;;
esac
case "$1" in
  secrets) cmd_secrets ;;
  apply) cmd_apply ;;
  bootstrap) cmd_bootstrap ;;
  render) cmd_render ;;
  close-join) cmd_close_join ;;
esac
