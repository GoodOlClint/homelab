# UniFi network module (WP5, ADR 0005) — the new aggregation switch + the
# migration-touched config only. Full-fabric import is future work.
#
# Ownership split:
#   - UniFi-ONLY L2 VLANs (managed_by == ["unifi"]: corosync 31/32, ceph 33 —
#     ADR-0008/0014) exist nowhere else, so this module CREATES them.
#   - Dual-managed VLANs (pfsense+unifi: mgmt, storage, services, …) already
#     live in the hand-managed controller config; they are referenced read-only
#     via data sources, never created (a duplicate VLAN id would conflict).

locals {
  network_data = yamldecode(file(var.vlans_file_path))
  ports_data   = yamldecode(file(var.ports_file_path))

  # Every top-level stanza with a `ports:` list is a managed switch.
  # `adopted: false` keeps a pre-populated stanza (e.g. a switch that hasn't
  # arrived yet, MAC unknown) out of the graph until it's flipped true.
  switches = {
    for k, v in local.ports_data : k => v
    if can(v.ports) && try(v.adopted, true)
  }

  unifi_only_vlans = {
    for k, v in local.network_data.vlans : k => v
    if contains(try(v.managed_by, []), "unifi")
    && !contains(try(v.managed_by, []), "pfsense")
    && !try(v.is_wireguard, false)
  }

  # Port-profile name → id, for the bindings file's `profile:` field.
  profile_ids = merge(
    { trunk = unifi_port_profile.trunk_all.id },
    { node_install = unifi_port_profile.node_install.id },
    { for k, p in unifi_port_profile.access : k => p.id },
  )
}
