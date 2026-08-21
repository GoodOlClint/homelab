# Post-MS-01 End State — Rebuild-as-Routine Design

**Status:** approved (operator, 2026-07-28). **Date:** 2026-07-28.

Defines what makes "rebuild any guest from the latest image" a routine, no-drama operation in the post-migration end state (3-node PVE 9 + Ceph, static-IP LXCs, Terraform-managed hosts — [ms01-cluster-iac-plan.md](ms01-cluster-iac-plan.md)). Design only; implementation lands through the plan's WPs.

## Decisions locked (operator interview 2026-07-28)

| Decision | Choice |
|---|---|
| Default durable-state mechanism | **Detached Ceph data volume** per stateful guest, managed by Terraform independently of the guest resource. Rebuild = destroy guest, keep volume, reattach. PBS backs volumes for DR but restore is not on the routine-rebuild path (ADR 0015) |
| Guest OS image policy | **Pinned + deliberately rolled** — images pinned by version/checksum; a bump is an explicit commit; container tags stay `latest` (ADR 0016) |
| Zero-outage tier | **DNS only** (dual AdGuard + BIND pair, ADR 0003 stands). Every other service tolerates its rebuild window |
| Observability history | **Preserved across routine rebuilds** — OpenObserve parquet + metadata.sqlite and `/var/lib/uptime-kuma` ride the data-volume pattern. (Landed 2026-08-21 at the openobserve greenfield-replace: history was carried onto the volume, not dropped) |
| Guest networking (added 2026-07-28) | **Single-homed on services VLAN 40** ([ADR 0017](decisions/0017-guests-are-single-homed-on-the-services-vlan-storage-reaches-containers-via-host-bind-mounts.md)): no guest management-VLAN legs; storage via host bind mounts; PBS keeps the sole VLAN 20 leg; squid retired with VLAN 140; Ceph cluster VLAN renumbered 33→21 |

## State classes

Every guest falls into exactly one class; the matrix below assigns them.

- **S — stateless/re-seeded.** Config comes from roles, secrets from Infisical. Rebuild is `terraform` + `ansible` with no data step. This is the default for anything not listed otherwise.
- **V — detached data volume.** Real state lives on a Terraform-managed Ceph RBD volume that outlives the guest. The guest rootfs is always disposable.
- **B — restore-on-provision.** Rebuild imports a backup artifact. Reserved for services with a vendor-supported import path where a raw data-dir volume is fragile. **UniFi only.**
- **Accepted loss** is called out per row where it applies (caches, stats, DDNS journals).

## Per-service state/rebuild matrix

