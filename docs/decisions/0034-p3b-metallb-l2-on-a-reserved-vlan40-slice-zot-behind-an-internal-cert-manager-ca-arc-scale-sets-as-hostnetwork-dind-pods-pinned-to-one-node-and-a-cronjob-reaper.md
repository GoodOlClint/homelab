# ADR 0034 — P3b: MetalLB L2 on a reserved vlan40 slice, Zot behind an internal cert-manager CA, ARC scale sets as hostNetwork dind pods pinned to one node, and a CronJob reaper

- **Status:** Accepted (approved 2026-08-23)
- **Date:** 2026-08-23
- **Deciders:** operator + agent
- **Context source:** P3b brownfield gate, [docs/talos-p3b-plan.md](../talos-p3b-plan.md); builds [ADR 0022](0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md), [ADR 0032](0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md), [ADR 0033](0033-talos-p3a-rides-talosctl-from-a-kubernetes-tree-with-the-factory-image-pinned-in-cloud-images-the-worklab-member-via-a-second-bpg-provider-alias-flannel-and-cluster-secrets-in-infisical.md)

## Context

P3a left a cluster with only ClusterIP services. P3b needs: an address for cluster services on vlan40; the ADR 0022 pull-through registry with TLS that docker clients accept; ADR 0032's ephemeral runners, whose first consumer (PSProxmoxVE's integration job) runs an answer server and NFS/iSCSI containers on the runner's docker host that the nested PVE guests on VLAN 60 must reach, and shares terraform state across three jobs through `/opt/pve-integration`; and the reaper ADR 0032 requires before the first job. The `ci@pve` token is pool-scoped, so the nested guests must be created with `pool_id = "ci"` and the ISO upload needs `Datastore.AllocateTemplate`.

The operator does not want the registry name in public DNS or certificate-transparency logs.

## Decision

- **LoadBalancer:** MetalLB in L2 mode; `IPAddressPool` = vlan40 offsets **64–79** (outside the pfSense `.100–.254` DHCP pool and above the Talos 60–63 block). No ingress controller in P3b — Zot takes its own LB IP; an ingress controller arrives with the first HTTP stack in P4.
- **TLS:** cert-manager with a **self-signed internal CA** (`ClusterIssuer homelab-ca`). Registry name `registry.<domain_suffix>`, AdGuard rewrite → its LB IP. The CA is exported by `make` to gitignored `kubernetes/.secrets/`, trusted on the Talos nodes through a `machine.files` containerd hosts entry, and on fleet docker daemons with the ADR 0022 ref-templating follow-on. **Amends ADR 0022:** registry TLS rides the internal CA, not Cloudflare DNS-01. The self-signed issuer is a placeholder: **the ClusterIssuer is swapped to Infisical PKI (cert-manager `infisical-pki-issuer`) through its own gate BEFORE the ADR 0022 ref-templating rollout** pushes the CA onto fleet docker daemons — after that point a CA swap costs a fleet-wide trust redistribution instead of one `talosctl apply`.
- **Registry:** Zot, upstream image ref (never through itself), proxy namespaces `docker.io`/`ghcr.io`/`quay.io`, blobs on one `ceph-rbd` PVC. ADR 0022's NAS/S3 blob backend stays open research; the Ceph PVC is bounded and disposable.
- **Runners:** ARC controller + per-repo scale sets (`psproxmoxve`, `pbs-collection`), `containerMode: dind`, **`hostNetwork: true`** and **`nodeSelector` = talos-cp-a**, dind mounting a RWO `ceph-rbd` PVC at `/opt/pve-integration`. hostNetwork gives the docker host the node's vlan40 address (reachable from VLAN 60 with one pfSense `ci → talos-cp-a` allow); node pinning makes the RWO cache/state volume shareable across the provision → test → cleanup jobs. GitHub App creds and the `ci@pve!ci` token enter the cluster as one-off `kubectl create secret` calls from `make` (Infisical `/github-runner`, `terraform/hosts` output) — a P3b-local path; the general Infisical→k8s decision stays at P4 (ADR 0031).
- **Reaper:** a Kubernetes CronJob (hourly) using the `ci` token against the VIP, destroying any pool-`ci` guest older than 6 h — lives in `kubernetes/arc/`, not in `proxmox_host`.
- **Host plane + PSProxmoxVE:** `terraform/hosts` ISO-store ACL becomes PVEDatastoreAdmin; PSProxmoxVE's nested VMs get `pool_id = "ci"` and VMIDs 5091/5092/5081/5082.
- **Retirement:** github-runner 113 stopped + `onboot 0` (ADR 0028: never destroyed), removed from `vm-configs.tf`, `backup_jobs`, `services.yml`, and the role deleted — after the first green ARC run.

## Rejected alternatives

- **kube-vip services mode** — Talos's API VIP is native, so kube-vip is a new component either way; MetalLB is the boring one.
- **Installing ingress-nginx now** — nothing in P3b speaks HTTP through an ingress; Zot is a docker endpoint.
- **Cloudflare DNS-01 (ADR 0022's original line)** — leaks the name to CT logs for no gain on a LAN-only service; the internal CA's trust distribution is needed anyway for `.internal` names.
- **Plain HTTP + `insecure-registries`** — daemon.json surgery on every client and against ADR 0022.
- **Re-hosting PSProxmoxVE's storage containers as cluster Services** — a PSProxmoxVE refactor outside this kickoff; hostNetwork is one line and reversible.
- **Reaper as a node systemd timer (`proxmox_host`)** — would put CI logic in the hypervisor role; the CronJob lives beside the runners it cleans up after.
- **CephFS CSI for a RWX cache volume** — a second CSI driver to avoid one `nodeSelector`.

## Consequences

- `kubernetes/` gains `metallb/`, `cert-manager/`, `zot/`, `arc/`; `make talos-lb|talos-certs|talos-registry|talos-arc|talos-trust|registry-smoke`.
- vlan40 offsets 64–79 are reserved for LB addresses (document in `vlans.yaml` comment / plan doc); `registry.<domain_suffix>` is an AdGuard rewrite.
- The runner pod shares talos-cp-a's network namespace; accepted until a dedicated worker exists post-RMA (`nodeSelector` change only).
- pfSense (hand-managed) gains `ci → talos-cp-a` allow; ADR 0032's rule set otherwise unchanged.
- Infisical `/github-runner` stays as the source folder (read by `make talos-arc`), the `github_runner` Ansible role and `services.yml` play go.
- The PBS collection scale set idles until its workflow adopts `runs-on: [self-hosted, pbs]`.
