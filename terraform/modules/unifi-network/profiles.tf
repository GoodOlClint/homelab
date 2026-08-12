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
  # Native = None (operator decision 2026-08-11): trunk ports carry TAGGED
  # traffic only — untagged frames are dropped. Operational consequence,
  # accepted: UniFi switch management and factory-default adoption ride the
  # untagged path, so a downstream switch on a tf-trunk-all port must have a
  # tagged management VLAN configured (or be adopted before the port moves to
  # this profile).
  #
  # native_networkconf_id is DELIBERATELY ABSENT: the 0.55 provider cannot
  # express "None" (an empty string is dropped from the write payload and
  # read back as unset, so "" here diffs forever). The None was set once via
  # the controller API (PUT rest/portconf/<id> {"native_networkconf_id":""})
  # and Terraform leaves the attribute unmanaged. If the profile is ever
  # recreated, re-run that PUT — a fresh create defaults to the VLAN 1
  # Default network.
}

# Node install-link ports on the 48-port switch (ADR 0019): the i226-V that
# carries the untagged VLAN 30 install/mgmt plane PLUS corosync ring0 tagged
# (network.yml leaves ring0 tagged on the install NIC after the mgmt re-home).
resource "unifi_port_profile" "node_install" {
  name    = "tf-node-install"
  forward = "customize"
  # Native 30 untagged + all VLANs tagged: the node's i226-V only opens a
  # ring0 (VLAN 31) subif, so allow-all-tagged is functionally equivalent to
  # a corosync-only tag list — which the controller cannot store in the
  # legacy tagged_networkconf_ids field anyway (it silently drops it when
  # tagged_vlan_mgmt is custom; the modern model wants exclusion lists).
  native_networkconf_id = data.unifi_network.infrastructure.id
  tagged_vlan_mgmt      = "auto"
  autoneg               = true
}

# Access profiles — native-only ports: the ceph SFP28 node links (ADR 0014),
# the corosync ports (used on the 2.5G switch later; profiles are site-wide),
# and the NAS LAG members (storage VLAN).
resource "unifi_port_profile" "access" {
  for_each = merge(
    { for k, v in local.unifi_only_vlans : k => unifi_network.l2[k].id },
    { storage = data.unifi_network.storage.id },
    # Core access: untagged client ports on the aggregation switch (Mac
    # Studio 10G via the patch loop — no VLAN config needed on macOS).
    { core = data.unifi_network.core.id },
  )

  name                  = "tf-${replace(each.key, "_", "-")}-access"
  # "customize" + native network + no tagged networks = an access port. The
  # controller normalizes "native" to this on write, which fails the
  # provider's post-apply verification if we say "native" here.
  forward               = "customize"
  native_networkconf_id = each.value
  autoneg               = true
}
