# ADR 0004 — Greenfield rebuild over restore for the cluster migration

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator (interview 2026-07-10)
- **Context source:** docs/ms01-cluster-iac-plan.md · ~/okf/playbooks/ms01-cluster-migration.md (which this partially supersedes on the restore phases)

## Context

The okf runbook's Phases 1–2 restore production VMs from vzdump onto an MS-01 "landing zone", then decompose to LXCs later — two moves per service. But the repo's philosophy is greenfield: every role works on a fresh guest. The operator confirmed DNS is ephemeral, Infisical is rebuildable (`make infisical-seed` from the SOPS DR export holds everything the IaC needs), and UniFi — the one odd stateful VM — re-imports its cloud backup onto a fresh VM at the cost of a device re-adoption blip.

## Decision

No service is migrated by restore. Every guest is rebuilt greenfield in its **final** form (LXC or VM per ADR 0003) directly on the new cluster — one move per service. Infisical is re-seeded from the SOPS export; UniFi re-imports its cloud backup; stateful payloads (Plex library DB, arr postgres dump, minio contents, doge chain data) are copied out per the plan's stateful-data checklist and restored into fresh guests. vzdump backups of every pve VM are still taken and restore-verified first, but serve as **rollback insurance only**. Cutover is per-service: the old VM on pve is stopped (not destroyed) as its replacement goes live, avoiding static-IP conflicts and keeping rollback one power-on away until pve is wiped. Core order: infisical (seeded) → adguard/dns → unifi → everything else after Ceph is up. vGPU and the `nvidia-licensing` VM are retired, not rebuilt.

## Rejected alternatives

- **Restore-then-convert (runbook Phases 1–2 as written)** — fastest full-service recovery but two moves per service and it re-imports hand-accumulated VM state the greenfield model exists to shed.
- **Restore Infisical instead of re-seeding** — workable, but the seed path exercises the documented DR mechanism and proves the vault is rebuildable; the SOPS export is the same data.
- **Big-bang outage (wipe pve first, rebuild all at once)** — needless downtime and no rollback; per-service cutover keeps the old fleet bootable until the last moment.

## Consequences

- The homelab runs degraded (non-core services down) between first cutover and the post-Ceph fleet deploy — accepted for a multi-day window.
- The SOPS DR export and UniFi cloud backup must be verified **before** any wipe (plan WP0 gate).
- Stateful-data checklist decisions (Plex metadata, arr postgres, minio, doge) must each be made before that service's rebuild.
- The okf runbook's restore-based Phases 1–2 are superseded by this rebuild flow; the okf doc gets a pointer note when implementation starts.
- Known-issue bonus: the postgres PBS-restore gap is sidestepped for this migration via a manual pg_dump copy-out.
