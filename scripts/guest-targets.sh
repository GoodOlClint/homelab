#!/usr/bin/env bash
# Resolve a guest's Terraform resource address(es) by name, VM-or-LXC aware (B2,
# audit 2026-08-10). The per-guest make targets previously hardcoded the VM
# resource path, so they could not build/rebuild the mostly-LXC target fleet.
#
# Usage: guest-targets.sh <guest-name> <mode>
#   address        -> the guest's resource address (vm OR container)
#   targets        -> full -target list for a staged build (network + guest +
#                     VM-only cloud-init files + HA resource when ha = true;
#                     LXCs configure via initialization{})
#   replace        -> -replace=<address> for rebuilds
#   group-targets  -> `targets` for EVERY config guest named <name> or <name><N>
#                     (redundancy pairs: adguard1/adguard2) — used by bootstrap
#                     so it tracks the WP4 numbered-instance convention.
#
# Resolution order: vm-configs.tf (the DESIRED type — authoritative, so a
# VM->LXC conversion resolves to the new container address, not the stale
# state entry) with terraform state as fallback for guests no longer in config.
# Conversion caveat: a targeted apply will not destroy the orphaned old-type
# resource (targets exclude it); the next full apply prunes it.
# The data-volume holder is never returned — rebuilds must not touch it
# (ADR 0015). Every failure exits non-zero: callers MUST abort on failure or an
# empty expansion turns a targeted apply into an unscoped fleet apply.
set -euo pipefail

NAME="${1:?usage: guest-targets.sh <guest-name> <address|targets|replace|group-targets>}"
MODE="${2:-address}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# Parse vm-configs.tf: emit "name type ha" for every guest block.
config_guests() {
  python3 - "$TF_DIR/vm-configs.tf" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
for m in re.finditer(r'\{[^{}]*?name\s*=\s*"([a-z0-9-]+)"', src):
    name = m.group(1)
    depth, i = 0, m.start()
    for j, ch in enumerate(src[i:], start=i):
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                block = src[i:j]
                break
    else:
        sys.exit("unbalanced braces parsing vm-configs.tf")
    t = re.search(r'\btype\s*=\s*"(vm|lxc)"', block)
    ha = re.search(r'\bha\s*=\s*true\b', block)
    print(name, t.group(1) if t else "vm", "ha" if ha else "-")
PY
}

vm_addr()  { echo "module.vms.proxmox_virtual_environment_vm.vms[\"$1\"]"; }
lxc_addr() { echo "module.vms.proxmox_virtual_environment_container.containers[\"$1\"]"; }

# resolve <name> -> sets guest_type + guest_ha, or returns 1
resolve() {
  local name="$1"
  guest_type=""
  guest_ha="-"
  local line
  if line=$(config_guests | awk -v n="$name" '$1 == n { print; exit }') && [[ -n "$line" ]]; then
    guest_type=$(awk '{print $2}' <<<"$line")
    guest_ha=$(awk '{print $3}' <<<"$line")
    return 0
  fi
  # Fallback: guest absent from config (being retired) — take the type from state.
  local state_list
  if state_list=$(cd "$TF_DIR" && terraform state list 2>/dev/null); then
    if grep -qF "$(vm_addr "$name")" <<<"$state_list"; then
      guest_type="vm"; return 0
    elif grep -qF "$(lxc_addr "$name")" <<<"$state_list"; then
      guest_type="lxc"; return 0
    fi
  fi
  echo "guest-targets.sh: guest '$name' not found in vm-configs.tf or terraform state" >&2
  return 1
}

emit_targets() {
  local name="$1" type="$2" ha="$3" addr
  [[ "$type" == "lxc" ]] && addr=$(lxc_addr "$name") || addr=$(vm_addr "$name")
  echo "-target=$addr"
  if [[ "$type" == "vm" ]]; then
    echo "-target=module.vms.proxmox_virtual_environment_file.user_data[\"$name\"]"
    echo "-target=module.vms.proxmox_virtual_environment_file.network_data[\"$name\"]"
  fi
  # -target pulls dependencies but NOT dependents — the HA registration must be
  # targeted explicitly or an ha=true guest builds unregistered (Codex P1).
  if [[ "$ha" == "ha" ]]; then
    echo "-target=module.vms.proxmox_virtual_environment_haresource.guests[\"$name\"]"
  fi
  # Reconcile type conversions and HA disables within the staged apply: if
  # state still holds the OPPOSITE-type resource (VM->LXC conversion) or an HA
  # registration the config no longer declares, target them too so they are
  # destroyed in the same run — otherwise the old VM squats on the VMID and the
  # LXC create fails (Codex P1, second review).
  local state_list
  if state_list=$(cd "$TF_DIR" && terraform state list 2>/dev/null); then
    if [[ "$type" == "lxc" ]] && grep -qF "$(vm_addr "$name")" <<<"$state_list"; then
      echo "-target=$(vm_addr "$name")"
      echo "-target=module.vms.proxmox_virtual_environment_file.user_data[\"$name\"]"
      echo "-target=module.vms.proxmox_virtual_environment_file.network_data[\"$name\"]"
    elif [[ "$type" == "vm" ]] && grep -qF "$(lxc_addr "$name")" <<<"$state_list"; then
      echo "-target=$(lxc_addr "$name")"
    fi
    if [[ "$ha" != "ha" ]] && grep -qF "proxmox_virtual_environment_haresource.guests[\"$name\"]" <<<"$state_list"; then
      echo "-target=module.vms.proxmox_virtual_environment_haresource.guests[\"$name\"]"
    fi
  fi
}

case "$MODE" in
  address)
    resolve "$NAME"
    [[ "$guest_type" == "lxc" ]] && lxc_addr "$NAME" || vm_addr "$NAME"
    ;;
  replace)
    resolve "$NAME"
    [[ "$guest_type" == "lxc" ]] && echo "-replace=$(lxc_addr "$NAME")" || echo "-replace=$(vm_addr "$NAME")"
    ;;
  targets)
    resolve "$NAME"
    echo "-target=module.network"
    emit_targets "$NAME" "$guest_type" "$guest_ha"
    ;;
  group-targets)
    matches=$(config_guests | awk -v n="$NAME" '$1 == n || $1 ~ "^" n "[0-9]+$" { print }')
    if [[ -z "$matches" ]]; then
      echo "guest-targets.sh: no config guest matches '$NAME' or '${NAME}<N>'" >&2
      exit 1
    fi
    echo "-target=module.network"
    while read -r name type ha; do
      emit_targets "$name" "$type" "$ha"
    done <<<"$matches"
    ;;
  *)
    echo "guest-targets.sh: unknown mode '$MODE'" >&2
    exit 2
    ;;
esac
