#!/usr/bin/env python3
"""Seed Uptime Kuma's own database with the internal reachability monitors and the
ntfy notification channel. Idempotent: rows are matched by name and left alone if
present. Run with the uptime-kuma container stopped, then start it — Kuma loads
monitors from this table at boot.

Usage: seed-kuma.py <targets.json> <ntfy-topic>
"""
import json
import sqlite3
import sys

DB = "/var/lib/uptime-kuma/kuma.db"
NOTIFICATION_NAME = "ntfy (homelab alerts)"

targets = json.load(open(sys.argv[1]))
topic = sys.argv[2].strip()
if not topic:
    sys.exit("empty ntfy topic")

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row
user_id = con.execute("select id from user where active = 1 order by id limit 1").fetchone()["id"]

# --- notification channel ---
row = con.execute("select id from notification where name = ?", (NOTIFICATION_NAME,)).fetchone()
if row:
    notif_id = row["id"]
    print(f"notification: already present (id {notif_id})")
else:
    config = {
        "name": NOTIFICATION_NAME,
        "type": "ntfy",
        "isDefault": True,
        "applyExisting": True,
        "ntfyserverurl": "https://ntfy.sh",
        "ntfytopic": topic,
        "ntfyPriority": 5,
        "ntfyPriorityDown": 5,
        "ntfyAuthenticationMethod": "none",
    }
    cur = con.execute(
        "insert into notification (name, active, user_id, is_default, config) values (?, 1, ?, 1, ?)",
        (NOTIFICATION_NAME, user_id, json.dumps(config)),
    )
    notif_id = cur.lastrowid
    print(f"notification: created (id {notif_id})")

# --- monitors ---
DEFAULTS = {
    "interval": 60,
    "retry_interval": 60,
    "resend_interval": 0,
    "maxretries": 2,
    "timeout": 16,
    "active": 1,
    "accepted_statuscodes_json": '["200-299"]',
    "method": "GET",
    "ignore_tls": 0,
    "upside_down": 0,
    "maxredirects": 10,
    "expiry_notification": 0,
    "packet_size": 56,
    "weight": 2000,
    "conditions": "[]",
}

created = skipped = 0
for t in targets:
    name = t["name"]
    if con.execute("select 1 from monitor where name = ?", (name,)).fetchone():
        skipped += 1
        print(f"monitor: {name!r} already present, skipped")
        continue

    row = dict(DEFAULTS)
    row["name"] = name
    row["user_id"] = user_id
    row["type"] = t["type"]
    for key in ("url", "hostname", "port", "dns_resolve_server", "dns_resolve_type",
                "interval", "maxretries", "retry_interval",
                "json_path", "expected_value", "json_path_operator"):
        if key in t:
            row[key] = t[key]
    if "ignoreTls" in t:
        row["ignore_tls"] = 1 if t["ignoreTls"] else 0
    if "accepted_statuscodes" in t:
        row["accepted_statuscodes_json"] = json.dumps(t["accepted_statuscodes"])

    cols = ", ".join(f"`{k}`" for k in row)
    con.execute(
        f"insert into monitor ({cols}) values ({', '.join('?' * len(row))})",
        list(row.values()),
    )
    mid = con.execute("select last_insert_rowid() as id").fetchone()["id"]
    con.execute(
        "insert into monitor_notification (monitor_id, notification_id) values (?, ?)",
        (mid, notif_id),
    )
    created += 1
    print(f"monitor: created {name!r} (id {mid})")

con.commit()
total = con.execute("select count(*) as n from monitor").fetchone()["n"]
linked = con.execute("select count(*) as n from monitor_notification").fetchone()["n"]
con.close()
print(f"\nsummary: {created} created, {skipped} existed | {total} monitors in db, {linked} linked to a channel")
