# Fleet MDM (fleetdm) — change plan

Status: approved by the operator 2026-11-23, after the Codex review the same day. Decision record: [ADR 0065](decisions/0065-fleet-mdm-runs-on-the-services-cluster-as-tree-fleetdm-on-the-free-tier-lan-only-with-its-own-mysql-and-saml-login.md).

## Scope

Run a self-hosted Fleet server on the services cluster and enroll the M5 Mac Studio, so the Studios get inventory, configuration profiles and operator-triggered Homebrew updates from one place. The M4 Studio enrolls at its runner rebuild (ADR 0061); Windows VMs are out of scope but not blocked.

Not in scope: Fleet Premium, Apple Business Manager, any device outside the LAN, the M4's runner profile and supervisor (its own plan).

## Interview answers (2026-11-23)

- Placement: the Talos services cluster, not a Proxmox guest.
- Device scope: LAN only, for the server's whole life.
- M4 Studio on the `ci` VLAN: one allow rule to Fleet, amending ADR 0061.
- First jobs on the M5: inventory and queries, software updates, configuration profiles.
- License: free tier.

## Facts this plan rests on

Checked 2026-11-23 against fleetdm.com docs and the fleetdm/fleet repository; recheck at build time.

- Server fleet-v4.95.0 (2026-11-17). Helm chart `fleet` from `https://fleetdm.github.io/fleet/charts`; on `main` it is chart v7.0.33 for app v4.95.0. The chart runs database migrations at install and upgrade, does not create the namespace or Secrets, calls its bundled MySQL and Valkey dev/test only, and has backend TLS (`fleet.tls.enabled`) on by default, independent of its ingress switch.
- MySQL 8.0.44, 8.4 and 9.5 are tested; 9.6 is incompatible; Postgres is not supported.
- Free tier: Apple and basic Windows MDM, configuration profiles, scripts run on demand, SAML SSO to the UI for users that already exist. Premium: policy automations that run scripts, Fleet-maintained apps, OS update enforcement, FileVault escrow, SSO user creation, end-user authentication, Apple Business Manager.
- Fleet's first-run setup is unauthenticated and makes the caller global admin.
- The manual enrollment profile carries a static challenge that can enroll any Mac while it is enabled; disabling it keeps existing enrollments.
- The Apple push certificate and other stored secrets are encrypted with the server private key.
- The VPS relay forwards public TCP 443 to Traefik's shared address (ADR 0044, `vps_nftables`).

## Work packages (one PR, stacked commits)

**WP1 — Secrets and seed.** The `k8s_apps` role gains `fleetdm.yml`: `generate_secret.yml` into Infisical `/fleetdm` for `mysql_root_password`, `mysql_password` (`openssl rand -hex 24`), `server_private_key` (`openssl rand -base64 32`) and `admin_password`. `/fleetdm` joins the nested-path loop in `ansible/tasks/infisical_login.yml` and the folder-ownership table in CLAUDE.md. `fleetdm` joins `k8s_seed_namespaces` (namespace + per-tree Flux service account, as `codeintel`). `vlans.yaml` gains `metallb.offsets.fleetdm: 70`, so the seed publishes `FLEETDM_IP`. Check: `make k8s-seed` then a second `make k8s-apps` both report 0 changed and no value is regenerated.

