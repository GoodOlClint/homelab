# UniFi-only L2 VLANs — vlan-only purpose: no subnet, no DHCP, no gateway.
# pfSense never sees these (corosync/ceph are unrouted by design).
resource "unifi_network" "l2" {
  for_each = local.unifi_only_vlans

  name    = each.value.name
  purpose = "vlan-only"
  vlan    = each.value.id
  # The site's gateway is pfSense (ADR 0005) — the controller pins this true
  # on every network; the provider default of false otherwise fights it on
  # every apply and fails post-apply verification.
  third_party_gateway = true
}

# Pre-existing hand-managed networks referenced by port profiles (read-only).
data "unifi_network" "storage" {
  name = local.network_data.vlans.storage.name
}

data "unifi_network" "infrastructure" {
  name = local.network_data.vlans.infrastructure.name
}

data "unifi_network" "core" {
  name = local.network_data.vlans.core.name
}

data "unifi_network" "vivint" {
  name = local.network_data.vlans.vivint.name
}

data "unifi_network" "iot" {
  name = local.network_data.vlans.iot.name
}

data "unifi_network" "management" {
  name = local.network_data.vlans.management.name
}
