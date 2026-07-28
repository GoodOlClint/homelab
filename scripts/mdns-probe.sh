#!/bin/sh
# mDNS wireless-delivery probe (macOS / Mac Studio, dual-homed on vlan100).
#
# WHAT BROKE (2026-07-21): wireless clients on the U7 Pro stopped receiving
# wired-origin multicast. pfSense/Avahi reflected VLAN 121 Sonos records onto
# vlan100 correctly (verified: 23 pkts from the pfSense reflector), the AP bridged them to
# the wireless VAPs (verified, same timestamps), and associated wireless clients
# received ZERO. Wired clients were fine throughout. Both a 5GHz iPhone 14 and
# 6GHz clients were affected, so it is not band-specific. Wireless-origin
# multicast (Apple TVs on the same vlan) kept working. Only a radio/VAP reset
# clears it — client reconnect does not. Recurs every few weeks, silently.
#
# WHY IT CAPTURES TWO INTERFACES: this host is wired AND wireless on vlan100.
# A probe that just runs `dns-sd` sees the records over ethernet and reports
# green while wifi is dead. Counting per-interface is the whole point:
#
#   wired>0, wifi>0   -> ok            (delivery healthy both paths)
#   wired>0, wifi==0  -> WIFI_DOWN     (the bug: AP not delivering to wireless)
#   wired==0          -> UPSTREAM_DOWN (avahi/pfSense/reflection problem instead)
#
# That split matters: it tells you which box to look at before you start.
#
# Requires root (tcpdump) -> install as a LaunchDaemon, not a LaunchAgent.
#
# Usage:
#   mdns-probe.sh              probe, POST to OpenObserve, exit non-zero if bad
#   mdns-probe.sh --dry-run    probe and print, POST nothing   <-- runnable check
#
# Env (from Infisical-rendered env_file):
#   OPENOBSERVE_URL OPENOBSERVE_ORG OPENOBSERVE_USER OPENOBSERVE_PASSWORD

set -u

WIRED_IF="${MDNS_WIRED_IF:-en0}"
WIFI_IF="${MDNS_WIFI_IF:-en1}"
REFLECTOR="${MDNS_REFLECTOR:?set MDNS_REFLECTOR to the avahi reflector (pfSense vlan100) IP}"
DURATION="${MDNS_DURATION:-15}"
STREAM="${MDNS_STREAM:-mdns_probe}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

TMP=$(mktemp -d /tmp/mdnsprobe.XXXXXX) || exit 1
trap 'pkill -f "tcpdump -i $WIRED_IF" 2>/dev/null; pkill -f "tcpdump -i $WIFI_IF" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

# wifi must actually be associated or the result is meaningless, not "down".
# Test for an IPv4 address, NOT the SSID: modern macOS reports the SSID as
# "<redacted>" without Location Services, and `networksetup -getairportnetwork`
# claims "not associated" even when the interface is up with an address.
WIFI_IP=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)
SSID="${WIFI_IP:-none}"
if [ -z "$WIFI_IP" ]; then
    STATUS="WIFI_NOT_ASSOCIATED"; WIRED_N=0; WIFI_N=0
else
    # capture both paths over the SAME window, filtered to the reflector's frames
    tcpdump -i "$WIRED_IF" -n "udp port 5353 and src host $REFLECTOR" > "$TMP/wired" 2>/dev/null &
    tcpdump -i "$WIFI_IF"  -n "udp port 5353 and src host $REFLECTOR" > "$TMP/wifi"  2>/dev/null &
    sleep 2

    # stimulate: browsing makes the speakers answer, which avahi then reflects.
    # without this the window can be silent simply because nothing announced.
    ( dns-sd -B _raop._tcp & dns-sd -B _ipp._tcp &
      sleep "$DURATION"; kill %1 %2 2>/dev/null ) >/dev/null 2>&1

    sleep 1
    pkill -f "tcpdump -i $WIRED_IF" 2>/dev/null
    pkill -f "tcpdump -i $WIFI_IF" 2>/dev/null
    sleep 1

    # `grep -c` prints the count AND exits non-zero when it is 0, so a naive
    # `|| echo 0` appends a SECOND zero and yields "0\n0", which then breaks the
    # -eq comparisons below and silently misclassifies an outage as ok.
    # `|| true` inside the substitution keeps grep's own "0" and clears the status.
    WIRED_N=$(grep -c "$REFLECTOR" "$TMP/wired" 2>/dev/null || true)
    WIFI_N=$(grep -c "$REFLECTOR" "$TMP/wifi" 2>/dev/null || true)
    WIRED_N=${WIRED_N:-0}
    WIFI_N=${WIFI_N:-0}

    if [ "$WIRED_N" -eq 0 ]; then STATUS="UPSTREAM_DOWN"
    elif [ "$WIFI_N" -eq 0 ]; then STATUS="WIFI_DOWN"
    else STATUS="ok"; fi
fi

HOST=$(hostname -s)
# Timestamp is load-bearing for forensics: without it the log is an undated
# sequence and blips can't be correlated against AP events, client roams, or
# each other across hosts. Learned the hard way.
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PAYLOAD="[{\"ts\":\"$TS\",\"host\":\"$HOST\",\"status\":\"$STATUS\",\"wired_pkts\":$WIRED_N,\"wifi_pkts\":$WIFI_N,\"wifi_ip\":\"$SSID\",\"reflector\":\"$REFLECTOR\"}]"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "$PAYLOAD"
    [ "$STATUS" = "ok" ] || echo "PROBLEM: $STATUS (wired=$WIRED_N wifi=$WIFI_N)" >&2
    [ "$STATUS" = "ok" ]
    exit $?
fi

# Always log locally first: if the OpenObserve creds are missing or wrong, the
# probe must still leave evidence rather than dying under `set -u`. A monitor
# that fails silently is worse than no monitor.
echo "$PAYLOAD"

if [ -n "${OPENOBSERVE_URL:-}" ] && [ -n "${OPENOBSERVE_USER:-}" ] \
   && [ -n "${OPENOBSERVE_PASSWORD:-}" ] && [ -n "${OPENOBSERVE_ORG:-}" ]; then
    curl -sS --max-time 15 \
        -u "$OPENOBSERVE_USER:$OPENOBSERVE_PASSWORD" \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD" \
        "$OPENOBSERVE_URL/api/$OPENOBSERVE_ORG/$STREAM/_json" >/dev/null \
        || echo "WARN: OpenObserve POST failed" >&2
else
    echo "WARN: OpenObserve env not set — logged locally only" >&2
fi

[ "$STATUS" = "ok" ]
