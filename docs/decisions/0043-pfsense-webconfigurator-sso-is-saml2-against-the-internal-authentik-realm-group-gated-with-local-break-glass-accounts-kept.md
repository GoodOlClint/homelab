# ADR 0043 — pfSense webConfigurator SSO is SAML2 against the internal authentik realm, group-gated, with local break-glass accounts kept

- **Status:** Accepted (operator, 2026-08-28)
- **Date:** 2026-08-28
- **Deciders:** operator + agent
- **Context source:** extends [ADR 0040](0040-p5-real-dns-on-a-flat-public-domain-zone-bind-fed-by-nsupdate-external-dns-adguard-forwards-rewrites-retired-let-s-encrypt-dns-01-wildcards-as-traefik-s-default-cert-two-authentik-realms-split-by-audience-jellyfin-over-the-vps-relay-with-ldap-auth.md) §P5c (internal realm, one consumer per provider) · depends on [ADR 0041](0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md) for the pfSense certificate ([docs/pfsense-acme.md](../pfsense-acme.md)) · pfSense sits on the vlan10 out-of-band plane of [ADR 0030](0030-three-management-planes-vlan10-out-of-band-vlan30-hypervisor-with-pdm-pbs-apt-cache-pxe-vlan40-services.md)

## Context

Every other admin surface in the fleet — PVE, PBS, PDM, Portainer, MeshCentral, Grafana, DSM — authenticates against the internal authentik realm. The firewall was the last one on a standalone local password. pfSense's webConfigurator supports only Local Database, LDAP and RADIUS natively; it has no OIDC client, so the eight existing consumers' pattern does not transfer. SAML2 reaches it only through a third-party package, `pfrest/pfSense-pkg-saml2-auth` v2.1.0 (a generic OneLogin php-saml integration — no authentik guide exists for it).

## Decision

1. **SAML2, not LDAP.** LDAP against the external realm's outpost would unify *credentials* and still show a password prompt on the firewall. SAML2 reuses the authentik browser session, so an admin already signed in reaches the webConfigurator without re-entering anything, and MFA/policy live in one place.
2. **The internal realm, as a normal blueprint entry.** `kubernetes/authentik/blueprint-internal.yaml` gains a `authentik_providers_saml.samlprovider` named `pfsense` — ACS `https://pfsense.<service domain>/saml2_auth/sso/acs/`, audience (SP entity ID) `https://pfsense.<service domain>/saml2_auth/sso/metadata/`, `sp_binding: post`, `sign_assertion: true`, signed by the same self-signed keypair the OIDC providers use. NameID carries the username; the managed Groups mapping emits `http://schemas.xmlsoap.org/claims/Group`, the exact attribute pfSense reads. No outpost, no LDAPS, no MetalLB address — offset 68 stays free.
3. **The application is bound to a `pfsense-admins` group.** With no groups in the assertion *and* a local account of the same name present, pfSense silently grants that local account's privileges. Gating the application at authentik means a user outside the group never gets an assertion at all, so the inheritance path cannot be reached by an unprivileged fleet account.
4. **Local accounts stay as break-glass.** The authentication server order keeps Local Database, so a services-plane outage does not lock the firewall's console or webConfigurator out. Break-glass usernames must not collide with authentik usernames (see 3).
5. **The certificate is watched.** `pfsense.<service domain>:443` joins `blackbox-tls`; the cert is a 1-year `fleet-hosts` leaf on a ~60-day renewal cycle and nothing else observes it.
6. **The pfSense half is documented, never automated.** `ansible` sudo on pfSense is password-gated, so package install and SP configuration are operator steps in [docs/authentik-setup.md](../authentik-setup.md), like the ACME package before it.

## Rejected alternatives

- **LDAP against the external realm's LDAP outpost.** Only unifies the credential; still a password prompt on every admin login, and it points the firewall at the realm built for media guests.
- **RADIUS.** Same prompt, plus a new service to run for one consumer.
- **Traefik forward-auth in front of the webConfigurator.** Would route firewall administration through the services plane's ingress — the firewall must stay reachable when the cluster is not.
- **Leave the firewall on a local password.** The one admin surface outside SSO is also the one whose compromise is worst; MFA and offboarding stay manual.
- **A dedicated MetalLB address / outpost for SAML.** The provider is served by the authentik server itself; nothing needs an outpost.

## Consequences

- **The firewall's admin auth now depends on the services plane.** authentik down (or the Talos cluster down) means no SSO login. Mitigation is the kept local accounts — this is the reason 4 is a decision and not an omission, and the reason a local admin password must remain known and current.
- **A pfSense upgrade removes the package** (the NUT and ACME precedents). Expect to reinstall `pfSense-pkg-saml2-auth` and re-enter the SP settings after every upgrade; SSO logins fail closed to the local database in the meantime.
- The package is third-party and unsigned by Netgate, on the firewall's authentication path. Its build is ABI-pinned per pfSense base (FreeBSD 14/15/16 → the 2.7/2.8/2.9 assets); installing the wrong one fails, and the download must be fetched somewhere with a current CA bundle because pfSense's own trust store rejects the GitHub chain.
- New surfaces: the `pfsense` SAML provider + application, the `pfsense-admins` group and its policy binding, one more `blackbox-tls` target.
- Renaming the firewall's certificate name changes the SP Base URL, which changes both the ACS URL and the SP entity ID — the blueprint must follow in the same change, exactly as the DSM device name does.
