# P8 — the vault's machine URL moves to https: every Infisical consumer dials `https://infisical.<service domain>` and verifies the root

- **Status:** APPROVED 2026-08-25 (operator "Approved — build it"); build in progress
- **Decision record:** [ADR 0042](decisions/0042-p8-the-vault-s-machine-url-is-https-on-the-service-domain-python-clients-trust-a-certifi-root-bundle-the-operator-and-probes-mount-the-root-8080-binds-to-localhost-the-vault-s-tls-material-rides-the-pbs-dump.md) (closes the `infisical_url` clause ADR 0041 deferred; amends ADR 0039's DR-path contents)
- **Inputs:** [ADR 0041](decisions/0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md) §5 + the P7 plan §4 "Open after P7", ADR 0039 (DR path), ADR 0035 (operator = the k8s secret path), kickoff `homelab-p8-vault-https-20260826`
- **Tranche shape:** serial (`PARALLEL: no`), small commits on `nut-client`, no push

## 1. Existing state (mapped 2026-08-25)

| Surface | Today | Finding |
|---|---|---|
| The binding | `bootstrap_config.infisical_url` = `http://<services ip>:8080` (SOPS). Read by `infisical_login.yml`/`load_secrets.yml` (every play), `infisical_write_secret.yml`, `api_certificate.yml`, `provision_identity.yml`/`delete_identity.yml`, `refresh-identity.yml`, `proxmox-hosts.yml`, the `infisical_client` agent config, `kubernetes/lib.sh` `inf_host_api`, `kubernetes/infisical/deploy.sh`, `kubernetes/talos/talos.sh`, `scripts/infisical_backup.sh`, `seed_infisical.sh`, `organize_infisical_folders.sh`, `clean-infisical-sops` | One binding; every consumer derives from it. `bootstrap_infisical_setup.yml` (greenfield `make bootstrap`) *writes* it as `http://<ip>:8080` — correct there, no PKI exists yet. |
| The vault (VM 205) | Caddy on 443 with the API-issued cert `CN=infisical.<domain>` → `Homelab Hosts CA` → `Homelab Root CA` (verified `Verify return code: 0`); app on `0.0.0.0:8080`; `SITE_URL` https | `https://infisical.<domain>/api/status` → 200 from the workstation with `curl` (macOS keychain). The compose healthcheck runs inside the container (`localhost:8080`); the role's own health wait is `localhost:8080` on the VM. |
| Workstation clients | `curl`, the Go `infisical` CLI, terraform, helm, kubectl → keychain (root trusted, proven live). **python `requests` (infisicalsdk = `infisical.vault.login`, proxmoxer) and Ansible `uri` fail** — certifi / homebrew-openssl stores, no keychain | Proven fix: a bundle = certifi + root; `SSL_CERT_FILE` makes `uri` pass, `REQUESTS_CA_BUNDLE` makes requests pass (both tested against the live vault). `InfisicalSDKClient(host, token, cache_ttl)` exposes no CA option. |
| Fleet agents | `infisical-agent` runs on **control** and **plex** only (the `infisical_client` role is in those two plays); both hold `/usr/local/share/ca-certificates/homelab-root-ca.crt` (`ca_trust`, Phase 0, `hosts: all`); agent = Go binary → system store; `agent.yaml` `address:` from the binding; `restart infisical-agent` handler on template change | Flip + `make ansible-all` re-renders and restarts both. No other guest dials the vault at runtime (`pbs_client` reads the agent's file where one exists). |
| Kubernetes operator | `secrets-operator` v0.11.8, distroless image, `readOnlyRootFilesystem`, `INFISICAL_HOST_API=http://<ip>:8080/api` from the chart's `hostAPI`; 18 `InfisicalSecret`s across 10 namespaces each carry `hostAPI: ${HOST_API}` rendered at deploy time; the CRD has `spec.tls.caRef {secretName, secretNamespace, key}`; the chart has `controllerManager.extraVolumes` / `manager.extraVolumeMounts` / `manager.extraEnv` | Go on Linux loads every file in `/etc/ssl/certs` on top of the bundle file, so one root mounted into the operator pod covers every CRD without 18 `caRef` edits. `infisical/deploy.sh smoke` greps `pbs_fingerprint` — a key ADR 0041 retired (the smoke's check is stale). |
| Rebuild / restore | `make rebuild-infisical` = dump → unprotect → `make rebuild` → `make infisical-restore` → `make ansible infisical` → `make refresh-identity`. A fresh VM gets a **self-signed placeholder** from `api_certificate.yml` until a play with runtime secrets issues the real cert; `load_secrets.yml` skips secrets for the vault's own play only while `/api/status` is unreachable | Over https the placeholder fails verification, so the play can never log in to issue the cert (deadlock) unless the restored vault already serves the real cert. The nightly `infisical_pbs_backup.sh` pxar carries the pg dump + `ENCRYPTION_KEY`/`AUTH_SECRET` only. The restore script's read-back uses the Mac's `infisical` CLI against `http://<host>:8080`. `wl-resolute` (`.30.93`, docker via sudo) is still up for the rehearsal. |
| Other consumers of `http://…:8080` | Kuma row `Infisical`, the homepage tile `href`, README §"Infisical Secret Vault", `bootstrap.sops.example.yml` comments | Both live consumers break the moment 8080 leaves the LAN. |
| Monitoring (extra, operator-approved) | `pbs-exporter` `PBS_INSECURE=true`; blackbox `http_2xx_insecure` for the three UIs (Traefik → LE wildcard since P5b, so public trust suffices) and for `https://<plex ip>:32400/identity` (an IP, so the LE `plex.<media domain>` cert can never match); `tls_connect` `insecure_skip_verify` (expiry metric only) | The blackbox and pbs-exporter images are Go; the same root-in-`/etc/ssl/certs` mount lifts the flags. Plex's probe moves to its name. `tls_connect` keeps skip-verify (it exists to read expiry, and Plex's chain does not verify). |

