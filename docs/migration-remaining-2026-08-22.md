# Migration — what is left (snapshot 2026-08-22)

Sources: [ms01-cluster-iac-plan.md](ms01-cluster-iac-plan.md), [rebuild-as-routine-design.md](rebuild-as-routine-design.md), live `pvesh` guest list on the cluster, session memory, and prior chat transcripts (2026-07-13 → 2026-08-21).

## Where we are

Days 0–3 are done: 3-node PVE 9 cluster + Ceph (8 OSDs, HEALTH_OK), VIP, restore-bridge retired, fleet on `ceph-rbd`. Greenfield-replace (ADR 0028) is most of the way through.

| Guest | Final form | Status |
|---|---|---|
| homepage 211 | LXC | DONE 08-20 |
| infisical 205 | VM | DONE 08-21 |
| adguard1/2 251/252 | LXC pair + VIP | DONE 08-21 |
| dns1/dns2 218/219 | LXC pair + VIP | DONE 08-21 |
| unifi 200 | VM | DONE 08-21 |
| plex 208 | LXC + iGPU + data vol | DONE 08-21 |
| plex-services 206 | docker-LXC + data vol | DONE 08-21 |
| openobserve 203 | docker-LXC + data vol | DONE 08-21 |
| proxmox-backup 201 | VM, PBS 4 / Debian 13 | DONE 08-21 |
| docker 204 | docker-LXC + data vol | DONE 08-21 (valheim-status PlayFab pin still open) |

## Remaining — in the plan

### A. Greenfield-replace, still pending (restored copies still running)

| Guest | Live VMID | Target | Notes |
|---|---|---|---|
| github-runner | 113 (running, restored shape) | VM 213, single-homed vlan40 | stateless (class S) |
| mcp | 115 (running) | LXC 215 | matrix says "verify stateless at rebuild; promote to V if ChromaDB state matters" |
| apt-cache | 116 (running) | 216 | built 08-11 pre-cutover in old shape; client half (`Proxy-Auto-Detect` drop-in) still NOT wired fleet-wide (ADR 0021 follow-on) |
| pxe | 117 (running) | 217 | built pre-cutover; same re-home |
| minio | not restored (old 112) | LXC + data vol, `mc mirror` carry | inventory bucket contents first; ADR 0022 flagged it for possible retirement — decide |
| doge | not restored | LXC + data vol | dogecoin node was dropped from docker 204 (f70e0ce) — confirm it is retired, not just deferred |

### B. Decommission sweep (after a week of stable replacements)
**RUN 2026-08-25:** `qm destroy <id> --purge 1 --destroy-unreferenced-disks 1` (105 unprotected first) for 101–109, 111, 113–117 and `pct destroy` for the retired docker-LXCs 203/204/206/211 — the holder volumes `vm-900-disk-1/2/3` they mounted were skipped by ownership and `rbd ls` still lists `vm-900-disk-0..4`; no terraform-state, HA, replication or backup-job reference existed for any of them (`nightly-fleet`/`pbs-self` unchanged). **Left: 100 (restored unifi, stopped)** — the operator's `qm destroy 100 --purge 1 --destroy-unreferenced-disks 1` on ms-01a; `rbd -p ceph-rbd ls | grep vm-100-` = 0 afterwards. PBS snapshots for the swept VMIDs (plus 112 minio and the W-rehearsal 1000) were deliberately kept — retention review is a separate decision.
- Stopped restored copies: 100, 101, 102, 103, 104, 105, 106, 108, 109, 111 — `qm destroy` + PBS retention review.
- Retired for good: nvidia-licensing 107, squid 114 (still in `vm-configs.tf` and `backup_jobs` vmids), lancache 110 (ADR 0021; VM def + role + NFS share + AdGuard/homepage refs).
- `backup_jobs` vmids still list 113/114/115/116/117 — re-author as the replacements land; apply has NOT been run since the VMID moves (memory: "backup_jobs still NOT applied").

### C. Day 3+ items from the sequencing table
| Item | State |
|---|---|
| **HA resources** | not started; plex can land on any node (iGPU by PCI path, 4ec8bb0); LLM VM must pin to msi |
| **LLM VM** (vfio passthrough of the RTX 5000 on msi, data vol for model cache) | not started; blocked on msi RMA chip swap (turbo-capped now) |
| **PDM VM** (see D) | not started |
| **monitoring per-node** (node exporters / Ceph metrics into Prometheus) | not started |
| **WP8 PKI + certs** (Infisical PKI gate → node ACME + `cert_client` role + LE wildcard) | not started |
| **WP7 docs** (README prerequisites, CLAUDE.md LXC conventions) | partial — CLAUDE.md is current; README make-target table not audited |
| **Worklab folds in** as non-voting compute-only member (ADR 0009) | parked; prereq = Ceph-server eligibility gate in `proxmox_host` |
| **msi SB conversion + ms-01a SB conversion** | ms-01b proven; a + msi pending (msi at RMA swap) |

