# Runbook — full-cluster outage to re-rack ms-01a and ms-01b

Planned 2026-09-25. ms-01a and ms-01b move from the 3D-printed mounts to Racknex sliding mounts in the same cabinet. Two of three Ceph hosts go down together, so this is a **full, planned outage**: every guest and all three nodes power off, and the cluster comes back in reverse order. msi cannot keep serving alone: it is 1 of 3 corosync votes (not quorate, and HA's watchdog would reset it) and 1 of 3 Ceph mons (no quorum, so every Ceph-backed disk freezes).

Scope is **physical only**: recable like-for-like. Ring1 stays on the Pro-Max-48 (ADR 0058 waits for msi's M.2 i226 card), and the Ceph cluster link stays on the Pro-Agg until the CRS518 cutover (ADR 0057), which is one node at a time under `noout` and needs no outage.

Run every node command from a node shell (`ssh root@<node mgmt address>`). **DNS goes down with the cluster** (both AdGuard and both BIND instances are guests), so keep the node management addresses and AMT addresses from `network-data/local/host-bindings.yaml` open before you start. `kubectl` means `kubectl --kubeconfig kubernetes/talos/.secrets/kubeconfig` from the repo root.

## Before the window

- [ ] Not inside the 02:30 backup window (`nightly-fleet` runs on PBS).
- [ ] `ceph health` is `HEALTH_OK` and `ha-manager status` shows all three LRMs `active`.
- [ ] **ms-01a has had no kernel oops this boot:** `journalctl -k -b | grep -iE "oops|BUG:"` is empty. After an oops, its next clean shutdown hangs forever on `pve-ha-lrm` stop (2026-09-25), and you will need an AMT reset. Plan for it rather than waiting.
- [ ] AMT console open for ms-01a and ms-01b (KVM/JetKVM for msi).
- [ ] Label every cable on ms-01a and ms-01b before unplugging: 2× X710 SFP+ (bond → Pro-Agg), ConnectX port 0 (Ceph VLAN 21 → Pro-Agg SFP28), i226-LM (install/mgmt + ring0 + AMT → Pro-Max), i226-V (ring1 → Pro-Max), power.

## Shutdown

**1. Stop the HA guests through HA.** HA shuts them down itself; setting them to `stopped` is also what lets each LRM go idle and release its watchdog, so losing quorum later fences nothing.

```sh
for sid in vm:200 vm:201 vm:205 vm:220 ct:208 ct:212 ct:213; do ha-manager set $sid --state stopped; done
watch -n5 'ha-manager status'
```

Wait until every service shows `stopped`, then until **all three** LRMs show `idle` (that can take a few minutes after the last service stops). Do not continue while any LRM is `active`.

**2. Stop the Kubernetes nodes.** Talos handles ACPI shutdown. Run on each node for its own VM, or on any node with `pvesh`:

```sh
qm shutdown 230 --timeout 300   # on ms-01a
qm shutdown 231 --timeout 300   # on ms-01b
qm shutdown 232 --timeout 300   # on msi
```

**3. Stop the other guests**, applications first, DNS last:

```sh
# msi
qm shutdown 242; qm shutdown 240
# ms-01a
pct shutdown 280; qm shutdown 217; qm shutdown 216
# DNS last (both nodes)
pct shutdown 218; pct shutdown 251      # ms-01a
pct shutdown 219; pct shutdown 252      # ms-01b
```

Check with `pvesh get /cluster/resources --type vm --output-format json | grep -c '"status":"running"'` → `0` (VM 900, the data-volume holder, is never started).

**4. Freeze Ceph.** Only after every guest is down:

```sh
ceph osd set noout; ceph osd set norebalance; ceph osd set norecover; ceph osd set nobackfill
```

Do **not** set `pause`: the nodes' kernel cephfs mounts would block, and shutdown would hang unmounting `/mnt/pve/cephfs`.

**5. Power off the nodes**: msi, then ms-01b, then ms-01a.

```sh
systemctl poweroff
```

Watch each on its console. If a node sits after "unmounting" with no progress for more than 2 minutes, check `systemctl list-jobs` from another shell if it still answers; a stuck `pve-ha-lrm` stop means an AMT/KVM reset. That is safe at this point, because the node holds no guests and `noout` is set.

## Physical

- [ ] Re-rack ms-01a and ms-01b in the Racknex mounts.
- [ ] Recable exactly as labelled. Same switch, same port for every cable.

## Bring-up

**1. Power on ms-01a, then ms-01b, then msi.**

**2. On ms-01a, offline the faulty core immediately** (a cold boot brings it back; see the core-8 warranty case):

```sh
echo 0 > /sys/devices/system/cpu/cpu4/online; echo 0 > /sys/devices/system/cpu/cpu5/online
cat /sys/devices/system/cpu/online      # expect 0-3,6-19
```

**3. Check the cluster and the links**, on each node:

```sh
pvecm status | grep -E 'Quorate|Total votes'   # Quorate: Yes, 3 votes
corosync-cfgtool -s                             # link 0 and link 1 connected to both peers
ip -br addr | grep -E 'vmbr0|\.3[0-2]|nic'      # addresses back on mgmt, ring0, ring1
```

A link reporting `disconnected` for one peer points at a cable swapped between ports: fix it before continuing.

**4. Ceph**: wait for mon quorum and all OSDs, then release the flags:

```sh
ceph -s                                  # 3 mons in quorum, 8 osds: 8 up, 8 in
ceph osd unset nobackfill; ceph osd unset norecover; ceph osd unset norebalance; ceph osd unset noout
pvesm status                             # on EVERY node: cephfs and ceph-rbd active
```

If `pvesm status` shows cephfs unreachable on a node, `umount -f /mnt/pve/cephfs` and let pvestatd remount it (CLAUDE.md, the blocklisted-client trap). The `[FAILED] Failed to mount mnt-pve-cephfs.mount` lines on the console during boot are the known race and resolve themselves.

**5. Non-HA guests start themselves.** Every guest has `onboot: 1`, and `pve-guests` waits for the cephfs mountpoint (`proxmox_host/tasks/autostart.yml`). Confirm, and start anything missing by hand (`qm start` / `pct start`):

```sh
pvesh get /cluster/resources --type vm --output-format json | python3 -c 'import json,sys; [print(r["node"],r["vmid"],r["name"],r["status"]) for r in json.load(sys.stdin) if r["vmid"]!=900 and r["status"]!="running" and not r.get("hastate")]'
```

**6. Restore HA.** Terraform owns `state started`, so every one of the seven must go back:

```sh
for sid in vm:200 vm:201 vm:205 vm:220 ct:208 ct:212 ct:213; do ha-manager set $sid --state started; done
ha-manager status                        # all seven started, three LRMs active
```

**7. Services plane**, from the workstation once DNS answers again:

```sh
kubectl get nodes                        # talos-cp-a/b/c Ready
kubectl get pods -A | grep -vE 'Running|Completed'
make k8s-smoke                           # rbd / registry / nfs / infisical: each "smoke: PASS"
```

**8. Final checks**

- [ ] `ceph health` → `HEALTH_OK`.
- [ ] Uptime Kuma all green.
- [ ] `cat /sys/devices/system/cpu/online` on ms-01a still reads `0-3,6-19`.
- [ ] `make plan` in the fleet root shows no HA-state drift.
