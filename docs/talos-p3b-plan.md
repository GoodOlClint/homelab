# P3b change plan — LoadBalancer, Zot registry, ARC runners, retire github-runner 113

Status: **Approved 2026-08-23** (self-signed CA is a placeholder for Infisical PKI — see ADR 0034). Decision record: [ADR 0034](decisions/0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md). Follows [P3a](talos-p3a-plan.md) / [ADR 0033](decisions/0033-talos-p3a-rides-talosctl-from-a-kubernetes-tree-with-the-factory-image-pinned-in-cloud-images-the-worklab-member-via-a-second-bpg-provider-alias-flannel-and-cluster-secrets-in-infisical.md); builds [ADR 0022](decisions/0022-container-images-pull-through-a-fleet-local-registry-via-templated-refs-the-registry-rebuilds-itself-from-upstream.md) (registry) and [ADR 0032](decisions/0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md) (CI sandbox).

## Existing state (mapped 2026-08-23)

- Cluster: `talos-cp-a/b/w` Ready (k8s 1.36.2, Flannel), `ceph-rbd` default StorageClass, only ClusterIP services. No LB, no ingress, no cert-manager. Deploy pattern = `helm template | kubectl apply` (`kubernetes/ceph-csi/deploy.sh`).
- vlan40 addressing: offsets 10–20, 51–52, 101–115 (fleet guests), 60–63 (Talos VIP + nodes); DHCP pool `.100–.254` (pfSense). Offsets **64–79** are free on both counts.
- github-runner 113: Ubuntu VM, dual-homed, two `actions/runner` instances labelled `self-hosted,proxmox,integration` for `goodolclint/PSProxmoxVE`, GitHub App creds in Infisical `/github-runner` (`github_app_id`, `github_app_private_key`, `github_app_installation_id`), docker-prune timer. In `backup_jobs.nightly-fleet`, `services.yml` play `github-runner`, `infisical_login.yml` loop.
- CI sandbox (ADR 0032, applied): pool `ci`, `ci@pve!ci` token = `terraform -chdir=terraform/hosts output -raw ci_api_token`, ACLs PVEVMAdmin+PVEPoolAdmin on `/pool/ci`, PVEDatastoreUser on `ceph-rbd` + `cephfs`, PVESDNUser on `Homelab/Ci`. VNET `Ci` (VLAN 60) exists. Repo secrets `PVE_ENDPOINT`/`PVE_API_TOKEN` and vars `DISK_STORAGE=ceph-rbd ISO_STORAGE=cephfs NETWORK_BRIDGE=Ci PVE_TARGET_NODE=ms-01a` set on PSProxmoxVE 2026-08-23.
- PSProxmoxVE `tests/infrastructure`: nested VMs created **without `pool_id`**, VMIDs 99091/99092/99081/99082, auto-install ISO uploaded via the API (needs `Datastore.AllocateTemplate` — not in PVEDatastoreUser), the answer server + NFS/iSCSI storage containers run `--net=host` on the runner's docker host and the nested VMs must reach that IP; `/opt/pve-integration` holds the ISO cache **and the terraform state shared by the provision → test → cleanup jobs**. Jobs run in `container:` with the docker socket mounted.
- PBS collection: no self-hosted job yet (`integration.yml` is `ubuntu-latest`, workflow_dispatch).
- Workstation: `helm`, `talosctl`, `kubectl`, `docker` present; no `crane`.

## Decisions (ADR 0034)

