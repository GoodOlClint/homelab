# Homelab Physical Build-Out Plan — Network Closet

Planning notes for the physical rebuild (rack, cooling, power, UPS, cabling). Companion to the [IaC provisioning research](research-baremetal-iac-2026-07-10.md) and the [MS-01 cluster migration plan](ms01-cluster-iac-plan.md). This doc is **facilities only** — it does not change any migration architecture. pve stays the GPU/LLM passthrough node + 3rd Ceph node per [ADR-0001](decisions/0001-repoint-iac-to-a-3-node-pve-9-cluster-with-ceph.md); the Mac Studio is an additional (Apple Silicon / MLX) LLM host for GPU-vs-Apple comparison, not a replacement.

## Location: the front closet (single location)

Everything lives in the existing front closet, re-dual-purposed as coat + gear closet. It is already the house MDF — camera runs and house drops terminate here — so no house cabling moves. Consolidating all compute here keeps the Ceph 25G mesh and both corosync rings **internal to the closet** (short DACs/patch); only the network uplink leaves the closet.

Rejected alternatives (why the closet wins):
- **Nook over the TV** — sealed 21"-deep wall cavity, no airflow, noise above the TV. Only ever viable for the ~200W access layer; can't cool the full stack.
- **Master-bedroom portable rack** — works, but puts fan noise in a bedroom and needs the heat solved anyway. The closet contains noise better (door back on) and is already wired.

## Layout — single stack: shelf under the rack, one airflow column (REVISED 2026-08-07)

**Supersedes the split-zone layout below.** Closet is **96"H × 43"D × 32"W**. The floor-zone/wall-cabinet split is collapsing back to the original single-stack design: heavy/hot gear on a **shelf directly under** the SRW15US, everything in one vertical column instead of two zones joined by a cross-closet chase. Simplifies cabling (all three runs terminate at/near the same spot instead of floor-to-cabinet across the room) and cooling (see Cooling, single capture instead of two).

**Shelf (floor, under the cabinet):** **pve** tower + **Synology** DS1821+ + **Worklab** (moved here from the rack — was sharing RU6-8 with the Mac Studio in an earlier draft of the elevation; simpler to shelf it alongside pve/Synology than fit it into the Mac Studio rack mount). pve is still ~80% of the closet's heat; sits at the bottom of the column so the rack's bottom-intake fans (see Cooling) pull its exhaust up through the stack.

**Closet clearance (MEASURED 2026-08-07): only 4" on either side of the rack.** This drives several downstream constraints:
- **pve can't stand upright beside the rack** — too wide for the 4" gap. It goes **on its side, under the rack, next to the Synology.** **Verified (2026-08-07):** closet is 32" wide; tower height (18", becomes the horizontal footprint lying down) + Synology width (13") = 31" against the 32" shelf width — 1" spare. **Worklab stacks on top of the Synology** rather than adding to the 32" width budget — its height is shorter than pve's on-side height, so it doesn't exceed the tallest point already on the shelf. DS1821+ venting is rear (2×120mm fans) + side mesh + bottom, no top-panel cooling path, so stacking doesn't block anything — just keep the NAS's own feet clear of the shelf surface for its bottom vents, same as it'd need standing alone. **No GPU anti-sag concern with this rotation** — rolling the case so the motherboard lies flat swings the GPU (RTX 5000) from a horizontal cantilever (perpendicular to gravity — the classic sag mechanism) to a vertical one (parallel to gravity, no bending lever arm). Just orient it so the card points up, not down, when set on the shelf — up is self-seating under gravity, down slowly works the card away from the slot over years of vibration.
- **Verify pve's exhaust still feeds the rack's intake path in the sideways orientation** — rotating the case doesn't rotate the fan layout with it; confirm the rear/GPU exhaust still vents toward the bottom-intake path (see Cooling) rather than sideways into the 4" gap.
- **The SRW15US's swing-out hinge is effectively unusable — see Open Items.** 4" of side clearance limits the opening to ~18°, nowhere near enough for rear access. This changes what "verify swing clearance" (an open item below) actually means: it's resolved, and the answer is "doesn't work," which cascades into the cable-management plan below.