| Service | Form | Class | Durable state & end-state home | Rebuild outage → covered by | Cutover carry |
|---|---|---|---|---|---|
| infisical | VM (protected) | S* | All runtime secrets in its DB on its own Ceph disk. DR is `make infisical-backup` → SOPS export → `make infisical-seed`, plus PBS vzdump. *Not the volume pattern: the seed path is the documented, exercised DR mechanism (ADR 0004) and the guest is `protected`, so routine rebuild is rare and deliberate | Minutes–hours. Agents serve cached rendered env files, so running containers are unaffected; deploys and secret rotation are blocked during the window — schedule accordingly | Re-seed from the WP0-verified SOPS export (decided, ADR 0004) |
| adguard ×2 | LXC | S | None kept. Config is IaC (rewrites parameterized, resolved Phase J); query stats accepted loss. **Gap that must close for determinism: the web-UI admin password exists only as a bcrypt hash on the live box — seed a known password into Infisical and have the role template the hash, so a rebuilt instance has known creds** | Zero. Rebuild one instance at a time; the partner serves; clients hold both resolver IPs (pfSense DHCP, manual step per plan) | Nothing — DNS ephemeral (decided) |
| dns (BIND) ×2 | LXC | S | Zone data is generated from the Terraform inventory (ADR 0006); TSIG key in Infisical `/infrastructure`. DDNS journal entries accepted loss (repopulate as leases renew) | Zero. Rebuild secondary first; during a primary rebuild the secondary serves from its transferred copy | Nothing — zones regenerate from inventory |
| plex | LXC (iGPU) | V | Library dir (metadata, watch history) on a data volume; media stays on Synology NFS. **Manual match fixes (split shows, fix-match — e.g. Scrubs 2001 vs 2026) are additionally pinned by `.plexmatch` files in the show folders on the media share** — the Library restore preserves them, but only the `.plexmatch` pin survives a fresh rescan; make one whenever a match is hand-corrected | Minutes. No failover — schedule idle hours (accepted: DNS-only zero-outage tier) | Copy the Library dir out of the old VM → into the volume (plan checklist, decided) |
| plex-services | docker-LXC | V | arr postgres + app configs on a data volume. **`plex-services-pgdump.timer` (built 2026-08-21) writes a daily `pg_dumpall` to the same volume so every PBS snapshot contains a consistent dump — closes the known postgres-PBS-restore gap for DR without touching the routine path** | Minutes–an hour. arr consumers retry; downloads resume; nothing user-critical | pg_dump + config copy-out from the old VM → volume (plan, decided) |
| openobserve stack | docker-LXC | V | One volume: `/var/lib/openobserve` (**parquet + metadata.sqlite move together — the `file_list` index lives in the sqlite; separating them orphans all history**, ADR 0011), Prometheus TSDB, `/var/lib/uptime-kuma`. Grafana dashboards are provisioned (IaC) | Minutes of blind window. UptimeRobot covers outside-in; missed internal alerts during the window accepted | DONE 2026-08-21: history preserved — every store rsynced onto `/var/lib/monitoring/<store>` on volume index 3 |
| unifi | VM | B | Controller/UOS state (MongoDB). Scheduled autobackup `.unf` to the NAS + UniFi cloud backup. Rebuild = fresh VM + import latest `.unf`; UOS internals (dual auth stores, Podman) make a raw data-dir volume fragile — the vendor import path is the supported one | Management plane down during rebuild; **data plane (switching/WiFi) keeps forwarding**. Re-adoption blip on import, accepted | Cloud backup re-import (decided, ADR 0004) |
| proxmox-backup | VM | S | The datastore on the Synology NAS is the asset and survives independently (decided). Config re-provisioned by role; admin creds/tokens regenerate into Infisical `/pbs` + `/shared`. Fingerprint rotates on rebuild → fleet `pbs_client` re-run required (and beware its known always-SUCCESS false positive when verifying) | Backup-window gap only; nothing consumer-facing | Nothing to carry — datastore stays on the NAS; WP0 vzdump insurance unaffected |
| github-runner | VM | S | None — runners ephemeral, GitHub App creds in Infisical `/github-runner` | CI jobs queue until the runner returns | Nothing |
| lancache | LXC | — | Cache contents: **accepted loss** (cold cache re-warms) | Zero user-visible — clients fall through to origin | Nothing |
| squid | — | retired | **Retired at cutover (ADR 0017)** — its purpose was transparent interception of the openclaw staging VLAN 140, which is deleted. Role/tag/`/squid` Infisical folder go dormant; lancache continues to cover game caching | n/a | Nothing — not rebuilt |
| homepage | LXC | S | Config is IaC; tokens in Infisical `/homepage` | Cosmetic | Nothing |
| mcp | LXC | S | Assumed stateless — **verify at WP4 rebuild time**; promote to V if it holds real state | Minutes | Nothing |
| minio | LXC | V | Bucket contents on a data volume | Minutes; S3 consumers retry | `mc mirror` out of the old VM → volume (plan, decided) |
| doge | LXC | V | Chain data on a data volume (avoids multi-day re-sync on every rebuild) | Minutes; nothing depends on it | Copy datadir (plan) |
| docker-legacy | docker-LXC | V | Valheim world data (+ any surviving app volumes; authentik currently disabled) on a data volume | Game sessions drop — announce, rebuild off-hours | Copy world data/volumes out of the old VM |
| LLM | VM (new) | V | Model cache on a data volume — re-download is the acceptable fallback, but tens of GB per rebuild is needless | User-facing only; no dependents | New guest, nothing to carry |
| PDM | VM (new) | S | Management-pane config; verify at deploy whether anything merits a volume | None — humans use the node UIs meanwhile | New guest, nothing to carry |
| vps | external | S | WG keys in Infisical `/vps`; `make vps-rebuild` is the existing rebuild path; ADR 0013 constraints (IPv4 endpoint, measured MTU 1400) stand | External access down during rebuild; LAN unaffected | Not part of the cluster cutover |
| pfsense | external | — | Hand-managed (ADR 0005). Ask: periodic `config.xml` export to the NAS so the DR story is at least a copy, not a memory | n/a | One manual change at cutover: DHCP hands out both resolver IPs (plan WP4) |

## Image policy (ADR 0016)

