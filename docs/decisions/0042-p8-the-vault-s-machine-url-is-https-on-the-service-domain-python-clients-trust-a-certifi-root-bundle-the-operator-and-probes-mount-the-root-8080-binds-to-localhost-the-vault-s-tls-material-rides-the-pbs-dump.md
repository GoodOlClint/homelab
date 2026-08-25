# ADR 0042 — P8: the vault's machine URL is https on the service domain; python clients trust a certifi+root bundle, the operator and probes mount the root, 8080 binds to localhost, the vault's TLS material rides the PBS dump

- **Status:** Accepted (operator "Approved — build it", 2026-08-25)
- **Date:** 2026-08-25
- **Deciders:** operator + agent
- **Context source:** [docs/p8-vault-https-plan.md](../p8-vault-https-plan.md) · closes the "8080 stays, flipping `infisical_url` is a later tranche" clause of [ADR 0041](0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md) §5; amends the DR-path contents of [ADR 0039](0039-wp8-an-infisical-internal-root-signs-cert-manager-s-homelab-ca-intermediate-acme-http-01-stays-for-per-host-certs-the-pbs-postgres-dump-is-the-ca-s-dr-path.md); the operator trust shape extends [ADR 0035](0035-p4a-traefik-ingress-on-one-lb-ip-with-a-wildcard-internal-cert-the-infisical-kubernetes-operator-is-the-secret-path-and-homepage-is-the-first-zot-templated-ref.md)

## Context

P7 gave the vault a root-chained certificate behind Caddy on 443 and left every machine consumer on `http://<ip>:8080` — Ansible's login from the workstation, the two fleet agents, the Kubernetes operator and its 18 `InfisicalSecret`s, `lib.sh`, the backup/restore scripts. All of them read one binding, `bootstrap_config.infisical_url`. The P8 map found the flip is cheap everywhere except two places: python on the workstation (`infisical.vault.login` → infisicalsdk → requests; Ansible `uri`; proxmoxer) trusts certifi / homebrew-openssl stores that know nothing of the keychain the Go tools use, and a rebuilt vault serves a self-signed placeholder until a play with runtime secrets can issue its real cert — which over https can never verify, so the rebuild path deadlocks unless the restored vault already holds the cert.

## Decision

1. **`bootstrap_config.infisical_url` is `https://infisical.<service domain>`.** One binding, flipped in one window; every consumer re-derives from it (Ansible tasks, the agent config, `inf_host_api`, the operator's `hostAPI`, the scripts). Greenfield `make bootstrap` still writes the http URL — no root exists yet — and the flip is the documented post-PKI step.
2. **Python on the workstation trusts a generated bundle.** `kubernetes/cert-manager/deploy.sh` writes `kubernetes/.secrets/ca-bundle.pem` = certifi + `Homelab Root CA` next to the root export; the Makefile exports `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` to it whenever it exists. No `validate_certs: false`, no per-task `ca_path`.
3. **Pods trust the root by mount, not per CRD.** A `homelab-root-ca` ConfigMap from the same root file is mounted at `/etc/ssl/certs/homelab-root-ca.crt` into the operator, `pbs-exporter` and `blackbox` pods (Go scans that directory on top of the system bundle). The `InfisicalSecret` `tls.caRef` field stays unused. `PBS_INSECURE` and the `http_2xx_insecure` blackbox module retire; `tls_connect` keeps `insecure_skip_verify` because it exists to read expiry from chains the prober will never trust (Plex).
4. **8080 binds to `127.0.0.1` once the binding is https.** The compose template keys the publish address on the binding's scheme, so the greenfield path keeps the LAN port and the first post-flip `make ansible infisical` closes it. The container healthcheck, the role's health wait and the restore script already use localhost.
5. **The vault's TLS key and cert are part of the nightly PBS dump.** `infisical_pbs_backup.sh` adds `tls/key.pem` + `tls/cert.pem` to the pxar; `infisical_pbs_restore.sh` restores them into a production stack and restarts Caddy, so `make rebuild-infisical` logs in over https immediately after the restore. The restore's proof read runs on the host against `localhost:8080`.

## Rejected alternatives

- **Keep 8080 LAN-open as a permanent fallback.** Leaves a plaintext path to the vault on the services VLAN for a recovery case the dump now covers; the escape hatch for a pre-P8 dump is one SOPS flip, not an open port.
- **An http fallback in `load_secrets.yml` for the vault's own play.** Needs 8080 open on the LAN and adds a second URL derivation to the one task every play runs.
- **Per-CRD `tls.caRef`.** 18 edits plus a CA Secret the operator reads cross-namespace, for the same trust one mount gives the pod; kept as the fallback if an image ever lacks the `/etc/ssl/certs` scan.
- **Install the root into homebrew's OpenSSL store / `pip install truststore`.** A hand step on the operator's Mac that a `brew upgrade ca-certificates` reverts; Ansible does not inject truststore; the bundle is derived from files the repo already produces.
- **Stage the cutover (operator + `lib.sh` first, Ansible + agents later).** Requires the Ansible side to read a second binding for a day and then a cleanup; the consumers are few and the rollback is one `sops --set`.
- **Escrow the vault's TLS material in Infisical itself.** Circular — the material is what the restore needs before the vault answers.

## Consequences

- Closes ADR 0041's deferred clause; the fleet has no plaintext vault path in steady state. Amends ADR 0039: the PBS dump now carries `tls/` beside the pg dump and the encryption material.
- New surfaces: `kubernetes/.secrets/ca-bundle.pem` (gitignored, generated), the `homelab-root-ca` ConfigMaps in `infisical-operator` and `monitoring`, the scheme-keyed 8080 bind.
- Forbidden from now: any vault URL that is not the binding; `validate_certs: false`, `--insecure`, `PBS_INSECURE` or an `insecure` blackbox module against a fleet-root host; a hand-run Infisical client on the Mac outside `make` that expects python to trust the root (export the bundle first).
- Escape hatch for a dump older than P8 restored into a fresh VM (no `tls/`): `sops --set` the binding back to `http://<services ip>:8080`, `make ansible infisical` twice (first pass re-opens 8080, second logs in and issues the cert), flip back, one more `make ansible infisical`.