## 2. Decisions (interview 2026-08-25)

1. **One binding, one window.** `bootstrap_config.infisical_url` flips to `https://infisical.<service domain>`; every consumer re-derives it. Rollback is `sops --set` back and the same runbook. No second URL anywhere.
2. **8080 binds to localhost once the URL is https.** The compose template publishes `127.0.0.1:8080:8080` when the binding starts with `https://`, `8080:8080` otherwise — greenfield `make bootstrap` (http, no PKI) keeps the LAN path by construction and the first `make ansible infisical` after the flip closes it. The container healthcheck, the role's health wait and the restore script already use localhost.
3. **The vault's TLS key + cert ride the nightly PBS dump.** `infisical_pbs_backup.sh` adds `tls/key.pem` + `tls/cert.pem` to the pxar; `infisical_pbs_restore.sh` puts them back (production branch only) and restarts Caddy, so a restored vault verifies at once and `make ansible infisical` logs in over https. PBS already holds the vault's `ENCRYPTION_KEY`; no new trust boundary. Amends ADR 0039's DR-path contents.
4. **Workstation python trust = a generated bundle.** `kubernetes/cert-manager/deploy.sh` writes `kubernetes/.secrets/ca-bundle.pem` (certifi + root) beside `homelab-ca.crt`; the Makefile exports `SSL_CERT_FILE` + `REQUESTS_CA_BUNDLE` to it when it exists. Nothing else on the Mac changes (Go/curl already trust the keychain).
5. **Pod-level trust for the operator and the probes, not per-CRD `caRef`.** A `homelab-root-ca` ConfigMap (from `kubernetes/.secrets/homelab-ca.crt`) in `infisical-operator` and `monitoring`, mounted at `/etc/ssl/certs/homelab-root-ca.crt` (`subPath`) into the operator, `pbs-exporter` and `blackbox` pods. Fallback if a distroless image lacks the dir scan: `SSL_CERT_FILE` via `extraEnv`.
6. **Extras ride along:** Kuma row + homepage tile → `https://infisical.<domain>`; `PBS_INSECURE` and `http_2xx_insecure` retire; the Plex probe targets `plex.<media domain>`.

## 3. Change plan

| Step | Surface | Change |
|---|---|---|
| A | `kubernetes/cert-manager/deploy.sh`, `Makefile` | Write `ca-bundle.pem` next to the root export; `ifneq ($(wildcard …))` export of `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`; `.gitignore` already covers `.secrets/` |
| B | `ansible/roles/infisical/templates/docker-compose.yml.j2`, `infisical_pbs_backup.sh.j2` | 8080 bind keyed on the binding's scheme; tls material into the pxar |
| C | `scripts/infisical_pbs_restore.sh` | Restore `tls/` when the dump carries it and a production compose exists, `docker compose restart caddy`; read-back = `curl` on the host against `localhost:8080` (works with the localhost bind, for production and the throwaway alike) |
| D | `kubernetes/infisical/deploy.sh` + `values.yaml` | `homelab-root-ca` ConfigMap; `extraVolumes`/`extraVolumeMounts`; smoke greps `pbs_backup_token` |
| E | `ansible/playbooks/uptime-kuma.yml`, `kubernetes/homepage/config/services.yaml` | https rows |
| F | `kubernetes/monitoring/deploy.sh`, `app.yaml`, `config/blackbox.yml`, `config/prometheus.yml` | root ConfigMap + mounts; `PBS_INSECURE` gone; `http_2xx_insecure` gone, Plex probe on its name |
| G | `README.md`, `bootstrap.sops.example.yml`, `CLAUDE.md`, tracker row, ADR 0042 | docs |

