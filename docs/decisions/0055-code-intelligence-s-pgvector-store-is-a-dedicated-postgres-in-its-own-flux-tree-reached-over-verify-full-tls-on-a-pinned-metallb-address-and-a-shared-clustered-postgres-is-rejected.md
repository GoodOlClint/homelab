# ADR 0055 — Code intelligence's pgvector store is a dedicated Postgres in its own Flux tree, reached over verify-full TLS on a pinned MetalLB address, and a shared clustered Postgres is rejected

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** operator + agent
- **Context source:** issue #46 (code-intelligence ADR 0013 decision 6), issue #47 (the homelab-mcp consumer), session 2026-09-14

## Context

code-intelligence publishes every index generation into Postgres (2560-dim `halfvec` embeddings, one HNSW index per `gen_id` partition, pgvector ≥ 0.7), and the `code-intel-mcp` package inside the homelab-mcp gateway reads the same database. The consumers are outside the Talos cluster: the generator is scratch LXC 280 `code-intel` (ADR 0054) and the gateway is VM 242 `mcp` (ADR 0052), both on the services VLAN. Each publish is a full-unit load (mlx: 40 s COPY + 28 s HNSW build, ~1.2 GB) in one transaction; retention detaches and drops partitions. The index will carry private repositories in code-intelligence's tranche 2.

The fleet runs four Postgres instances, each a plain `postgres:17` beside its app: infisical (VM 205) and the internal authentik realm (LXC 213) on the bootstrap tier, plex-services and authentik-ext on the cluster, the latter two backed up by the shared `kubernetes/pg-backup` CronJob to PBS. The operator asked whether this is the moment for one clustered Postgres that many services use.

## Decision

- **A dedicated, single-instance Postgres in its own Flux tree `codeintel`** (namespace `codeintel`): `pgvector/pgvector` pinned to an exact pgvector + PG 17 tag through Zot, one ceph-rbd PVC, `strategy: Recreate`, cpu+memory requests, and `../pg-backup` for the nightly `pg_dumpall` → PBS ns `databases` (backup-id `codeintel-postgres`). The pin has a demonstrated reason (ADR 0016): pgvector versions change the on-disk format, so a bump is a deliberate roll with a dump/restore check.
- **One pinned MetalLB address, `metallb.offsets.codeintel`**, with `externalTrafficPolicy: Local` so clients' real source IPs reach Postgres, and an A record `codeintel.<service domain>` from `make dns-records`.
- **TLS verify-full only.** A cert-manager `homelab-ca` Certificate for `codeintel.<service domain>` is Postgres's server cert; every non-local `pg_hba` line is `hostssl`, and clients connect with `sslmode=verify-full` against the root the `ca_trust` role already installed.
- **`pg_hba` by source address, per role:** writer from `${CODE_INTEL}` only, reader from the mcp host only (the line lands when 242 exists), the superuser from the cluster pod CIDR only (the backup CronJob). `pg_hba.conf` is a generated ConfigMap (a file change rolls the pod); a `reload` sidecar SIGHUPs Postgres hourly so a renewed cert or a binding-only change lands without a restart.
- **Roles are converged by the `k8s_apps` tail**, not an initdb script: `generate_secret.yml` creates `writer_password` + `reader_password` + `postgres_password` in Infisical `/codeintel` (the new folder, added to `infisical_login.yml`'s loop); a `kubectl exec psql` step creates/ALTERs the `codeintel` database, the `ci_writer` and `ci_reader` roles, `CREATE EXTENSION vector`, and the writer's default privileges granting `SELECT` to the reader. Second run = 0 changed.
- **Delivery:** the writer password reaches LXC 280 through the scratch role's existing `folder.key` form (`codeintel.writer_password`), not a copy under `/scratch/code-intel`; the reader password reaches the gateway through homelab-mcp's own delivery (#47).

## Rejected alternatives

- **A shared clustered Postgres (CloudNativePG, Patroni) for many services.** Half the fleet's instances cannot join it: infisical and the internal authentik realm are bootstrap tier and must not depend on the services plane (ADR 0031, ADR 0049 moved authentik off the cluster for exactly that cold-start reason). #46 requires isolation from other tenants' outages and WAL churn, and a publish is a 1.2 GB load plus an index build. Streaming replication on top of 3× Ceph RBD buys a faster failover than the drain-first discipline already gives, at double the write amplification; getting its real value needs local disks on Talos. One image and one major version for every tenant would couple pgvector to the arr stack's upgrade. CNPG's native backup path is barman to object storage, which the fleet no longer has (minio retired), while the PBS `pg-backup` lane works today. Revisit only as an operator with **one cluster per tenant**, and only when a third non-bootstrap tenant needs it or the PG 17 end-of-life roll hurts across the separate instances.
- **Putting `codeintel` in the plex-services or authentik-ext Postgres.** Plain `postgres:17` has no pgvector, and #46 forbids coupling to the media stack.
- **Postgres on LXC 280 or on the mcp VM.** 280 is a scratch guest with no backup and a throwaway lifecycle (ADR 0054); the mcp VM is a gateway whose holder slot is sized for its audit spool, and co-locating would make the generator's writes depend on the gateway's host.
- **Plaintext with SCRAM.** SCRAM keeps passwords off the wire but not the index rows, which include private code from tranche 2, crossing the services VLAN.
- **Passwords only, no source rules.** A leaked reader password would work from any host on the services VLAN.
- **Roles from `docker-entrypoint-initdb.d`.** Runs once on an empty data dir, so a rotation or the mcp reader's later arrival would need hand SQL.

## Consequences

- New objects: tree `codeintel` + `kubernetes/flux/apps/codeintel.yaml`, `k8s_seed_namespaces.codeintel: baseline`, `metallb.offsets.codeintel` (next free offset, 68) in the gitignored `vlans.yaml` and its example, a `POD_CIDR` binding the seed reads from flannel's `kube-flannel-cfg` (a literal pod CIDR is an RFC 1918 address the guardrail blocks), Infisical folder `/codeintel` owned by `k8s_apps`, the Folder Ownership table row, `codeintel.writer_password` in the `code-intel` scratch spec, and an optional `KEEP_DAYS` on the shared `pg-backup` (codeintel keeps 1 day of local dumps; a generation dumps to GBs and PBS holds the history).
- The mcp reader's `pg_hba` line depends on VM 242 existing (a `MCP` binding); until then the reader role exists and can log in from nowhere.
- A pgvector bump is a deliberate roll: dump → bump the tag → restore check of a `halfvec` partition. Rebuild from the generator (`ci-pg-load.py --republish`) is the fallback, never the plan.
- The generator and the gateway take a hard dependency on the services plane. The homelab-mcp package must fail soft when the store is unreachable so the gateway's other servers stay usable during a cluster outage — tracked on #47.
- Postgres on the cluster stays per-app; this ADR is the record that a shared instance was weighed and declined.
