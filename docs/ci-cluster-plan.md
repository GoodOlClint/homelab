# CI cluster change plan

Change plan for [ADR 0062](decisions/0062-arc-moves-off-the-services-cluster-onto-a-dedicated-two-node-ci-cluster-with-the-github-app-key-kept-from-job-nodes.md), with the implementation decisions in [ADR 0063](decisions/0063-the-ci-cluster-is-a-second-talos-cluster-built-by-the-same-tooling-which-takes-a-cluster-name-and-gains-a-worker-role.md) and [ADR 0064](decisions/0064-the-ci-cluster-nodes-sit-on-a-dedicated-ci-runner-vlan-filtered-at-pfsense.md). Status: approved by the operator 2026-11-19, after one Codex review.

## Goal

Actions Runner Controller (ARC) runs on a dedicated two-node Talos cluster. The node that holds the GitHub App key never runs job code. No runner pod runs on the services cluster.

## What the map found

Read on 2026-11-19 from the repo, the live cluster and the two consumer repositories.

- **Only one workflow uses the runners.** PSProxmoxVE's integration and package-currency workflows run on the `psproxmoxve` scale set, started by hand or by a weekly schedule. No pull request starts a self-hosted job.
- **The `pbs-collection` scale set has no consumer.** No branch of that repository names it.
- **Host networking is no longer needed on PSProxmoxVE's default branch.** The answer server, NFS and iSCSI run on a storage VM the job creates.
- **The cache volume holds state, not only downloads.** Terraform state, the storage VM's SSH key and answer files pass from the provision job to the test and cleanup jobs through `/opt/pve-integration`.
- **The Talos tooling assumes one cluster** in `talos.sh`, `talos.tf`, the Flux root, `k8s_seed`, `flux_check.py`, `update-nodes.yml` and the Makefile.
- **Terraform manages no Proxmox firewall.**
- **The cluster has three Proxmox nodes** (`ms-01a`, `ms-01c`, `msi`). Free memory per node is not recorded in the repo.

## Scope

In scope: the second cluster, ARC's move, the reaper's move, the new VLAN, removal of ARC from the services cluster, host maintenance for two clusters, documentation.

Out of scope: the Mac runner (ADR 0061), a VM-per-job controller, a scheduled automatic rebuild of the worker (a manual target ships first), and Proxmox firewall management in Terraform.

## Design

| Piece | Today | After |
|---|---|---|
| ARC controller and listeners | services cluster, `arc-systems` | CI cluster control-plane node |
| Runner pods | services cluster, `talos-cp-a`, host networking | CI cluster worker, pod networking |
| GitHub App key | Secret beside the runners on an etcd member of the services cluster | a fresh key, on the CI cluster, reachable only from the control-plane node |
| Scale set | `psproxmoxve`, `pbs-collection` | one new name, `psproxmoxve-ci`; the consumer workflow's `runs-on` changes to it |
| ARC manifests | `kubernetes/arc/` | a new path, `kubernetes/ci-arc/`; the old path is deleted at the end |
| Cache | 40 GiB Ceph volume | local volume on the worker's scratch disk |
| Reaper | CronJob in `arc-runners` with the job token | CronJob on the services cluster in its own namespace with its own token |
| Network | services VLAN, plus an allow from the `ci` VLAN to `talos-cp-a` | `ci-runner` VLAN; the `talos-cp-a` allow deleted |

Node sizes: control plane 2 cores and 4 GiB; worker 6 cores, 16 GiB and a 100 GiB local scratch disk. Placement: one node each on `ms-01a` and `ms-01c`, confirmed against free memory before the build. Neither VM is in pool `ci`, and neither is a high-availability resource.

### Keeping the key from the worker

Every workload that holds a credential is pinned to the control-plane node by the `node-role.kubernetes.io/control-plane` label, which a worker's kubelet cannot set on itself. That covers the ARC controller, the listeners and all four Flux controllers; the Flux Helm and Kustomize controllers hold cluster-admin, so one of them landing on the worker would break the boundary. Only runner pods may schedule on the worker. If the control-plane node is unavailable, those workloads stay Pending.

### A new scale-set name

ARC 0.14.2 looks a scale set up by name and reuses its GitHub id, so two clusters cannot hold `psproxmoxve` at once, and uninstalling the old release would delete the id the new one adopted. The CI cluster therefore registers `psproxmoxve-ci`. Cutover is a one-line change of `runs-on` in the consumer repository, and rollback is reverting that line.

## Work packages

