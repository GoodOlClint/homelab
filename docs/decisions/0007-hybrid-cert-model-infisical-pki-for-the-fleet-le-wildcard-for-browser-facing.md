# ADR 0007 — Hybrid cert model: Infisical PKI for the fleet, LE wildcard for browser-facing

- **Status:** Accepted — verification gate resolved by [ADR 0039](0039-wp8-an-infisical-internal-root-signs-cert-manager-s-homelab-ca-intermediate-acme-http-01-stays-for-per-host-certs-the-pbs-postgres-dump-is-the-ca-s-dr-path.md) (2026-08-24; DR requirement amended there: the PBS Postgres dump, not `make infisical-backup`, covers CA keys)
- **Date:** 2026-07-10
- **Deciders:** operator (interview 2026-07-10)
- **Context source:** docs/ms01-cluster-iac-plan.md · ADR 0006 (names drive the need for certs)

## Context

Name-based access (ADR 0006) makes untrusted-cert warnings the daily irritation, so every host/service needs TLS. Constraints: Let's Encrypt logs every cert to public Certificate Transparency — per-host LE certs would publish internal hostnames, against the public-repo scrub posture (WP6). An internal CA avoids CT but its root must be trusted by clients. Infisical (already the crown-jewel secrets vault, already backed up via the SOPS DR export) ships a PKI product: internal CA hierarchies, cert profiles, lifecycle, and issuance over ACME/EST/SCEP/API, available self-hosted — so an internal CA need not be a new service. The repo already holds a working LE DNS-01 pattern (plex_certificate role + Cloudflare token).

## Decision

Two trust planes. (1) **Fleet certs come from Infisical PKI**: an internal CA issues per-host certs over ACME — PVE nodes use their native ACME client pointed at Infisical's directory (Terraform-managed via the bpg ACME resources), guests use a lego/certbot role. Ansible installs the root CA into every managed guest's and node's trust store, so fleet-internal TLS (and future mTLS) verifies with zero per-device chores. No internal hostname ever reaches CT. (2) **Browser-facing UIs additionally get a Let's Encrypt wildcard** (one per internal zone, DNS-01 via the existing Cloudflare token, generalizing the plex_certificate role, delivered via the Infisical-agent file pattern) so unmanaged devices — phones, TVs, guest laptops — get trusted TLS without installing any root. CT sees only the wildcard.

**Verification gate:** Infisical PKI's ACME issuance must be confirmed available on the self-hosted tier before WP8 builds on it (docs place PKI near enterprise features). Fallback if gated: **step-ca** as a small LXC fills the same ACME-CA role; the rest of the design is unchanged.

## Rejected alternatives

- **LE per-host certs** — publishes every internal hostname to CT logs forever.
- **LE wildcard only** — one private key shared across many hosts (one compromised host exposes the zone's cert), and no per-service identity/mTLS story.
- **Internal PKI only** — every unmanaged client device needs the root installed or lives with warnings; the wildcard sidesteps that for exactly the surfaces those devices touch.
- **Standalone step-ca as first choice** — another crown-jewel service to run/back up when Infisical already holds that role and its DR path; step-ca demoted to fallback.

## Consequences

- New WP8: Infisical PKI CA + profiles, ACME wiring (nodes via bpg ACME resources, guests via a cert role), root-CA distribution task in a common role, generalized wildcard role + agent delivery.
- Infisical becomes even more load-bearing (secrets + PKI) — reinforces ADR 0004's VM line, the hardening tightening (plan WP4), and the DR-export discipline; CA key material must be covered by `make infisical-backup` (verify the export includes PKI objects — part of the WP8 license check).
- Issuance depends on Infisical availability; existing certs outlive outages, so an Infisical outage degrades renewals only.
- Cert lifetimes: fleet certs short-lived (ACME auto-renew); wildcard on the standard 90-day LE cycle, renewed centrally.
