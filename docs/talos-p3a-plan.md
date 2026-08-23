# P3a change plan — Talos services-plane cluster (ADR 0031 build, ADR 0033 forks)

Status: **Proposed 2026-08-23** — awaiting operator approval. Decision record: [ADR 0033](decisions/0033-talos-p3a-rides-talosctl-from-a-kubernetes-tree-with-the-factory-image-pinned-in-cloud-images-the-worklab-member-via-a-second-bpg-provider-alias-flannel-and-cluster-secrets-in-infisical.md). Scope: three control-plane VMs, cluster bootstrap, Ceph CSI RBD, the `kubernetes/` tree. Registry, ARC, ingress and runner-113 retirement are P3b.

## Existing state (mapped 2026-08-23)

- Cluster: ms-01a/ms-01b/msi, PVE 9.2.11, Ceph mons on VLAN 20 (`.20.55/.65/.45`), pool `ceph-rbd` (3.2 TB, 18 % used), no `client.csi-*` user yet. No HA resources for any guest.
- worklab: standalone PVE 9.2.10 at `.30.75`, 16 cores / 93 GB free, `local-lvm` 1.8 TB. VLAN 40 reachable only via `vmbr0` (2.5G, install profile); VLAN 20 reachable only **untagged** on `vmbr1` (Storage-access port). Its own `Storage@vmbr1` tagged leg is dead (36 frames since boot — operator item, outside this plan).
- Free VMIDs 230–232 on both the cluster and worklab. Free vlan40 offsets 60–63; vlan20 offsets 61–63.
- Fleet root: `cloud_images` pin map (ADR 0016/0025), module is cloud-init-shaped; `worklab-campaign/` root shows the worklab bpg provider pattern (root@pam + password).
- Tooling: `kubectl` present on the workstation; `talosctl`, `helm` are not (brew).

## Changes

| # | Change | Files |
|---|---|---|
| 1 | Pin Talos v1.13.9 factory qcow2 (schematic `ce4c9805…`, sha512) as `cloud_images.talos` | `terraform/variables.tf` |
| 2 | `talos.tf`: `proxmox.worklab` provider alias (`worklab_endpoint`, `worklab_password` vars; password from a new `bootstrap.worklab_password` SOPS key exported by the Makefile), `local.talos_nodes` map (VMID, node, offsets, MACs), `proxmox_virtual_environment_vm.talos_cp` ×2 on the cluster + `talos_cp_worklab` ×1 (download_file on worklab too — its `local` datastore), `talos_nodes` output | `terraform/talos.tf`, `terraform/variables.tf`, `Makefile`, `bootstrap.sops.yml` |
| 3 | `kubernetes/talos/`: `cluster.env` (name, endpoint VIP, node IPs), `patches/common.yaml` (install disk `/dev/vda`, installer image ref from the schematic, allowSchedulingOnControlPlanes, VIP on the services NIC), `patches/<node>.yaml` (hostname, two static NICs by MAC, MTU 9000 on the Ceph leg), `.secrets/` gitignored | `kubernetes/talos/**`, `.gitignore` |
| 4 | `kubernetes/ceph-csi/values.yaml` (clusterID = fsid, mons, rbd only), `storageclass.yaml` (`ceph-rbd`, default, `client.csi-rbd`), `secret` rendered from the cephx key at deploy time (never committed), `test/pvc-smoke.yaml` | `kubernetes/ceph-csi/**` |
| 5 | Make targets: `talos-build` (targeted apply of the three VMs + download files), `talos-secrets` (pull/generate `/talos` Infisical secrets → `.secrets/`), `talos-apply` (gen config + apply-config to maintenance nodes by DHCP address from terraform output, then static), `talos-bootstrap` (bootstrap + kubeconfig + wait Ready), `talos-csi` (ceph user + helm install + storageclass), `talos-smoke` (PVC + pod write/read) | `Makefile` |
| 6 | `/talos` added to the Infisical nested-path loop; CLAUDE.md: canonical pipeline `kubernetes/`, folder-ownership row, make targets; plan doc P3 row; `backup_jobs.nightly-fleet` += 230, 231 | `ansible/tasks/infisical_login.yml`, `CLAUDE.md`, `docs/ms01-cluster-iac-plan.md`, `vars.auto.tfvars` |

## Sequencing (each step a commit after it verifies)

1. Pins + `talos.tf` + Makefile + SOPS key → `make talos-plan` shows 3 VMs + 2 download files to add, nothing else. Commit.
2. `make talos-build` → three VMs running in maintenance mode, DHCP addresses visible via the guest agent. Verify `qm config` on each host, `ha-manager status` lists none.
3. `kubernetes/talos` tree + `make talos-secrets` (generates `secrets.yaml` once, writes to Infisical `/talos`) + `make talos-apply` → nodes reboot onto static `.40.61–63`, VIP `.40.60` answers on :6443 after bootstrap. Commit.
4. `make talos-bootstrap` → `kubectl get nodes` 3 Ready; `talosctl etcd members` 3. Commit.
5. `ceph auth get-or-create client.csi-rbd` (profile rbd on pool ceph-rbd) + `make talos-csi` + `make talos-smoke` → PVC Bound, pod writes/reads. Commit.
6. Second fleet-root `terraform plan`: no changes for the talos resources. Docs (CLAUDE.md, plan doc P3 row, ADR 0033 → Accepted), backup job. Commit. P3b kickoff.

## Test bar / DoD

`kubectl get nodes` — three CPs Ready, one per host (`qm config 230/231/232`, `ha-manager status` shows none); `talosctl etcd members` = 3; `kubectl get pvc` Bound on `ceph-rbd` and a pod round-trips a file; second `terraform plan` clean for talos VMs; commits on `nut-client`.

## Rollback

`terraform destroy -target` is banned for shared blocks (ADR 0028 lesson) — the talos resources are their own blocks, so `terraform state rm` + `qm destroy` per VM is the retirement path. Ceph user removal: `ceph auth del client.csi-rbd`. Nothing in the bootstrap tier changes.

## Risks / notes

- Talos maintenance mode on a DHCP lease in the vlan40 pool: pfSense probes before leasing; the lease is only used for the first `apply-config`.
- worklab member is temporary (ADR 0031): after the msi RMA, `talos-cp-w` is removed from etcd (`talosctl etcd remove-member`), the VM destroyed, and a `talos-cp-c` on msi added — same files, one map entry.
- ADR 0016: `latest` container tags apply to the Helm charts (`ceph-csi-rbd` unpinned); Talos/K8s versions are the pinned-and-rolled exception, same as OS images.
