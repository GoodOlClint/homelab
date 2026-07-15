# ADR 0003 — Decompose services to static-IP LXCs, VMs only where isolation demands

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** operator + agent
- **Context source:** ~/okf/brainstorm/workload-placement-vm-lxc-docker.md · docs/ms01-cluster-iac-plan.md

## Context

The stack is 100% VMs — a legacy of vGPU (a VM was the only way to share the GPU) and of an old IaC blocker: the bpg provider couldn't read a DHCP-assigned LXC address back (bpg issue #2349 — **verified 2026-07-10: fixed in provider v0.88**, so this is no longer a technical blocker). With vGPU retired, LXCs offer iGPU sharing via `/dev/dri` bind-mounts (Plex/QuickSync), one host kernel to patch instead of ~18 guest kernels, and near-instant rebuilds — a good fit for the repo's greenfield philosophy. Full VMs still earn their cost where the kernel boundary matters. LXCs restart-migrate only (verified: no live migration in any PVE version, but with disks on Ceph the blip is stop+start — sub-second to a few seconds), so availability-critical services need an answer for planned host maintenance.

## Decision

Guests are LXCs by default; a VM requires one of: non-Linux kernel, untrusted code execution, or crown-jewel secret isolation. Placement: **VMs** — infisical (vault, `protected=true`), pfsense (FreeBSD), github-runner (untrusted CI), proxmox-backup, unifi (UOS/Podman — nesting too finicky), LLM (GPU passthrough, pinned to pve). **LXCs** — plex (`/dev/dri` iGPU), adguard, dns, lancache, squid, homepage, mcp, minio, doge. **docker-on-LXC** (`nesting=1`, `keyctl=1`) — plex-services, openobserve, docker-legacy. **Retired** — nvidia-licensing. Every LXC gets a static IP via Terraform `initialization.ip_config` — **never DHCP an LXC** — extending the existing `vm_id → static IP` convention. The provider *can* now read DHCP LXC addresses (v0.88+), but static assignment keeps the inventory deterministic at plan time instead of dependent on apply-time reads and lease stability; the rule stands as convention, not workaround. **DNS gets availability by redundancy, not migration:** two AdGuard LXCs and a BIND9 primary/secondary pair, pinned to different nodes, with both resolvers handed out to clients — zero downtime for planned maintenance *and* unplanned node failure.

## Rejected alternatives

- **Stay all-VM** — keeps per-guest kernels, slower rebuilds, and forces vGPU-style tricks (or a wasted iGPU) for Plex transcode.
- **LXC for infisical** — operator held the VM line: the one box whose compromise unlocks everything else keeps hardware isolation.
- **LXC-share the NVIDIA GPU on pve (LLM as container)** — puts the NVIDIA driver back on the host, recreating the host-driver/reboot coupling the migration exists to kill; passthrough VM keeps the driver in the guest.
- **DHCP for containers** — readable since provider v0.88, but it makes inventory an apply-time artifact hostage to lease churn; static IPs keep addresses a plan-time fact.
- **AdGuard/BIND as VMs for live migration** — solves planned maintenance only; a node *failure* still takes DNS down until HA restarts it. Redundant instances cover both cases and IaC deploys the second instance for near-zero marginal cost.
- **Docker VMs instead of docker-on-LXC** — acceptable fallback per-service if nesting misbehaves (density is not a goal), but not the default.

## Consequences

- The `proxmox-vm` module grows `proxmox_virtual_environment_container` support (or a sibling module); inventory output gains guest type + node.
- Ansible roles port as-is over SSH; tasks assuming a VM (qemu-guest-agent, kernel/sysctl tuning like the SABnzbd NFS knobs) need `when: not lxc` guards or move to the host.
- LXCs restart-migrate only: non-DNS LXCs blip for seconds on host maintenance — accepted. DNS is exempted via redundancy (adds a second AdGuard + a BIND secondary to the fleet, config sync owned by IaC/zone-transfer, and a client-facing change: both resolver IPs handed out via pfSense DHCP).
- "Never DHCP an LXC" enters CLAUDE.md What Never To Do.
- BOINC left open: CPU-only LXC or dropped — decide before the docker-legacy stack lands (plan WP4).
