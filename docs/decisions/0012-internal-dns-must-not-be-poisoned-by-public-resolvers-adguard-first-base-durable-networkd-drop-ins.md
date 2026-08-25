# ADR 0012 — Internal DNS must not be poisoned by public resolvers: AdGuard-first base, durable networkd drop-ins

- **Status:** Accepted — amended for containers by [ADR 0029](0029-adguard-is-an-lxc-pair-behind-a-keepalived-vip-container-resolv-conf-is-terraform-owned-adguard-only-except-on-the-resolver-cts.md) (CT resolv.conf is Terraform-owned; the drop-in mechanism stays VM-only) Scoped exception (ADR 0040 P5b, 2026-08-25): cert-manager's DNS-01 self-check queries public resolvers only (`dns01RecursiveNameserversOnly`) — the AdGuard → BIND chain answers the service zone authoritatively and never sees the `_acme-challenge` TXT; no other component may bypass AdGuard.
- **Date:** 2026-07-27
- **Deciders:** operator + agent (session 2026-07-27)
- **Context source:** ADR 0011 Consequences (exporter repairs) · ansible/roles/dns_config/ · network-data/vlans.yaml

## Context

Every VM's cloud-init netplan listed `1.1.1.1` ahead of AdGuard (`dns_servers` in `network-data/vlans.yaml`, deliberately ordered so greenfield bootstrap has DNS before AdGuard exists). With a public resolver in a link's server set, systemd-resolved sticks to whichever server answers — and 1.1.1.1 answers NXDOMAIN for every split-horizon `*.<internal-domain>` name. The `dns_config` role masked this with per-link `resolvectl` calls, which are runtime-only: any reboot silently reverted the fleet to the poisoned state. This is what kept pbs-exporter down (ADR 0011) and makes any internal-name consumer fail nondeterministically after a reboot, looking like a missing DNS record rather than resolver ordering.

## Decision

Three parts, all operator-approved and rolled out 2026-07-27:

1. **Base order flips: AdGuard first, `1.1.1.1` second** in `vlans.yaml` `dns_servers`. The public resolver remains only as greenfield-bootstrap failover (resolved uses it while AdGuard doesn't exist yet).
2. **`dns_config` deploys systemd-networkd drop-ins**, not resolvectl: `/etc/systemd/network/10-netplan-<iface>.network.d/dns-override.conf` with an empty `DNS=` reset followed by AdGuard v4+v6 and the VLAN's `Domains=`. Drop-ins in `/etc` apply to the netplan-generated files in `/run` and survive both reboots and netplan regeneration.
3. **`update-dns.yml` is the rollout vehicle** and gained the standard `full_pre_tasks` pre-flight it was missing (its `dns_zones` assert could never have passed before).

Verified: fleet rollout to 15 VMs, then a reboot of the openobserve VM with zero manual fixes — resolver came back AdGuard-only and internal names resolved (the same reboot re-poisoned DNS before this change).

## Rejected alternatives

- **AdGuard-only base (`dns_servers: ['<adguard-ip>']`).** Deadlocks greenfield bootstrap: the AdGuard VM itself needs working DNS to download AdGuardHome from GitHub before AdGuard exists.
- **A netplan override file (`/etc/netplan/90-dns-override.yaml`).** Tried live and disproven: netplan *merges* `nameservers.addresses` lists across files (verified with `netplan get` — the union appeared), so an override can add servers but can never remove `1.1.1.1`.
- **BIND as the fallback resolver.** `named.conf.options` is `recursion no` — authoritative-only, cannot resolve public names.
- **Keeping resolvectl.** Runtime-only; demonstrated failure mode is exactly the incident that prompted this ADR.

## Consequences

- Fresh VMs have a pre-Ansible window where `1.1.1.1` is present (as failover behind AdGuard); the drop-in removes it at the first `dns_config` run. Internal names may be flaky in that window — bootstrap flows use IPs, so impact is minimal.
- If AdGuard is down, VMs resolve nothing new. Accepted: AdGuard was already the single resolver for every other client on the network; the VM-only public fallback merely masked partial outages while breaking split-horizon.
- The `vlans.yaml` reorder only reaches **future** VMs (cloud-init file changes are `ignore_changes` on live VMs). Discovered while verifying: the current `terraform plan` wants to **replace all 17 VMs** for pre-existing reasons (`latest` Ubuntu cloud-image size drift forces image replacement, and the MAC formula changed from sha256-name to vm_id-based since the fleet was built). **`make apply` is a destroy-the-fleet foot-gun until that drift is deliberately reconciled** — likely as part of the MS-01 greenfield migration rather than in place.
- The AdGuard DNS rewrites themselves are still hand-seeded on the live instance (initial-only template, ADR 0011 / CLAUDE.md trap); the rewrite *content* is now correct in the repo for fresh builds (`from_prefix` fix).
