# Port profiles (site-wide; tf- prefix marks Terraform ownership).
#
# trunk_all — node bond0 members, pfSense uplink, Pro-24 downlink: every
# network tagged, controller-default native. Jumbo is a device-level toggle
# (jumboframe_enabled on the switch), not a profile property.
resource "unifi_port_profile" "trunk_all" {
  name    = "tf-trunk-all"
  forward = "all"
  autoneg = true
}

# Access profiles — native-only ports: the ceph SFP28 node links (ADR 0014),
# the corosync ports (used on the 2.5G switch later; profiles are site-wide),
# and the NAS LAG members (storage VLAN).
resource "unifi_port_profile" "access" {
  for_each = merge(
    { for k, v in local.unifi_only_vlans : k => unifi_network.l2[k].id },
    { storage = data.unifi_network.storage.id },
  )

  name                  = "tf-${replace(each.key, "_", "-")}-access"
  # "customize" + native network + no tagged networks = an access port. The
  # controller normalizes "native" to this on write, which fails the
  # provider's post-apply verification if we say "native" here.
  forward               = "customize"
  native_networkconf_id = each.value
  autoneg               = true
}
