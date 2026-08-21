# pfSense NUT server — as-built config

The pfSense NUT package is the NUT server for both UPSes (architecture and rationale in [physical-buildout-plan.md](physical-buildout-plan.md#repo-hook-nut-graceful-shutdown)). The package is hand-managed in the pfSense GUI per ADR-0005 (no pfSense IaC); this doc captures the config so it can be re-entered after a pfSense rebuild. There is no REST-API lane for NUT (the pfSense REST API package has no NUT endpoints), so re-entry is GUI or `pfSsh.php`.

Both UPSes are on pfSense's USB (via a small powered hub on an extension — enumerates fine as `ugen0.3`/`ugen0.4`). The GUI configures one UPS; the second rides the package's Advanced-settings boxes, which append raw NUT config.

## ups.conf (GUI UPS + Advanced boxes)

The package renders ups.conf in three parts: the **global** Advanced box (`ups_conf`, "Additional configuration lines for ups.conf") first, then the GUI-defined `[network-ups]` stanza, then the **per-driver** Advanced box (`extra_args`) appended verbatim — which is where the extra `[ups]` stanza lives.

Global box — required, or both drivers stay "Driver not connected" ("UPS Daemon pending" in the GUI):

```
user = root
```

`usbhid-ups` drops to user `nut`, but the devd rule set (`/usr/local/etc/devd/nut-usb.conf`) has no entry for the OR2200PFCRT2U / CP1500PFCRM2U product IDs, so the `ugen` nodes stay `root:operator 0600` and the driver cannot open them. Rediscovered 2026-08-21 after the 26.07 upgrade dropped the NUT package (and its whole config section) — note every pfSense upgrade may require re-entering all of this; check Services → UPS after each one.

Rendered result:

```
user = root

[network-ups]
    driver = usbhid-ups
    port = auto
    product = ".*CP1500.*"
    desc = "CP1500 network UPS"

[ups]
    driver = usbhid-ups
    port = auto
    product = ".*OR2200.*"
    desc = "OR2200 compute UPS"
```

Constraints baked into the above:

- **The stanza named `ups` MUST stay the OR2200 (compute UPS), and the account below MUST stay `monuser`/`secret`** — the Synology's built-in NUT client hardcodes all three. Renaming any of them silently breaks the Synology (it would keep connecting to whatever `ups` is, or stop authenticating).
- **Matching is by `product` regex, not serial** — both CyberPower units report a blank `device.serial`, and the model strings (`OR2200PFCRT2U` / `CP1500…`) are the only stable discriminator on one USB tree.
- `desc` is what the Home Assistant NUT integration shows in its device picker ("Description unavailable" without it).
- `network-ups` (CP1500) is the UPS pfSense's own `upsmon` monitors as primary — pfSense is powered by it, so pfSense only shuts itself down when *its own* feed goes critical, never when the compute UPS drains. The compute-side clients act on `ups`'s `OB LB` status themselves as secondaries; no FSD from pfSense is involved.

## upsd.conf (Advanced box)

```
LISTEN 0.0.0.0 3493
```

upsd answers on the **management-VLAN pfSense address** (clients are configured against that address, not their own VLAN's gateway). With a well-known account in play, **the firewall rule on 3493/tcp is the only real access control** — keep it scoped to the client hosts/subnets (Synology, PVE hosts, HA Green, Mac Studio), never any-any.

## upsd.users (Advanced box)

```
[monuser]
    password = secret
    upsmon secondary
```

One shared account, deliberately: it must exist verbatim for the Synology anyway, and a `secondary`-role login can only read status (FSD is primary-only), so a second stronger account would add management overhead and zero security. See the firewall note above.

## Clients

| Client | Mechanism | Monitors |
|--------|-----------|----------|
| PVE hosts (pve, worklab; crete/crete2 at cutover) | `nut_client` role, `make nut-clients` | `ups` (compute) |
| Synology | Built-in "synchronize with network UPS server" mode | `ups` (compute, hardcoded name) |
| HA Green | Home Assistant NUT integration — alerts/automation only, never load-bearing for shutdown | both |
| Mac Studio | Homebrew `nut` + launchd daemon (below) | `ups` (compute) |

## Mac Studio (unmanaged, hand-configured 2026-08-13)

`/opt/homebrew/etc/nut/upsmon.conf` (root:wheel 0600) — same MONITOR line as the `nut_client` role's template but with `SHUTDOWNCMD "/sbin/shutdown -h now"`, pointed at the same server address.

`/Library/LaunchDaemons/org.networkupstools.upsmon.plist` runs `/opt/homebrew/sbin/upsmon -F` with `RunAtLoad` + `KeepAlive`; load with `sudo launchctl bootstrap system /Library/LaunchDaemons/org.networkupstools.upsmon.plist`.

## Verification

From any client: `upsc ups@<server> ups.status` → `OL` (no auth needed), and an ESTABLISHED TCP session to `<server>:3493` owned by `upsmon` proves the authenticated monitor is up.

## Open items

- **Pull-the-plug rehearsal** once compute workloads are configured: confirm all secondaries shut down on `OB LB`.
- **Compute-UPS output cut for BIOS auto-restart** ([physical-buildout-plan.md](physical-buildout-plan.md#power-recovery-coming-back-after-an-outage)): no primary shuts the compute UPS down anymore, so the load-off must come from `upssched`/`upscmd load.off.delay` on pfSense — design and verify at the rehearsal.
