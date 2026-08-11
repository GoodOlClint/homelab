# The aggregation switch itself: adoption, jumbo (device-level — covers the
# storage VLAN end-to-end), and every port override incl. LACP aggregates.
# Port assignments are site bindings — they live in the gitignored ports file.
resource "unifi_device" "aggregation" {
  mac                = local.switch.mac
  name               = try(local.switch.name, "USW-Pro-Aggregation")
  # null = leave the device default. The Pro-Aggregation REFUSES this toggle
  # (api.err.JumboFrameChangeNotAllowed — jumbo is always-on for aggregation
  # models, the field just reads false); set jumbo_frames in the bindings only
  # for switches that actually expose the toggle (e.g. the 48-port PoE).
  jumboframe_enabled = try(local.switch.jumbo_frames, null)
  allow_adoption     = true
  forget_on_destroy  = false

  dynamic "port_override" {
    for_each = local.switch.ports
    content {
      index             = port_override.value.index
      name              = try(port_override.value.name, null)
      port_profile_id   = try(local.profile_ids[port_override.value.profile], null)
      op_mode           = length(try(port_override.value.aggregate_members, [])) > 0 ? "aggregate" : null
      aggregate_members = try(port_override.value.aggregate_members, null)
    }
  }
}