**WP2 — The tree, no client entry point.** `kubernetes/fleetdm/`:
- `mysql`: Deployment on `mysql:8.4` (the LTS line, pinned; the reason and the rule for moving to the next LTS are in ADR 0065), ceph-rbd PVC with `Retain`, `strategy: Recreate`, cpu+memory requests, readiness and liveness probes.
- `valkey`: Deployment on `valkey/valkey:latest`, no PVC, requests set.
- `certificate.yaml`: cert-manager `Certificate` for `fleet.${DOMAIN}` from the `letsencrypt` ClusterIssuer.
- `helm.yaml`: the `fleet` chart as a `HelmRelease` pinned to one chart version; external database and cache pointed at the two Services; one replica; chart ingress off; `fleet.tls.enabled: true` with that certificate's Secret; install and upgrade remediation retries so the chart's migration Job waits out a late Secret or a MySQL that is still starting. Its Service stays `ClusterIP`.
- `secrets.yaml`: an `InfisicalSecret` on `/fleetdm`, and one on `/shared` for `pbs-secrets` (the backup's PBS credential), as `codeintel` does.
- `kubernetes/flux/apps/fleetdm.yaml` with `healthChecks` on mysql and the Fleet Deployment, plus its entry in `kubernetes/flux/kustomization.yaml`.
Before committing, render the pinned chart with these values and check the backend protocol and every Secret key it references. Check: `make flux-check` passes; after the push the Kustomization is Ready with the Fleet pod serving on its ClusterIP, and nothing outside the cluster can reach it.

**WP3 — Backup lane.** A `kubernetes/mysql-backup/` component, the `pg-backup` shape: a `mysqldump --single-transaction --all-databases` init container writing to the tree's `backups` PVC (declared in the tree, as `codeintel` does), then the same `pbs-push` container; a failed dump fails the Job before any upload. Check: a manual Job run puts a `fleetdm-mysql` snapshot in PBS namespace `databases`.

**WP4 — First setup, then the entry point.** `k8s_apps` runs Fleet's first-time setup over a `kubectl port-forward` (organisation, break-glass admin from `/fleetdm`), then authenticates as that admin and verifies it is the only global admin. Only then does the tree gain `service-lb.yaml`: a `LoadBalancer` at `${FLEETDM_IP}` (`metallb.io/loadBalancerIPs`, `externalTrafficPolicy: Local`, `external-dns.alpha.kubernetes.io/hostname: fleet.${DOMAIN}`). On every later run, `k8s_apps` stops with an error if setup is open or an unexpected global admin exists, which also guards a recovery that starts Fleet on an empty database. Check: `https://fleet.<service domain>/healthz` returns 200 from the Core VLAN with a publicly trusted certificate, and a request to the VPS's public address with `Host: fleet.<service domain>` does not reach Fleet.

**WP5 — Login.** A SAML provider `fleetdm` in `kubernetes/authentik/blueprint-internal.yaml`, group-gated like `pfsense`, signing an assertion whose NameID is the user's email, with Fleet's callback URL. Applied by `make ansible authentik`. `k8s_apps` sets Fleet's SSO settings and creates the SSO-enabled operator account by email (free Fleet does not create users from SSO). Check: an operator in the group logs in by SSO; a user outside the group is refused; break-glass login works with authentik stopped.

**WP6 — Fleet configuration as code.** Scripts and configuration profiles live in `kubernetes/fleetdm/config/` and are applied by `k8s_apps` (or `fleetctl gitops`, if a check before building shows it is free-tier and can own these files).
- `brew-upgrade.sh`: runs `brew update && brew upgrade` as the user that owns `/opt/homebrew`, excluding `omlx`. Operator-triggered from the UI or `fleetctl run-script`.
- `omlx-upgrade.sh`: `brew upgrade omlx`, then a restart through the `local.omlx` LaunchDaemon. Run by the operator when no inference is running.
- Inventory: the built-in `homebrew_packages` table shows installed versions; detecting "outdated" automatically is deferred (it needs Premium automations or a custom data source).
- One configuration profile, chosen at review: `profiles/software-update.mobileconfig` (check, never download or install on its own; XProtect data still installs). The classic `com.apple.SoftwareUpdate` payload, because the DDM `softwareupdate.settings` declaration is supervised-only on macOS and the Studio is manually enrolled.
- The application firewall is not profile-managed (2026-11-24). A `com.apple.security.firewall` profile replaced the Studio's local app rules (17 → 4) and makes macOS refuse `socketfilterfw` changes, and its `Applications` bundle-ID rule for `org.python.python` was not shown to admit Homebrew's ad-hoc-signed Python. Both upgrade scripts instead allow every Homebrew `Python.app` path with `socketfilterfw` after an upgrade, so a Python move to a new Cellar path never waits behind the on-screen prompt.
Check: deleting a script in the UI and rerunning `make k8s-apps` restores it; `brew-upgrade.sh` upgrades a deliberately outdated test formula while `omlx` stays on its version and the server keeps serving.

**WP7 — Monitoring.** An Uptime Kuma row for `/healthz` in `ansible/playbooks/uptime-kuma.yml`, and a Prometheus alert `FleetAPNsCertExpiringSoon` in `kubernetes/monitoring/config/alert.rules.yml` that fires 30 days before the push certificate's renew date. Fleet's push-certificate endpoint answers only global admins (observer, observer+ and maintainer get 403), so instead of an admin token in Kuma the date is pinned in the rule and `make k8s-apps`, which already signs in as admin, fails when the pin no longer matches Fleet. Check: `make uptime-kuma CHECK=1` shows 0 changed with the row present; a pin one second off fails `make k8s-apps`; the expression returns a sample with a 400-day threshold and none with 30.

**WP8 — M4 rule (docs only now).** `docs/pfsense-ci-vlan.md` gains the M4 host → `FLEETDM_IP`:443 rule and the `ci` resolver's host override for `fleet.<service domain>`, applied by hand at the M4 rebuild. The M4 runner plan must show that its guests do not share the host's address (bridged, not NAT) or are otherwise kept from Fleet.

**WP9 — CIS level 1 through Fleet (2026-11-24, ADR 0066).** Fleet's own CIS policies stop at macOS 26 (fleetdm/fleet#54600), so the Studio's tailored baseline comes from NIST's mSCP instead. `kubernetes/fleetdm/config/cis/cis_lvl1_studio.yaml` is the baseline (stock CIS level 1 minus auditd, sudo timeout, password history and lifetime, the firewall rules, the login-window text, screen sharing, SMB, SSH, wake-on-network, automatic macOS installs and critical-update installs). Generated from it with mSCP at `2b71e960` (`./mscp.py guidance -p -s --no-docs custom/baselines/cis_lvl1_studio.yaml`): the 12 `profiles/cis-*.mobileconfig` (mSCP's software-update profile is dropped; `software-update.mobileconfig` carries downloads and app updates on, macOS installs and critical updates off) and `scripts/cis-compliance-check.sh` (defaults to `--check --quiet=1`, never `--fix`). `profiles/cis-exemptions.mobileconfig` exempts rules with a reason through the `org.cis_lvl1_studio.audit` domain. Two "No team" policies in `config/policies.yaml` report results: freshness (under 7 days; Fleet reruns the script on failure) and "every rule passes" (exemptions excluded). Regenerating: clone mSCP at the pinned commit, copy the baseline into `custom/baselines/`, run the command above with a Python 3.13 venv, and replace the generated files here.

