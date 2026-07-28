# UniFi-only L2 VLANs — vlan-only purpose: no subnet, no DHCP, no gateway.
# pfSense never sees these (corosync/ceph are unrouted by design).
resource "unifi_network" "l2" {
  for_each = local.unifi_only_vlans

  name    = each.value.name
  purpose = "vlan-only"
  vlan    = each.value.id
}

# Pre-existing hand-managed networks referenced by port profiles (read-only).
data "unifi_network" "storage" {
  name = local.network_data.vlans.storage.name
}
