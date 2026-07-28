#!/bin/sh
# Client-view mDNS probe for a SINGLE-HOMED WIRELESS host (laptop/phone-class).
#
# Companion to mdns-probe.sh, which runs on the dual-homed Mac Studio and
# compares wired-vs-wifi packet counts. That comparison needs two interfaces, so
# it can't run here. This one instead measures the user-visible symptom: "can I
# discover the speakers/printer at all?" — no root required, so it can run as a
# LaunchAgent.
#
# WHY BOTH: testing the cascade hypothesis — that one client loses mDNS and the
# rest follow over time. A single vantage point cannot distinguish "this client
# is broken" from "the network is broken" (2026-07-23: the Studio reported
# WIFI_DOWN for a sustained period while this MacBook saw everything fine).
# Two independent wireless clients logging timestamps lets us see whether a
# failure on one is followed by the other, and in what order.
#
# CAVEAT: dns-sd reads mDNSResponder's cache, so a brief multicast gap can be
# masked by cached records (Bonjour TTLs are ~75min, refreshed while healthy).
# This probe is therefore RELIABLE FOR SUSTAINED OUTAGES (the real failure mode,
# which lasts hours) and BLIND TO SHORT BLIPS. Don't read a passing result here
# as proof that no momentary gap occurred.
#
# Usage: mdns-client-probe.sh [--dry-run]

set -u

LOG="${MDNS_CLIENT_LOG:-$HOME/Library/Logs/mdns-client-probe.log}"
BROWSE_SECS="${MDNS_BROWSE_SECS:-8}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Only meaningful on wifi. If this host is on ethernet, its result says nothing
# about wireless delivery — record that rather than a misleading "ok".
WIFI_IP=$(ipconfig getifaddr en0 2>/dev/null)
if [ -z "$WIFI_IP" ]; then
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    LINE="{\"ts\":\"$TS\",\"host\":\"$(hostname -s)\",\"status\":\"NO_WIFI\",\"raop\":0,\"ipp\":0}"
    [ "$DRY_RUN" -eq 1 ] && echo "$LINE" || echo "$LINE" >> "$LOG"
    exit 0
fi

# count distinct discovered instances; "Add" lines carry them
RAOP=$(dns-sd -t "$BROWSE_SECS" -B _raop._tcp 2>/dev/null | grep -c 'Add' || true)
IPP=$(dns-sd -t "$BROWSE_SECS" -B _ipp._tcp 2>/dev/null | grep -c 'Add' || true)
RAOP=${RAOP:-0}
IPP=${IPP:-0}

# speakers are the canonical cross-vlan reflected service; zero = discovery dead
if [ "$RAOP" -gt 0 ]; then STATUS="ok"; else STATUS="CLIENT_DOWN"; fi

TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LINE="{\"ts\":\"$TS\",\"host\":\"$(hostname -s)\",\"status\":\"$STATUS\",\"raop\":$RAOP,\"ipp\":$IPP,\"wifi_ip\":\"$WIFI_IP\"}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "$LINE"
    [ "$STATUS" = "ok" ]
    exit $?
fi

echo "$LINE" >> "$LOG"
[ "$STATUS" = "ok" ]
