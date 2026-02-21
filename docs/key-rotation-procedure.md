# WireGuard Key Rotation Procedure

## Overview

Rotate the VPS WireGuard keypair periodically or if a key is suspected compromised. The process generates a new keypair on the VPS, then requires manual update of the pfSense peer configuration.

**Downtime:** ~30 seconds (time to update pfSense + PersistentKeepalive reconnect)

## Procedure

### 1. Run Key Rotation Playbook

```bash
make vps-rotate-keys
```

This generates a new keypair on the VPS, updates the VPS WireGuard config, and displays the new public key.

### 2. Update pfSense

1. Navigate to **VPN > WireGuard > Peers**
2. Edit the VPS peer (Vultr VPS Dallas)
3. Replace **Public Key** with the new key displayed by the playbook
4. Save and Apply Changes

### 3. Verify Tunnel Reconnects

Within 25 seconds (PersistentKeepalive interval), the tunnel should re-establish:

1. **pfSense:** Status > WireGuard — check "Latest Handshake" updates
2. **VPS:** `wg show wg0` — verify peer handshake timestamp
3. **Functional test:** Access Plex via the VPS public endpoint

### 4. Update Secrets File

Update `ansible/group_vars/secrets.sops.yml` with the new private key so future Ansible runs use the correct key:

```bash
sops ansible/group_vars/secrets.sops.yml
# Update vps_wg_private_key with the new private key
```

## Emergency Rotation (Key Compromise)

If a key is suspected compromised:

1. **Immediately** run `make vps-rotate-keys` to replace the VPS key
2. Update pfSense peer as above
3. If the VPS itself is compromised, run `make vps-rebuild` instead (full teardown + rebuild)
4. Review VPS logs in OpenObserve for suspicious activity
5. Consider rotating the pfSense keypair as well (manual — regenerate in pfSense WireGuard tunnel settings, then update `pfsense_wg_public_key` in secrets.sops.yml and re-run `make vps-deploy`)

## Full VPS Rebuild

If rotation isn't sufficient (VPS compromise suspected):

```bash
make vps-rebuild
```

This destroys and recreates the VPS instance from scratch. The reserved IP is preserved, so DNS and pfSense endpoint configuration remain valid. Update the pfSense peer with the new VPS public key after rebuild.

## Schedule

Recommended rotation schedule:
- **Routine:** Every 90 days
- **After incident:** Immediately
- **After VPS rebuild:** Automatic (new keys generated)
