# Port profiles (site-wide; tf- prefix marks Terraform ownership).
#
# trunk_all — node bond0 members, pfSense uplink, Pro-24 downlink: every
# network tagged, controller-default native. Jumbo is a device-level toggle
# (jumboframe_enabled on the switch), not a profile property.
resource "unifi_port_profile" "trunk_all" {
  name = "tf-trunk-all"
  # "customize" with no tagged/excluded lists = all VLANs tagged. The
  # controller normalizes "all" to this the moment a non-default native is
  # set, and the provider fails post-apply verification on the echo.
  forward = "customize"
  autoneg = true
  # Native = Infrastructure (VLAN 30), NOT the controller-default VLAN 1 and
  # NOT None: UniFi switch management and factory-default adoption both ride
  # the trunk's untagged path (the Pro-Agg itself DHCPs untagged on VLAN 30),
  # so a tagged-only trunk would orphan downstream switches. Node bonds only
  # use tagged subifs and ignore the native either way.
  native_networkconf_id = data.unifi_network.infrastructure.id
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
