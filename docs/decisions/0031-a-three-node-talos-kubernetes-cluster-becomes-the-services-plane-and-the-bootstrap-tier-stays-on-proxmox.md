# ADR 0031 — A three-node Talos Kubernetes cluster becomes the services plane and the bootstrap tier stays on Proxmox

- **Status:** Accepted
- **Date:** 2026-08-22
- **Deciders:** operator + agent
- **Context source:** migration-remaining review session 2026-08-22 ([docs/migration-remaining-2026-08-22.md](../migration-remaining-2026-08-22.md))

## Context

The greenfield-replace is nearly done and the fleet now runs Docker in five separate guests (plex-services, openobserve, docker, homepage, github-runner), each a compose stack with its own role. Three new wants push past what compose-per-guest does well: ephemeral CI runners (GitHub's Actions Runner Controller is Kubernetes-native), the fleet-local container registry ([ADR 0022](0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md)), and a single place to manage containers (Portainer was the stand-in). The operator wants Kubernetes "eventually" and asked which of the fleet would sensibly move.

The msi node runs a degraded 14900K awaiting RMA (turbo-capped); worklab is the standing spare/QDevice host.

## Decision

- **Kubernetes is the *services* plane, never the *infrastructure* plane.** A **3-node Talos** cluster runs as one VM per PVE node, control-plane VMs **pinned by `node_name`, no HA resource** (two etcd members on one host would lose quorum on that host's failure). Talos over k3s: immutable, API-driven, image-pinned — the same philosophy as ADR 0016.
- **Bootstrap tier stays on Proxmox forever:** adguard ×2, dns ×2, infisical, pbs, apt-cache, pxe, unifi, plex (iGPU), the LLM VM (vfio), PDM. Anything the cluster needs to boot, or that needs a kernel device or a non-services VLAN leg, does not move.
- **Migration candidates, in order:** registry (Zot) and ARC runners first — new workloads, nothing to migrate; then homepage (+ Caddy); then openobserve stack, plex-services (+ Libation), mcp, MeshCentral, the games host — one at a time, replace-beside-and-stop-old per the [ADR 0028](0028-greenfield-replace-builds-final-form-guests-beside-the-restored-copies-under-vmid-old-100-after-pruning-the-fleet-state-of-every-proxmox-resource.md) discipline. Durable state rides PVs on the same Ceph pool (CSI) — the ADR 0015 model with the platform's own volume noun.
- **Until the msi RMA completes, the third etcd member runs on worklab**, then is replaced by a member on msi (Talos member replacement). CI nested-PVE tests target ms-01a, not msi.
- **Timing:** after P0–P2 of the plan (no further greenfield-replaces for k8s-bound guests — github-runner 113 and mcp 115 stay until they move) — not in parallel with the ADR 0030 plane work.

## Rejected alternatives

- **No Kubernetes; ephemeral runner containers on an LXC** — 95 % of the runner security for 10 % of the cost, but the operator wants k8s as the next service plane, and a cluster carrying only CI would have been the objection.
- **k3s on Ubuntu VMs** — mutable OS under the cluster reintroduces the drift ADR 0016 removed.
- **Moving the bootstrap tier (DNS, Infisical, PBS) onto k8s** — circular dependency: the cluster cannot come up without them.
- **Plex on k8s via a device plugin** — possible, not worth the iGPU passthrough complexity for one pod.
- **Build now, 3 control planes including msi** — a degraded CPU under etcd fsync latency flaps the member; worklab holds the seat instead.

## Consequences

- New guests: `talos-cp-{a,b,msi}` (VMs, pinned, no HA), worklab-hosted third member during the RMA window. `terraform/` grows a Talos machine-config path; a `kubernetes/` tree (manifests/Helm values) is a new canonical pipeline and must be named in CLAUDE.md.
- ADR 0022's open items close in the same pass: Zot on a Ceph PV, Harbor remains unbuilt; minio retires.
- Each stack that moves retires its Ansible role and compose template; the docker-LXC shape is transitional, not end-state. The rebuild matrix gains a "k8s" column.
- The Infisical-agent-renders-env-files secret path needs a Kubernetes equivalent (Infisical operator / ESO) — decided at the first stateful migration, not here.
- Losing any one PVE node leaves etcd and Ceph quorate; the msi RMA window is a planned single-node loss.
