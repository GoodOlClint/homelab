# pfSense — CI VLAN rules (ADR 0032 / 0034, hand-managed per ADR 0005)

The `CI` interface (VLAN 60) exists with DHCP enabled and public DNS, but as of 2026-08-23 it carries **no firewall rules**, so every nested PVE guest the runners build is isolated from everything — including the runner that serves its answer file. Apply these on **Firewall → Rules → CI**, top to bottom (first match wins):

| # | Action | Proto | Source | Destination | Port | Why |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | CI net | `<services prefix>.61` (talos-cp-a) | 8000, 111, 2049, 3260 | answer server (8000), NFS (111/2049), iSCSI (3260) — the PSProxmoxVE storage containers run `--net=host` on the runner node |
| 2 | Block | any | CI net | `<internal supernet>` (the `/12` in `vlans.yaml`) | * | CI guests never reach the fleet, the nodes, or the workstation |
| 3 | Pass | any | CI net | any | * | internet (Debian/Proxmox repos, GitHub) |

Notes:
- Rule 1 must sit **above** rule 2. If the ARC scale set is ever re-pinned to another node (`kubernetes/arc/values-common.yaml` `nodeSelector`), update the destination.
- The Services VLAN already has a catch-all pass, so the runner → CI, runner → vlan30:8006 and runner → internet legs in ADR 0032 need no new rules.
- No inbound rule from any other VLAN into CI is required: the runner initiates to the nested guests (API :8006, SSH) and pf state handles the replies.
- Reaper: a CronJob in `arc-runners` (`kubernetes/arc/reaper.yaml`) destroys pool-`ci` guests older than 6 h; nothing on pfSense is involved.
