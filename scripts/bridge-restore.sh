#!/usr/bin/env bash
# Restore-bridge (ADR 0024/0027): restore one old-fleet VM from PBS onto a new
# cluster node, re-home its NICs from the old SDN VNETs onto the VLAN-aware
# vmbr0, stop the original on the old host, start the copy.
#
# Usage: scripts/bridge-restore.sh <vmid> <target-node-ip> <old-host-ip> [storage] [backup-storage]
#   target-node-ip : cluster node that receives the VM (restored onto `bridge`)
#   old-host-ip    : host still running the original (stopped + onboot 0 here)
#   backup-storage : where the backup lives (default pbs; the PBS guest itself is on nas-nfs)
#
# Needs root SSH to both. Snippets (cicustom) are synced from the old host first.
set -euo pipefail
VMID="${1:?vmid}"; NODE="${2:?target node ip}"; OLD="${3:?old host ip}"; STORAGE="${4:-bridge}"; SRC="${5:-pbs}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# VNET name -> VLAN id from the gitignored vlans.yaml (bridge: field = old SDN VNET).
read -r VNET_MAP JUMBO_VNET < <("$REPO_ROOT/.venv/bin/python3" - "$REPO_ROOT/network-data/vlans.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
vl = [v for v in d["vlans"].values() if v.get("bridge")]
print(",".join(f'{v["bridge"]}={v["id"]}' for v in vl), ",".join(v["bridge"] for v in vl if v.get("mtu") == 9000))
PY
)

ssh root@"$NODE" "qm status $VMID" >/dev/null 2>&1 && { echo "ERROR: VMID $VMID already exists on $NODE"; exit 1; }

echo ">> snippets: $OLD -> $NODE"
ssh root@"$NODE" "pvesm set local --content iso,backup,vztmpl,import,snippets >/dev/null 2>&1 || true; mkdir -p /var/lib/vz/snippets"
ssh root@"$OLD" "tar -C /var/lib/vz/snippets -cf - ." | ssh root@"$NODE" "tar -C /var/lib/vz/snippets -xf -"

SNAP=$(ssh root@"$NODE" "pvesm list $SRC" | awk -v v="$VMID" '($NF == v || $0 ~ ("vm/" v "/")) && /backup/ {print $1}' | sort | tail -1)
[ -n "$SNAP" ] || { echo "ERROR: no backup for VM $VMID on $SRC"; exit 1; }
echo ">> restore $SNAP -> $NODE:$STORAGE"
ssh root@"$NODE" "qmrestore '$SNAP' $VMID --storage $STORAGE --unique 0"

echo ">> re-home NICs onto vmbr0"
ssh root@"$NODE" "qm config $VMID" | grep -E '^net[0-9]+:' | while IFS= read -r line; do
  key="${line%%:*}"; val="${line#*: }"
  vnet=$(sed -n 's/.*bridge=\([^,]*\).*/\1/p' <<<"$val")
  tag=""; for kv in ${VNET_MAP//,/ }; do [ "${kv%%=*}" = "$vnet" ] && tag="${kv#*=}"; done
  if [ -n "$tag" ]; then
    new=$(sed -e "s/bridge=$vnet/bridge=vmbr0,tag=$tag/" -e 's/,tag=[0-9]*,tag=/,tag=/' <<<"$val")
    case ",$JUMBO_VNET," in *",$vnet,"*) new="$(sed -e 's/,mtu=[0-9]*//' <<<"$new"),mtu=9000" ;; esac
    echo "   $key: $val -> $new"
    ssh -n root@"$NODE" "qm set $VMID --$key '$new' >/dev/null"
  else
    echo "   $key: $val (left as is — no VLAN mapping for '$vnet')"
  fi
done
ssh -n root@"$NODE" "qm config $VMID | grep -q ^hostpci0 && qm set $VMID --delete hostpci0 >/dev/null && echo '   hostpci0 dropped (no GPU on this node)' || true"

echo ">> stop original on $OLD"
ssh root@"$OLD" "qm set $VMID --onboot 0 >/dev/null; qm status $VMID | grep -q running && qm shutdown $VMID --timeout 120 || true; qm status $VMID"

echo ">> start $VMID on $NODE"
ssh root@"$NODE" "qm set $VMID --onboot 1 >/dev/null; qm start $VMID"
echo "done: VM $VMID now on $NODE (original stopped on $OLD)"