1. **MetalLB L2**, `IPAddressPool` = vlan40 offsets 64–79, L2Advertisement on all nodes.
2. **cert-manager with a self-signed internal CA** (`ClusterIssuer homelab-ca`); registry name `registry.<domain_suffix>` → AdGuard rewrite to the LB IP. CA cert exported to `kubernetes/.secrets/homelab-ca.crt` by make; trusted on the Talos nodes via a `machine.files` patch (containerd registry config) and on the workstation by hand. Fleet docker-daemon trust lands with the ADR 0022 ref-templating follow-on. **Amends ADR 0022's Cloudflare DNS-01 line.**
3. **Zot** (upstream image ref, never through itself) with proxy namespaces `docker.io`, `ghcr.io`, `quay.io`, TLS from the cert-manager Certificate, one `ceph-rbd` PVC (50 GB; ADR 0022's NAS/S3 blob backend stays an open research item — cache blobs are disposable, so a Ceph PVC is acceptable until the S3 pick lands). Service type LoadBalancer on :443.
4. **ARC** (`gha-runner-scale-set-controller` + two `gha-runner-scale-set` releases: `psproxmoxve` labels `self-hosted,proxmox,integration` for `GoodOlClint/PSProxmoxVE`; `pbs-collection` for `GoodOlClint/ansible-collection-proxmox_backup_server`, idle until its workflow adopts it). `containerMode: dind`, **`hostNetwork: true` + `nodeSelector` talos-cp-a**, dind mounts a RWO `ceph-rbd` PVC at `/opt/pve-integration`. GitHub App creds: one-off `kubectl create secret` from Infisical `/github-runner` via `make` (P3b-only path; the general Infisical→k8s decision stays at P4 per ADR 0031).
5. **Reaper** = k8s CronJob in the `arc-runners` namespace (hourly, `curl`+`jq` against the VIP with the `ci@pve!ci` token, destroys any pool-`ci` guest older than 6 h). Token secret created by `make` from the `terraform/hosts` output. Satisfies ADR 0032's "must exist before the first integration job".
6. **PSProxmoxVE changes (its own repo, branch `ci/pool-ci`):** `pool_id = "ci"` on the nested VMs, default VMIDs 5091/5092/5081/5082 (inside the ADR 0032 range), `PVE_ENDPOINT` already the VIP. **Host plane:** `terraform/hosts` ACL on the ISO store becomes PVEDatastoreAdmin (`Datastore.AllocateTemplate` for the ISO upload).
7. **pfSense (hand-managed, ADR 0005):** `ci → talos-cp-a` (vlan40 .61) allow — the nested VMs fetch their answer file and mount NFS/iSCSI from the runner node. Documented in `docs/pfsense-ci-vlan.md` as an operator item; the ADR 0032 rule set is otherwise unchanged.
8. **Retire 113:** `qm stop 113` + `onboot 0` (never destroy, ADR 0028); drop from `vm-configs.tf` + `backup_jobs`; delete `ansible/roles/github_runner`, the `services.yml` play + `github-runner` tag, and the `/github-runner` loop entry — **only after** the PSProxmoxVE run is green on ARC. The Infisical folder stays (it is now the source for the k8s secret).

## Changes

| # | Change | Files |
|---|---|---|
| 1 | `kubernetes/metallb/` — `deploy.sh` (helm template metallb), `pool.yaml` (IPAddressPool from `nodes.json` subnet + offsets 64–79, L2Advertisement) | `kubernetes/metallb/**` |
| 2 | `kubernetes/cert-manager/` — `deploy.sh` (helm template cert-manager + CRDs), `issuer.yaml` (selfsigned → CA Certificate → `ClusterIssuer homelab-ca`), CA export to `kubernetes/.secrets/` | `kubernetes/cert-manager/**`, `.gitignore` |
| 3 | `kubernetes/zot/` — `deploy.sh`, `config.json` (sync on-demand per upstream, TLS paths), `zot.yaml` (ns, PVC, Deployment, Certificate, Service LoadBalancer) | `kubernetes/zot/**` |
| 4 | Talos trust: `patches/common.yaml` gains `machine.files` for `/etc/cri/conf.d/hosts/registry.<domain_suffix>/{hosts.toml,ca.crt}` rendered by `talos.sh` from the exported CA (apply = rolling `apply-config`, no reboot) | `kubernetes/talos/**` |
| 5 | `kubernetes/arc/` — `deploy.sh` (controller + scale sets via helm template, GitHub App secret from Infisical, ci-token secret from `terraform/hosts` output, reaper CronJob), `values-controller.yaml`, `values-psproxmoxve.yaml`, `values-pbs.yaml`, `reaper.yaml`, `cache-pvc.yaml` | `kubernetes/arc/**` |
| 6 | Make: `talos-lb`, `talos-certs`, `talos-registry`, `talos-arc`, `talos-trust` (CA → nodes), `registry-smoke` (`docker pull registry.<domain_suffix>/docker.io/library/busybox`) | `Makefile` |
| 7 | Host plane: `ci_storages` ACL role PVEDatastoreAdmin on the ISO store | `terraform/hosts/iam.tf`, `variables.tf` |
| 8 | AdGuard rewrite `registry.<domain_suffix>` → LB IP (`make adguard-rewrite`) | none (API) |
| 9 | PSProxmoxVE: `pool_id`, VMIDs, branch + PR | `~/Source/PSProxmoxVE/tests/infrastructure/{main.tf,scripts/run-integration.sh}` |
| 10 | Retire 113 (see Decision 8) | `terraform/vm-configs.tf`, `vars.auto.tfvars`, `ansible/roles/github_runner/`, `ansible/playbooks/services.yml`, `ansible/tasks/infisical_login.yml` |
| 11 | Docs: ADR 0034, ADR 0022 amendment note, CLAUDE.md (pipelines, make targets, folder table, tags), plan-doc P3 row, `docs/pfsense-ci-vlan.md` | docs |

## Sequencing (commit after each verifies)

1. MetalLB → `kubectl get svc` shows a test LoadBalancer with EXTERNAL-IP `.40.64`, `curl` answers from the workstation. Commit.
2. cert-manager + CA + Zot → PVC Bound, `registry.<domain_suffix>` resolves (AdGuard rewrite), workstation trusts the CA, `docker pull registry.<domain_suffix>/docker.io/library/busybox` succeeds. Talos trust patch applied (`talosctl` re-apply, `crictl pull` equivalent via a pod using the registry ref). Commit.
3. `terraform/hosts` ACL bump (`make hosts-plan` shows 1 change; apply). PSProxmoxVE branch pushed + PR. Commit (homelab side).
4. ARC controller + scale sets + reaper + cache PVC → `kubectl get pods -n arc-systems` Running; listener registered (`gh api repos/GoodOlClint/PSProxmoxVE/actions/runners` shows the scale set). pfSense rule added by operator (blocking for step 5). Commit.
5. Operator merges the PSProxmoxVE PR → integration run on ARC; watch pool `ci` gain then lose 5091/5092/5081/5082; run URL recorded. If green: stop 113 (`qm stop` + `onboot 0`), retire files, `make inventory`. Commit.
6. `make talos-plan` + `make plan` no drift; docs + memory. Commit. P4 kickoff (new session).

## Test bar / DoD

`kubectl get svc -A` shows a LoadBalancer EXTERNAL-IP on vlan40 answering from the workstation; `docker pull` through Zot succeeds and `kubectl get pvc -n zot` is Bound on `ceph-rbd`; PSProxmoxVE integration run URL completed on an ARC pod with pool-`ci` guests created and destroyed; 113 stopped, `onboot 0`, absent from `vm-configs.tf`; second `make talos-plan` + `make plan` clean; all on `nut-client`.

## Rollback

Each component is its own namespace: `kubectl delete ns` reverses it. 113 is stopped, not destroyed — `qm start 113` + reverting the retire commit restores the old runner (its registration is still valid until the GitHub App is rotated). PSProxmoxVE branch is a PR; revert = close it.

## Risks / notes

- `hostNetwork` runner pods share talos-cp-a's network namespace (kube-apiserver :6443, Talos :50000 on localhost). Both are mTLS/token-authenticated; the runner pod holds no cluster credentials. Accepted for P3b; a dedicated worker node (post-RMA) removes it — same manifests, one `nodeSelector` change.
- RWO cache PVC forces every scale-set pod onto one node; `max-parallel: 2` test jobs share it on that node, which RBD allows.
- Zot cache blobs on Ceph NVMe contradict ADR 0022's "blobs belong on NAS" — bounded by the PVC size (50 GB, expandable); the S3 backend research item stays open.
- Internal CA means `docker pull` from fleet guests fails until their daemons trust the CA — nothing in the fleet pulls through Zot yet (templated refs are the follow-on), so no regression.
