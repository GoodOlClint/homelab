# Cloudflare DNS — the media zone (ADR 0040): VPS relay records, direct (unproxied,
# non-HTTP traffic needs the real address). Zone by name from the vlans.yaml binding.

data "cloudflare_zone" "media" {
  filter = { name = module.network.media_domain }
}

locals { media_zone_id = data.cloudflare_zone.media.id }

resource "cloudflare_dns_record" "vps" {
  zone_id = local.media_zone_id
  name    = "vps.${module.network.media_domain}"
  type    = "A"
  content = vultr_reserved_ip.vps.subnet
  ttl     = 300
  proxied = false
  comment = "VPS WireGuard relay — managed by Terraform"
}

resource "cloudflare_dns_record" "plex" {
  zone_id = local.media_zone_id
  name    = "plex.${module.network.media_domain}"
  type    = "A"
  content = vultr_reserved_ip.vps.subnet
  ttl     = 300
  proxied = false
  comment = "Plex TLS endpoint — managed by Terraform"
}

resource "cloudflare_dns_record" "vps_ipv6" {
  zone_id = local.media_zone_id
  name    = "vps.${module.network.media_domain}"
  type    = "AAAA"
  content = vultr_instance.vps.v6_main_ip
  ttl     = 300
  proxied = false
  comment = "VPS WireGuard relay IPv6 — managed by Terraform"
}

resource "cloudflare_dns_record" "plex_ipv6" {
  zone_id = local.media_zone_id
  name    = "plex.${module.network.media_domain}"
  type    = "AAAA"
  content = vultr_instance.vps.v6_main_ip
  ttl     = 300
  proxied = false
  comment = "Plex TLS endpoint IPv6 — managed by Terraform"
}

resource "cloudflare_dns_record" "jellyfin" {
  zone_id = local.media_zone_id
  name    = "jellyfin.${module.network.media_domain}"
  type    = "A"
  content = vultr_reserved_ip.vps.subnet
  ttl     = 300
  proxied = false
  comment = "Jellyfin over the VPS relay (P5d) — managed by Terraform"
}

resource "cloudflare_dns_record" "jellyfin_ipv6" {
  zone_id = local.media_zone_id
  name    = "jellyfin.${module.network.media_domain}"
  type    = "AAAA"
  content = vultr_instance.vps.v6_main_ip
  ttl     = 300
  proxied = false
  comment = "Jellyfin over the VPS relay IPv6 (P5d) — managed by Terraform"
}
