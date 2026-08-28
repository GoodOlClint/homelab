# Firewall platform evaluation — pfSense Plus vs OPNsense, and the Protectli hardware question

**Status:** open evaluation, no decision. Written 2026-08-28 after the pfSense SAML2 attempt failed ([ADR 0043](decisions/0043-pfsense-webconfigurator-sso-is-saml2-against-the-internal-authentik-realm-group-gated-with-local-break-glass-accounts-kept.md)).

## Summary

Two decisions get bundled here and should not be. Keep them apart:

- **Hardware** — Protectli (coreboot, Secure Boot, TPM) vs the current box. Independent of the OS; Protectli runs either.
- **OS** — pfSense Plus vs OPNsense. Driven by API architecture, auth extensibility and licensing.

**Nothing here justifies a swap on its own today.** The trigger that started this (webConfigurator SSO) is the weakest argument, and the manageability argument is already half-answered: `pfSense-pkg-RESTAPI` is installed and working on 26.07. Revisit if Plus licensing changes, if the REST API package stalls, or at the next hardware refresh — that is the natural window.

## What triggered it

pfSense has **no extension point for authentication sources**. Netgate's [package development docs](https://docs.netgate.com/pfsense/en/latest/development/develop-packages.html) document manifests, config XML, `.inc`/`.php` supporting files and PHP install hooks — and nothing for auth backends. Local/LDAP/RADIUS are hardcoded, so any SSO integration must edit `/etc/inc/auth.inc`, `authgui.inc` and `priv.inc`.

That is why `pfrest/pfSense-pkg-saml2-auth` ships patch files, why it supports CE only, and why it failed on 26.07: it fell back to the CE 2.9 patch set and hunk 3 of `auth.inc` did not apply. Upstream's stated reason for never supporting Plus is legal, not technical — Plus patches would be derived from closed source. The same wall blocks a package of our own, in any protocol.

Two hazards recorded from the attempt:

- The installer **aborts without rolling back**. Hunks 1 and 2 landed in `auth.inc`; only the exit code said anything was wrong. A half-modified login path on the firewall is the failure mode to design against.
- `pkg-static` and `curl` do not share a trust store. `curl` verified GitHub via `CApath: /etc/ssl/certs/`; libfetch reads a bundle file and failed on the Sectigo root. `env SSL_CA_CERT_PATH=/etc/ssl/certs pkg-static add …` works. Note the shell is tcsh — `VAR=x cmd` is not valid there.

OPNsense's answer is structural: `Auth` is a core MVC module, and its community OIDC plugin registers under **Access → Servers** as a first-class auth server type. Native OIDC is Business Edition (shipped Oct 2025, WebGUI + Captive Portal + OPNWAF); the free edition uses the plugin. Either way it is additive, not a patch.

## API: three options, not two

| | Netgate official | pfrest RESTAPI | OPNsense |
|---|---|---|---|
| What it is | `Netgate/pfsense-api` — OpenAPI schema + Python client for the **MIM** (Multi-instance Management Controller) | third-party package on the firewall | **core**, no package |
| Runs on | a separate controller | the firewall | the firewall |
| Coverage | 486 paths — deep (DHCP + static mappings, `dyndns/rfc`, full ACME, firewall rules/NAT, interfaces/VLANs, `vpn/wg`, certificates, packages) | broad, plus `ansible-collection-pfsense` | generated from the same MVC models that drive the GUI, so coverage tracks features |
| License | Apache-2.0 toolkit; MIM itself is a separate Netgate product | Apache-2.0 | core |
| Installed here | no | **yes, 2.10** | — |

The official toolkit is genuinely capable — it even carries `/login/saml/autheq/{name}` and `/login/ssoauth`, so Netgate is building SSO somewhere in the Plus stack. But it targets MIM, a multi-device controller, which is a product to stand up and license for a single firewall. **Open question: whether the same API is reachable directly on a Plus box or only through MIM.** Verify before weighing it.

The structural difference is that OPNsense's API is generated from its MVC models, so it cannot drift behind the GUI. pfrest's is a well-maintained third party tracking a moving target — it ships builds per pfSense version (`2.8.1`, `2.9.0`, `25.11.1`, `26.03`, `26.03.1`, `26.07`), which is both the reassurance and the exposure.

