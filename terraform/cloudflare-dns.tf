# Cloudflare DNS — VPS relay record
# Direct A record (not proxied — non-HTTP traffic needs direct connection)

resource "cloudflare_dns_record" "vps" {
  zone_id = var.cloudflare_zone_id
  name    = "vps.clintflix.tv"
  type    = "A"
  content = vultr_reserved_ip.vps.subnet
  ttl     = 300
  proxied = false
  comment = "VPS WireGuard relay — managed by Terraform"
}

resource "cloudflare_dns_record" "plex" {
  zone_id = var.cloudflare_zone_id
  name    = "plex.clintflix.tv"
  type    = "A"
  content = vultr_reserved_ip.vps.subnet
  ttl     = 300
  proxied = false
  comment = "Plex TLS endpoint — managed by Terraform"
}
