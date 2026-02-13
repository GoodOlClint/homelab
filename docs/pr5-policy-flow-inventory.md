# PR5 Policy Flow Inventory

Purpose: capture zone-to-zone intent candidates from current infrastructure/service behavior before expanding `network-data/public_policy.yaml`.

## Evidence Sources

- `ansible/group_vars/all.yml` (`dns_zones`, `service_ports`, storage/NFS references)
- `ansible/roles-infrastructure/bind9/tasks/main.yml` (multi-zone DNS management)
- `ansible/roles/dns_config/tasks/main.yml` (DNS resolver assignment per interface)
- Existing policy in `network-data/public_policy.yaml` (mDNS/AirPlay/NTP + deny baseline)

## Current Declared Zones

- `management`
- `storage`
- `infrastructure`
- `services`
- `media`
- `core`
- `work`
- `iot`
- `sonos`
- `vivint`
- `guest`

## Existing Policy Coverage (Already Declared)

- Work -> Sonos (`mdns_discovery`)
- Work -> Media (`airplay_control`)
- IoT -> Infrastructure (`ntp`)
- IoT -> Management (`block any`)

## Candidate Additional Intents (To Evaluate/Implement)

1. DNS client flows to infra DNS services
   - Candidate zones: `core`, `work`, `iot`, `sonos`, `guest` -> `infrastructure`
   - Service candidate: `dns` (udp/tcp 53)
2. Monitoring/observability ingest paths
   - Candidate zones: all managed endpoints -> `infrastructure` / `services` monitoring stack
   - Service candidates: syslog, telegraf metrics, scrape/exporter traffic
3. Backup traffic
   - Candidate zones: `services` / `media` -> `storage` and/or `infrastructure` (PBS)
   - Service candidates: NFS (legacy), PBS client traffic
4. Service-management access controls
   - Candidate zones: `management` -> `services` / `infrastructure`
   - Service candidates: SSH/admin ports currently represented in role/playbook behavior

## PR5 Expansion Guardrails

- Keep policy file intent-only (no IP/CIDR/interface literals).
- Keep private address/interface details in `network-data/local/private_bindings.yaml` only.
- Add aliases first, then rules that reference those aliases.
- Preserve deny-first posture for high-risk cross-zone paths.