## Installed packages and where they land

pfSense Plus 26.07-RELEASE, ABI `FreeBSD:16:amd64`:

| pfSense package | OPNsense | Migration note |
|---|---|---|
| `RESTAPI` 2.10 (pfrest) | **core** | net simplification |
| `WireGuard` 0.2.13_4 | **core** since 24.1 | re-derive the VPS peer — measured MTU 1400 and the `pfctl -k` state-table trap ([ADR 0013](decisions/0013-vps-tunnel-peers-over-reserved-ipv4-mtu-is-measured-per-address-family.md)) |
| `suricata` 7.0.9 | **core** (IDS/IPS) | rule config re-entered |
| `acme` 1.3.2 | `os-acme-client` | re-do the private-CA setup ([docs/pfsense-acme.md](pfsense-acme.md)) — custom directory, RFC 2136, DNS Sleep |
| `nut` 2.8.2_9 | `os-nut` | both UPSes; `[ups]` name is hardcoded by Synology ([docs/pfsense-nut.md](pfsense-nut.md)) |
| `udpbroadcastrelay` 1.2.8 | `os-udpbroadcastrelay` | direct |
| `Avahi` 2.2_10 | `os-mdns-repeater` | **not equivalent** — a repeater, not Avahi. Check against the 6 GHz multicast work |
| `pfBlockerNG-devel` 3.2.17_1 | **none** | biggest item. Splits into core Unbound blocklists (DNSBL) + firewall aliases with GeoIP. Full re-derivation |
| `sudo` 0.3.4 | none in tree | moot — the API is why it exists |
| `arping` 1.2.2_7 | core diagnostics | trivial |
| `ipsec-profile-wizard` 1.2.6 | none | IPsec export differs; unused here? |
| `Netgate_Firmware_Upgrade`, `Nexus`, `aws-wizard` | n/a | Plus-only |

Verified against the OPNsense plugin tree and `opnsense/core`'s MVC controllers (`Wireguard`, `IDS`, `Unbound`, `Syslog`, `Trust`, `Kea`, `Auth`).

## Migration cost

pfSense is the most load-bearing hand-configured box in the fleet, and an outage takes everything. Beyond the package table, a swap re-derives:

- DHCP + **DDNS registration into BIND** — the whole P5 DNS design leans on it ([ADR 0040](decisions/0040-p5-real-dns-on-a-flat-public-domain-zone-bind-fed-by-nsupdate-external-dns-adguard-forwards-rewrites-retired-let-s-encrypt-dns-01-wildcards-as-traefik-s-default-cert-two-authentik-realms-split-by-audience-jellyfin-over-the-vps-relay-with-ldap-auth.md)), including self-registration of its own name
- per-VLAN IPv6, hand-managed by design ([ADR 0005](decisions/0005-unifi-network-config-under-terraform-now-pfsense-iac-deferred.md), [docs/ipv6.md](ipv6.md))
- firewall rules including the CI VLAN ([docs/pfsense-ci-vlan.md](pfsense-ci-vlan.md)) and the Valheim + Jellyfin forwards
- remote syslog and netconsole to the cluster LB
- the "DNS Server Override" trap — WAN-supplied resolvers preempting internal names

Wants a maintenance window, a rollback path, and console access confirmed first. Multi-session.

## Hardware — Protectli

Separate axis. coreboot + Secure Boot + TPM. Note this no longer makes the firewall an outlier: **ms-01a and ms-01b run `Secure Boot: enabled (user)` on shim+grub** as of 2026-08-28, so SB on the firewall brings it up to the nodes' posture rather than ahead of it. No prior evaluation of Protectli exists in this repo, `~/okf`, or memory — if one happened it was never recorded.

## What would actually decide this

1. Plus licensing trajectory — the strongest single driver, and outside our control.
2. Whether `pfSense-pkg-RESTAPI` keeps tracking Plus releases. It does today (a `26.07` build exists); if it stalls, the manageability argument flips hard.
3. Whether firewall SSO matters enough to want a pluggable auth stack. Today: no — LDAP covers the credential-unification half at zero risk.
4. A hardware refresh creating the window anyway.

Until one of those moves, staying is the cheap answer.