## Operator steps

1. Create the Apple push certificate: Fleet → Settings → Integrations → MDM → Apple → download the CSR, sign it at identity.apple.com with your Apple Account, upload the `.pem`. Put the renewal date in your calendar.
2. Enroll the M5 Studio at its screen: enable manual enrollment, download the profile, install and approve it in System Settings, then disable the static challenge and delete the downloaded profile.
3. Choose the one configuration profile for WP6.

## Rollout

WP1 (`make k8s-seed`, `make k8s-apps`) → push WP2 and WP3 → manual backup Job → `make k8s-apps` for WP4 setup → push the `LoadBalancer` → `make ansible authentik` and `make k8s-apps` for WP5 → operator step 1 → WP6 → operator steps 2 and 3 → WP7. The database is backed up before it holds anything that cannot be recreated, and no client can reach Fleet before its admin exists.

## Definition of done

- The `fleetdm` Kustomization is Ready; `/healthz` answers 200 on the LAN with a publicly trusted certificate; a Host-header request through the VPS relay does not reach Fleet.
- `make k8s-apps` stops when pointed at a Fleet with open setup (tested against a scratch Fleet with an empty database); second runs of `make k8s-seed` and `make k8s-apps` report 0 changed.
- SSO works for a group member, is refused for a non-member, and break-glass works with authentik down.
- Recovery drill, after the M5 enrolls: a snapshot from PBS restored into an isolated MySQL, with Fleet at the pinned version and `server_private_key` read back from Infisical, shows the Studio's host record and MDM status and reports the Apple push certificate as valid.
- The M5 Studio shows MDM "On (manual)" and osquery inventory; one `brew-upgrade.sh` run succeeded with output; the old enrollment profile no longer enrolls a second Mac.
- Deleting the Fleet pod brings it back with the Studio still checking in.

## Risks

- **The push certificate lapses:** every Mac must re-enroll. Mitigation: WP7's expiry alert and the calendar entry.
- **A chart bump runs migrations:** run the backup Job by hand first.
- **MySQL ages out:** at each Fleet chart bump, check whether the next MySQL LTS line is on Fleet's tested list and has had a patch release, and compare against 8.4's Premier Support end date. ADR 0065 sets the move window.
- **Losing `server_private_key` makes every backup useless for MDM.** It lives in Infisical, whose own backup lane is its DR path; the recovery drill proves the round trip.
- **Free tier limits:** no automatic updates, no FileVault escrow, no OS update enforcement. Accepted in ADR 0065.

## Review disposition

Codex adversarial review, 2026-11-23, one pass, verdict needs-attention, ten findings. All ten accepted.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | critical | The VPS relay forwards 443 to the shared Traefik listener, so a Fleet Ingress there is reachable from the internet | Fixed: Fleet gets its own MetalLB address and terminates TLS; WP4's check sends a Host-header request through the relay |
| 2 | critical | Ingress opens before the first admin exists; Fleet's setup is unauthenticated | Fixed: WP4 sets up over a port-forward, verifies the admin, then adds the LoadBalancer; later runs stop on open setup |
| 3 | high | Scripts triggered by policy failure are Premium; `brew outdated` has no free data source | Fixed: updates are operator-triggered scripts; automatic detection deferred |
| 4 | high | The M4 rule to Traefik's address reaches every service on it; the `ci` resolver cannot resolve Fleet | Fixed by finding 1's own address; WP8 adds the resolver override and the guest-NAT requirement |
| 5 | high | The restore drill could pass without proving enrollment state or the key round trip | Fixed: post-enrollment restore with the key from Infisical, in isolation |
| 6 | high | The backup job needs `pbs-secrets` and a `backups` PVC | Fixed in WP2 and WP3 |
| 7 | high | Free SSO does not create users; Fleet expects an email NameID; the blueprint deploys via `make ansible authentik` | Fixed in WP5 and the rollout |
| 8 | high | The tree is not in the seed allowlist; the chart's migration can race the Secret and MySQL | Fixed in WP1 and WP2 (remediation retries) |
| 9 | high | Chart ingress off leaves backend TLS on with no certificate | Fixed: Fleet terminates TLS with the cert-manager certificate; WP2 renders the chart before committing |
| 10 | medium | The manual enrollment profile is a reusable credential | Fixed: operator step 2 disables the static challenge after each enrollment |
