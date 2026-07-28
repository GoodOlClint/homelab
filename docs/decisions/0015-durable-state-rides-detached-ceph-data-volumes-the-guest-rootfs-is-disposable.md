# ADR 0015 — Durable state rides detached Ceph data volumes; the guest rootfs is disposable

- **Status:** Accepted
- **Date:** 2026-07-28
- **Deciders:** operator (interview 2026-07-28)
- **Context source:** docs/rebuild-as-routine-design.md · docs/ms01-cluster-iac-plan.md stateful-data checklist

## Context

The MS-01 end state wants "rebuild any guest from the latest image" as a routine, no-drama operation. Greenfield roles already make *config* rebuildable, and Infisical makes *secrets* rebuildable — but real data (Plex library metadata, arr postgres, minio buckets, doge chain, observability history) has had no house pattern beyond the one-time migration copy-out checklist. Without one, every rebuild of a stateful guest is bespoke surgery, which is exactly what makes rebuilds dramatic today.

## Decision

Every stateful guest's durable data lives on a **Terraform-managed Ceph RBD data volume that is a separate resource from the guest** — the guest is destroyed and recreated freely; the volume persists and reattaches. The guest rootfs is always disposable. PBS backs up the volumes for disaster recovery, but restore is **not** on the routine-rebuild path.

Named exceptions, each with a reason:

- **Infisical** keeps its own path: `make infisical-backup` → SOPS export → `make infisical-seed` (ADR 0004). The seed path is the exercised DR mechanism and the guest is `protected` — routine rebuild does not apply.
- **UniFi** is restore-on-provision: fresh VM + latest autobackup `.unf` import. UOS internals (dual auth stores, embedded MongoDB under Podman) make a raw data-dir volume fragile; the vendor import path is the supported one.
- **Accepted loss** (no volume, no restore): lancache contents, AdGuard query stats, BIND DDNS journal entries.
- **Observability history is preserved** (operator decision): OpenObserve parquet **together with** `metadata.sqlite` (the `file_list` index lives there — separating them orphans all history, ADR 0011), Prometheus TSDB, and `/var/lib/uptime-kuma` all ride one data volume on the openobserve guest.

The per-service assignment is the matrix in docs/rebuild-as-routine-design.md.

## Rejected alternatives

- **PBS restore-on-provision as the default.** Rebuild time scales with data size, loses everything since the last backup, and inherits the known pbs_client/postgres restore gaps. Fine as DR, wrong as the routine path.
- **Per-service ad-hoc decisions with no default.** Every new service re-litigates the question; the fleet ends up where it is today.
- **Keeping stateful guests un-rebuildable ("pets").** Contradicts the greenfield philosophy and leaves image updates blocked on the scariest guests.
- **Dropping observability history on rebuild.** Was the migration-cutover call (rebuildable-by-waiting), but as a *routine* policy it resets the forensic window on every rebuild — the 24-day ingestion outage (ADR 0011) was found in exactly that history.

## Consequences

- The `proxmox-vm` module (WP3) must express a volume whose lifecycle is independent of the guest — gate item: verify bpg can attach a pre-existing RBD volume to an LXC `mount_point` and a VM disk; fallback is an API/`pvesm`-created volume referenced by ID.
- `make rebuild <guest>` becomes the universal verb: destroy guest, keep volume, recreate, converge role, service starts against existing data. Acceptance per service at WP4: state survives, second run zero changes.
- Roles must put their data dirs on the volume mount point (WP4): docker volumes, `/var/lib/openobserve`, Plex Library, postgres data, etc.
- plex-services adds a pg_dump timer writing to its volume so every PBS snapshot holds a consistent dump — closes the postgres-PBS-restore gap for DR without touching the routine path.
- "No migration tasks" holds: volume attach is steady-state IaC; all one-time copy-outs stay in the migration plan, never in roles.
- AdGuard rebuilds require its admin password seeded in Infisical first (design doc matrix) — otherwise a rebuilt instance has unknown creds and the rebuild is not routine.
