# ADR 0023 — Proxmox cluster create and join use the community.proxmox API module, not pvecm-over-SSH

- **Status:** Accepted
- **Date:** 2026-08-11
- **Deciders:** operator + agent
- **Context source:** Worklab validation campaign W4 (docs/pre-migration-state/worklab-campaign-w4-results.md)

## Context

The `proxmox_host` role's `cluster.yml` created and joined the PVE cluster by shelling out to `pvecm create` / `pvecm add ... --use_ssh`. W4 (nested 3-node dress rehearsal) proved the JOIN is unreliable under Ansible: it failed **in-play three distinct ways across repeated fresh rebuilds** — an indefinite hang, a cross-host `hostvars[first].ring0_ip` resolution error, and (after both were worked around) a silent failure where `pvecm add` never actually executed on the joining node (no `pve-cluster`/corosync activity in its journal). The identical command succeeds **100% of the time** run by hand or via `ansible ... -m command` ad-hoc. Three role/harness patches (set_fact ring IP, join retries, an inter-node SSH mesh) did not make the in-play join reliable. `pvecm add --use_ssh` restarts `pve-cluster`/`pveproxy` mid-command and drives its own nested SSH; something in that dance is fragile under Ansible's non-interactive execution and not worth further reverse-engineering.

Proxmox exposes cluster create/join over its HTTP API (`POST /cluster/config`, `/cluster/config/join`), and the maintained `community.proxmox` collection (v2.0.0) wraps it in idempotent modules.

## Decision

The `proxmox_host` role creates and joins the cluster with the **community.proxmox** modules over the PVE API — never `pvecm ... --use_ssh`:

- `community.proxmox.proxmox_cluster` (state=present) creates on the first node (cluster_name + link0/link1) and joins the rest (master_ip + fingerprint + link0/link1).
- **Joins are strictly serial with a completion gate between them** (amended 2026-08-11): PVE's create and join are async background workers and the module returns as soon as the POST is accepted — it can report `changed` for a join that later aborts. A join also transiently drops master quorum while corosync reconfigures, so a join submitted while the previous one is in flight is rejected with `cluster not ready - no quorum?`. The role therefore orchestrates the whole sequence `run_once` from the control node: create → wait quorate → per-joiner (join → wait until the master reports it online and quorate) → final full-membership gate. `throttle: 1` on a bare join task is NOT sufficient — it serializes the POSTs, not the workers.
- `community.proxmox.proxmox_cluster_join_info` is read **once** from the first node; the join fingerprint is the `pve_fp` of the **master's own nodelist entry** (selected by name — `nodelist[0]` is only safe on a clean 1-node cluster; the list is unordered once members exist).
- `master_ip` is the master's **mgmt** address (amended 2026-08-19 on the real MS-01 cluster, reversing the 2026-08-11 ring0 amendment): the module's re-run idempotency check compares `master_ip` against `/cluster/status` node `ip` fields, which PVE derives by resolving each nodename through `/etc/hosts` — the answer-file install writes the mgmt IP there — so a ring0 `master_ip` made the second `make proxmox-hosts` fail "Node is already part of a cluster". The 2026-08-11 reasoning assumed those fields were ring0 addresses; measured live they are not (the nested harness had mgmt==ring0 and could not tell the two apart). Rings still go in `link0`/`link1`.
- `community.proxmox.proxmox_cluster_status_info` gates on quorum and full membership.

The modules run **`delegate_to: localhost`** and authenticate to each node's API at its mgmt IP as `root@pam` (password via `proxmox_host_api_password`, sourced from the bootstrap root password), `validate_certs: false`. Delegation keeps the `proxmoxer` dependency on the control node only — no python deps on the PVE nodes. This retires the SSH mesh, ring-IP-as-host-fact, and join-retry workarounds W4 accreted.

New dependencies: `community.proxmox` (galaxy, version floor `>=2.0.0` in `ansible/requirements.yml`) and `proxmoxer >= 2.3` + `requests` (control-node venv, added to the `make init` pip install alongside `ansible` itself — the venv is the interpreter the delegated modules run under).

## Rejected alternatives

- **Keep `pvecm add --use_ssh`, harden further** (pseudo-tty, async, alternate invocation): three patches already failed; the mechanism is opaque and self-severing, and chasing it burns cutover-prep time with no confidence of a fix.
- **`lae/ansible-role-proxmox`** (mature all-in-one cluster+Ceph role): a much larger adoption that would displace the working `ceph.yml`/`keepalived.yml`; its PVE-Ceph support is upstream-flagged experimental. Not worth the blast radius when only the join is broken.
- **Run the modules on the nodes** (api_host=localhost): needs `proxmoxer` on every PVE node (externally-managed python — pip fights PEP 668, and `python3-proxmoxer` packaging is unreliable). Delegation to the control node avoids the whole problem.

## Consequences

- `cluster.yml` is rewritten to the module flow; the WP2 Terraform/Ansible boundary line "Cluster create/join (`pvecm`) … Ansible" now means *the community.proxmox API modules*, not raw `pvecm`. Update the boundary table in `docs/ms01-cluster-iac-plan.md` and the CLAUDE.md WP2 references.
- The `proxmox_host` playbook must supply `proxmox_host_api_password` (bootstrap root password). The role stays otherwise Infisical-free; this is the tier-1 host credential, available pre-guest.
- `ansible/requirements.yml` gains `community.proxmox`; `make init` must install it. The control venv needs `proxmoxer>=2.3`.
- W4's join workarounds (SSH mesh pre-tasks, ring0_ip set_fact, join retries) are obsolete once this lands; the nested harness drops them. The Ceph PG/MDS self-heal is unaffected (a separate nested-fidelity concern).
- Follow-up (operator, 2026-08-11): audit the rest of the role's CLI-shelling tasks (qdevice `pvecm qdevice setup`, `pveceph` flow, `pvesm`/`pvesh`/`qm`/`pct` call sites) for community.proxmox / community.general module replacements where the collection covers our exact need — same failure-driven motivation, tracked in memory.
- **Validation status (amended 2026-08-11 — the topology theory is withdrawn):** the "second joiner fails only in the nested harness, plausibly a shared-NIC ring artifact" hypothesis was disproven by reading the nodes' PVE task logs after a failed run. The real cause was **overlapping joins**: both joiners POSTed within the same second (and, on the first attempt, while `clustercreate` itself was still running); the master is transiently non-quorate while corosync reconfigures for the previous join, so the overlapping join aborts with `cluster not ready - no quorum?` while the Ansible module still reports `changed`. This is topology-independent and WOULD have recurred at cutover. Fixed by the serialized, membership-gated orchestration above; re-validated end-to-end on the recreated nested harness.
- The join module returns before PVE's async clusterjoin task completes and can report success even if that task later aborts; the per-joiner membership gate and final quorum/membership gate (`proxmox_cluster_status_info` with retries) are the real checks that the cluster actually formed.
