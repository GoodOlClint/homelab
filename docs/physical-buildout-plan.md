# Homelab Physical Build-Out Plan — Network Closet

Planning notes for the physical rebuild (rack, cooling, power, UPS, cabling). Companion to the [IaC provisioning research](research-baremetal-iac-2026-07-10.md) and the [MS-01 cluster migration plan](ms01-cluster-iac-plan.md). This doc is **facilities only** — it does not change any migration architecture. pve stays the GPU/LLM passthrough node + 3rd Ceph node per [ADR-0001](decisions/0001-repoint-iac-to-a-3-node-pve-9-cluster-with-ceph.md); the Mac Studio is an additional (Apple Silicon / MLX) LLM host for GPU-vs-Apple comparison, not a replacement.

## Location: the front closet (single location)

Everything lives in the existing front closet, re-dual-purposed as coat + gear closet. It is already the house MDF — camera runs and house drops terminate here — so no house cabling moves. Consolidating all compute here keeps the Ceph 25G mesh and both corosync rings **internal to the closet** (short DACs/patch); only the network uplink leaves the closet.

Rejected alternatives (why the closet wins):
- **Nook over the TV** — sealed 21"-deep wall cavity, no airflow, noise above the TV. Only ever viable for the ~200W access layer; can't cool the full stack.
- **Master-bedroom portable rack** — works, but puts fan noise in a bedroom and needs the heat solved anyway. The closet contains noise better (door back on) and is already wired.

## Layout — wall cabinet high, heavy gear on the floor

Closet is **96"H × 43"D × 32"W**. Two zones joined by an in-wall cable chase: heavy/hot gear on the **floor**, light gear in a **wall cabinet** up high, coats in the band between.

**Floor zone (heavy, hot — backs to the wall):**
- Both **UPSes** stood vertical on the floor (CP1500 is a tower; OR2200 is rack/tower-convertible with feet; SLA batteries orientation-agnostic).
- **pve** tower + **Synology** DS1821+.
- All oriented **backs to the wall** (exhaust) / **fronts to the room** (intake), so the floor sideways-hood captures their heat (see Cooling). Floor-standing = zero cantilever, heaviest-lowest, trivially serviceable. pve is ~80% of the closet's heat and lives here.