### D. Open items list (plan §Open items)
- **pfSense DHCP DDNS** — every scope has empty `ddnsdomain*`; nothing registers leases. Server side proven. Manual pfSense step.
- **PTR zones + `use_dns(yes)` on the axosyslog netconsole source** — PTR records exist via DDNS now only for registered leases; static fleet PTRs need generating from inventory.
- **ADR 0021 client wiring** — `apt-proxy-detect.sh.j2` rendered by no task; `apt_cache_proxy_host` undefined.
- **Secure Boot** — stays off fleet-wide until converted.
- BOINC: resolved (decommissioned 08-21).
- ring1 / PCIe lane items: resolved.

## Remaining — discussed in chat, not (fully) in the plan

| Service | Where discussed | Decision state | Plan coverage |
|---|---|---|---|
| **Proxmox Datacenter Manager VM** — single pane over the cluster + standalone worklab | plan §Decisions locked ("Management pane"), ADR 0001/0009, 2026-08-19 session ("I thought we were going to use PDM instead of a VIP?") | decided as a guest; shape: VM, class S, hand-rolled (no collection — modernization review) | one row in the Day 3+ line + matrix row. **No VM def, role, or ADR.** Note: PDM does not replace the VIP — VIP is the API endpoint for IaC, PDM is the human pane. |
| **Internal container registry** (pull-through + private repo) | [ADR 0022](decisions/0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md), 2026-08-11 sessions | Accepted: Zot provisional, Harbor not rejected; templated `image:` refs; registry self-rebuilds from upstream. Open: product choice, blob backend (NAS bind mount vs S3), minio retirement | **not in the plan doc at all** — ADR only |
| **apt-cacher-ng client wiring** | ADR 0021 | accepted, staged | plan open item |
| **GitHub runner → official Actions Runner Controller (ARC) on Kubernetes** | operator, 2026-08-22 (no earlier transcript captures it) | not decided — needs a design + security discussion (below) | **not in plan**; current github-runner 113 is the old VM shape, still to be replaced |
| **MeshCentral** (AMT console, not laptop-local) | memory 2026-08-17, research doc | decided | **not in plan** — needs a home (LXC on the fleet, class S) |
| **LLM VM** | plan, matrix, 2026-07/08 sessions | decided | in plan (Day 3+) |
| **Libation** (audiobook ingest in plex-services stack) | ADR 0018 | parked until WP7; plex-services 206 is built, so the park condition is near | ADR only |
| **pfsense-test VM** | old fleet (stopped 200, not restored) | never decided | listed in WP4 placement as a VM; VMID 200 is now unifi — drop or renumber |
| **Periodic pfSense `config.xml` export to NAS** | matrix `pfsense` row | asked, undecided | matrix only |
| **Uptime Kuma re-seed / `.unifi` backup** | done with openobserve 203 / unifi 200 | done | — |

## ARC runner — discussion seed (not a design)

How it works: [ARC](https://github.com/actions/actions-runner-controller) is a controller in a Kubernetes cluster; a *runner scale set* registers with GitHub via a GitHub App, a listener pod long-polls for jobs, and each job gets an **ephemeral runner pod** that is deleted when the job ends. No persistent runner VM, no warm state between jobs.

What it needs from the fleet: a small Kubernetes cluster (k3s or Talos on 1–3 VMs — Talos was already on the table 2026-08-11 for the registry pull-through), a container-image build path (Docker-in-Docker mode vs Kubernetes mode with kaniko/buildkit — DinD needs a privileged pod), and the existing `/github-runner` Infisical App creds.

Security to lock down before building:
- **Scope of the runner registration** — repo-level scale set per repo, not org-level; GitHub App permissions minimal (actions: read, admin self-hosted runners).
- **Fork / `pull_request` jobs** — self-hosted runners must never run untrusted PR code; keep `pull_request_target` off and require approval for first-time contributors.
- **Ephemeral only** — `ephemeral: true` is the default in ARC; never reintroduce a persistent runner.
- **Network egress** — runner namespace on its own VLAN or NetworkPolicy: allow GitHub + the pull-through registry + apt-cache, deny the services/mgmt VLANs. Today's runner VM can reach the whole fleet.
- **Build privileges** — DinD = privileged pod with node-wide reach; prefer Kubernetes mode + rootless buildkit, or accept DinD on a dedicated node pool.
- **Secrets** — no fleet secrets in the runner; CI gets only what the Infisical `/github-runner` folder holds; no `secrets` fact on the k8s hosts.
- **Image trust** — runner image pinned from the registry (ADR 0022 templated refs).

Decision needed: is a Kubernetes cluster worth carrying just for CI, or does the registry (ADR 0022) + runner share one small cluster? That is the gate question for an ADR.

## Loose end right now
`terraform/vm-configs.tf` has an uncommitted change reverting docker 204 from 16 GB back to 8 GB — the opposite of HEAD commit fe8784f ("8 GB thrashed at memory.high"). Either re-apply 16 GB or the revert is deliberate after dropping dogecoin (f70e0ce) — confirm before the next `make build docker`.
