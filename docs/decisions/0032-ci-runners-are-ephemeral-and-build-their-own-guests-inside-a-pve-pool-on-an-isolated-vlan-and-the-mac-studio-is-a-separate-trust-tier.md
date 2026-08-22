# ADR 0032 — CI runners are ephemeral and build their own guests inside a PVE pool on an isolated VLAN and the Mac Studio is a separate trust tier

- **Status:** Accepted
- **Date:** 2026-08-22
- **Deciders:** operator + agent
- **Context source:** migration-remaining review session 2026-08-22; `PSProxmoxVE/.github/workflows/integration-tests.yml`

## Context

Today's github-runner is one persistent Ubuntu VM, dual-homed, with a GitHub App from Infisical `/github-runner`; every job runs on the same long-lived host with reach into the fleet. PSProxmoxVE's integration workflow (`runs-on: [self-hosted, proxmox, integration]`) uses a **parent PVE API token + Terraform to create nested PVE VMs** and tests against them with a root password; the PBS collection's integration job is the same shape. The operator also wants Apple-silicon CI on the Mac Studio (MLX repos). Requirements: the runner creates and destroys its own guests, has zero access to fleet guests, and its guests are VLAN-isolated.

## Decision

- **Ephemeral only.** Runners are ARC runner-scale-set pods on the [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md) cluster — one fresh pod per job, just-in-time registration, destroyed on completion. No persistent Linux runner is ever registered again.
- **Registration + workflow policy:** repo-scoped scale sets; GitHub App permissions limited to `actions:read` + `administration:write`; `pull_request_target` banned on self-hosted; fork PRs never run self-hosted; self-hosted labels only on trusted-branch workflows.
- **CI sandbox on Proxmox:** PVE resource pool `ci`, user `ci@pve` with an API token holding VM-admin privileges on `/pool/ci` only, datastore access to one storage, SDN access to one VNET; **no `/` or `/nodes` privilege**. VMID range **5000–5999** reserved for CI guests. A **`ci` VLAN** (number placed by the operator in `vlans.yaml`/pfSense; DHCP allowed — the no-DHCP-LXC rule is about fleet determinism, and these guests are disposable) with rules: `ci → internet` allow, `ci → RFC 1918` deny, `runner → ci` allow, `runner → vlan30:8006` allow, default deny. A **reaper** destroys any pool-`ci` guest older than N hours.
- **Runner egress:** GitHub, the fleet registry, apt-cache, `vlan30:8006`, the `ci` VLAN. Denied to vlan10 and every fleet guest. No `secrets` fact, no Infisical agent on runners; `PVE_API_TOKEN` (the scoped one) and test passwords are GitHub repo secrets. The fleet's own Terraform token is never given to CI.
- **Mac Studio = separate trust tier:** native `actions/runner` under launchd as a dedicated low-privilege macOS user (own home, no keychain), its own labels (`macos, studio`) and registration, trusted-branch workflows only. It is persistent by nature; the process, not the network, is the boundary.

## Rejected alternatives

- **Greenfield-replace the VM as-is (213)** — keeps one host per every job; a compromised workflow owns the runner.
- **Ephemeral containers without Kubernetes** — equivalent security, rejected only because ADR 0031 brings the cluster anyway.
- **Give CI the fleet Terraform token with a VMID convention** — convention is not enforcement; PVE ACLs on a pool are.
- **CI guests on the services VLAN** — a nested PVE under test would sit beside production services.
- **macOS runner in a VM/container** — not a supported or practical shape for Apple-silicon CI.

## Consequences

- Proxmox side (`terraform/hosts/` + `proxmox_host` role): pool, user, token, ACLs, VNET; pfSense side (ADR 0005, hand-managed, documented): the `ci` VLAN + rules. `vlans.yaml` gains `ci`.
- Reaper: a systemd timer on a node (role `proxmox_host`) or an ARC finalizer — pick at build; must exist before the first integration job.
- The `github_runner` role and `/github-runner` Infisical folder retire with the VM; the GitHub App creds move to the ARC secret.
- PSProxmoxVE / PBS-collection workflows: `PVE_TARGET_NODE` → ms-01a while msi is on the RMA-pending CPU; `PVE_ENDPOINT` → the VIP.
- Open: the Mac Studio runner's own repo (`openclaw-mac-studio-setup`) owns its launchd unit; this ADR only fixes the trust boundary.