Each package is one or more small commits. Every package names the check that fails before it and passes after.

### WP0 — Operator prerequisites (hand steps)

1. Choose the VLAN id and subnet; add `ci_runner` to `network-data/vlans.yaml`. The tracked `vlans.example.yaml` gains the schema entry.
2. pfSense: the interface, the rule table from ADR 0064, and DHCP with a reservation for each node's MAC. A fresh Talos VM needs an address before its static configuration can be delivered.
3. pfSense resolver: listen on the new VLAN and forward the `ci.<service domain>` zone to BIND for the new subnet, as it does for the `ci` VLAN. BIND's allow list gains the subnet through the `bind9` role.
4. Switch trunks for the new VLAN on the Proxmox node ports.
5. `make sdn-apply` creates the VNET from `vlans.yaml` through the fleet network module, which owns SDN.
6. Confirm free memory on the two chosen Proxmox nodes.
7. Generate a second private key for the GitHub App and store it for the CI cluster. The existing key and the App's repository grants are left alone until WP5.

Check: the VNET is active on both chosen hosts. A throwaway guest on the new VLAN resolves a public registry name and a `ci` zone name through its configured resolver, reaches GitHub and the Proxmox API port, cannot reach a services-VLAN address, and cannot be reached from a guest on the `ci` VLAN.

### WP1 — Talos tooling takes a cluster name

- `talos.tf`: the node map gains the CI nodes with a cluster and a role attribute, and accepts any number of workers. Existing keys and resource addresses are unchanged. The CI nodes have one network leg and no Ceph leg, VIP or registry trust patch.
- `talos.sh`: one validated cluster selection derives the node inventory file, the secrets directory, the Infisical folder, the kubeconfig and the control-plane endpoint. An unknown cluster, or an inventory that does not match the selection, fails before any write. A worker render is added. The CI render does not bind etcd metrics to all interfaces.
- Makefile: `talos-build CLUSTER=…` targets only that cluster's VM instances and writes only that cluster's inventory file.
- `flux_check.py` and `k8s_seed`: the kubeconfig becomes a cluster argument that defaults to the services cluster.
- `update-nodes.yml`: finds every Talos guest on the host with its cluster, and drains each through its own cluster's kubeconfig before the host reboots. The CI worker is drained only when no workflow run is active.

Checks, before any CI node exists:

1. Machine configs rendered for the three services nodes are byte-identical to a capture taken before the change.
2. `make plan` shows no change to the existing Talos VMs or image.
3. With both inventories present, a dry run of every `CLUSTER=ci` target lists no services VM, file or endpoint, and every `CLUSTER=services` target lists no CI one.
4. A mismatched inventory and an unknown cluster name each exit non-zero with nothing written.

### WP2 — Build the CI cluster

- `make talos-build CLUSTER=ci`, then secrets, apply and bootstrap for the new cluster. Its Talos secrets live in a new Infisical folder `/talos-ci`, owned by `talos.sh` as `/talos` is. CLAUDE.md's folder table gains the row.
- The build is rehearsed from blank disks with the final firewall rules in place, and the worker is rebuilt once the same way.

Check: both nodes Ready; the worker carries no control-plane role; from the worker's segment, the control-plane node answers only on the Talos and Kubernetes API ports; the services cluster's nodes and workloads are untouched.

### WP3 — Seed, Flux and ARC on the CI cluster

- `k8s_seed` gains a per-cluster object set. The CI set is: the two ARC namespaces, the Flux service account and role bindings for the ARC tree, `cluster-bindings`, the root CA, and `github-app` holding the new key. No Ceph, Infisical operator or registry objects.
- A second Flux root, `kubernetes/flux-ci/`, lists only `kubernetes/ci-arc/`. It reads the same public repository with no credential, as ADR 0048 requires. It patches all Flux controllers onto the control-plane node.
- `kubernetes/ci-arc/` is new. `kubernetes/arc/` is not edited in this package, because the services Flux root deploys that path and would roll the changes into production.
- In `ci-arc`: pod networking; runner pods select the worker role label, not a hostname; controller and listener select the control-plane node; the cache is a local volume; the scale set is `psproxmoxve-ci`; no `pbs-collection`; no reaper.

Checks:

1. Flux and Helm report Ready on the live CI cluster and the listener is connected to GitHub. `flux_check.py` alone is not the proof; it only builds local trees.
2. The services cluster's ARC release still renders its original node selector, host networking and cache claim.
3. Every pod on the worker is listed with its service account, and none can read `github-app`. The worker's kubelet credential cannot read it either.
4. With the control-plane node cordoned, a restarted Flux or ARC controller stays Pending and does not land on the worker.

