# unifi-network — aggregation switch + migration-touched UniFi config (WP5)

Scope per ADR 0005: the new USW-Pro-Aggregation and the config the MS-01
migration touches. Full-fabric import (Pro-24, Flex, APs) is future work.

What it manages:

- **L2 VLANs** the controller doesn't have yet — the UniFi-only entries in
  `vlans.yaml` (`managed_by: ["unifi"]`): corosync 31/32 (ADR 0008) and ceph 33
  (ADR 0014). Created as `vlan-only` networks: no subnet, no DHCP, no gateway.
  Dual-managed VLANs (pfsense+unifi) already exist in the hand-managed
  controller and are referenced read-only via data sources.
- **Port profiles** (`tf-` prefix): `trunk` (forward all — node bonds, uplink,
  downlink), plus native-access profiles for ceph, corosync, corosync-ring1,
  and storage (NAS LAG members).
- **The switch device**: adoption, `jumboframe_enabled` (device-level — this is
  the storage-VLAN jumbo knob), per-port profile assignment, and LACP
  aggregates (`aggregate_members` on the first member port).

This module is consumed by the **separate `terraform/unifi/` root** (own
state), not the fleet project — the 0.55 provider connects to the controller
at plan time, which must never gate a routine fleet plan (same separate-plane
rationale as `terraform/hosts/`, ADR-0002).

## Enabling (Day-0, after racking the switch)

1. Adopt the switch in the controller; note its MAC.
2. Copy `network-data/unifi-ports.example.yaml` →
   `network-data/local/unifi-ports.yaml` (gitignored) and fill the MAC + real
   port map. SFP28 25G ports are 29–32 on the Pro-Aggregation.
3. Copy `terraform/unifi/vars.auto.tfvars.example` → `vars.auto.tfvars` and
   fill; seed `unifi_admin_password` in `bootstrap.sops.yml` (currently
   unfilled — the Makefile exports it as TF_VAR_unifi_password).
4. `make unifi-plan` / `make unifi-apply` (interactive confirm).

DoD (plan WP5): apply produces the complete working switch config with zero
hand edits; re-apply is a no-op; node bonds negotiate LACP; jumbo validated
end-to-end (`ping -M do -s 8972` to the NAS).

Provider: `ubiquiti-community/unifi ~> 0.55` — the module was written against
the 0.55 schema (`vlan`, `purpose = "vlan-only"`, `aggregate_members`); 0.41
had incompatible attribute names.

## Provider quirks (learned live, first apply 2026-08-11)

- **`third_party_gateway = true` is mandatory on every `unifi_network`** here:
  the site's gateway is pfSense, the controller pins the flag true, and the
  provider's false default fails post-apply verification on every write.
- **Access profiles use `forward = "customize"`**, not `"native"` — the
  controller normalizes native→customize on write (same semantics: native
  network set, nothing tagged), and the echo fails verification otherwise.
- **`unifi_device` writes always error** ("invalid result object" — unknown
  `port_override` sub-attributes) even when the write LANDS. Recovery ritual:
  check the controller applied it, `terraform untaint` the device, re-plan;
  converges in one or two rounds.
- **Never set `jumbo_frames` for aggregation models** — the controller refuses
  the toggle (`api.err.JumboFrameChangeNotAllowed`; jumbo is always-on and the
  field reads false). Binding is per-switch for models with a real toggle.
- The controller normalizes/renames silently; after any errored apply, diagnose
  from `rest/networkconf` / `stat/device` reality first — most "failures" were
  successful writes with a broken read-back.
- The `terraform` UniFi user needs full Network **Administrator** — Viewer
  passes plan (reads) and 403s only at apply.
