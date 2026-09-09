# ADR 0046 — The internal authentik realm is published as a federation upstream so the operator keeps one identity

- **Status:** Proposed
- **Date:** 2026-08-29
- **Deciders:** operator + agent
- **Context source:** amends [ADR 0040](0040-p5-real-dns-on-a-flat-public-domain-zone-bind-fed-by-nsupdate-external-dns-adguard-forwards-rewrites-retired-let-s-encrypt-dns-01-wildcards-as-traefik-s-default-cert-two-authentik-realms-split-by-audience-jellyfin-over-the-vps-relay-with-ldap-auth.md) §P5c (two realms split by audience) · raises the stakes of [ADR 0043](0043-pfsense-webconfigurator-sso-is-saml2-against-the-internal-authentik-realm-group-gated-with-local-break-glass-accounts-kept.md) (firewall admin auth depends on this realm) · exposure rides [ADR 0044](0044-a-declared-ingress-mode-per-service-drives-the-public-dns-record-and-nothing-else.md) · plan: [docs/ingress-policy-plan.md](../ingress-policy-plan.md)

## Context

ADR 0040 split authentik into two realms **by audience**: `auth.<service domain>` internal and LAN-only for fleet administration, `auth.<media domain>` external and public for family media. The internal realm gates pfSense (ADR 0043), PVE, PBS, PDM, Portainer, MeshCentral, Headlamp, Grafana, Zot and Home Assistant.

Remote testers of the Case Project guests need to authenticate, and the guests are on the service domain. The first proposal was to publish the internal realm and put tester accounts in it. Two operator corrections reshaped that.

**First:** publishing the identity provider does not publish its relying parties. Every one of them sits behind a LAN-only Traefik, so an attacker who reaches the login page — and even succeeds — holds a session for services they cannot route to. Network isolation is doing the real work and is unchanged. The original framing overstated the blast radius.

**Second:** the operator already holds two accounts (internal for admin, external for media) and does not want a third. The first proposal would have kept it at two *and* placed tester accounts beside admin accounts in one directory.

Federation answers both: the external realm takes an OIDC/SAML **source** pointing at the internal realm, so the operator signs in there with their existing identity instead of a second credential.

## Decision

1. **The internal realm is published** at `auth.<service domain>` — `mode = vps`, `tls = traefik` under ADR 0044. It already serves the Let's Encrypt wildcard; only reachability changes.
2. **Its purpose is narrow: operator login and federation upstream.** It does not host a tester directory.
3. **The external realm federates to it.** An OIDC/SAML source in `blueprint-external.yaml` gives the operator "continue with `<internal>`" — one identity, no second credential.
4. **Case testers live in the external realm only, never in an admin group**, and the Case application is group-gated the way `pfsense-admins` already is. Admin and tester directories never merge.
5. **A `case` brand serves `auth-case.<service domain>`** over the external realm's directory, so a business tester is never redirected to the media domain to log in. No third realm.
6. **MFA is enforced on the admin-bound groups** (`authentik Admins`, `pfsense-admins`) via an authentication-flow stage in `blueprint-internal.yaml`. This is not optional and is the mitigation that carries the decision.
7. **Rate limiting at the VPS edge** reuses the per-source meter `vps_nftables` already runs for Plex.
8. **ADR 0040's audience split is amended, not reversed** — the federated topology preserves it. Only the internal realm's LAN-only property changes.

## Rejected alternatives

- **Case testers in the internal realm.** Merges admin and external-tester directories for no gain once federation exists. This was the first draft.
- **A third `case` realm.** A brand over the external directory gets the domain separation without a third Postgres, a third PBS dump lane and a third set of secrets.
- **Reusing `auth.<media domain>` as-is for testers.** Works, but redirects business testers to a media-branded domain — the reason brands are in the decision.
- **GeoIP allowlisting the auth host.** Remote testers are the point and their locations are not known in advance.
- **Keeping the realms fully separate with two operator accounts.** Directly contradicts the stated constraint, and two credentials means two MFA enrolments and two offboarding paths.

## Consequences

- **The operator goes from two accounts to one.** Federation is the mechanism; it is the primary benefit, not a side effect.
- **authentik becomes internet-facing attack surface in its own right.** An authentication bypass or RCE in the IdP is a beachhead *inside the cluster*, in a namespace holding the identity Postgres. This is independent of whether any relying party is exposed, and it is why this realm stays patched on a short leash.
- **Credential takeover becomes durable.** A brute-forced account buys nothing reachable today but stays valid, cashing in the moment the attacker reaches the LAN by any other route. MFA on admin groups is what bounds this.
- **The "no exposed relying parties" premise expires by design.** Case guests are internet-exposed *and* authenticate against this identity system; once they land, account separation (decisions 4 and 5) replaces network isolation as the control that matters.
- **External login for the operator now depends on the internal realm.** If internal is down, federated sign-in fails; family and tester *local* accounts are unaffected. The operator keeps a break-glass path into the external realm, the same reasoning ADR 0043 applies to pfSense.
- **ADR 0043's dependency deepens.** The firewall's admin auth already depended on the services plane; it now depends on a publicly-reachable IdP. The kept local break-glass accounts become more load-bearing, not less, and the username-collision rule there is now a live concern rather than a theoretical one.
- Publishing is one DNS record and is reversible in seconds — the mitigations can be tested in production without ceremony.
