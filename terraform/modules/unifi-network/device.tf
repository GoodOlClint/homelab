# Managed switches: adoption, jumbo, and every port override incl. LACP
# aggregates. Port assignments are site bindings — they live in the gitignored
# ports file. Every top-level key in that file with a `ports:` list is a
# switch; a stanza with `adopted: false` is pre-populated config that stays
# inert until the device is adopted and its real MAC filled in.
resource "unifi_device" "switches" {
  for_each = local.switches

  mac  = each.value.mac
  name = try(each.value.name, each.key)
  # null = leave the device default. The Pro-Aggregation REFUSES this toggle
  # (jumbo is always-on for aggregation models), and non-excluded switches
  # follow the site's Global Switch Settings — the controller reverts the
  # per-device field and the apply bounces forever. Only set jumbo_frames for
  # a switch listed in global_switch.switch_exclusions (README, quirks).
  jumboframe_enabled = try(each.value.jumbo_frames, null)
  allow_adoption     = true
  forget_on_destroy  = false

  dynamic "port_override" {
    for_each = each.value.ports
    content {
      index             = port_override.value.index
      name              = try(port_override.value.name, null)
      port_profile_id   = try(local.profile_ids[port_override.value.profile], null)
      op_mode           = length(try(port_override.value.aggregate_members, [])) > 0 ? "aggregate" : null
      aggregate_members = try(port_override.value.aggregate_members, null)
    }
  }
}

moved {
  from = unifi_device.aggregation
  to   = unifi_device.switches["aggregation_switch"]
}