**Wall cabinet (light gear, up high): Tripp Lite SRW15US** — 15U wall-mount, switch-depth (~20.5"), hinged/swing-out, 200 lb wall-rated (only ~45 lb loaded):

| U | Item |
|---|---|
| 1 | Patch panel |
| 2 | USW-Pro-24-PoE |
| 3 | Patch panel (expansion — size once port count known) |
| 4 | USW-Pro-Aggregation |
| 5-6 | MS-01 2U (thingsINrack) |
| 7-8 | Mac Studio + Worklab tray |

~8U used of 15U → airflow gap + growth. Switch-depth is enough (deepest item is the Pro-24 at ~15.7"); the UPSes are NOT in the cabinet (floored), so no need for the pricey UPS-depth cabinet.

**Coats:** hang in the middle band between the floor gear (tops out ~20") and the cabinet — jacket-length. The floor sideways-hood keeps pve's heat out of them (the design-around for heat-into-coats).

**Off-cabinet, wall-mounted:** Netgate 6100 + Flex-2.5G (light, wall-mount tabs).

**Cabling — in-wall chase, floor → cabinet, three separate runs:** data (fiber + copper network), power (UPS → PDU-up), and pve's heat duct. Keep power apart from copper data; keep the hot-air duct apart from both.

- **JetKVM:** at each headless host (pve, Worklab, optional Mac) — HDMI/USB-C short runs; patches to the PoE switch. Powered from host USB, not the UPS.
- **Mounting:** cabinet holds only ~45 lb, but wall-mount into a **plywood backer + studs** (added while the wall's open). Same open-wall window: run the 20A circuit, the three chases, and the intake.

## Cooling — two capture zones, both venting to the laundry room

**Recirculate into the house** (decided 2026-07, confirmed by a datacenter HVAC engineer): dump waste heat into the adjacent **laundry room** — house AC removes it in summer (~270W electrical at COP 3), free heat in winter. Beats exhausting outside: no exterior penetration, no makeup air, no backdraft, no economizer logic, no CAZ/backdraft check — all moot when no air leaves the house. (The floor combustion appliances are in the garage anyway, outside the house pressure envelope.)

Two heat sources → two captures, both ducted to the laundry room. **Fans do the moving; every device keeps its intake open to the room → no backpressure, nothing sealed to a device fan.**

**Zone 1 — floor "sideways vent hood" (the big one; pve ≈ 80% of the heat).** Floor gear backs face the wall; a low horizontal capture hood spans their backs → **wall grille → duct → fan → laundry room**.
- **Loose hood, open fronts** — gear pulls cool room air in the front, dumps hot out the back into the hood.
- **Shroud pve's rear** to the grille (foam-board / sheet-metal collar) so its exhaust goes into the duct, not up into the coats. Cut clearance for pve's rear cables (brush grommet / notch).
- **The duct fan is the mover** — pve's low-pressure case fans won't push through ductwork on their own.
- Synology (~55W) + UPSes are low-heat; the hood grabs their warmth incidentally — don't engineer for them.

**Zone 2 — wall cabinet top exhaust.** The enclosed SRW15US *is* the containment: light gear exhausts inside it → **CLOUDLINE fan out the top → duct → laundry room**, intake low on the cabinet. Use a **flexible duct coupling** so the cabinet can still swing out on its hinge without disconnecting.

(Supersedes the earlier closet-as-hood / top-canopy / baffle-and-rear-chase model — that assumed one floor-standing rack. With heavy gear floored and light gear in a wall cabinet, it's two separate captures.)

- **Fans:** cabinet gets the **AC Infinity CLOUDLINE T8** (8", ~400+ CFM), thermostatic (low baseline + ramp, probe at the hot zone), continuous-duty. The floor duct needs its own inline fan (size to pve's load; a T6 is plenty for one box). T8 for the cabinet not T6 — the whole-stack ~1236W peak needs ~260 CFM, which would pin a T6 near full tilt (loud) next to living space.
- **Critical:** the laundry-room air must reach the house AC return — don't dead-end it in a closed room or the hotspot just relocates there. Undercut/louver the laundry door, leave it open, or confirm a return/supply is present.
- Loop: house air → closet (door-louver intake) → gear → laundry room → back to house AC.

### Heat / power budget — MEASURED 2026-07 (Kill-A-Watt, network and compute metered separately)

| State | Draw | How |
|---|---|---|
| Network (switches, pfSense, PoE cams + AP) | **~250W** | derived (800W total − 550W compute) |
| Compute idle — BOINC GPU **not** crunching | **~550W** | measured |
| Compute idle — BOINC GPU crunching | **~780W** | measured (RTX 5000 at full 231W) |
| **Compute PEAK — everything maxed** | **986W** | measured: 3 hosts all-core CPU + RTX 5000 at 231W + Mac Studio inference + Synology 8 drives (Time Machine) + Plex |
| **Whole-stack peak** | **~1236W** | 986W compute + 250W network |

Nothing is unmeasured — the GPU hit its full 231W TDP during the test, so 986W is a genuine worst case. Earlier projections (~1230W compute / ~1500W stack) **overestimated by ~25%**.

Sizing: ~170 CFM holds 800W at ΔT≈15°F; ~260 CFM covers the 1236W peak. **CLOUDLINE T8** — a T6 (350 CFM max) would run near full tilt (loud) at peak; the T8 moves the same air at lower RPM, which matters next to living space.

### ⚠️ BOINC silently sets the baseline

BOINC (in the docker VM) runs PrimeGrid GPU work units and pegs the RTX 5000 at its full **231W whenever work is available** — unprompted. That means "idle" is ~550W *or* ~780W depending on whether it has a task, plus 231W of continuous heat and an audible blower. Decide deliberately: keep GPU crunching (design for ~780W typical), restrict BOINC to CPU-only (GPU idles at 17W), or schedule it to off-hours.

### Noise — MEASURED, and it inverted the assumption

**pve is quiet even at full GPU load** (231W, 81°C, blower at 60%). **The Synology's 8 drives are the loudest thing in the closet.** This supersedes the earlier (wrong) assumption that pve's blower Quadro was the node that "cannot be made quiet" — that assumption drove the abandoned garage-exile plan. The real noise mitigation target is the **Synology**: keep the closet door closed (it contains it), enable drive spin-down when idle, and audition it from the living room with the door shut.

## Power

- **One dedicated 20A circuit, two outlets** (electrician, while the wall is open):
  - **Floor outlet** → the two UPSes (stood **vertical on the floor** — CP1500 tower / OR2200 rack-tower-convertible; floor-standing = zero cantilever, heaviest-lowest).
  - **Top outlet** (rack height) → future-owner escape hatch (run the rack gear on wall power with no UPS layer) + handy now for the CLOUDLINE fan.
  - One circuit is plenty: measured peak ~1236W « 1920W (20A) limit; continuous ~800-900W (~45%). Don't need two circuits. A 15A (1440W limit) would be exceeded by the ~1500W projected peak — hence 20A.
- **Power path (UPSes floored):** floor UPS → one cord up → a power strip / 1U PDU in the rack → rack gear. One PDU per UPS keeps the network/compute split clean. pve + Synology (also floored) plug straight into the compute UPS. Use a PDU with a long enough (~6 ft) input cord or proper 14/12 AWG — no flimsy daisy-chained strips up the wall.
- **~800W is continuous heat** into the laundry room: free heat in winter, ~270W electrical of AC work in summer (COP 3).

## UPS — split, SLA, right-sized

Two units, two goals (see [research doc](research-baremetal-iac-2026-07-10.md) for full reasoning). Both **CyberPower SLA, stood vertical on the floor** — not in the wall cabinet. Each feeds a PDU up to the cabinet (see Power). All-CyberPower → **one NUT driver** (`usbhid-ups`).

**Lithium rejected on cost.** LiFePO4 UPSes run ~3× the SLA price — not worth ~$3,900 over a 10-yr TCO to avoid ~$400 of battery swaps. The OR500's real failures were **undersizing + self-test config**, not SLA chemistry — both fixed cheaply below. The active-cooled closet gives SLA its full 4-6 yr life (heat was the only strong lithium argument, and the CLOUDLINE removes it).

| Role | Load | Pick | Goal |
|---|---|---|---|
| **Network** | ~250W (~25%) | **CyberPower CP1500PFCLCD** (1500VA/1000W, mini-tower) — **$239** | Ride-through for internet/cameras/AP |
| **Compute** | ~575W typ (~37%), **986W peak (~64%)** | **CyberPower OR2200PFCRT2U** (2000VA/1540W, rack/tower, **8 outlets**: 2× 5-20R + 6× 5-15R; ~15 min half-load) | Graceful shutdown of Ceph nodes + NAS |

- **Compute needs the 1920W unit.** Cheap CyberPower CP2000PFCRM2U is only 1200W — the deliberate GPU-comparison peak (pve + Mac both maxing, ~1300-1500W) trips it. Don't cheap out on this slot.
- **~$1,050 for the pair** (verify pricing). Battery packs ~$60-120, user-swappable, every ~4-6 yr in the cooled closet.
- **The actual OR500 fix (chemistry-independent):** keep load ≤40% (you're at 25%/37%), **reschedule/disable the periodic self-test** (this was the monthly-outage cause), USB to the NUT-owner host (`usbhid-ups`). Both CyberPower → one driver.

## Networking

- All compute co-located → **25G switchless mesh + corosync rings stay internal** to the closet (hardware in hand per the migration plan).
- Cameras (VLAN 122), APs, and house drops already land on the closet's USW-Pro-24-PoE — no change.
- Uplink: the closet's aggregation/edge to the rest of the network is the only inter-area link. (No fiber-to-bedroom, no nook — those options are dropped.)

## Repo hook: NUT graceful shutdown

The compute UPS is only useful if the nodes obey it. Architecture (USB + NUT, **no SNMP/network card** — saves ~$300-500 and isn't needed):

- **NUT master = pfSense (Netgate 6100).** USB from the **compute UPS** → Netgate. pfSense is always-on (it's the firewall), in the closet (USB reach), has a mature NUT package, and is **cross-powered from the *network* UPS** — so it survives while the compute UPS drains and can signal the nodes to shut down. It must NOT be powered by the UPS it's monitoring (chicken-and-egg), and can't be a compute node (those are what shut down).
- **NUT clients:** pve + crete + crete2 (new `nut_client` Ansible role — `upsmon` secondary pointed at pfSense) and the Synology (built-in "remote NUT server" mode → pfSense). They shut down on low battery.
- **HA Green:** NUT *client* for monitoring/alerts only (Home Assistant NUT integration → battery %, load, runtime, automations). Not the master — HA OS updates/reboots make it too flaky to coordinate Ceph shutdown.
- **Network UPS:** runtime only, no orchestrated shutdown — switches/pfSense/APs boot clean from a hard power-off. Optionally monitored for alerts.

Only the `nut_client` role (pve/crete/crete2) is repo work; pfSense NUT (ADR-0005 defers pfSense IaC) and Synology are configured in their own UIs.

### Power recovery (coming back after an outage)

Primary mechanism is **BIOS "Restore on AC Power Loss" → Power On** on every host, *not* WoL. The catch: if NUT gracefully shuts a node down but mains returns **before the UPS drains**, the PSU never saw an AC loss→restore cycle and the node stays off. Fix by completing the NUT shutdown properly — the primary (pfSense) commands the compute UPS to **cut its output** (UPS set to power back on when line returns), forcing the cycle so BIOS auto-boot fires. Verify the OR2200 "restart when power restored" behavior.

Per-host: pve/crete/crete2/Worklab → BIOS auto-power-on; Synology → DSM "restart after power failure"; Mac Studio → `pmset autorestart 1`; switches/Netgate → auto-boot inherently.

Backstops (manual/orchestrated wake): WoL enabled on the node NICs; **JetKVM ATX board powers pve on**, **AMT powers the MS-01s on** — the break-glass if auto-recovery wedges.

Software layer self-heals: Proxmox guests set "Start at boot", Ceph reforms quorum as nodes appear, HA resources restart. Network gear (fast) is up before the nodes finish booting. Optional: set a minimum-recharge-before-restore threshold so a second quick outage doesn't hit a flat battery; stagger the two UPSes' restore delays if inrush trips anything.

### pfSense upgrades and NUT

**pfSense upgrades don't shut the cluster down.** `upsmon` secondaries shut down only on `OB`+`LB` (a real power event) or an explicit FSD from the primary — never on loss-of-comms with the master. A pfSense reboot just makes clients log "stale/unavailable" until it returns. The only (tiny) exposure is the inverse: a mains outage landing *during* the ~5-min upgrade window means no FSD is sent — mitigated by the ~20 min compute-UPS runtime (pfSense re-arms well before critical) and not upgrading during flaky power. Eliminating even that would need the SNMP card (each node polls the UPS directly) — not worth $300-500 for the exposure.

## Rack + hardware shopping list

- **Rack — Tripp Lite SRW15US:** 15U wall-mount, switch-depth (~20.5"), hinged/swing-out, 200 lb wall-rated. Holds **light gear only** (~45 lb): patch ×2, both switches, MS-01 2U, Mac/Worklab tray (~8U of 15). Check B2B (Provantage/CDW/Newegg) — often below Amazon's third-party price. Mount into a **plywood backer + studs** (added while the wall's open).
- **UPSes — 2× CyberPower SLA, floor-standing:** **CP1500PFCLCD** (network, $239, tower) + **OR2200PFCRT2U** (compute, 2000VA/1540W, rack/tower, 8 std outlets). Not lithium — SLA in a cooled closet, ~3× cheaper (see UPS section). Verify the OR2200 "restart when power restored."
- **PDUs:** one power strip / 1U PDU per UPS, floor UPS → cord up to the cabinet. Basic/unmetered (NUT gives the totals). Skip the WebcardLXE (~$200) unless you want per-bank load-shed later.
- **Cooling:** 2× inline fans — **CLOUDLINE T8** (cabinet top) + a smaller inline (T6-class) for the floor pve duct; wall grille + foam/sheet-metal shroud for pve's rear; **flexible duct coupling** at the cabinet (for the swing); short ducts into the laundry-room top; cabinet low-intake + door louver.
- **MS-01 mount:** [thingsINrack 2U dual-mount](https://www.amazon.com/thingsINrack-Mount-MiniSforum-19inch-Dual-Mount/dp/B0FC2FYSRC) (both nodes, 2U). Power bricks velcro'd to the tray.
- **JetKVM:** host-powered (not UPS), one per headless non-MS-01 host (pve, Worklab, optional Mac), mounted at the host.
- **Electrical:** one dedicated **20A circuit, two outlets** (floor for UPSes, top for the future no-UPS option / fan). While the wall's open: 20A circuit + three cable chases (data / power / heat-duct) + intake.

## Open items / to verify

1. **BOINC decision (the one genuinely open item)** — it pegs the GPU at 231W whenever it has work, setting "idle" at ~780W not ~550W, +231W heat, +audible blower. Keep GPU-crunching / restrict to CPU-only / schedule to off-hours. Sets real steady-state draw + closet heat.
2. Confirm the **laundry-room air path back to the house AC return** (undercut/louver the door, or a return present) — else the hotspot just relocates there.
3. Verify SRW15US **swing clearance** in the closet + the flexible duct coupling accommodates the swing.
4. ~~Eave vent~~ moot (recirculate to laundry). ~~Closet dims~~ measured (96×43×32). ~~One vs two circuits~~ → one 20A, two outlets. ~~pve noise~~ measured quiet (Synology is the noise source). ~~T6 vs T8~~ → T8 cabinet + smaller floor fan.
