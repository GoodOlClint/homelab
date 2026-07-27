# ADR 0011 — Two alerting lanes: Uptime Kuma for reachability, Alertmanager for metrics

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** operator (session 2026-07-27)
- **Context source:** docs/uptime-kuma-monitors.md · docs/uptimerobot-setup.md · ansible/roles/monitoring/

## Context

Nothing in this homelab could notify anyone. Uptime Kuma had been running on the monitoring VM for months with zero monitors and no notification channel. Twelve Prometheus alert rules evaluated on schedule against no Alertmanager and no Grafana notifier, so every one of them fired into the void — `HighDiskUsage` among them, which would have caught AdGuard reaching 88% if anything could have delivered it.

The motivating incident is sharper than "a service went down". OpenObserve stopped ingesting logs after 2026-07-02 and nobody noticed for 24 days, across two reboots. No reachability check would have caught it: the container was running and port 5080 answered `200` on `/healthz` the entire time. Only the *volume* of ingested data had gone to zero. Investigating that during this session found the root cause — OpenObserve returns `401` to axosyslog because the root credential in Infisical no longer matches the one in OpenObserve's own user table — and, separately, that `password_file`-style secret delivery had never worked at all (below).

`docs/uptimerobot-setup.md` already records the settled split: UptimeRobot is the external, outside-in prober; Uptime Kuma is internal. That split is not reopened here. The open question was what the internal side looks like and where the orphaned Prometheus rules go.

## Decision

**Alerting runs in two lanes with one delivery channel.**

**Lane 1 — Uptime Kuma: internal reachability.** Kuma answers "can I connect to this thing", and only that. It monitors internal VM services by their services-VLAN address (HTTP, TCP port, DNS query) plus ICMP to the VPS public IP and the WireGuard tunnel peer. Kuma is configured through its web UI and **hand-managed-and-documented**, following the ADR-0005 precedent for UI-configured tools. The consequence of that precedent is binding: `docs/uptime-kuma-monitors.md` describes what exists, not what is recommended.

**Lane 2 — Prometheus + Alertmanager: everything metric-shaped.** The twelve orphaned rules get a delivery path rather than deletion. An `alertmanager` service joins the monitoring stack, Prometheus gains an `alerting:` stanza pointing at it, and Alertmanager routes every alert to the shared channel. Rules whose metrics do not exist yet are kept, not culled — see Consequences.

**Delivery channel — ntfy.** Both lanes publish to a single ntfy.sh topic. The topic string is itself the credential and lives in Infisical at `/monitoring/alert_ntfy_topic`; the Infisical agent renders the full publish URL to `/etc/infisical/secrets/alert-ntfy-url` for Alertmanager's `url_file`, and Kuma holds the topic in its own notification config. ntfy's built-in `?template=alertmanager` formats the webhook JSON into readable firing/resolved notifications with no bridge service.

**The hard case — ingestion volume goes in Lane 2, as a Prometheus rule.** A new `SyslogIngestionStalled` rule alerts when OpenObserve has accepted zero successful `_json` log-ingest batches in 30 minutes:

```
sum(increase(zo_http_incoming_requests{endpoint="/api/org/ingest/logs/_json", status="200"}[30m])) == 0
```

## Rejected alternatives

- **Grafana unified alerting instead of Alertmanager.** Grafana is already deployed, so this looked like the lazier option. It is not: the alert rules are twelve Prometheus expressions that already exist in a template the monitoring role renders, and Grafana would require re-authoring each one as a Grafana rule object in provisioning YAML with a different schema. Alertmanager consumes the rules as written. Grafana also owns dashboards here, not alerting policy, and coupling the two means a Grafana outage takes alerting with it.
- **Delete the twelve rules.** They encode real operational thresholds someone already thought about. The problem was never the rules, it was that nothing consumed them.
- **An Uptime Kuma PUSH monitor fed by a script that queries OpenObserve for recent syslog docs.** This was the closest call. It was rejected because it needs a new cron job, a new script, and OpenObserve credentials to run — and the credentials are exactly what broke in the incident being defended against, so the detector would fail in the same failure mode as the thing it watches. The Prometheus rule reads OpenObserve's own unauthenticated `/metrics` endpoint, which Prometheus already scrapes, and needs no new moving parts.
- **An OpenObserve-native alert.** Same objection, more strongly: an alert evaluated by the component that is failing cannot be trusted to report that component failing. Ingestion stopping and alert evaluation stopping share a cause.
- **Reachability check on OpenObserve as ingestion coverage.** Empirically disproven by the incident itself — 24 days of a healthy port and zero data.
- **Discord webhook as the channel.** The intended reuse target, `valheim_discord_webhook`, turned out not to exist in Infisical at all (the Valheim env file renders without it), so there was no working webhook to reuse. ntfy needs no account.

## Consequences

- Alerting now depends on ntfy.sh, a free public service, with no account and no delivery guarantee. Acceptable for a homelab; the topic is unguessable but public-by-URL, so alert summaries must not carry secrets. Self-hosting ntfy is the upgrade path if that changes.
- **`SyslogIngestionStalled` fires immediately and stays firing**, because ingestion is genuinely broken right now (the `401` above). This is correct behaviour — the first thing the new alerting layer reports is the real, still-unfixed 24-day outage — but it is noise until the credential is repaired. That repair is deliberately *not* done here: OpenObserve's root password is an argon2 hash in its live metadata DB, the old plaintext is unrecoverable, and rewriting auth records in the production log store needs operator authorisation.
- **Discovered while wiring this up: agent-rendered secrets were unreadable by every non-root container.** The Infisical agent writes `0600 root` and offers no permission option, while the `prom/*` images run as `nobody`. Prometheus `remote_write` to OpenObserve had therefore been failing on `permission denied` continuously and silently — it retries forever at WARN level — and Alertmanager's first delivery attempt failed the same way. Templates consumed by a non-root container now declare `mode:` in `infisical_agent_templates`; the role applies it after render and the template's `post_command` re-applies it after a rotation.
- Rules for metrics that no exporter currently produces (`wireguard_latest_handshake_seconds`, `pbs_snapshot_timestamp`) stay in place and simply never fire. They are the specification for the exporters that should exist; deleting them loses that intent. `proxmox-exporter` and `pbs-exporter` remain open threads.
- `node_exporter` runs only on the monitoring VM — every other host reports through telegraf — so the memory and disk rules were covering one host in eight. Telegraf-sourced twins (`HighMemoryUsageTelegraf`, `HighDiskUsageTelegraf`) now cover the rest. This is the gap that made the AdGuard 88% disk event undetectable even in principle.
- Kuma's monitor set is not managed by Ansible, but it is reproducible: `scripts/seed_uptime_kuma.py` inserts the monitors and the notification channel from a JSON target list, idempotently. The real list carries private addresses and lives in the gitignored `network-data/local/uptime-kuma-monitors.json`; `network-data/uptime-kuma-monitors.example.json` is the tracked template. `/var/lib/uptime-kuma` still belongs in the backup set — the seeder restores monitors, not history.
