# ADR 0039 — WP8: an Infisical internal root signs cert-manager's homelab-ca intermediate; ACME HTTP-01 stays for per-host certs; the PBS Postgres dump is the CA's DR path

- **Status:** Accepted (operator "approved", 2026-08-24)
- **Date:** 2026-08-24
- **Deciders:** operator + agent
- **Context source:** WP8 gate probe 2026-08-24 ([plan §WP8](../ms01-cluster-iac-plan.md#wp8--pki--certs-adr-0007)); kickoff `homelab-wp8-pki-gate-20260825`; resolves the verification gate in [ADR 0007](0007-hybrid-cert-model-infisical-pki-for-the-fleet-le-wildcard-for-browser-facing.md); replaces the placeholder CA of [ADR 0034](0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md) / [ADR 0035](0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md)

## Context

ADR 0007 chose Infisical PKI as the fleet's internal CA and gated WP8 on two checks: that PKI (internal CA + ACME) exists on the self-hosted tier we run, and that the CA key material is covered by DR. Meanwhile P3b/P4a built the cluster's TLS on a **self-signed cert-manager CA** (`ClusterIssuer homelab-ca`, explicitly a placeholder): Traefik's wildcard default TLS store and Zot's certificate are issued from it, the Talos nodes trust it through `machine.registries` (`make talos-trust`), and ADR 0022's fleet-wide ref-templating is gated on swapping it — every `registry.<domain>` ref pushed into a compose file or a node config carries the trust root with it, so the root has to be the final one first.

The gate probe (plan §WP8, 2026-08-24, VM 205 `v0.162.22`, self-hosted, no license → `tier -1`) found: PKI is available and unlicensed — it is the separate *Certificate Manager* project type, with internal root/intermediate CAs whose keys stay in Infisical's KMS, `sign-intermediate` for an external CSR, certificate policies/profiles, and an ACME server (`pkiAcme: true`, EAB) that is **HTTP-01 only** (DNS-01 is "planned"). HTTP-01 cannot issue the `*.<domain>` wildcard the ingress design depends on, and Zot sits on its own LB address where no HTTP-01 solver can answer. On DR: `make infisical-backup` exports secret folders only and internal-CA keys are non-exportable by design, so the SOPS export can never carry them; the lane that does — the nightly Postgres dump + `ENCRYPTION_KEY` to PBS — had never succeeded (`pbs-client.env` rendered with empty fallbacks by the `TAGS=pbs_client` no-facts trap; the vault runs no Infisical agent).

## Decision

**The cluster's CA is an intermediate signed by an Infisical internal root.** One Certificate Manager project (`homelab-pki`) holds one internal root CA, **`Homelab Root CA`** (`EC_secp384r1`, 20 years, `maxPathLength: 1`, key in Infisical's KMS). `kubernetes/cert-manager/deploy.sh` creates both idempotently through the API with the fleet machine identity, generates the intermediate key + CSR (`CN=homelab-ca`, EC P-256, 5 years, `maxPathLength: 0`), has the root sign it via `POST /api/v1/cert-manager/ca/internal/{caId}/sign-intermediate`, and writes `tls.key` / `tls.crt` (intermediate) / `ca.crt` (root) into the existing `homelab-ca` secret. The `homelab-ca` **`ca` ClusterIssuer, the Traefik wildcard, the Zot certificate, the Talos trust patch and every Makefile target keep their shape**; the `selfsigned` issuer and the self-signed CA `Certificate` are deleted. `kubernetes/.secrets/homelab-ca.crt` is the **root** from now on — nodes, the workstation's docker `certs.d`, and (later) the fleet root-distribution role trust the root, never the intermediate.

**The intermediate is disposable state.** It lives only in the cluster secret; on cluster loss `deploy.sh` re-signs a fresh one and nothing that trusts the root notices. It is not exported to Infisical or SOPS.

**ACME HTTP-01 is the per-host path, not the cluster's.** PVE nodes (bpg ACME resources in `terraform/hosts/`) and guests (a `cert_client` role) enroll against a certificate profile's ACME directory with EAB when that phase lands; the cluster never uses ACME.

**The CA's DR path is the PBS Postgres dump lane**, not `make infisical-backup`. ADR 0007's "covered by `make infisical-backup`" requirement is amended to "covered by a proven PBS `databases/infisical` snapshot (pg_dump + `ENCRYPTION_KEY`/`AUTH_SECRET`)"; the SOPS export stays secrets-only. Fixing that lane (`make ansible infisical TAGS=phase1`, then a snapshot newer than the fix) is step 0 of the build, and a restore rehearsal of the dump is owed before the root is trusted fleet-wide.

## Rejected alternatives

- **ACME ClusterIssuer against Infisical's directory (HTTP-01 + EAB).** Cannot issue the wildcard, so it kills ADR 0035's single default TLS store — every Ingress would need a `tls:` block and its own cert — and Zot's own LB address cannot host an HTTP-01 solver. Revisit only if Infisical ships DNS-01.
- **Infisical's external cert-manager issuer (`infisical-issuer` controller, API enrollment).** Every leaf issued by Infisical is the cleanest audit trail, but it adds a controller and a second machine identity to the cluster, makes every renewal depend on the vault, and its wildcard / `isCA` support is undocumented. The intermediate gives the same trust chain with zero new components.
- **step-ca LXC (ADR 0007's fallback).** Not needed — the gate passed; a second crown-jewel CA to run and back up for no capability Infisical lacks.
- **Keep the self-signed `homelab-ca` and distribute it fleet-wide.** Cheapest today, but it makes the placeholder permanent and forks the fleet's trust root from the ADR 0007 per-host plane (two roots on every client).
- **Export the intermediate key to Infisical `/talos` for DR.** Unnecessary — re-signing is cheaper than restoring, and a stored CA key is one more secret to leak.

## Consequences

- `kubernetes/cert-manager/` gains an API dependency on Infisical at deploy time (project, CA, `sign-intermediate`); runtime issuance stays inside cert-manager, so an Infisical outage never blocks a renewal.
- The swap re-issues `wildcard-tls` and `zot-tls` and re-rolls the Talos node configs (`make talos-trust`): a ~2 min window where nodes still trust the old root while Zot serves the new chain — image pulls fail, running pods do not.
- Operator follow-ups after the swap: `~/.docker/certs.d/registry.<domain>/ca.crt` and the macOS keychain get the new root; the old self-signed root can be dropped from both.
- ADR 0022's ref-templating is unblocked. WP8's remaining phases (certificate profile + ACME enrollment, PVE ACME via bpg, `cert_client`, the root-distribution role, the LE wildcard generalization) build on this root.
- Infisical is now the CA as well as the vault: the PBS dump lane must be monitored by **snapshot recency** (CLAUDE.md rule), and a restore rehearsal is an open item.
- ADR 0007's status flips to Accepted with its gate resolved here.
- P6 (2026-08-25): the restore rehearsal passed on worklab's `wl-resolute` (`make infisical-restore HOST= DIR=`: newest `databases/infisical` snapshot → `pg_restore` → `/api/status` 200 → identity read) and the same script then restored the vault into the replaced VM 205; `make rebuild-infisical` restores the dump and never re-bootstraps (the bootstrap path discards this root and every identity). The SOPS export now carries every folder (`authentik`, `authentik-ext`, `jellyfin` were missing).
