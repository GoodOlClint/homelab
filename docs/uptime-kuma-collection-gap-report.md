# Gap report — `goodolclint.uptime_kuma` vs the homelab's Uptime Kuma

Date: 2026-08-23. Sources: `~/Source/homelab` (`docs/uptime-kuma-monitors.md`, ADR 0011, `docs/ansible-collection-modernization-review.md`, `docs/rebuild-as-routine-design.md`, `scripts/seed_uptime_kuma.py`, `network-data/uptime-kuma-monitors.example.json`, `ansible/roles/monitoring/`), this repo at `origin/main` (PR #2 merged), and a live probe of the instance at `<private ip>:3001`.

## Bottom line

The collection is structurally right for the job (8 modules + a role, ADR for the pip dependency, CI green) but is **not usable against the homelab instance today** for four reasons, in priority order:

1. **Target version mismatch.** The homelab runs `louislam/uptime-kuma:2`. The pinned `uptime-kuma-api` 1.2.1 (Sept 2023) documents support for Kuma 1.21.3–1.23.2 only. Live probe: connect + `login` round-trip works against v2, but everything post-login (monitor add/edit payloads, settings, version gating on `info.version`) is **unverified** — there were no credentials in this session.
2. **Connect timeout.** With the collection's default `api_timeout: 10` the lib fails with `unable to connect` (engine.io long-poll read timeout) against the live instance. `timeout=30` connects. Every module would fail before doing anything.
3. **Monitor module can't express 1 of the 23 homelab monitors and the role can't express 13 of them.** `json-query` (Valheim) needs `json_path` / `expected_value` / `json_path_operator`; the module has none. The role doesn't pass `ignore_tls`, `accepted_statuscodes`, `dns_resolve_server`, `dns_resolve_type`, `url` variants, or notification linkage.
4. **Notification linkage is by integer ID.** The homelab needs "attach every monitor to `ntfy (homelab alerts)`" by name; Kuma does not auto-apply default notifications to API-created monitors (lucasheld/uptime-kuma-api #76), so each monitor must carry an explicit ID list.

Everything else is delivery/wiring work on the homelab side.

## What the homelab has today

| Item | Current state |
|---|---|
| Deployment | `monitoring` role, docker-compose, image `louislam/uptime-kuma:2`, data at `/var/lib/monitoring/uptime-kuma` on the openobserve LXC (ADR 0015 data volume) |
| Configuration | Hand-managed in UI per ADR 0011 ("hand-managed-and-documented") |
| Reproduction | `scripts/seed_uptime_kuma.py` writes SQLite rows directly (monitor + notification + monitor_notification), container stopped, matched by name, never updates |
| Source of truth | gitignored `network-data/local/uptime-kuma-monitors.json` (23 monitors); tracked `uptime-kuma-monitors.example.json` |
| Monitor types used | `http` (15), `port` (4), `dns` (2), `ping` (2), `json-query` (1) |
| Per-monitor knobs used | `url`, `hostname`, `port`, `dns_resolve_server`, `dns_resolve_type`, `interval`, `maxretries`, `ignoreTls`, `accepted_statuscodes`, `json_path`, `json_path_operator`, `expected_value`; defaults `retry_interval 60`, `timeout 16`, `maxretries 2` |
| Notification | one `ntfy` channel, `isDefault`+`applyExisting`, topic from Infisical `/monitoring/alert_ntfy_topic` |
| Admin bootstrap | first-visit UI setup, manual |
| Known drift | 3 monitors added in UI and lost from the list until 2026-08-10 — exactly the failure declarative management fixes |
| Stated intent | modernization review: "Adopt first. Replaces hand-managed Kuma UI config + seed script"; rebuild-as-routine design lists Kuma re-seed as recurring rebuild machinery |

## Gap table

| # | Gap | Where | Severity | Evidence |
|---|---|---|---|---|
| G1 | Kuma 2.x compatibility of `uptime-kuma-api` 1.2.1 unverified post-login | lib / `module_utils/uptime_kuma_api.py` | **Blocker** | PyPI: supports ≤1.23.2. v2 `info` pre-login omits `version`; lib gates `parent`, `invertKeyword`, `chromeExecutable`, `nscd` on `parse_version(self.version)` — `None` would raise if `info` is not re-sent with a version after login |
| G2 | Default `api_timeout: 10` cannot connect to the live instance | all modules, `uptime_kuma_argument_spec()` | **Blocker** | Probe: 10s → `UptimeKumaException: unable to connect`; 30s → connected, `login` answered `authIncorrectCreds` |
| G3 | No `json_path` / `expected_value` / `json_path_operator` on `uptime_kuma_monitor` | `plugins/modules/uptime_kuma_monitor.py` | High | Valheim monitor can't be created; `json-query` is in `choices` but unusable |
| G4 | No `timeout` (per-check) on `uptime_kuma_monitor` | same | Medium | homelab default is 16s on every monitor; module can't set it, Kuma default is 48s |
| G5 | Role drops most monitor fields | `roles/uptime_kuma/tasks/main.yml` | High | no `ignore_tls`, `accepted_statuscodes`, `dns_resolve_*`, `max_redirects`, `notification_ids` — 13/23 monitors need one of these |
| G6 | Notifications linkable only by integer ID | `uptime_kuma_monitor` `notification_ids` | High | playbooks can't know IDs; default-notification auto-apply doesn't happen via API (#76) |
| G7 | Idempotency of `notificationIDList` compare | `needs_update()` | Medium | module sends a list, Kuma returns `{"<id>": true}` — every run reports changed once linkage is used. Also unverified: `accepted_statuscodes` ordering, `maxredirects`, `dns_resolve_server` default `1.1.1.1` vs what v2 returns |
| G8 | No first-run admin setup | collection | Medium | rebuild-as-routine needs unattended bootstrap; lib has `need_setup()` / `setup()` |
| G9 | Integration tests never execute in CI | `.github/workflows/ci.yml` | Medium | no Kuma service container; the only place v2 behaviour would be caught |
| G10 | No release tag; `galaxy.yml` 0.1.0 unpublished | repo | Medium | homelab `requirements.yml` needs a git `version:` pin; local `main` is also behind `origin/main` |
| G11 | Control-node pip dependency not in the homelab venv; modules must `delegate_to: localhost` | homelab `Makefile` `init`, monitoring role | Medium | role runs on the LXC, which has no pip lib; review already flagged `make init` |
| G12 | ADR 0011 says Kuma is hand-managed; `docs/uptime-kuma-monitors.md` + seed script + example JSON become stale | homelab docs | Low (policy) | adopting the collection is an architectural change that needs an ADR amendment per the house rule |
| G13 | Secret plumbing: ntfy topic must reach `notification_config.ntfytopic` | homelab | Low | Infisical lookup already exists for Alertmanager; `ntfytopic` is treated write-only so it can't drift-detect — acceptable |

Not gaps: `uptime_kuma_status_page`, `maintenance`, `api_key`, `settings`, tags — the homelab uses none of these (ADR 0011 keeps Kuma internal, no status pages). They stay as-is.

## Plan

Phases are ordered so each one produces something verifiable; the collection work is P0–P2, the homelab wiring is P3–P4.

### P0 — Prove or replace the library (unblocks everything)

1. Create a read-only or throwaway admin on the live instance (or run `louislam/uptime-kuma:2` locally in Docker) and run the lib through: `login`, `info()` → `version`, `get_monitors`, `add_monitor` for each of `http / port / dns / ping / json-query`, `edit_monitor`, `add_notification(type=ntfy)`, `get_monitor` round-trip field names.
2. Outcome A (lib works, maybe with a shim): keep `uptime-kuma-api`, add a `version` fallback in `UptimeKumaClient` (treat missing as `2.0.0`) and pass through v2-only fields (`json_path_operator`, `conditions`) as `**kwargs`.
3. Outcome B (lib breaks on v2): switch the pip dependency to `uptime-kuma-api-v2` (fork, targets 2.0.0-beta.2, also unmaintained) **or** replace the lib with a thin `python-socketio` client inside `module_utils` — the probe shows ~15 lines of `socketio.Client` + `sio.call(event, payload)` handles connect/login/emit; Kuma's protocol is just named events with `{ok, msg}` replies. That would also drop the `packaging`/version-gating problem. Record the outcome in CONTRIBUTING ADR-001 either way (amend, don't rewrite).
4. Raise default `api_timeout` to 30 and document why.

Exit: a scripted smoke test (`tests/smoke_v2.py` or an integration target) that creates/edits/deletes one monitor of each homelab type against a v2 instance and passes.

### P1 — Close the monitor-module gaps

1. Add `timeout`, `json_path`, `json_path_operator` (`==`, `!=`, `<`, `<=`, `>`, `>=`, `contains`, `not_contains`, `starts_with`, `ends_with`), `expected_value`, `resend_interval`, `parent` (group name → id lookup) to `uptime_kuma_monitor`.
2. Add `notification_names` (list of str, mutually exclusive with `notification_ids`) resolved via `get_notification_by_name`; fail clearly if a name is missing.
3. Normalise `notificationIDList` in `needs_update` (dict keys → sorted int list) and pin the compare with a unit test using a captured v2 `get_monitor` payload from P0.
4. Pass all of the above through the role; add `uptime_kuma_monitor_defaults` so the homelab's "every monitor: retries 2, retry 60, timeout 16" is one dict, not 23 repeats.

Exit: unit tests for the new fields; the smoke test from P0 extended to the Valheim `json-query` case with `platform == playfab`.

### P2 — Bootstrap + CI + release

1. `uptime_kuma_setup` module (`need_setup()` → `setup(username, password)`), idempotent: no-op when setup is done. Wire it as the first role task, gated on `uptime_kuma_bootstrap_admin: true`.
2. CI: add a `services: uptime-kuma: louislam/uptime-kuma:2` job that runs `setup` then the integration targets. This is the only durable guard against v2 drift.
3. Pull `origin/main` into local `main`, tag `v0.1.0` (or `v0.2.0` after P1) so the homelab can pin `version:` in `requirements.yml`. Galaxy publish is optional; git source is enough for one consumer.

### P3 — Homelab adoption (in `~/Source/homelab`)

1. `requirements.yml`: add `goodolclint.uptime_kuma` as a git source pinned to the tag; `Makefile` `init`: add `uptime-kuma-api` (or nothing if P0 went stdlib + python-socketio — then add `python-socketio[client]`).
2. New `group_vars`/host_vars structure: `uptime_kuma_notifications` (the single ntfy entry, `ntfytopic` from the existing Infisical lookup) and `uptime_kuma_monitors` (port the 23 entries from `network-data/local/uptime-kuma-monitors.json`; the addresses stay in the gitignored/SOPS lane exactly as now).
3. In the `monitoring` role (or a new `uptime_kuma_config` play), after the compose stack is healthy: `uptime_kuma_setup` (first boot only), then `include_role: goodolclint.uptime_kuma.uptime_kuma` with `delegate_to: localhost` and `api_url: http://{{ service_ip }}:3001`. Add a `wait_for` on port 3001 and the `/` 302 before the role runs.
4. First run is in check mode against the live instance; it must report 0 changes for the 23 existing monitors once names and fields match. Any diff is either a real drift (fix the vars) or an idempotency bug (fix the module). That check-mode run is the acceptance test for the whole effort.

### P4 — Retire the old path

1. Delete `scripts/seed_uptime_kuma.py` and `network-data/uptime-kuma-monitors.example.json`; replace with an example vars file.
2. Amend ADR 0011 (Kuma becomes Ansible-managed; the "hand-managed-and-documented" clause and its ADR-0005 precedent no longer apply to Kuma) and rewrite `docs/uptime-kuma-monitors.md` to point at the vars file — keep the "Deliberate omissions" section, it's the valuable part.
3. Update the rebuild-as-routine doc: Kuma re-seed becomes a role run, not a script copy.

## Order of work and sizing

| Phase | Effort | Depends on |
|---|---|---|
| P0 | 0.5–1 day (mostly the live test) | admin credentials or a local v2 container |
| P1 | 0.5 day | P0 field names |
| P2 | 0.5 day | P1 |
| P3 | 0.5 day | P2 tag |
| P4 | 1 hour | P3 passing check mode |

Open decisions for the operator: (a) whether P0's fallback is the fork or an in-repo `python-socketio` client; (b) whether the first P3 run is allowed against the live instance (it is read-only in check mode, but `apply_existing` on the notification will touch every monitor's linkage if the names don't already match).

## Homelab adoption — P3/P4 DONE 2026-08-24

`ansible/playbooks/uptime-kuma.yml` + `make uptime-kuma` (`CHECK=1` = check mode with diff); collection pinned in `requirements.yml` (git, `v0.2.1`), `python-socketio[client]` in `make init`. Kuma runs on the cluster since P4b, so the role runs from localhost against `https://uptime-kuma.<domain>` with `validate_certs: false`; the admin password is Infisical `/monitoring/uptime_kuma_admin_password` (the live instance was reset to it with `extra/reset-password.js --new-password`). Acceptance: check mode against the live 22 rows reported 18 unchanged + the 4 real drifts (PBS → vlan30, Homepage → ingress, apt-cache re-created, VPS ping by name); applied; second run `changed=0`; all 23 UP and linked to ntfy. Seeder, example JSON and the three `deploy.sh kuma` sqlite repoints deleted; ADR 0011 amended; `docs/uptime-kuma-monitors.md` rewritten. Found on the way: the collection's `dns_resolve_server`/`dns_resolve_type`/`json_path_operator` module defaults made every UI-created monitor report changed (fixed in `v0.2.1`), and the homelab's `infisical_login.yml` returned empty secrets under `--check` (`read_secrets` short-circuits in check mode; the reads are now `check_mode: false`).

## Change plan (approved scope 2026-08-23: 2.x only, all 8 modules) — C0–C7 landed 2026-08-23 on `claude/build-ansible-collection-r4cFP`; tag `v0.2.0` pending operator

Decision record: [ADR 0001](decisions/0001-in-repo-python-socketio-client-replaces-the-uptime-kuma-api-wrapper-uptime-kuma-2-x-only.md). This replaces P0 "prove or replace" above with "replace".

| Step | Commit | Definition of done |
|---|---|---|
| C0 dev instance | `chore: add local Uptime Kuma 2.x dev instance` | `tests/dev/docker-compose.yml` + `tests/dev/up.sh` bring up `louislam/uptime-kuma:2` on :3001 with a known admin (via the `setup` event); `integration_config.yml` points at it |
| C1 client | `feat: python-socketio client replaces uptime-kuma-api` | `module_utils/uptime_kuma_api.py` rewritten: connect/login/token/setup/`_call`; monitor payload builder for the 2.x field set; same public method names as today so modules compile unchanged. Unit tests mock `socketio.Client`. A smoke script against C0 creates/edits/deletes one monitor of each homelab type (http, port, dns, ping, json-query) and an ntfy notification |
| C2 monitor gaps | `feat(monitor): timeout, json-query, resend, parent, notification_names` | new params + `notificationIDList` normalisation; check-mode re-run after create reports `changed: false` for every type (idempotency test in integration target) |
| C3 setup module | `feat: add uptime_kuma_setup module` | `need_setup` → `setup`; second run no-op |
| C4 remaining modules | one commit each: notification, tag, monitor_tag, maintenance, status_page, api_key, settings | each integration target passes against C0; any 2.x payload drift fixed in the client, not the module |
| C5 role | `feat(role): pass through full monitor field set + defaults dict` | role run with the homelab example list (placeholders) applies cleanly and is idempotent |
| C6 CI | `ci: run integration targets against uptime-kuma:2 service` | CI green with the container; unit + integration both required |
| C7 docs + release | `docs: requirements, ADR back-links, changelog` then tag `v0.2.0` | README Requirements = `python-socketio[client]`; supported Kuma = 2.x |

Each commit stacks on the previous; integration test is the regression pin. Homelab adoption (P3/P4 above) starts after the tag.