- Guest OS images (Ubuntu cloud image, LXC templates) are **pinned by explicit version URL + checksum** in tfvars, downloaded once to shared storage (CephFS/NAS) so guest creation is node-agnostic.
- `terraform plan` is therefore always a pure statement of *your* changes — the current replace-all-17-VMs drift (ADR 0012 Consequences) is exactly the failure mode this kills, and the greenfield cutover is when the pin lands.
- An image bump is a deliberate commit: edit the pin → plan shows exactly which guests would replace → roll per-service via `make rebuild <guest>` on your schedule. Roll order for paired services: one instance, verify, then the partner.
- Cadence is operator-driven (monthly-ish or on a CVE that matters), not upstream-driven.
- **Container tags stay `latest`** (CLAUDE.md rule unchanged) — container updates flow through `make update` and never touch Terraform. The CLAUDE.md "no version pinning without reason" line gets scoped to say exactly this (conflict resolved in the same edit window, see below).

## The routine rebuild verb

`make rebuild <guest>` becomes the universal, any-day operation:

1. Terraform destroys the guest; the data-volume resource is untouched (separate resource, no `depends_on` into the guest lifecycle).
2. Guest recreates from the pinned image with its static IP and volume attachment.
3. The Ansible role converges config and secrets; the service starts against its existing data.

Acceptance (this is the design's DoD, verified per-service at WP4): rebuild of every Class-V service preserves its state; rebuild of either instance of a DNS pair causes zero resolution failures observed from a client during the window; second run of everything is zero changes.

## What the migration must carry across the cutover (consolidated)

Everything below is already decided in the plan/ADR 0004 — this consolidates it against the end-state matrix. Nothing new is added to the cutover's critical path.

1. Infisical: verified SOPS DR export (WP0 gate) → `make infisical-seed`.
2. UniFi: cloud backup `.unf` (WP0 gate) → re-import.
3. Plex: Library dir copy-out → new data volume.
4. plex-services: pg_dump + configs → new data volume.
5. minio: `mc mirror` copy-out → new data volume.
6. doge: datadir copy → new data volume.
7. docker-legacy: Valheim world data → new data volume.
8. Kuma (optional, cheap): sqlite copy if the uptime record is wanted; monitors re-seed regardless.
9. Manual: pfSense DHCP dual-resolver change; AdGuard admin password seeded into Infisical **before** the first AdGuard LXC build so both instances deploy with known creds.
10. Dropped deliberately: OpenObserve history, lancache cache, AdGuard stats, DDNS journals.

## Verification items owned by WPs (design gates, not code)

- **WP3 gate — RESOLVED (spike 2026-07-28, provider schema v0.111.1):** bpg has no standalone volume resource, but both attach paths exist — LXC `mount_point.volume` accepts an existing volume ID, VM `disk.path_in_datastore` attaches an existing disk image. **Chosen mechanism: a never-started "datavols" holder VM** (reserved VMID, `started=false`, `on_boot=false`, `protection=true`, Terraform `prevent_destroy`) declaratively owns every data volume as one of its disks on the Ceph pool; stateful guests attach by volume ID. PVE guest destroy only deletes volumes owned by the destroyed VMID, so rebuilds never touch the data. Volume create/resize stays fully declarative (edit the holder's disk list). Remaining live check at Day-1 bring-up: PVE accepting a cross-VMID volume on a CT `mount_point` via the API (CLI accepts it; GUI doesn't offer it). Fallback if rejected: `pvesh`-alloc script creating the same holder-VMID-owned volumes — guest references unchanged either way.
- **WP3:** pinned-image resources replace the `latest` download; drop the `lifecycle.ignore_changes` cloud-init workarounds that papered over drift.
- **WP4:** per-service volume definitions per the matrix; pg_dump timer (plex-services); AdGuard admin-password seeding; Kuma/OpenObserve/Prometheus data dirs relocated onto the volume mount.
- **WP4:** the acceptance checks under "The routine rebuild verb", run once per service as it lands.

## Conflicts with existing rules (surfaced per house discipline)

- CLAUDE.md Greenfield Philosophy says "No version pinning without reason. Use `latest` tags for Docker images…". ADR 0016 supplies the reason for OS images (plan determinism; the replace-all foot-gun is the evidence) and leaves the Docker-tag half intact. The CLAUDE.md line is amended alongside this design (same edit window).
- "No migration tasks" holds: volume attach/reattach is steady-state IaC, not migration logic; all copy-out steps live in the plan and runbook, never in roles.

## Deferred open threads (unchanged by this design)

- Kuma "VPS WireGuard peer Down" 2026-07-27 15:44 — unconfirmed, investigate separately.
- PBSBackupStale → `pbs_snapshot_count` re-point.
- Branch unpushed.
- AdGuard admin creds unrecorded — *partially absorbed*: the end-state fix (seed into Infisical, template the hash) is in the matrix; recovering the current live password stays an open thread until cutover, where it becomes moot.
