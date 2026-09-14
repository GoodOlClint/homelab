# codeintel pgvector store — change plan (#46)

Status: **APPROVED 2026-09-14, building.** Decision: [ADR 0055](decisions/0055-code-intelligence-s-pgvector-store-is-a-dedicated-postgres-in-its-own-flux-tree-reached-over-verify-full-tls-on-a-pinned-metallb-address-and-a-shared-clustered-postgres-is-rejected.md). Consumer side: #47 (homelab-mcp posts the split).

## Scope

In: the `codeintel` tree, its LB address + DNS name + cert, `/codeintel` secrets and role convergence, the writer password on LXC 280, backups, the halfvec restore proof. Out: the mcp reader's `pg_hba` line and DSN delivery (lands with VM 242), the homelab-mcp package, code-intelligence's schema (the writer creates it).

## Interview answers (2026-09-14)

- Wire: TLS `verify-full`, `hostssl` only.
- Access: `pg_hba` source rules per role, `externalTrafficPolicy: Local`.
- Defaulted: dedicated instance (the shared-cluster question is ADR 0055's rejected alternative), tree/namespace `codeintel`, offset 68, roles converged by `k8s_apps`, pgvector pinned to an exact tag, PVC 20 Gi (tranche 1 needs ~3 GB; `ceph-rbd` allows expansion).

## Commits (one PR, stacked commits)

1. **Bindings + seed.** `metallb.offsets.codeintel: 68` in `vlans.example.yaml` (operator mirrors it into the gitignored `vlans.yaml`); `POD_CIDR` in `cluster-bindings.yaml.j2` read from flannel's net-conf ConfigMap (confirm its name/key on the live cluster first); `codeintel: baseline` in `k8s_seed_namespaces`. Check: `make k8s-seed` twice → second run 0 changed; `CODEINTEL_IP` and `POD_CIDR` present in the ConfigMap.
2. **Tree.** `kubernetes/codeintel/`: `pvc.yaml`, `certificate.yaml` (`codeintel.${DOMAIN}`, `homelab-ca`), `secrets.yaml` (`InfisicalSecret` on `/codeintel`), `app.yaml` (Deployment `postgres`: `${REGISTRY}/docker.io/pgvector/pgvector:<exact tag>`, `ssl=on`, `hba_file` from a generated ConfigMap, cert Secret mounted `defaultMode: 0640` with `fsGroup: 999`, requests, `Recreate`, readiness `pg_isready`; Service `postgres` type LoadBalancer on `${CODEINTEL_IP}`, Local policy), `pg_hba.conf` (local trust for the socket, `hostssl` writer from `${CODE_INTEL}/32`, superuser from `${POD_CIDR}`, everything else rejected), `kustomization.yaml` with `../pg-backup`; `kubernetes/flux/apps/codeintel.yaml` with `NS PG_USER PG_SECRET BACKUP_ID SCHEDULE`. Check: `make validate` (includes `flux_check.py`), `make flux-check`.
3. **Secrets + roles.** `k8s_apps/tasks/codeintel.yml`: `generate_secret.yml` × 3 on `/codeintel`; wait rollout; idempotent `psql` (create database/roles if absent, `ALTER ROLE … PASSWORD` only when a SCRAM check fails, `CREATE EXTENSION IF NOT EXISTS vector`, `ALTER DEFAULT PRIVILEGES FOR ROLE ci_writer … GRANT SELECT ON TABLES TO ci_reader`); `codeintel` added to `infisical_login.yml`'s loop. Check: `make k8s-apps` twice → second run 0 changed.
4. **Delivery + docs.** `codeintel.writer_password: ci-writer` in the `code-intel` scratch spec; the Folder Ownership row; CLAUDE.md pointer to ADR 0055 + tree `codeintel` in the Make table; README tree list. Check: `make ansible code-intel` twice → 0 changed; `/etc/scratch-secrets/writer_password` 0400 `ci-writer`.

## Rollout

Push → Flux reconciles → `make k8s-seed` (bindings) before the tree can substitute → `make dns-records` → `make k8s-apps` → `make ansible code-intel`. Nothing existing is touched; rollback is deleting the Kustomization (PVC reclaim is `Retain`).

## Definition of done (#46, evidenced in the PR)

From LXC 280 with `sslmode=verify-full host=codeintel.<service domain>`:

- writer: `create extension if not exists vector` succeeds; creates a `halfvec(2560)` table partitioned by `gen_id` with an HNSW index on a partition.
- reader: `select` succeeds on it; `create table` fails with permission denied; after the writer adds a new partition, reader `select` on it still succeeds (default privileges).
- `sslmode=disable` from 280 is rejected; the reader from 280 is rejected by `pg_hba`; a login from any other services-VLAN host is rejected.
- The `pg-backup` CronJob run by hand leaves a fresh `codeintel-postgres` snapshot in PBS ns `databases` (judged by snapshot recency).
- Restore proof: that dump restored into a throwaway `pgvector` pod with the same tag, and the partition's row count and a nearest-neighbour query match the source.

Fails before the change (no host, no roles); every line above is a command output pasted into the PR, with bindings redacted.