**SRW15US wall cabinet (above the shelf), 15U, switch-depth (~20.5"), hinged/swing-out, 200 lb wall-rated:** now also holds **both UPSes** (previously floor-standing — see UPS section). Full elevation (RESOLVED 2026-08-07 — fills all 15U, zero spare beyond the one deliberate gap):

| RU | Item |
|---|---|
| 1 | **Space + rack-mounted JetKVMs (PoE)** — kept open at the bottom intake so the rack's fans (see Cooling) pull mostly into open air rather than across the UPS chassis; the JetKVM tray (see JetKVM note below) is small enough to leave most of the RU's cross-section clear, a minor airflow tradeoff against a real cabling/power win. RU1 starts above the cabinet's actual floor, so the [4POSTRAILKITWM support rail](#ups--split-sla-right-sized-rack-mounted-revised-2026-08-07) is required for the OR2200 regardless — no floor-support tradeoff either way. Still gives cable exiting downward out of the enclosure somewhere to go. |
| 2-3 | CyberPower OR2200PFCRT2U (compute UPS, 2U, 57.2 lb — support rail required, see UPS section) |
| 4-5 | CyberPower CP1500PFCRM2U (network UPS, 2U rack-mount — replaces the tower CP1500PFCLCD) |
| 6-8 | Mac Studio (3U, MyElectronics **Empower Station** — dual-capable, blank plate in the 2nd slot for now). **Future-proofed 2026-08-07:** a 2nd Mac Studio (M5 Ultra) is planned for fall 2026 alongside the M4 Max — this mount takes it without any rework, same 3U footprint either way. Run 10GbE to the 2nd slot now while the wall's open, so it's wire-ready when the second unit arrives instead of needing new cable pulled through an already-hung, zero-rear-access cabinet. |
| 9-10 | MS-01 2U (thingsINrack) |
| 11 | DAC/fiber passthrough |
| 12 | USW-Pro-Aggregation (SFP switch) |
| 13 | 24-port patch panel |
| 14 | 48-port PoE switch w/ built-in 2.5G — **replaces the USW-Pro-24-PoE** (confirmed upgrade, not a placeholder) and **absorbs corosync VLANs 31/32** ([ADR 0019](decisions/0019-corosync-moves-onto-the-shared-48-port-access-switch-trading-physical-isolation-for-consolidation.md), superseding [ADR 0008](decisions/0008-corosync-on-a-dedicated-switch-local-vlan-vlan-30-stays-infrastructure.md)'s dedicated-switch model) — the standalone Flex-2.5G is dropped |
| 15 | 24-port patch panel (expansion) |

**Resolved:** the earlier "recount before ordering" open item is closed — 15/15 U confirmed. **New tradeoff to note:** the original plan assumed ~8U/15U with headroom for growth; this elevation uses the entire cabinet, so there's no slack left for anything added later — the two 24-port patch panels and the 48-port switch's own headroom are the deliberate future-proofing instead. The **200 lb wall rating vs. loaded weight** still needs on-site verification now that two UPSes (SLA batteries are heavy) are in the cabinet instead of floored — confirm the plywood-backer mount (below) spans enough to carry it.

**Coats:** the original band assumed vertical separation between a floor zone and a high wall cabinet. With the shelf now directly under the cabinet, re-check where coats actually hang in the 32"W closet — may need to move to an adjacent section rather than the same vertical run as the stack.

**Off-cabinet, wall-mounted:** Netgate 6100 (Flex-2.5G dropped — see RU14, [ADR 0019](decisions/0019-corosync-moves-onto-the-shared-48-port-access-switch-trading-physical-isolation-for-consolidation.md)).

**Cabling — in-wall chase, three separate runs still apply** (data, power, heat-duct — keep apart from each other) but runs are now short since shelf and cabinet are co-located rather than floor-to-cabinet across the closet.

- **JetKVM (REVISED 2026-08-07 — rack-mounted, PoE upgrade deferred):** consolidated into RU1 instead of one-per-host, mounted in the [8-unit tool-less 1U rack mount](https://www.etsy.com/listing/1859353396/jetkvm-1u-rackmount-for-8-x-jetkvm) (PETG, blank inserts for unpopulated slots, tool-less clips). **PoE variant is out of stock** — starting with regular USB-powered JetKVMs, upgrading to PoE later is a tool-less clip swap since the mount itself is power-agnostic (no bundled PoE hardware to replace). **Interim power:** a small powered USB hub mounted at/near RU1 (one power feed in, short USB-C runs to each JetKVM) rather than running a second cable per unit back to each host — goes away once PoE units replace them. HDMI/USB-C video-capture runs from RU1 down to the shelf (pve, Worklab) are short in absolute terms — the whole 15U cabinet is only ~26" tall. Route them down the side channel with the rest of the vertical cable management (see Cable management below). **Once upgraded to PoE:** draws through whichever PoE switch it's patched to, inheriting UPS protection transitively (both UPSes now feed rack gear) instead of depending on host power state — stays reachable during a graceful-shutdown sequence even after the host it's watching has powered off.
- **Mounting:** wall-mount into a **plywood backer + studs** (added while the wall's open) — re-verify it's sized for the added UPS weight, not just the original ~45 lb light-gear estimate.

### Cable management inside the cabinet — plan before hanging (REVISED 2026-08-07 — swing access confirmed dead)

**Measured 2026-08-07: only 4" clearance on either side of the rack, and the swing-out hinge opens ~18° at best — not usable for rear access.** This is a harder constraint than "plan ahead as good practice": once hung, **there is no rear access path at all.** Any future change means pulling the affected item back out of the rack (front access only), not swinging the frame open to reach behind it. Everything below is now a pre-hang gate, not a nice-to-have.

- **Patch panel termination must be 100% complete and tested before hanging — no do-overs.** Patch panels punch down from the rear. With swing access dead, a mis-terminated or forgotten port isn't a quick fix after the cabinet's on the wall — it means pulling the whole panel back out. Verify every port with a cable tester before it goes up, not after.
- **Label both ends of every structured cable before hanging.** Wall-drop ID ↔ patch panel port (RU13/RU15), while everything is easy to reach — this was already good practice, and is now the only real diagnostic tool you'll have once it's hung and unreachable from behind.
- **Route the wall-chase entry toward whichever knockout is physically closer to RU13-15.** The patch panels sit near the top of the stack; if the chase's data run enters at the top knockout, structured cable never has to cross the full packed height of the cabinet. If it has to enter at the bottom (co-located with the shelf per the cabling note above), plan a dedicated vertical path up one side rather than draping across populated gear.
- **No spare U means side-mounted management, not a horizontal bar.** Use D-rings or hook-and-loop tie points along the frame's vertical edges to carry the vertical run, rather than looking for a U to dedicate to it. Most patch panels include a small integrated rear cable bar for strain relief at the panel itself — use that as the anchor point, then route down the side channel.
- **Short patch cables, not generic lengths.** RU13→RU14 and RU14→RU15 are immediately adjacent — 0.5–1ft patches are enough. In a fully packed cabinet, standard 3-7ft cables just create slack you have nowhere to store.
- **Keep UPS power cords/PDU runs on the opposite side from data cabling** — same separation principle as the wall chase's three-run rule, applied inside the cabinet: AC and copper data don't share a bundle.
- **Leave a service loop at the chase entry point regardless of the dead hinge** — even without swing, thermal expansion/contraction and the occasional bump are enough reason not to dress a cable drum-tight right at the entry point.
- **DAC bend radius at RU11-12:** DACs are stiffer than patch cords with a larger minimum bend radius — confirm the front door clears with them routed, or route them along the side away from the door swing rather than straight across the face.
- **Build bottom-up while it's on the ground:** UPSes (RU1-5) are the heaviest items — mount those first while lifting is easiest, then work upward. Do the patch panel labeling/testing and cable dressing last, right before hanging — it's the part with zero margin for error once the cabinet's up.
- **The front-only toolless hardware (RackStuds, PatchBox /dev_mount, 4POSTRAILKITWM) earns its keep here.** Every one of them installs and services from the front — which is now the *only* access path, not a convenience.

<details>
<summary>Superseded: original split-zone layout (floor zone + wall cabinet, two UPSes floored)</summary>

Two zones joined by an in-wall cable chase: heavy/hot gear on the **floor**, light gear in a **wall cabinet** up high, coats in the band between.

**Floor zone (heavy, hot — backs to the wall):**
- Both **UPSes** stood vertical on the floor (CP1500 is a tower; OR2200 is rack/tower-convertible with feet; SLA batteries orientation-agnostic).
- **pve** tower + **Synology** DS1821+.
- All oriented **backs to the wall** (exhaust) / **fronts to the room** (intake), so the floor sideways-hood captures their heat. Floor-standing = zero cantilever, heaviest-lowest, trivially serviceable.

~8U used of 15U → airflow gap + growth. Switch-depth is enough (deepest item is the Pro-24 at ~15.7"); the UPSes were NOT in the cabinet (floored), so no need for the pricey UPS-depth cabinet.

**Cabling — in-wall chase, floor → cabinet:** data (fiber + copper network), power (UPS → PDU-up), and pve's heat duct.

</details>

## Cooling — single capture, one external fan (REVISED 2026-08-07)

**Supersedes the two-zone-capture model below.** Collapsing to one physical stack (see Layout) means one air path instead of two: **house air → closet intake → up through the shelf+rack column → single external fan → laundry room → house AC return**. Same recirculate-into-house rationale as before (dump waste heat into the adjacent laundry room — house AC removes it in summer at COP 3, free heat in winter; no exterior penetration, no makeup air, no backdraft logic since no air leaves the house).

- **Rack self-ventilation (the chimney):** fans mounted in/on the SRW15US draw room air in at the **bottom** — across the shelf gear (pve + Synology, ~80% of the heat) — and exhaust it out the **top** of the cabinet. Specific fan model/CFM/count not yet chosen — size to the same ~260 CFM peak target below, and keep thermostatic control if the chosen product supports it (the superseded CLOUDLINE T8 did). **Open item.**
- **External fan — [KOVIET 8" Room-to-Room Ventilation Fan](https://www.amazon.com/dp/B0FBWZF39Z), 320 CFM:** replaces the CLOUDLINE T8 + T6 pair below with a single unit, cut through the closet wall straight to the laundry room. 10-speed, temperature-controlled, reversible. 320 CFM clears the ~260 CFM sizing target for the 1236W whole-stack peak (see budget below) with headroom to spare — one fan covers what two were sized for.
  - **Check before cutting the wall:** KOVIET's spec sheet lists a 3.5"–6.2" fit range for wall thickness — confirm the closet/laundry shared wall falls in that range first.
  - Reversible + temp-controlled also means it can push air the other direction if ever useful (e.g. pre-cooling from the laundry side) — a capability the old two-fan setup didn't have.
- **Critical (unchanged):** the laundry-room air must still reach the house AC return — don't dead-end it in a closed room or the hotspot just relocates there. Undercut/louver the laundry door, leave it open, or confirm a return/supply is present.
- Loop: house air → closet (door-louver intake) → shelf+rack column → laundry room → back to house AC.

<details>
<summary>Superseded: two-capture-zone model (floor sideways-hood + wall-cabinet top exhaust, CLOUDLINE T8 + T6)</summary>

Two heat sources → two captures, both ducted to the laundry room, assuming heavy gear stayed physically separate from the wall cabinet across the closet floor.

**Zone 1 — floor "sideways vent hood."** Floor gear backs face the wall; a low horizontal capture hood spans their backs → wall grille → duct → fan → laundry room. Shroud pve's rear to the grille so its exhaust goes into the duct, not up into the coats.

**Zone 2 — wall cabinet top exhaust.** The enclosed SRW15US *is* the containment: light gear exhausts inside it → CLOUDLINE fan out the top → duct → laundry room, intake low on the cabinet, flexible duct coupling for the swing-out hinge.

**Fans:** cabinet got the AC Infinity CLOUDLINE T8 (8", ~400+ CFM, thermostatic, continuous-duty); the floor duct got its own smaller inline fan (T6-class, sized to pve alone).

</details>

### Heat / power budget — MEASURED 2026-07 (Kill-A-Watt, network and compute metered separately)

| State | Draw | How |
|---|---|---|
| Network (switches, pfSense, PoE cams + AP) | **~250W** | derived (800W total − 550W compute) |
| Compute idle — BOINC GPU **not** crunching | **~550W** | measured |
| Compute idle — BOINC GPU crunching | **~780W** | measured (RTX 5000 at full 231W) |
| **Compute PEAK — everything maxed** | **986W** | measured: 3 hosts all-core CPU + RTX 5000 at 231W + Mac Studio inference + Synology 8 drives (Time Machine) + Plex |
| **Whole-stack peak** | **~1236W** | 986W compute + 250W network |

Nothing is unmeasured — the GPU hit its full 231W TDP during the test, so 986W is a genuine worst case. Earlier projections (~1230W compute / ~1500W stack) **overestimated by ~25%**.

Sizing: ~170 CFM holds 800W at ΔT≈15°F; ~260 CFM covers the 1236W peak. The **KOVIET 320 CFM** external fan clears that target on its own with margin — verified against the same math the superseded CLOUDLINE T8+T6 pair was sized to.

### ⚠️ BOINC silently sets the baseline

BOINC (in the docker VM) runs PrimeGrid GPU work units and pegs the RTX 5000 at its full **231W whenever work is available** — unprompted. That means "idle" is ~550W *or* ~780W depending on whether it has a task, plus 231W of continuous heat and an audible blower. Decide deliberately: keep GPU crunching (design for ~780W typical), restrict BOINC to CPU-only (GPU idles at 17W), or schedule it to off-hours.

### Noise — MEASURED, and it inverted the assumption

**pve is quiet even at full GPU load** (231W, 81°C, blower at 60%). **The Synology's 8 drives are the loudest thing in the closet.** This supersedes the earlier (wrong) assumption that pve's blower Quadro was the node that "cannot be made quiet" — that assumption drove the abandoned garage-exile plan. The real noise mitigation target is the **Synology**: keep the closet door closed (it contains it), enable drive spin-down when idle, and audition it from the living room with the door shut.

## Power

- **One dedicated 20A circuit, two outlets** (electrician, while the wall is open):
  - **Floor outlet:** originally sized for the two floor-standing UPSes. **Open item now that both UPSes rack-mount** (see UPS section) — nothing lives on the floor except the shelf gear (pve/Synology), which now plugs *up* into the rack UPSes instead of a UPS plugging *up* into the rack. Confirm with the electrician whether the floor outlet is still worth running, or whether both outlets should land at rack height.
  - **Top outlet** (rack height) → future-owner escape hatch (run the rack gear on wall power with no UPS layer) + powers the KOVIET external fan.
  - One circuit is plenty: measured peak ~1236W « 1920W (20A) limit; continuous ~800-900W (~45%). Don't need two circuits. A 15A (1440W limit) would be exceeded by the ~1500W projected peak — hence 20A.
- **Power path (UPSes rack-mounted):** both UPSes now live in the SRW15US and feed rack gear directly from their own onboard outlets (OR2200: 8 outlets; CP1500PFCRM2U: check its outlet count) — no floor-to-rack PDU cord needed for either. **Inverted from before:** pve + Synology on the shelf below now run a cord *up* to the rack UPSes instead of plugging in at floor level. A separate PDU may no longer be needed at all — re-check once the UPS outlet counts are confirmed against actual device count.
- **~800W is continuous heat** into the laundry room: free heat in winter, ~270W electrical of AC work in summer (COP 3).

## UPS — split, SLA, right-sized, rack-mounted (REVISED 2026-08-07)

Two units, two goals (see [research doc](research-baremetal-iac-2026-07-10.md) for full reasoning). **Both now rack-mount in the SRW15US** — supersedes the earlier floor-standing placement. All-CyberPower → **one NUT driver** (`usbhid-ups`), unaffected by the placement change.

**Lithium rejected on cost.** LiFePO4 UPSes run ~3× the SLA price — not worth ~$3,900 over a 10-yr TCO to avoid ~$400 of battery swaps. The OR500's real failures were **undersizing + self-test config**, not SLA chemistry — both fixed cheaply below. The active-cooled closet (now via the KOVIET external fan + rack self-ventilation) gives SLA its full 4-6 yr life.

| Role | Load | Pick | Goal |
|---|---|---|---|
| **Network** | ~250W (~25%) | **CyberPower CP1500PFCRM2U** (1500VA/1000W, 2U rack-mount, PFC sinewave — replaces the tower CP1500PFCLCD) | Ride-through for internet/cameras/AP |
| **Compute** | ~575W typ (~37%), **986W peak (~64%)** | **CyberPower OR2200PFCRT2U** (2000VA/1540W, rack/tower, **8 outlets**: 2× 5-20R + 6× 5-15R; ~15 min half-load) | Graceful shutdown of Ceph nodes + NAS |

- **Compute needs the 1920W unit.** Cheap CyberPower CP2000PFCRM2U is only 1200W — the deliberate GPU-comparison peak (pve + Mac both maxing, ~1300-1500W) trips it. Don't cheap out on this slot.
- Return the CP1500PFCLCD tower for the CP1500PFCRM2U rack unit — verify current pricing delta before ordering.
- **The actual OR500 fix (chemistry-independent):** keep load ≤40% (you're at 25%/37%), **reschedule/disable the periodic self-test** (this was the monthly-outage cause), USB to the NUT-owner host (`usbhid-ups`). Both CyberPower → one driver.
- **Open item:** re-verify the SRW15US's 200 lb wall rating against both UPSes' loaded weight (SLA batteries are heavy) plus the existing light gear — see Layout section.

## Networking

- All compute co-located → **25G switchless mesh + corosync rings stay internal** to the closet (hardware in hand per the migration plan).
- Cameras (VLAN 122), APs, and house drops already land on the closet's USW-Pro-24-PoE — no change.
- Uplink: the closet's aggregation/edge to the rest of the network is the only inter-area link. (No fiber-to-bedroom, no nook — those options are dropped.)

## Repo hook: NUT graceful shutdown

The compute UPS is only useful if the nodes obey it. Architecture (USB + NUT, **no SNMP/network card** — saves ~$300-500 and isn't needed):

- **NUT server = pfSense (Netgate 6100).** **Both UPSes** on its USB (the package GUI carries one; the second rides the Advanced `ups.conf` box). pfSense is always-on (it's the firewall), in the closet (USB reach), has a mature NUT package, and is **cross-powered from the *network* UPS** — its own `upsmon` monitors the *network* UPS as primary, so it only shuts itself down when its own feed goes critical and survives while the compute UPS drains. Compute-side secondaries act on the compute UPS's `OB LB` status directly (no FSD from pfSense needed).
- **NUT clients:** pve + crete + crete2 **+ worklab** (`nut_client` Ansible role — `upsmon` secondary, `make nut-clients`), the Synology (built-in "remote NUT server" mode → pfSense; its `ups`/`monuser`/`secret` hardcoding pins those names on the server forever), and the **Mac Studio** (Homebrew nut + launchd). They shut down on low battery.
- **HA Green:** NUT *client* for monitoring/alerts only (Home Assistant NUT integration → both UPSes: battery %, load, runtime, automations). Not the coordinator — HA OS updates/reboots make it too flaky to coordinate Ceph shutdown.
- **Network UPS:** runtime only, no orchestrated shutdown — switches/pfSense/APs boot clean from a hard power-off. Powers pfSense + HA Green, and the cabinet fans move onto it so cooling runs through a shutdown sequence.

Only the `nut_client` role is repo work; pfSense NUT (ADR-0005 defers pfSense IaC), Synology, and the Mac Studio are configured out-of-band — as-built config captured in [pfsense-nut.md](pfsense-nut.md).

**As-built status (2026-08-13):** pfSense serving both UPSes; Synology, HA Green, pve, worklab, and Mac Studio clients all connected and verified. Remaining: crete/crete2 inherit via the `proxmox` inventory group at cutover; pull-the-plug rehearsal once compute workloads are configured; compute-UPS output-cut for the BIOS auto-restart trick (below) needs an `upssched`/`upscmd load.off.delay` design now that no primary shuts that UPS down.

### Power recovery (coming back after an outage)

Primary mechanism is **BIOS "Restore on AC Power Loss" → Power On** on every host, *not* WoL. The catch: if NUT gracefully shuts a node down but mains returns **before the UPS drains**, the PSU never saw an AC loss→restore cycle and the node stays off. Fix by completing the NUT shutdown properly — the primary (pfSense) commands the compute UPS to **cut its output** (UPS set to power back on when line returns), forcing the cycle so BIOS auto-boot fires. Verify the OR2200 "restart when power restored" behavior.

Per-host: pve/crete/crete2/Worklab → BIOS auto-power-on; Synology → DSM "restart after power failure"; Mac Studio → `pmset autorestart 1`; switches/Netgate → auto-boot inherently.

Backstops (manual/orchestrated wake): WoL enabled on the node NICs; **JetKVM ATX board powers pve on**, **AMT powers the MS-01s on** — the break-glass if auto-recovery wedges.

Software layer self-heals: Proxmox guests set "Start at boot", Ceph reforms quorum as nodes appear, HA resources restart. Network gear (fast) is up before the nodes finish booting. Optional: set a minimum-recharge-before-restore threshold so a second quick outage doesn't hit a flat battery; stagger the two UPSes' restore delays if inrush trips anything.

### pfSense upgrades and NUT

**pfSense upgrades don't shut the cluster down.** `upsmon` secondaries shut down only on `OB`+`LB` (a real power event) or an explicit FSD from the primary — never on loss-of-comms with the master. A pfSense reboot just makes clients log "stale/unavailable" until it returns. The only (tiny) exposure is the inverse: a mains outage landing *during* the ~5-min upgrade window means no FSD is sent — mitigated by the ~20 min compute-UPS runtime (pfSense re-arms well before critical) and not upgrading during flaky power. Eliminating even that would need the SNMP card (each node polls the UPS directly) — not worth $300-500 for the exposure.

## Rack + hardware shopping list (REVISED 2026-08-07 — single-stack, rack-mount UPSes)

- **Rack — Tripp Lite SRW15US:** 15U wall-mount, switch-depth (~20.5"), hinged/swing-out, 200 lb wall-rated. Holds patch ×2, both switches, MS-01 2U, Mac/Worklab tray, **plus both UPSes now** — recount U and verify loaded weight against the 200 lb rating before ordering rails (see Layout, UPS open items). Check B2B (Provantage/CDW/Newegg) — often below Amazon's third-party price. Mount into a **plywood backer + studs** (added while the wall's open), sized for the added UPS weight.
- **UPSes — 2× CyberPower SLA, rack-mounted:** **CP1500PFCRM2U** (network, 2U rack — replaces the tower CP1500PFCLCD, return it) + **OR2200PFCRT2U** (compute, 2000VA/1540W, rack/tower, 8 std outlets). Not lithium — SLA, ~3× cheaper (see UPS section). Verify the OR2200 "restart when power restored."
- **PDUs:** possibly unnecessary now — both UPSes have their own onboard outlets and live in the rack directly. Re-check once outlet counts are confirmed against actual device count (see Power section). Skip the WebcardLXE (~$200) unless you want per-bank load-shed later.
- **Cooling — single external fan + rack self-ventilation:**
  - **[KOVIET 8" Room-to-Room Ventilation Fan](https://www.amazon.com/dp/B0FBWZF39Z), 320 CFM** — cuts through the closet/laundry shared wall, replaces the CLOUDLINE T8 + T6 pair. Confirm wall thickness falls in its 3.5"–6.2" fit range before cutting.
  - **Rack-mounted intake/exhaust fans (bottom intake, top exhaust)** — model/CFM not yet chosen, size to the ~260 CFM peak target. **Open item.**
  - Drop the wall-grille/foam-shroud/flexible-duct-coupling items below — those were specific to the two-zone capture model and no longer apply.
- **MS-01 mount:** [thingsINrack 2U dual-mount](https://www.amazon.com/thingsINrack-Mount-MiniSforum-19inch-Dual-Mount/dp/B0FC2FYSRC) (both nodes, 2U). Power bricks velcro'd to the tray.
- **JetKVM — rack-mounted at RU1, PoE deferred:** [8-unit tool-less 1U rack mount](https://www.etsy.com/listing/1859353396/jetkvm-1u-rackmount-for-8-x-jetkvm) (blank inserts for unpopulated slots). Regular USB-powered units for now (PoE variant out of stock) + a small powered USB hub at RU1; upgrade to PoE units later is a tool-less clip swap, no mount change. See Layout for cabling notes.
- **2nd Mac Studio (fall 2026, M5 Ultra):** rack mount already dual-capable (Empower Station, bought now) — no hardware purchase needed later, just the unit itself. Run 10GbE to the 2nd slot now while the wall's open.
- **Electrical:** one dedicated **20A circuit** — outlet placement now an **open item** (see Power section) since neither UPS is floor-standing anymore. While the wall's open: 20A circuit + three cable chases (data / power / heat-duct) + intake.

<details>
<summary>Superseded: two-zone cooling shopping list items (CLOUDLINE T8+T6, floor UPS PDUs)</summary>

- 2× inline fans — CLOUDLINE T8 (cabinet top) + a smaller inline (T6-class) for the floor pve duct; wall grille + foam/sheet-metal shroud for pve's rear; flexible duct coupling at the cabinet (for the swing); short ducts into the laundry-room top; cabinet low-intake + door louver.
- CP1500PFCLCD tower + one power strip/1U PDU per UPS, floor UPS → cord up to the cabinet.

</details>

## Open items / to verify

1. **BOINC decision** — it pegs the GPU at 231W whenever it has work, setting "idle" at ~780W not ~550W, +231W heat, +audible blower. Keep GPU-crunching / restrict to CPU-only / schedule to off-hours. Sets real steady-state draw + closet heat.
2. Confirm the **laundry-room air path back to the house AC return** (undercut/louver the door, or a return present) — else the hotspot just relocates there.
3. **Rack U count + loaded weight** — recount both UPSes into the 15U SRW15US alongside existing gear, and verify the 200 lb wall rating against actual loaded weight (was ~45 lb light-gear-only; now includes two SLA UPSes).
4. **KOVIET wall-thickness fit** — confirm the closet/laundry shared wall is within the fan's 3.5"–6.2" spec before cutting.
5. **Rack-mounted intake/exhaust fan selection** — bottom-intake/top-exhaust fans for the SRW15US itself not yet chosen; size to ~260 CFM peak target, prefer thermostatic if available.
6. **Floor outlet necessity** — with both UPSes rack-mounted, confirm with the electrician whether the originally-planned floor outlet still serves a purpose, or if both circuit outlets should land at rack height.
7. ~~pve-on-its-side shelf clearance + GPU sag~~ **RESOLVED 2026-08-07 — measured, 1" spare (32" closet − 18" tower height − 13" NAS width); no anti-sag bracket needed** — this rotation puts the GPU's cantilever parallel to gravity, not perpendicular. Just orient the card pointing up when placed on the shelf.
8. **UPS battery service path** — confirm the OR2200PFCRT2U's battery cartridge is front-accessible (CyberPower's spec sheet confirms "User Replaceable Battery: Yes" but not the access side — verify in the manual). With swing access dead (below), a rear-loading battery would mean pulling the whole UPS to service it every 4-6 years.
9. ~~Eave vent~~ moot (recirculate to laundry). ~~Closet dims~~ measured (96×43×32). ~~pve noise~~ measured quiet (Synology is the noise source). ~~Split cooling~~ → collapsed to single stack + single external fan (2026-08-07). ~~Swing clearance~~ **RESOLVED 2026-08-07 — measured 4" side clearance limits swing to ~18°, not usable for rear access.** See Cable management below for the consequence.