### WP4 — Reaper on the trusted plane

- `terraform/hosts/iam.tf`: a separate user and token for the reaper, with privilege separation, holding only what deleting a pool-`ci` guest needs. It has no datastore and no SDN privilege.
- A new Flux tree on the services cluster, `kubernetes/ci-reaper/`, in its own namespace, using that token.
- The old CronJob is suspended before the test below, and its active Jobs are allowed to finish.

Proxmox uses one privilege, `VM.Allocate`, for both deleting and creating a guest on a pool, so this token cannot be made delete-only. What it cannot do is give a guest a disk or a network. ADR 0062's "cleanup-only scope" is met to that limit and no further.

Check: with the CI cluster powered off and the old CronJob suspended, a deliberately aged test guest is deleted, and the Proxmox task log attributes the deletion to the new identity. The token's effective permissions list shows no datastore or SDN privilege.

### WP5 — Rehearse, then cut over

Nothing on the services cluster is removed until the CI cluster has passed a full run.

1. Freeze: confirm no run is in flight and pool `ci` is empty, and hold the weekly schedule until cutover ends.
2. Rehearse: on a branch of PSProxmoxVE whose `runs-on` names `psproxmoxve-ci`, start the integration workflow by hand. Provision, test and cleanup must all pass on the CI worker.
3. Cut over: merge the `runs-on` change in PSProxmoxVE. This is a workflow-file change in a consumer repository and is the operator's to merge.
4. Record the services revision, the old cache volume's name and the old release names. Rollback from here is reverting the `runs-on` line.
5. Retire, after one more passing run from the default branch: uninstall both old scale sets while their controller, Secret and App grant still exist, and confirm GitHub shows them deregistered. Then remove `arc` from the services Flux root, delete the old namespaces, cache volume and CRDs by hand (the tree has `prune: false`), delete `kubernetes/arc/`, and drop ARC's objects from the services seed set.
6. Narrow the GitHub App to the PSProxmoxVE repository and revoke its old private key, so any copy taken from the old runner node stops working.
7. Delete the pfSense allow from the `ci` VLAN to `talos-cp-a`.

### WP6 — Acceptance and documentation

The gates from ADR 0062, each run and its output recorded:

1. A complete integration run and cleanup on the new cluster, from the default branch.
2. The reaper cleans up while the CI cluster is down, attributed to its own identity.
3. The job token cannot stop, modify or delete either CI cluster VM.
4. No identity present on the worker can read the App key.
5. No runner pod, ARC namespace or ARC secret remains on the services cluster.
6. A guest on the `ci` VLAN cannot open a connection to either CI cluster node.
7. Host maintenance on a Proxmox node that carries a guest from each cluster drains both.

Documentation: CLAUDE.md, `.claude/rules/kubernetes.md`, `docs/pfsense-ci-vlan.md`, `docs/make-targets.md`, `docs/LESSONS.md`, README. A `make` target rebuilds the worker on request.

## Portability and scale

Added 2026-11-19 at the operator's request: the design should carry to another organisation and grow past one worker. This section was written after the Codex review and has not been reviewed.

### What carries anywhere ARC runs

These parts are a pattern, independent of Talos, Proxmox and pfSense.

- Runners live on a cluster that holds no production credential and is not joined to production.
- Two node pools: a protected pool for the controller, listeners and deploy tooling, and a job pool for runner pods only. Credentialed workloads are pinned by a label the job pool cannot set on itself.
- The GitHub App is installed only where runners are used, with a key issued for the runner cluster.
- Scale sets get new names at a migration, and cutover is the consumer's `runs-on` line.
- Cleanup of test resources runs outside the job pool, under its own identity.
- The job pool sits on its own network segment with a named allow list.
- The acceptance gates in WP6 are written as questions any install can be asked.

### What is bound to this homelab

`talos.sh` and the Terraform node map, pfSense rules, the Ansible seed role, Infisical, and Proxmox pool permissions. Another site swaps these for its own cluster build, firewall, secret store and cloud permissions. ARC's values file carries no homelab address or name; those arrive through `cluster-bindings`.

### What changes in this plan so it scales

