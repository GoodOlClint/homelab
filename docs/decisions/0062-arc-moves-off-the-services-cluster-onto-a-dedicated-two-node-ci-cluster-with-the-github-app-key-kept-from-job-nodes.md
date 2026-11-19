# ADR 0062 — ARC moves off the services cluster onto a dedicated two-node CI cluster with the GitHub App key kept from job nodes

- **Status:** Accepted
- **Date:** 2026-11-19
- **Deciders:** operator + Claude, reviewed by Codex
- **Context source:** session 2026-11-19 (live read of the cluster and `kubernetes/arc/`, one Codex design review over CrossTalk, operator ruling on key exposure)

## Context

A live read on 2026-11-19 showed how [ADR 0034](0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md) landed. The services cluster has three nodes and all are control-plane members. Runner pods use host networking, are pinned to `talos-cp-a`, tolerate the control-plane taint and carry a Docker-in-Docker container with `privileged: true`. Namespace `arc-runners` enforces pod security `privileged`, has no network policy, and holds the GitHub App key (`github-app`) and the CI Proxmox token (`pve-ci-token`). Job code therefore controls a privileged Docker daemon on an etcd member, one step from every secret in the services cluster.

Two premises of ADR 0034 have drifted. Host networking existed so nested test guests could call back to services on the runner; PSProxmoxVE `main` now provisions a dedicated storage VM for the answer server, NFS and iSCSI. The hourly reaper deletes every pool-`ci` guest older than six hours, and the CI token is `PVEVMAdmin` on that pool, so nothing durable can live there.

## Decision

Actions Runner Controller leaves the services cluster. It runs on a dedicated CI Kubernetes cluster of two Proxmox VMs. This amends the placement in [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md), [ADR 0032](0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md) and ADR 0034, and the ownership in [ADR 0048](0048-flux-reconciles-the-kubernetes-services-plane-from-the-repo-replacing-the-kubernetes-shell-deploy-layer-in-app-configuration-is-ansible-and-the-talos-lifecycle-stays-on-talos-sh.md).

- **Two nodes, two trust levels (operator ruling).** A protected node runs the ARC controller and listeners and holds the GitHub App key. A job node runs only runner pods. The App key is never mounted on, or readable from, the job node.
- **No production credentials.** The CI cluster holds no services-cluster, Ceph, Flux deploy or Infisical credential. Job nodes are never joined to the services cluster.
- **The VMs live outside pool `ci`.** Fleet Terraform builds and rebuilds them from outside CI. The CI token has no privilege over them.
- **The reaper moves to a trusted plane** with cleanup-only scope, so it still runs while the runner cluster is down.
- **Network.** The job node sits on its own filtered network, or is filtered at its Proxmox virtual NIC, because same-VLAN traffic never reaches the router. Allowed out: the Proxmox API port, DNS, GitHub, the image registries and verified test endpoints. Test guests cannot reach the job node, the CI cluster API or the fleet.
- **Host networking and the `ci` to `talos-cp-a` firewall allow are removed** once both consumer repositories are confirmed not to call back to the runner.
- **The App is narrowed.** Installed on the two CI repositories only, with the minimum permissions ARC needs.

## Rejected alternatives

- **Leave ARC on the services cluster** — privileged job code beside etcd.
- **A tainted worker joined to the services cluster** — a job-node escape holds node credentials for production.
- **One single-node CI cluster** — recommended by Claude as the least to build; the operator chose to keep the App key from jobs, which one node cannot do.
- **Controller on the services cluster, runner pods elsewhere** — stock ARC creates runner pods through the API of the cluster it runs in; a node selector does not span clusters.
- **A VM per job in pool `ci`** — the strongest isolation, but it needs a provisioning controller that does not exist here. It stays the pattern for the Mac tier ([ADR 0061](0061-the-m4-mac-studio-is-rebuilt-as-a-ci-runner-host-with-disposable-vms-for-pull-request-jobs-and-bare-metal-for-trusted-branch-gpu-jobs.md)).
- **An application proxy in front of the Proxmox API** — the pool-scoped token is already the application-level control.

## Consequences

- Jobs still share the job node between runs. A scheduled rebuild limits what persists, but a rebuild does not revoke a credential a job copied; the CI token and any repository secret a job can read are treated as exposed to every job.
- The shared cache volume becomes job-node local state, partitioned by repository and run.
- Cutover order: drain the scale sets through a full provision, test and cleanup before replacing shared state or letting Flux prune the old objects.
- Acceptance gates: one complete integration run and cleanup on the new cluster; the reaper cleans up while the runner cluster is down; the job identity cannot modify or delete either CI cluster VM; a pod on the job node cannot read the App key.
- Before removing host networking: confirm the deployed refs of both consumer repositories, not only PSProxmoxVE `main`.
- Open for the build plan: Talos or another distribution for the two nodes, Flux tree or Ansible for delivery, and where the reaper runs.
- Built before the Mac runner of ADR 0061 (operator ruling 2026-11-19: the Studio is unplugged and awaits a rebuild). Until this lands the exposure described in Context stands.