Not touched: `bootstrap_infisical_setup.yml` (greenfield stays http until the root exists — the flip is a post-PKI step, documented), `load_secrets.yml` (its unreachable-vault skip already covers the placeholder window because the restore brings the real cert back), every `kubernetes/*/secrets.yaml` (they already derive `hostAPI`), `lib.sh`/`scripts/*.sh` (curl + Go CLI; they follow the binding unchanged).

## 4. Runbook (one window)

0. `make talos-certs` is **not** re-run (it would re-sign nothing; the root file exists) — step A's bundle is produced once by hand with the same one-liner the script now carries, then verified: `SSL_CERT_FILE=… ansible localhost -m uri -a url=https://infisical.<domain>/api/status` → 200.
1. Commit A–G (code only; the binding is still http, so everything still converges).
2. `make infisical-backup` (fresh SOPS export before touching the vault).
3. Flip: `sops --set '["bootstrap_config"]["infisical_url"] "https://infisical.<domain>"' ansible/group_vars/bootstrap.sops.yml`.
4. `make ansible infisical` → login over https, compose re-rendered (8080 → localhost), Caddy untouched; check `ss -ltnp | grep 8080` on the VM shows `127.0.0.1`, `curl http://<ip>:8080` from the Mac refused.
5. `make ansible-all` → control + plex agents re-rendered and restarted; `journalctl -u infisical-agent` shows the https host and a fresh render; second `make ansible-all` = 0 changed.
6. `make talos-infisical` (operator pod re-rolled with the root + https `INFISICAL_HOST_API`), then patch every existing CRD: `kubectl get infisicalsecret -A -o json | jq -r '.items[]|"\(.metadata.namespace) \(.metadata.name)"' | while read ns n; do kubectl -n $ns patch infisicalsecret $n --type=merge -p "{\"spec\":{\"hostAPI\":\"$(inf_host_api)\"}}"; done` (the trees render the same value on their next deploy); `make infisical-smoke` PASS; operator log free of `x509`.
7. `make uptime-kuma`, `make talos-homepage`, `make talos-monitoring` (extras); Prometheus `probe_success` = 1 for the three UIs, Plex and PBS after the change.
8. Restore rehearsal: trigger one `infisical_pbs_backup.sh` run on 205 (the dump now carries `tls/`), then `make infisical-restore HOST=<wl-resolute> DIR=/opt/infisical-rehearsal` → `/api/status` 200 + `/shared` read; tear the stack down.
9. `make infisical-backup` again (proves the SOPS export path over https); `make plan` = no resource changes.

## 5. Definition of done

`sops -d --extract '["bootstrap_config"]["infisical_url"]'` prints `https://infisical.<service domain>`; `make ansible-all` logs in over https and its second run = 0 changed; both `infisical-agent` units active with a post-flip render and no TLS error in the journal; `kubectl get infisicalsecret -A` all synced with https `hostAPI` and no `x509` in the operator log; `make infisical-smoke` PASS; `make infisical-backup` succeeds; `make infisical-restore HOST=<throwaway>` succeeds from a dump that carries `tls/`; 8080 is `127.0.0.1`-bound on the VM; `git grep -n "insecure\|validate_certs: false" -- . ':!docs' ':!CLAUDE.md' | grep -i infisical` = 0 (the two `CLAUDE.md` hits are the P7 prose "`insecure = false`"); no `PBS_INSECURE`/`http_2xx_insecure` in `kubernetes/monitoring`; `make plan` = no resource changes; push notification "P8 ready for operator testing".

## 6. Risks

- **A pre-P8 dump restored into a fresh VM** has no `tls/` → the placeholder deadlock. Escape hatch (documented in the ADR): `sops --set` the binding back to `http://<services ip>:8080`, `make ansible infisical` twice (the first pass re-opens 8080, the second logs in and issues the cert), flip back, `make ansible infisical` once more. Nightly dumps from P8 on make this a one-time concern.
- **`SSL_CERT_FILE` is exported to every child of `make`** — a superset bundle (certifi + root), so nothing loses public trust; Go on darwin ignores it. Exported only while the file exists, so a fresh checkout before `make talos-certs` behaves as today.
- **The operator patch loop** touches 18 live CRDs in one go; the operator re-authenticates per CRD on the next resync. If a CRD sticks, `make talos-<component>` re-applies it.
- **8080 localhost-only** removes the last plaintext path; if https ever fails fleet-wide, the recovery is the escape hatch above (one SOPS flip), not a firewall change.
