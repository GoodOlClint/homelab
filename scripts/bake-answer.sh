#!/bin/bash
# Bake a proxmox-auto-install answer file for a node from its committed template.
#
# Injects site/secret bindings that are NOT committed (repo is public):
#   - root password hash  <- from bootstrap.sops.yml (proxmox_password, hashed here)
#   - fqdn/mailto/MAC/IP   <- from the gitignored network-data/local/host-bindings.yaml
#   - root SSH pubkey      <- from host-bindings.yaml (public key, but kept with the rest)
#
# Usage:  scripts/bake-answer.sh <node>            # -> terraform/hosts/answer-<node>.toml (gitignored)
#         scripts/bake-answer.sh <node> <base.iso> # also -> proxmox-auto-install-assistant prepare-iso
#
# Then:   proxmox-auto-install-assistant validate-answer terraform/hosts/answer-<node>.toml

set -euo pipefail

NODE="${1:?usage: bake-answer.sh <node> [base.iso]}"
BASE_ISO="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTS_DIR="$REPO_ROOT/terraform/hosts"
BOOTSTRAP="$REPO_ROOT/ansible/group_vars/bootstrap.sops.yml"
BINDINGS="$REPO_ROOT/network-data/local/host-bindings.yaml"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python3"

command -v sops >/dev/null || { echo "ERROR: sops not found"; exit 1; }
[ -x "$VENV_PYTHON" ] || { echo "ERROR: .venv not found (run: make init)"; exit 1; }
[ -f "$BINDINGS" ] || { echo "ERROR: $BINDINGS missing (copy network-data/host-bindings.example.yaml)"; exit 1; }

# Read a dotted path from the bindings YAML; scalars printed raw, lists as compact JSON.
yread() {
  "$VENV_PYTHON" -c '
import sys, json, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in sys.argv[2].split("."):
    d = (d or {}).get(p)
print("" if d is None else (json.dumps(d) if isinstance(d, (list, dict)) else d))' "$BINDINGS" "$1"
}

# MS-01 nodes share one template; pve has its own.
case "$NODE" in
  ms-01a|ms-01b) TMPL="$HOSTS_DIR/templates/answer-ms01.toml.tmpl" ;;
  msi|pve)       TMPL="$HOSTS_DIR/templates/answer-pve.toml.tmpl" ;;
  *) echo "ERROR: unknown node '$NODE' (expected ms-01a|ms-01b|msi)"; exit 1 ;;
esac
[ -f "$TMPL" ] || { echo "ERROR: template $TMPL missing"; exit 1; }

# Per-node bindings (gitignored).
b() { yread "nodes.${NODE}.$1"; }
FQDN=$(b fqdn); MAILTO=$(b mailto); MAC=$(b install_nic_mac)
CIDR=$(b install_cidr); GW=$(b install_gateway); SSHKEY=$(b root_ssh_key)
BOOT_DISK_MODEL=$(b boot_disk_model)
grep -q '@BOOT_DISK_MODEL@' "$TMPL" && [ -z "$BOOT_DISK_MODEL" ] && { echo "ERROR: binding 'boot_disk_model' empty for node '$NODE'"; exit 1; }
for v in FQDN MAILTO MAC CIDR GW SSHKEY; do
  [ -n "${!v}" ] || { echo "ERROR: binding '$v' empty for node '$NODE' in $BINDINGS"; exit 1; }
done

# Root password hash from the tier-1 secret (same password the provider authenticates with).
ROOT_PW=$(sops -d --extract '["bootstrap"]["proxmox_password"]' "$BOOTSTRAP")
[ -n "$ROOT_PW" ] && [ "$ROOT_PW" != "REPLACE_ME" ] || { echo "ERROR: bootstrap.proxmox_password not set"; exit 1; }
ROOT_HASH=$(printf '%s\n' "$ROOT_PW" | openssl passwd -6 -stdin)

# MAC with colons stripped, for the ID_NET_NAME_MAC glob filter.
MAC_NOSEP="${MAC//:/}"

# PXE first-boot hook (ADR 0026): cluster.pxe_url = http://<pxe service ip>.
# Empty = no hook (ISO/IDE-R fallback): the [first-boot] section is removed.
PXE_URL=$(yread cluster.pxe_url)

OUT="$HOSTS_DIR/answer-${NODE}.toml"
FQDN="$FQDN" MAILTO="$MAILTO" ROOT_HASH="$ROOT_HASH" SSHKEY="$SSHKEY" CIDR="$CIDR" GW="$GW" \
MAC_NOSEP="$MAC_NOSEP" BOOT_DISK_MODEL="$BOOT_DISK_MODEL" PXE_URL="$PXE_URL" \
"$VENV_PYTHON" -c 'import os, re, sys
tmpl, out = sys.argv[1], sys.argv[2]
s = open(tmpl).read()
for tag, var in [("FQDN", "FQDN"), ("MAILTO", "MAILTO"), ("ROOT_PW_HASH", "ROOT_HASH"), ("ROOT_SSH_KEY", "SSHKEY"),
                 ("INSTALL_CIDR", "CIDR"), ("INSTALL_GATEWAY", "GW"), ("INSTALL_NIC_MAC", "MAC_NOSEP"),
                 ("BOOT_DISK_MODEL", "BOOT_DISK_MODEL"), ("PXE_URL", "PXE_URL")]:
    s = s.replace("@%s@" % tag, os.environ[var])
if not os.environ["PXE_URL"]:
    s = re.sub(r"\n# First boot:.*?\[first-boot\]\n(?:.*\n)*?(?=\n\[|\Z)", "\n", s, flags=re.S)
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(s)
' "$TMPL" "$OUT"
echo "Baked $OUT"

if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  proxmox-auto-install-assistant validate-answer "$OUT" && echo "validate-answer: OK"
else
  echo "NOTE: proxmox-auto-install-assistant not on PATH — validate on a node before baking the ISO."
fi

if [ -n "$BASE_ISO" ]; then
  proxmox-auto-install-assistant prepare-iso "$BASE_ISO" \
    --fetch-from iso --answer-file "$OUT" \
    --output "$HOSTS_DIR/pve-autoinstall-${NODE}.iso"
  echo "ISO -> $HOSTS_DIR/pve-autoinstall-${NODE}.iso"
fi
