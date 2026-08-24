# ADR 0037 — P4c: plex-services moves to the cluster; media rides a kubelet-mounted NFS PV; postgres keeps a PBS dump lane via a locally built client image

- **Status:** Accepted
- **Date:** 2026-08-24
- **Deciders:** operator + agent
- **Context source:** [P4c plan](../talos-p4c-plex-services-plan.md); kickoff homelab-p4c-plex-services-20260823

## Context

P4a/P4b established the stack-migration shape (ADR 0035/0036): a `kubernetes/<stack>/` tree with `deploy.sh`, per-service ceph-rbd PVCs rsynced from the old guest, one `InfisicalSecret` per folder, Ingresses on Traefik, `${REGISTRY}` image refs, the guest stopped never destroyed. plex-services (LXC 206) is next and brings three problems the earlier stacks did not have: (1) the arr containers need the NAS media tree, which ADR 0017 delivers to guests as node-level bind mounts — a mechanism with no direct pod equivalent; (2) SABnzbd needs an unpack scratch that must be neither NFS (the DIR_LOCK stall) nor unbounded node-local storage; (3) postgres has an off-cluster protection lane (nightly pg_dumpall + PBS push) that would silently die with the guest, and ceph-rbd PVCs get no PVE/PBS backup. The stack's 2,400 lines of API-driven Ansible configuration are persisted state in the config files and the database, so the migration is a data move, not a re-implementation.

## Decision

- The whole stack (13 compose services) becomes namespace `plex-services` per the P4b shape; Services keep the compose names so in-config targets and the Cloudflare tunnel's `tautulli:8181`/`seerr:5055` routes resolve unchanged.
- **Media reaches the arr pods through one kubelet-mounted NFS PV** (Synology `/volume1/plex`, NFSv4.1, the fleet mount options), consumed with `subPath`. This amends ADR 0017 for the services plane: the invariant is that NFS terminates at node level and workloads receive a bind — on Proxmox the node mount + `pct` bind implements it, on Talos the kubelet mount does. NFS still never terminates inside a workload container, and guests/pods stay single-homed; the node's existing vlan20 leg carries the traffic. Plex 208 keeps reading the same tree; nothing moves media.
- **SABnzbd scratch is a bounded ceph-rbd PVC (60 Gi)** at `/scratch` — never NFS, never an unbounded emptyDir on a Talos node.
- **The postgres dump lane stays literally PBS** (operator decision): a nightly CronJob dumps via `pg_dumpall` to a staging PVC and pushes it with `proxmox-backup-client` as a pxar snapshot (ns `databases`). The client image is built in-tree from Debian trixie + the Proxmox no-subscription repo and pushed to Zot under a local `homelab/` prefix — the first non-proxied image in the registry. Backup health is judged by snapshot recency on the datastore, never by job exit codes.
- Secrets: one `InfisicalSecret` on `/plex-services` (env renames + recyclarr's `secrets.yml` as a file item) plus one on `/shared` for the PBS credentials; `PBS_REPOSITORY` is composed at deploy time from the inventory so no internal hostname enters a tracked file. No generator re-home: every value already exists in Infisical and the migrated configs/DB carry the working copies; DR remains `make infisical-seed`.
- LXC 206 retires exactly as 203 did (stopped + `onboot 0`, state rm, out of `vm-configs.tf`/`backup_jobs`, role + play + tag + agent templates deleted); holder data volume idx 2 stays.

## Rejected alternatives

- **Talos machine-level NFS mount + hostPath** — the literal ADR 0017 mechanism, but Talos has no first-class NFS machine mounts; it would push a per-stack storage concern into node machine configs on all three nodes.
- **NFS PV straight into each container as its own volume without subPath discipline** — multiplies PV objects for no isolation gain.
- **emptyDir for the SAB scratch** — unbounded by default; a large queue pressures the Talos node's ephemeral storage, and the node is a control-plane seat.
- **Dump-to-Synology-NFS CronJob instead of PBS** (agent's recommendation) — equivalent off-cluster protection with zero new tooling, but loses the PBS snapshot catalog/retention and splits the backup estate across two mechanisms; operator chose to keep the lane PBS-native at the cost of maintaining a client image.
- **Dumps to a ceph-rbd PVC only** — the copy shares the failure domain of the database; no off-cluster protection.
- **Community proxmox-backup-client images** — a credential-holding backup job on an unmaintained third-party image is a supply-chain liability; the in-tree Dockerfile is ~5 lines.
- **Re-implementing the role's API configuration as k8s Jobs** — the configuration is already persisted state; re-running it adds failure modes and violates the migration-is-a-data-move premise of P4a/P4b.

## Consequences

- `kubernetes/plex-services/` becomes the only surface for the stack; `roles/plex_services` and its play/tag/agent templates are deleted. Fresh-rebuild of the stack = redeploy + restore from the PBS dump / PVC copies, not an Ansible run.
- The cluster gains its first locally pushed image (`homelab/proxmox-backup-client`); `make plex-pbs-image` must be re-run when the PBS server major rolls, and Zot must keep accepting pushes on that prefix.
- The homepage Media group and the five Kuma rows repoint in the same change window (the `${PLEX_SERVICES}` `inv_env` variable dies when 206 leaves `vms.yaml`); `make talos-monitoring` re-renders the telegraf targets afterwards.
- ADR 0017's "storage reaches containers via host bind mounts" now reads, for the services plane: via node-level mounts that the kubelet manages.
- ADR 0018's Libation shape (pinned image, master key, publish-is-a-rename staging on the same export) carries over unchanged; the Audible login state moves as data.
