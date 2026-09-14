# ADR 0054 — Scratch guests live in the fleet root as their own list and get their secrets pushed at deploy time, never a vault credential

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** operator + agent
- **Context source:** issue #45 (code-intelligence asks for a scratch LXC) and the scratch-device issue form added the same day

## Context

Other projects now ask this repo for short-lived guests to prove something out before it is designed properly. #45 is the first: code-intelligence wants an LXC to run one index unit end to end, with two service users, a storage layout and two secrets, and it will throw the guest away or promote it depending on the result. More requests of this shape are expected, so the handling needs to be a convention, not a one-off.

Two facts about the existing fleet shaped the decision. First, a guest defined in `terraform/vm-configs.tf` gets a lot without further work: SDN placement, the pinned LXC template, an entry in `vms.yaml`, and through that a DNS name (`make dns-records`), patching (`make update`), the root CA (the Phase 0 play) and the apt proxy. Second, every Infisical machine identity the `infisical_client` role provisions is an organization `member` with read access to every folder in the project — `infisical_secret_paths` in the playbooks is declared but read by nothing. An agent on a guest therefore holds a credential that can read `/talos`, `/infrastructure` and the agent GitHub App keys.

## Decision

Scratch guests are a third list, `local.scratch_vms`, in `terraform/vm-configs.tf`, beside the infrastructure and services lists. Each entry carries a comment naming its request issue. The conventions:

- Services VLAN, `ip_offset` 80–99 (below the DHCP pool, above the MetalLB range), VMID = 200 + `ip_offset`.
- No HA, no backup job, no data volume. Everything on a scratch guest must be rebuildable by the requesting project.
- The fleet's one pinned LXC template (Ubuntu 26.04). A request for another distribution is answered with this template unless the software genuinely cannot run on it.
- The inventory output emits a `scratch` group, and one play (`services.yml`, tag `scratch`) runs `apt_proxy` and the `scratch` role on it.
- The `scratch` role reads a per-guest spec from `scratch_guests` in its defaults: a shared group, system users, directories, and a map of secret key → owning user. Homelab installs nothing else; the requesting project installs its own software.
- Secrets live in Infisical `/scratch/<guest name>`, seeded by the operator. The role reads them from the workstation at deploy time and writes each to `/etc/scratch-secrets/<key>`, `0400`, owned by the named user. **No Infisical agent and no machine identity is installed on a scratch guest.** A rotation is a re-run of `make ansible <guest>`.

When the proof ends, the issue closes either way. A discarded guest is removed from the list and retired with `terraform state rm` plus `pct destroy` (never a targeted destroy). A promoted guest leaves the scratch list and gets a real home, which may be a normal guest with its own role or a workload on the Talos services plane (ADR 0031).

## Rejected alternatives

**A separate Terraform root and inventory for scratch guests.** The only thing a separate state protects against is a bare fleet apply, which ADR 0028 already forbids. In exchange it would duplicate the network module wiring, the template pin and the inventory generation, and every consumer of `vms.yaml` (DNS records, updates, CA trust, the apt proxy) would need a second inventory.

**A PVE pool with a scoped token and its own VLAN, the CI shape (ADR 0032).** That isolation is right when the requester's automation creates the guests. Here homelab creates them, and the cost (a VLAN, pfSense rules, a token, a reaper) is out of proportion for one or two long-running proofs.

**The normal fleet secret path, an Infisical agent with a per-guest identity.** It would put a whole-project read credential on a machine whose software another project controls. Scoping identities per folder is the real fix and would benefit the whole fleet, but it is a separate change; until then scratch guests hold only the values they need.

**Host vars for the per-guest spec.** `ansible/inventory/host_vars/` is gitignored as a bindings location. A scratch spec holds names and paths, not bindings, so it stays tracked in the role defaults.

## Consequences

- A new scratch request is one entry in `scratch_vms`, one entry in `scratch_guests`, seeded secrets, and `make build <name>`. Firewall rules the request needs are pfSense hand steps (ADR 0005).
- Scratch guests appear in DNS, `make update` and the Phase 0 CA play like any other guest. They carry no telegraf, rsyslog or Uptime Kuma row; nobody is paged for them.
- `infisical_secret_paths` suggests a scoping that does not exist. That gap is fleet-wide and outside this ADR; it is recorded here because it is why scratch guests do not use the agent.
- The first entry is `code-intel` (#45), VMID 280 on ms-01a, 4 vCPU / 8 GB / 60 GB. Its rootfs grows in place if the full rollout needs more; the separate mount #45 suggested is not created.
