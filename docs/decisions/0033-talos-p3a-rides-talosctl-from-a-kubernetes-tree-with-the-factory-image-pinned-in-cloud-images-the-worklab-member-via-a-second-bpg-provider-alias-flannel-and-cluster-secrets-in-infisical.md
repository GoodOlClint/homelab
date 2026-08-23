# ADR 0033 — Talos P3a rides talosctl from a kubernetes tree with the factory image pinned in cloud_images, the worklab member via a second bpg provider alias, Flannel, and cluster secrets in Infisical

- **Status:** Accepted (approved 2026-08-23, built the same day)
- **Date:** 2026-08-23
- **Deciders:** operator + agent
- **Context source:** P3a brownfield gate, [docs/talos-p3a-plan.md](../talos-p3a-plan.md); amends [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md)

## Context

ADR 0031 decided *that* a 3-node Talos cluster is the services plane and left the build-level forks open: image source and pin, machine-config tooling, sizing, API addressing, CNI, how worklab's temporary third member is defined when worklab sits outside the fleet root's PVE endpoint, and where the cluster secrets live. The siderolabs terraform provider is mid-churn (stable 0.11; 0.12 alphas add `talos_machine`/`talos_cluster` and move to the factory installer). The fleet root's `modules/proxmox-vm` is cloud-init/Ubuntu-shaped (user-data template, gateway preconditions, `ansible_host` derivation) and has no business rendering a Talos guest. worklab's only path to VLAN 40 is `vmbr0` (the 2.5G install-profile port, tagged-mgmt auto); its 10G `vmbr1` trunk is Storage-access and does not carry 40 (probed 2026-08-23).

## Decision

- **Image:** Talos **v1.13.9** Image Factory **nocloud qcow2** with the `siderolabs/qemu-guest-agent` extension, schematic `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`, pinned by sha512 as `cloud_images.talos` — the ADR 0016 contract, rolled with `make rebuild`. Talos upgrades use the same schematic's installer ref via `talosctl upgrade`; the qcow2 pin only governs first boot.
- **VMs:** a plain `proxmox_virtual_environment_vm` block in `terraform/talos.tf`, **not** the module: `talos-cp-a` (ms-01a, VMID 230) and `talos-cp-b` (ms-01b, VMID 231) pinned by `node_name`, `talos-cp-w` (worklab, VMID 232) through a **second bpg provider alias `proxmox.worklab`** with a new bootstrap secret `worklab_password`. 4 vCPU host-type / 8 GB / 40 GB, no HA resource, `onboot`, no cloud-init drive — Talos boots to maintenance mode on DHCP and takes its config over the API. **Two legs:** `net0` on the Services VNET (worklab: `vmbr0` tag 40 — the only worklab bridge that carries 40) and `net1` on the Ceph public VLAN 20 at MTU 9000, the same ADR 0017 exception PBS holds, because the mons sit on `.20.x` and VLAN 20 has no router — CSI cannot reach Ceph from vlan40 alone. On the MS-01s that is `vmbr0` tag 20; on worklab it is `vmbr1` **untagged** (the Pro-Agg port is Storage-access native 20, and UniFi drops tagged frames on the native VLAN — probed 2026-08-23: tagged dead, untagged answers).
- **Machine configs:** `talosctl` driven from a **`kubernetes/` tree** (`kubernetes/talos/` patches, `kubernetes/ceph-csi/` values) via `make talos-*` targets. Static addresses `.40.61/.62/.63` (+ `.20.61/.62/.63` on the Ceph leg, no gateway, interfaces selected by MAC), kube-apiserver on the Talos **layer-2 shared VIP `.40.60`**, `allowSchedulingOnControlPlanes: true`, Flannel (Talos default), cluster name `homelab`.
- **Secrets:** `talosctl gen secrets` output and the `talosconfig` live in Infisical **`/talos`** (`talos_secrets_yaml`, `talosconfig` as base64; loaded by the `infisical_login.yml` nested-path loop). `make talos-secrets` pulls them to gitignored `kubernetes/talos/.secrets/`; kubeconfig is regenerated with `talosctl kubeconfig`.
- **Storage:** ceph-csi RBD (Helm) against the existing `ceph-rbd` pool with a dedicated `client.csi-rbd` cephx user (mgr/mon/osd profile caps on that pool only), StorageClass `ceph-rbd` set default.

## Rejected alternatives

- **siderolabs/talos terraform provider in the fleet root** — churn (0.12 alpha resource model) and the cluster secrets would land in fleet state; revisit when 0.12 is stable.
- **Rendering Talos through `modules/proxmox-vm`** — every module invariant (cloud-init user-data, gateway scan, `ansible_host`, `image` precondition wiring) is Ubuntu-shaped; forcing a `type = "talos"` branch in would spread conditionals through a module that is about to lose its reason to exist for services guests.
- **nocloud user-data carrying the machine config** — puts the machine secrets in a cephfs snippet; maintenance-mode `apply-config --insecure` costs one extra step and keeps secrets off the datastore.
- **Hand-built worklab VM via `qm`** — undocumented drift; the alias costs ~15 lines and the second `terraform plan` then covers all three.
- **Cilium now** — nothing in P3a/P3b needs NetworkPolicy or kube-proxy replacement; a later swap is a documented Talos procedure, not a rebuild.
- **SOPS file for the Talos secrets** — breaks the "Infisical is the runtime tier, SOPS is bootstrap-only" rule for no gain.
- **Dedicated workers now** — three 4/8 CPs carry Zot + ARC; workers join at P4 if a migration needs them.

## Consequences

- New canonical pipeline: `kubernetes/` (Talos patches, Helm values, manifests) — Talos/K8s state is never touched by Ansible; `make talos-*` is the only operator surface. `terraform/talos.tf` is the one terraform file with a second PVE provider; it is deleted from the fleet root when worklab's member is replaced by msi after the RMA (the `talos-cp-w` resource goes, the alias stays until then).
- Infisical gains `/talos` (owner: the `make talos-secrets` flow, no Ansible role, no agent reader).
- `backup_jobs.nightly-fleet` gains 230/231 (etcd on the VM disk; worklab's 232 has no PBS reach — deliberate, it is temporary).
- Ceph gains `client.csi-rbd`; the pool stays shared with PVE RBD images (CSI uses its own `csi-vol-` prefix).
- Registry, ARC, ingress/LB and runner retirement are P3b.
