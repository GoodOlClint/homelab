# pfSense + UniFi — the CI sandbox VLAN (ADR 0032)

Hand-managed per [ADR 0005](decisions/0005-pfsense-stays-hand-managed-unifi-gets-a-terraform-module.md). The VLAN number and subnet are bindings in the gitignored `network-data/vlans.yaml` (`vlans.ci`, decided 2026-08-22: **VLAN 60**); the Proxmox side (`Ci` VNET, pool `ci`, `ci@pve` token, reaper) is IaC.

## Intent

CI runners build disposable guests (nested PVE, test targets) on this VLAN. Those guests may reach the internet and nothing else; the runners reach them and the PVE API; the fleet never initiates toward them.

## UniFi (controller, by hand)

Networks → Create: **CI**, VLAN `<ci.id>`, *Third-party gateway*, subnet `<ci subnet>` — the node bonds are trunks (all tagged), so nothing else changes.

## pfSense

1. **Interfaces → Assignments → VLANs**: add VLAN `<ci.id>` on the LAN parent; assign as `CI`, enable, static IPv4 `<ci gateway>/24`. IPv4 only (no track6) — nothing here needs v6.
2. **Services → DHCP Server → CI**: enable, range `<ci.dhcp_range_start>`–`<ci.dhcp_range_end>`, DNS `1.1.1.1` (the sandbox must not resolve internal names — not the AdGuard VIP).
3. **Firewall → Rules → CI** (top to bottom):

| # | Action | Source | Destination | Ports | Note |
|---|---|---|---|---|---|
| 1 | Pass | CI net | CI net | any | guests talk to each other (nested clusters) |
| 2 | Block | CI net | alias `rfc1918` (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) | any | no path to any fleet VLAN |
| 3 | Pass | CI net | any | any | internet |

4. **Firewall → Rules → SERVICES** (where the runners live until ADR 0031 moves them): Pass `runner hosts` → CI net any; Pass `runner hosts` → `<VIP>` tcp/8006. Everything else from the runners toward vlan10/30 stays blocked.

**State 2026-08-22:** UniFi network + pfSense interface/DHCP are done; the CI rules are deliberately **pass-any while traffic is captured** for the rule-tightening pass. The block-rfc1918 rule above is the target, not the live state — tighten once the capture shows what the integration jobs actually need (expected: nothing internal).

Apply, then verify from a CI guest: `curl -m 3 https://1.1.1.1` succeeds; `curl -m 3 http://<adguard VIP>:3000` and `ping <a node>` fail.

## Proxmox side (IaC, for reference)

- `make sdn-apply` — creates the `Ci` VNET from `vlans.yaml`.
- `make hosts-apply ENDPOINT=…` — pool `ci`, user `ci@pve`, token `ci@pve!ci`, ACLs (`terraform/hosts/iam.tf`). Token: `cd terraform/hosts && terraform output -raw ci_api_token` → GitHub repo secret `PVE_API_TOKEN` = `ci@pve!ci=<value>`; `PVE_ENDPOINT` = the VIP; `PVE_TARGET_NODE` = `ms-01a` while msi is on the RMA-pending CPU.
- `make proxmox-hosts` — installs the hourly `ci-reaper` timer (destroys pool members older than `proxmox_host_ci_max_age_hours`, default 8).
- Workflow Terraform variables for PSProxmoxVE: `disk_storage = ceph-rbd`, `iso_storage = cephfs`, `network_bridge = Ci`, VMIDs in 5000–5999.
