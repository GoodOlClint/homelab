# ADR 0038 — P4d: the games host moves to the cluster — Valheim on a MetalLB UDP LB with Local policy, the PlayFab status sidecar keyed by server name in the same pod, Kiwix ZIMs via an NFS PV; MeshCentral stays on control

- **Status:** Accepted
- **Date:** 2026-08-24
- **Deciders:** operator + agent
- **Context source:** P4d change plan ([docs/talos-p4d-games-plan.md](../talos-p4d-games-plan.md)); kickoff `homelab-p4d-games-host-20260824`

## Context

The last docker-LXC stack on the services plane is `docker` 204: the crossplay Valheim dedicated server (`ghcr.io/community-valheim-tools/valheim-server`, UDP 2456–2458), a `valheim-status` node sidecar that polls the PlayFab lobby API and a busybox httpd publishing `status.json` for Uptime Kuma, `autoheal`, and `kiwix-serve` over a 538 GB NAS ZIM library. [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md) makes the Talos cluster the services plane and P4a–P4c ([ADR 0035](0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md)–[0037](0037-p4c-plex-services-moves-to-the-cluster-media-rides-a-kubelet-mounted-nfs-pv-postgres-keeps-a-pbs-dump-lane-via-a-locally-built-client-image.md)) fixed the shape: `kubernetes/<stack>/deploy.sh`, ceph-rbd PVCs for state, a kubelet-mounted NFS PV for NAS trees, `InfisicalSecret` per folder, Ingress on `.65` for HTTP, a MetalLB `LoadBalancer` for anything else, `${REGISTRY}` refs, retire = stop + `onboot 0` + state rm.

Three facts specific to this stack shaped the decision. (1) Under crossplay the A2S/Steam query does not exist and the upstream image has no PlayFab query of its own, so the PlayFab lobby sidecar is the only status source; it is keyed today on a pinned entity ID that rotates whenever the container is recreated (derived from the container's machine-id — `~/Source/Valheim` ADR 003), a known open item, and a fresh pod is guaranteed to rotate it. (2) The game's inbound path is UDP through the VPS relay: the VPS DNATs 2456–2458 to the pfSense tunnel IP, and pfSense was found to carry **no** forward for those ports at all (config.xml: zero hits) — players have joined through the PlayFab relay/join code only. (3) The plan row said "MeshCentral → games host", which [ADR 0030](0030-three-management-planes-vlan10-out-of-band-vlan30-hypervisor-with-pdm-pbs-apt-cache-pxe-vlan40-services.md) explicitly rejected.

## Decision

- **ADR 0030 stands (operator, 2026-08-24).** MeshCentral stays on the vlan10 `control` guest; the plan row's MeshCentral entry was a plan-doc error, struck without an ADR change. Nothing management-shaped moves to the services plane.
- **The games host becomes namespace `games` in `kubernetes/games/`** per the P4 shape: a `valheim` Deployment (server + the ported `valheim-status` sidecar + a busybox httpd in one pod, `strategy: Recreate`, `terminationGracePeriodSeconds: 120` so a stop is a clean world save) and a `kiwix` Deployment.
- **Valheim's game ports are a MetalLB `LoadBalancer` on services offset 67 with `externalTrafficPolicy: Local`.** One consistent address for the pfSense forward and the server's own public-IP lobby record; Local keeps the player's source IP on the server and adds no SNAT hop. The pfSense WG_VPS forward (UDP 2456–2458 → `.67`) is an operator UI step; the VPS DNAT is unchanged (it targets pfSense).
- **The status sidecar is keyed by server name** (`--name`, PlayFab `string_key5`), not a pinned entity ID: the name is configuration the operator already owns, survives every recreate, and the newest-lobby rule already filters stale orphans. The entity ID becomes an output. The sidecar and httpd share an `emptyDir`; the server container's **liveness probe** replaces `autoheal`: fail when `status.json` is stale (>3 min) or reports `online: false` for 10 consecutive minutes.
- **State:** one ceph-rbd PVC `valheim` (20 Gi) carrying `config` (worlds, backups, lists) and `data` (the server install, so the migrated pod starts without a Steam download); Kiwix reads the ZIMs through a **read-only NFS PV** of the Synology `docker` export (`subPath: kiwix`), the ADR 0037 mechanism.
- **Secrets:** one `InfisicalSecret` on the existing `/docker` folder → `SERVER_PASS`, `SUPERVISOR_HTTP_PASS`, `DISCORD_WEBHOOK`; the folder keeps its name (renaming would churn every consumer for no gain). The `authentik_*` keys die with the disabled stack.
- **Migration is player-gated:** `deploy.sh migrate` refuses to stop 204's server while its own `status.json` reports `players > 0`, polls until 0, then `docker compose stop valheim` (a clean SIGINT forces the save) before the rsync.
- **LXC 204 retires exactly as 206 did**; holder data volume idx 4 stays.

## Rejected alternatives

- **Move MeshCentral to the games host / services plane** — rejected by ADR 0030 and re-confirmed by the operator; an OOB console must not sit on the plane it manages.
- **`externalTrafficPolicy: Cluster`** — every packet would be SNAT'd to a node address, so the server logs a node IP for every player and the ban/permit lists by address become useless; Local costs nothing with a single-replica pod because MetalLB L2 announces from the node that has the endpoint.
- **`hostNetwork` / `hostPort` for the game ports** — pins the pod to a node address; the address would change on rescheduling and the pfSense forward with it.
- **Re-pin the entity ID from the new server log** — works once and rots on the next recreate, the exact open item this move was meant to close.
- **Keep `autoheal`** — needs the docker socket; a liveness probe is the native equivalent.
- **Let the pod download the 1.7 GB server install instead of copying it** — saves a 3 GB rsync but makes the first start depend on Steam at migration time; the copy is minutes.
- **Kiwix ZIMs on a ceph-rbd PVC** — 538 GB of read-only files already on the NAS; the NFS PV is the ADR 0017/0037 shape.
- **Rename `/docker` to `/games`** — churn in Infisical, `infisical_login.yml` and the folder table for a cosmetic gain.

## Consequences

- `kubernetes/games/` is the only surface for Valheim + Kiwix; `roles/docker`, the services.yml `docker` play + tag, `docker.yml`, the `docker-config.yml` section, and the three `docker*` agent templates are deleted; `docker` leaves `backup-clients.yml`, `refresh-identity.yml`, `update-all.yml`, `portainer_agent_hosts` and the telegraf template conditionals.
- MetalLB services offsets in use: 64 Zot, 65 Traefik, 66 syslog, **67 Valheim**; next free is 68.
- The pfSense forward is the one hand-managed piece (ADR 0005); `docs/pfsense-wireguard-vps-peer.md` records the rule. The VPS side needs no change.
- The Kuma "Valheim — PlayFab lobby" row targets the in-cluster `valheim-status` Service (`online == true`); the homepage Kiwix tile becomes `kiwix.<domain>`; `${DOCKER}` leaves `inv_env` consumers (homepage, the blackbox-ping target) in the same change window because it dies when 204 leaves `vms.yaml`.
- The Discord join-code hooks ride unchanged as container env; the join code still rotates on every server restart.
- The actual join path (PlayFab relay + the direct-IP forward) cannot be exercised without a game client; it is the operator's test after the build.