- **Workers are a pool, not a host.** The node map takes any number of worker entries, and runner pods select the worker role label, never a hostname. Adding a worker is one map entry and one build.
- **The cache is the scale limit.** Jobs pass Terraform state and an SSH key to the next job through a node-local volume, so all three jobs of a run must land on one worker. This build keeps one worker and that behaviour. The change that unlocks a second worker is in the consumer: pass job-to-job state as workflow artifacts and keep the cache for downloads only. It is listed here as the first follow-up, outside this plan.
- **One control-plane node.** A failure stops new jobs until it returns; it does not affect production. Three control-plane nodes is a node-map change when that matters.

### Open questions a larger install must answer

- **Privileged Docker-in-Docker.** Kept here because the consumer runs container jobs. A site with stricter rules chooses among ARC's Kubernetes mode, rootless Docker, a sandboxed runtime, or a VM per job.
- **Who may dispatch.** A personal GitHub account has no runner groups. An organisation account does, and can restrict a group to selected repositories and workflows; that is the enforcement point ADR 0061 could not use.
- **Job isolation between runs.** One shared worker is accepted here. A site running untrusted pull requests needs a VM per job or single-use nodes.

### Windows runners: a separate pilot, after this build

Discussed with Codex on 2026-11-19. Operator rulings: this plan is built first and its shape does not change; Windows follows as its own pilot with its own plan.

- **This plan is the Linux implementation.** ARC already handles demand, scheduling, single-use registration and cleanup for Linux pods. It is not the mechanism for Windows.
- **ARC has no supported Windows path for this cluster.** GitHub's Windows guide covers only the legacy mode, Talos has no Windows nodes, and Windows containers cannot supply what the reference case needs.
- **The reference case** is an on-premises hypervisor, tests that drive a real desktop, and tests that need domain behaviour or a reboot. That means a full Windows guest per job: create the VM, register it once, run one job, destroy it.
- **No ready-made tool was found for on-premises hypervisors.** GARM creates Windows VMs on Azure and AWS, and its provider list has no Proxmox, vSphere or Hyper-V entry. The two starting points are a GARM external provider or GitHub's `actions/scaleset` library, which is in public preview. The pilot plan chooses between them. No shared provisioner for Mac and Windows is designed until both exist.
- **What this build leaves ready for it:** the CI cluster's control-plane node is the candidate home for the piece that issues single-use registrations, since it already holds the App key away from job code. Windows guests can live in pool `ci` on the `ci` VLAN, where the reaper already removes anything older than six hours.

Questions the pilot plan must answer before any build:

1. The image: edition (Server with desktop, or a client edition), how it is patched and versioned, and Sysprep generalisation.
2. How the single-use registration reaches the guest after boot, over a channel bound to that one instance. No App key, domain credential or runner identity is ever baked into a template.
3. Domain: an isolated test domain with a disposable identity per run, and removal of the computer account afterwards. A workgroup guest wherever the test allows it.
4. Reboots: a runner reboot is not a resumable workflow step, so a rebooting installer needs a separate test target or a continuation design.
5. Desktop: the job must run in an interactive logged-in session, proven by a test that clicks something.
6. Speed: measure queue-to-first-step from a cold start before paying for a warm pool.
7. Failure: a failed boot, a cancelled job and a controller restart, each followed by a check that no runner record, VM, disk or directory object is left.
8. Licensing for the edition, the host and the peak number of running guests, including idle warm ones.

### Mac runner: notes for its own plan

Operator direction 2026-11-19, to be carried into the Mac runner plan for ADR 0061.

- The Studio is enrolled in an MDM server by hand at its rebuild, as a lab exercise that transfers to a managed fleet. The server pushes the privacy-permission profile, the VM tool and the supervisor. Fleet, self-hosted, is the first candidate.
- Zero-touch re-enrollment needs Apple Business Manager, which needs an organisation. It waits on the operator converting their developer account, which has the same prerequisites.
- Two existing tools to evaluate before writing a supervisor: GitHub's `actions/scaleset` library and `runscaler`, which is built on it and already runs macOS VM runners.

## Risks

- **Editing `talos.sh` and `update-nodes.yml` can break production's lifecycle tooling.** Mitigation: WP1's four checks, run before anything else.
- **A push to `main` deploys to both clusters within minutes.** The CI root lists one tree, so its blast radius is ARC.
- **Jobs share the worker between runs.** Accepted in ADR 0062; the job token is treated as exposed to every job.
- **The two CI nodes share a network segment,** so pfSense cannot filter between them. The control-plane node's exposure to the worker is checked in WP2.
- **The local cache volume dies with the worker.** A rebuild between a provision job and its cleanup job strands test guests; the reaper removes them within six hours.
- **The reaper token can allocate an empty guest in pool `ci`.** Proxmox cannot express less.

