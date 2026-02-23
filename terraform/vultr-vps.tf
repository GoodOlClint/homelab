# Vultr VPS — WireGuard Relay
# Dumb encrypted relay in Dallas. Forwards Plex, Valheim, and mobile WireGuard
# traffic through a WireGuard tunnel back to pfSense at home.

# ──────────────────────────────────────────────
# Look up Alpine Linux OS ID dynamically
# ──────────────────────────────────────────────

data "vultr_os" "alpine" {
  filter {
    name   = "name"
    values = ["Alpine Linux x64"]
  }
}

# ──────────────────────────────────────────────
# Startup Script (runs on first boot only)
# ──────────────────────────────────────────────

resource "vultr_startup_script" "vps_bootstrap" {
  name = "vps-wireguard-relay-bootstrap"
  type = "boot"
  script = base64encode(<<-SCRIPT
    #!/bin/sh
    set -e

    # Install Python3 (required for Ansible)
    apk update
    apk add python3 openssh-server

    # Configure SSH authorized key
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${file(pathexpand(var.ssh_public_key_path))}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Enable and start SSH
    rc-update add sshd default
    rc-service sshd start
  SCRIPT
  )
}

# ──────────────────────────────────────────────
# Reserved IP (survives instance replacement)
# ──────────────────────────────────────────────

resource "vultr_reserved_ip" "vps" {
  label   = "${var.vps_label}-ip"
  region  = var.vps_region
  ip_type = "v4"
}

# ──────────────────────────────────────────────
# Firewall Group + Rules
# ──────────────────────────────────────────────

resource "vultr_firewall_group" "vps" {
  description = "WireGuard relay firewall — strict inbound"
}

# WireGuard tunnel from pfSense
resource "vultr_firewall_rule" "wg_tunnel" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "51821"
  notes             = "WireGuard tunnel (pfSense peer)"
}

# Plex media streaming
resource "vultr_firewall_rule" "plex" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "32400"
  notes             = "Plex media streaming"
}

# Valheim game server (Phase 2)
resource "vultr_firewall_rule" "valheim" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "2456:2458"
  notes             = "Valheim game server"
}

# Mobile WireGuard relay (opaque UDP forwarded to pfSense)
resource "vultr_firewall_rule" "mobile_wg" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "51820"
  notes             = "Mobile WireGuard relay"
}

# ICMP ping (for UptimeRobot and Uptime Kuma monitoring)
resource "vultr_firewall_rule" "icmp" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "icmp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  notes             = "ICMP ping — external monitoring"
}

# SSH — only during provisioning (two-phase firewall)
resource "vultr_firewall_rule" "ssh_provisioning" {
  count             = var.vps_provisioning ? 1 : 0
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
  notes             = "SSH — provisioning only (remove after Ansible run)"
}

# ──────────────────────────────────────────────
# IPv6 Firewall Rules (mirrors IPv4 rules above)
# ──────────────────────────────────────────────

# WireGuard tunnel from pfSense (IPv6)
resource "vultr_firewall_rule" "wg_tunnel_v6" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "51821"
  notes             = "WireGuard tunnel (pfSense peer) — IPv6"
}

# Plex media streaming (IPv6)
resource "vultr_firewall_rule" "plex_v6" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "32400"
  notes             = "Plex media streaming — IPv6"
}

# Valheim game server (IPv6)
resource "vultr_firewall_rule" "valheim_v6" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "2456:2458"
  notes             = "Valheim game server — IPv6"
}

# Mobile WireGuard relay (IPv6)
resource "vultr_firewall_rule" "mobile_wg_v6" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "51820"
  notes             = "Mobile WireGuard relay — IPv6"
}

# ICMPv6 (required for IPv6 to function — NDP, path MTU discovery)
resource "vultr_firewall_rule" "icmpv6" {
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "icmp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  notes             = "ICMPv6 — required for NDP and path MTU discovery"
}

# SSH provisioning (IPv6)
resource "vultr_firewall_rule" "ssh_provisioning_v6" {
  count             = var.vps_provisioning ? 1 : 0
  firewall_group_id = vultr_firewall_group.vps.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "22"
  notes             = "SSH — provisioning only (remove after Ansible run) — IPv6"
}

# ──────────────────────────────────────────────
# VPS Instance
# ──────────────────────────────────────────────

resource "vultr_instance" "vps" {
  label             = var.vps_label
  region            = var.vps_region
  plan              = var.vps_plan
  os_id             = data.vultr_os.alpine.id
  firewall_group_id = vultr_firewall_group.vps.id
  script_id         = vultr_startup_script.vps_bootstrap.id
  reserved_ip_id    = vultr_reserved_ip.vps.id
  enable_ipv6       = true
  backups           = "disabled"
  ddos_protection   = false # Set to true for ~$10/month Vultr DDoS mitigation (10 Gbps)
  activation_email  = false

  lifecycle {
    ignore_changes = [script_id]
  }
}
