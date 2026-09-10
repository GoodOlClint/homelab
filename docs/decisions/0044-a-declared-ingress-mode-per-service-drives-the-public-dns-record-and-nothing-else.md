# ADR 0044 — A declared ingress mode per service drives the public DNS record and nothing else

- **Status:** Proposed
- **Date:** 2026-08-29
- **Deciders:** operator + agent
- **Context source:** extends [ADR 0035](0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md) (one Traefik LB) and [ADR 0040](0040-p5-real-dns-on-a-flat-public-domain-zone-bind-fed-by-nsupdate-external-dns-adguard-forwards-rewrites-retired-let-s-encrypt-dns-01-wildcards-as-traefik-s-default-cert-two-authentik-realms-split-by-audience-jellyfin-over-the-vps-relay-with-ldap-auth.md) §P5b/P5d (LE wildcards, the Jellyfin relay path) · plan: [docs/ingress-policy-plan.md](../ingress-policy-plan.md)

## Context

Exposure has been decided ad hoc, one service at a time. Plex and Jellyfin reach the internet over the VPS WireGuard relay; Seerr and Tautulli over a Cloudflare tunnel whose routes exist only in a dashboard; everything else is LAN-only. Nothing in the repo states which services are public or by what path, so answering "what of mine is on the internet" means reading `cloudflare-dns.tf`, a role default in `vps_nftables`, a Vultr firewall block and a web console.

The forthcoming Case Project guests make this concrete: they must be reachable by remote testers on `<name>.<service domain>` with publicly-trusted TLS, and they will not be the last.

Surveying what exists first showed the four intuitive "modes" are not four mechanisms. `none` and `vps` differ **by one DNS record** — both terminate on the same Traefik LB, with the same Let's Encrypt wildcard and the same middleware chain, because `:443` is already open end to end on the relay for Jellyfin. Two further facts fell out of the survey: `auth.<service domain>` already serves a public LE certificate (it inherits `wildcard-tls` as Traefik's default TLS store), and Plex already terminates its own LE certificate on a distinct port over the relay — so a guest holding its own certificate is an existing pattern, not a new one.

## Decision

1. **One tracked map in Terraform is the single home for public exposure.** `terraform/ingress.tf` keys each entry by a bare label with the domain interpolated from `module.network.*` — never a literal, since the service domain is a gitignored binding.
2. **`mode` drives the public DNS record, and nothing else.** `none` emits nothing; `vps` an A + AAAA at the relay's reserved IP; `tunnel` a CNAME at the tunnel target; `direct` an A at the WAN. Everything downstream — listener, certificate, forward-auth — is already shared and is not re-implemented per mode.
3. **`tls` is a separate axis from `mode`.** `tls = "traefik"` inherits the wildcard; `tls = "self"` means the backend terminates and gets a public-CA certbot lane. Coupling the two would misdescribe Plex, which is `vps` + `self` today.
4. **The public-CA lane is a new sibling of `cert_client`, not a change to it.** The existing role is hardwired to Infisical's private directory over `dns-rfc2136` against BIND. A publicly-trusted certificate must validate at the **public** authoritative nameserver, so the variant is Let's Encrypt + `python3-certbot-dns-cloudflare` reading `/infrastructure/cloudflare_dns_api_token` — the credential cert-manager already holds. *Amended 2026-09-10 (#36): this lane already exists — `cert_client` gained `cert_client_issuer: letsencrypt` (dns-cloudflare, per-consumer `cert_client_cloudflare_token`) with ADR 0049, and `plex_certificate` is an `include_role: cert_client` on it. `tls = self` consumes that switch; no `cert_client_public` role is built.*
5. **`direct` is built, with the pfSense NAT row as a documented hand step.** pfSense has no API in this repo and stays hand-managed per ADR 0005.
6. **Terraform never owns the WAN record.** It is DDNS-owned by pfSense's Cloudflare client; `direct` looks it up at run time, exactly as `internal_zones` already treats `vpn`.
7. **Retrofit is part of the change, and its test bar is a no-op.** The existing five public names move under the map with `make plan` showing **0 changes**. The map must provably describe reality before it drives it.

## Rejected alternatives

- **A mode per mechanism, implemented separately.** Would have built three parallel paths to one Traefik listener. `none` vs `vps` is one DNS record; treating them as separate subsystems is the parallel-implementation defect.
- **Publishing exposure from the Kubernetes tree** (an annotation consumed by external-dns). Splits the answer to "what is public" across two substrates and leaves VM-hosted services with no home at all.
- **Cloudflare-proxied records for the media paths.** Already rejected in ADR 0040 — direct-play bitrates hit Cloudflare's non-HTML streaming limits.
- **Making `tls` implicit in `mode`.** Plex is `vps` + own certificate and Jellyfin is `vps` + wildcard; one axis cannot express both.
- **Implementing pfSense REST (`pfrest`) to make `direct` declarative.** A subsystem of its own that pulls firewall management into an ingress change. Left open.

## Consequences

- **"What is exposed" becomes one file.** The audit that previously spanned four systems is a diff.
- **A public name is in Certificate Transparency logs forever.** Naming Case guests after clients or matters leaks that relationship; labels must be opaque.
- **`direct` exposes the home WAN address**, unlike `vps`. Inherent to the mode; `vps` stays the default for anything without a specific reason.
- New surfaces: `terraform/ingress.tf` (the `cert_client_public` role is moot — see decision 4) and hand-step rows in [docs/operator-hand-steps.md](../operator-hand-steps.md) for the pfSense NAT and tunnel routes.
- Tunnel routes stay a dashboard step. The token-authenticated `cloudflared` deployment carries no route config, so `tunnel` is the one mode the map cannot fully drive; it records intent, not configuration.
- `make plan` gains a class of diff that is always a defect: any non-zero plan during the retrofit means the map and reality disagree.