## Order and effort

WP0 is the operator's and gates WP2. WP1 can start at once. Rough effort: WP1 two days, WP2 and WP3 one and a half days, WP4 half a day, WP5 and WP6 one day. Five days in all, up from three before the review.

## Build notes

What the build changed against the plan as written. WP1, WP3 and WP4 are merged to local `main`, unpushed; WP2, WP5 and WP6 wait on WP0.

- **Runner pods are placed by the absence of the control-plane label,** not by a worker label. A Talos worker carries no role label, and a label a worker could give itself would be no boundary.
- **`make talos-build` targets each VM instance by name.** A whole-resource target would also build or restart the other cluster's VMs.
- **The node map is `terraform/talos-nodes.json`,** read by Terraform, the Makefile and `update-nodes.yml`.
- **The cache is a hostPath on the worker's scratch disk.** It does not fail closed if a second worker is added; the note in the manifest says so.
- **The CI Flux root reuses the services root's `gotk-components.yaml` by path,** so a local build needs `--load-restrictor LoadRestrictionsNone`. Whether Flux's own build accepts the reference shows at the first reconcile on the CI cluster.
- **The CI seed carries no root CA and an empty `cluster-bindings`;** `ci-arc` needs neither.
- **The new reaper ships suspended.** Order before the next push: `make hosts-apply`, `make k8s-seed`, then push. A seed run before `hosts-apply` fails on the missing token output.
- **WP4 done 2026-11-23.** `make hosts-apply` (targeted, since ms-01b is out of the cluster) created `ci-reaper@pve`; `make k8s-seed` seeded it and a second run reported 0 changed. A diskless VM backdated 7 h in pool `ci` was stopped and destroyed by a hand-started Job from the new CronJob, between two runs of the old reaper; the Proxmox task log credits `qmstop` and `qmdestroy` to `ci-reaper@pve`. The token's effective privileges are `Pool.Audit`, `VM.Allocate`, `VM.Audit` and `VM.PowerMgmt` on `/pool/ci` only.
- **WP0 done 2026-11-23.** Four steps the plan did not name: the VLAN also has to exist as a VLAN-only network in UniFi, or the switches drop it (pfSense's interface counted 0 packets in); the SDN VNET goes live only with `make sdn-apply REAPPLY=1`, because the applier resource does not re-run on its own; BIND answered the new subnet for the fleet zones, so `bind9_ci_vlans` now excludes `ci_runner` as well as `ci` (the job node resolves only the `ci` zone through BIND); and the pfSense rule table gains a block on the firewall itself, recorded in `docs/pfsense-ci-vlan.md`, which VLAN 60 also received. Checked from throwaway containers: a VLAN 61 guest takes a DHCP lease with the pfSense resolver, resolves public names and the `ci` zone, gets REFUSED by BIND on the fleet zone, reaches GitHub, the Proxmox API and a VLAN 60 guest, and cannot reach AdGuard, node SSH or the pfSense GUI. A VLAN 60 guest cannot reach the VLAN 61 guest.
- **WP2 done 2026-11-23.** Built from blank disks behind the final pfSense rules, then the worker rebuilt twice with `make talos-rebuild-worker`. Found and fixed: `talos.sh bootstrap` never bootstrapped a new cluster, because `grep -q` under `pipefail` made its state check fail; the rebuilt VM's DHCP lease shows before the Talos maintenance API listens, so the insecure apply retries; the CI nodes resolve through the VLAN gateway, not AdGuard. The control plane carries a Talos ingress firewall: default block, the Talos and Kubernetes API ports from anywhere, flannel VXLAN (UDP 4789 on Talos, not 8472) from the VLAN, host DNS from pods, and etcd and the kubelet from the node itself. From a pod on the worker only 6443, 50000 and 50001 answer. Finding B is closed by `close-join` (Review disposition). The services cluster was not touched.
- **The CI worker is placed on msi until ms-01b returns** (operator 2026-11-23). ms-01c took ms-01b's guests and has 45 GB of running guests plus three 4 GB OSDs on 63 GB, so a 16 GB worker no longer fits there; msi has about 35 GB free. The worker is not OOM-exempt (the hookscript covers the services cluster only), and VM 240 on msi is not either.
- **Found, not fixed:** the existing `kubernetes/arc/values.yaml` runner containers have no CPU or memory requests, and `flux_check.py` does not look inside HelmRelease values. Both go away when `kubernetes/arc/` is deleted at cutover.

## Review disposition

One Codex adversarial review of the first draft, 2026-11-19. Verdict: needs attention. Thirteen findings; twelve fixed in this revision, one fixed in part. Four were spot-checked against the files and held (the DHCP fallback in `talos.sh`, the `talos-cp-` match in `update-nodes.yml`, the unpinned Flux controllers, and SDN living in the fleet root).

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | critical | Flux controllers with cluster-admin could schedule onto the worker and expose the App key | Fixed: all credentialed workloads pinned by the control-plane label; WP3 checks 3 and 4 |
| 2 | high | Editing `kubernetes/arc/` would roll CI-only values into production, which deploys that path | Fixed: new path `kubernetes/ci-arc/`; WP3 check 2 |
| 3 | high | Two clusters registering the same scale-set name share one GitHub id | Fixed: a new permanent name, cutover by the consumer's `runs-on` line |
| 4 | high | Narrowing the App first strands the old `pbs-collection` release, which cannot then deregister | Fixed: uninstall first, narrow after; a fresh key for CI and the old key revoked |
| 5 | high | With DHCP off, a fresh Talos VM has no address to receive its first configuration | Fixed: DHCP reservations per node; rebuild rehearsed from blank disks |
| 6 | high | Matching production renders do not prove a CI command touches only CI | Fixed: one validated cluster selection; WP1 checks 3 and 4 |
| 7 | high | Proxmox cannot grant delete without create on a pool | Fixed in part: separate identity without disk or network privilege; the limit is stated, and the false "refused to create" check is dropped |
| 8 | high | The old reaper keeps running and could be credited with the new reaper's deletion | Fixed: old CronJob suspended; deletion attributed in the Proxmox task log |
| 9 | high | The first integration run came after the rollback window closed | Fixed: rehearsal before any removal; old cache and firewall rule kept until acceptance |
| 10 | high | The VNET belongs to the fleet Terraform root, not `terraform/hosts` | Fixed: `make sdn-apply` in WP0 |
| 11 | high | Host maintenance drains one cluster through one kubeconfig and would reboot the CI worker undrained | Fixed: `update-nodes.yml` in WP1; acceptance gate 7 |
| 12 | medium | Jobs could not resolve their test guests from the new VLAN | Fixed: resolver, zone forward and BIND allow in WP0, checked from the VLAN |
| 13 | medium | The Talos render binds etcd metrics to all interfaces, reachable from the worker | Fixed: omitted from the CI render; ports checked from the worker's segment in WP2 |

### Review of the merged work packages

One Codex adversarial review of WP1, WP3 and WP4 as merged (`980fddd..43bc908`), 2026-11-19. Verdict: needs attention, hold the push. Seven findings.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| A | high | `update-nodes.yml` skips the drain when the services kubeconfig is missing | Fixed: a missing services kubeconfig fails the host; only a `ci` guest may be skipped |
| B | high | A CI worker keeps the cluster's Kubernetes bootstrap token in its machine config. With it, code that has taken the worker could enrol under another node's identity and read what that node's pods may read, the App key included | Fixed in WP2 (2026-11-23): `talos.sh close-join` rotates the join token after the nodes are Ready and gives the new one to the control plane only; the worker's token returns 401, and the worker's config holds no CA private key. Its other secrets (trustd token, discovery key) give no Kubernetes identity |
| C | high | A failed authenticated probe makes `talos.sh` fall back to an unauthenticated apply to the recorded address, and the CI worker shares the control plane's segment | Rejected as a code change: the fallback is how every fresh node is provisioned and is unchanged for production. Mitigated by procedure in WP2: CI workers are powered off whenever the CI control plane is built or rebuilt |
| D | high | A drain failure on the CI guest leaves the services guest cordoned | Fixed: preflight before the first cordon, and uncordon what the run cordoned on failure |
| E | high | Host maintenance can evict a running CI job; the idle check reads only the services cluster | Fixed: fail the host when the CI cluster has unfinished runner pods. The brief for WP1 had dropped this plan requirement |
| F | medium | The reaper reports success when Proxmox rejects a stop or delete, or the pool listing fails | Fixed, in the new reaper only; the old one is deleted at cutover |
| G | medium | The live Flux check raises on the CI cluster's empty `cluster-bindings` | Fixed |

Not verified by anyone: live pfSense state, and whether ARC 0.14.2 behaves as its source reads for scale-set ids. The rehearsal in WP5 is where both show.
