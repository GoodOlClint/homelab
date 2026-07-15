# Fully-IaC bare-metal host provisioning: JetKVM, Intel AMT, and PXE

Research date: 2026-07-10. Method: 6 search angles → 27 sources fetched → 109 claims extracted → 25 adversarially verified (3-vote, 2/3 refutes kills) → 8 findings. 2 claims refuted, 4 open questions.

## Bottom line

Do not try to provision hosts with Terraform. Proxmox VE 8.2+ ships an official unattended installer (`answer.toml` + `proxmox-auto-install-assistant`) that boots over PXE/iPXE and needs nothing but DHCP + HTTP (or TFTP). That covers both node classes identically. JetKVM and Intel AMT are then **out-of-band power/console**, not provisioning tools — they exist to power the box on, point it at the network, and give you a screen when the install goes wrong.

Keep Terraform for VMs and SDN, which is exactly where this repo already has it.

## 1. JetKVM: no Terraform provider, and no REST API to write one against

There is no JetKVM Terraform provider — official, community, or registry. There is also no public REST control API.

The firmware ([jetkvm/kvm](https://github.com/jetkvm/kvm), GPL-2.0, TypeScript 36% / C 34% / Go 27%) exposes its control plane as **JSON-RPC 2.0 over a WebRTC data channel** (the reliable `rpc` channel). Plain HTTP and WebSocket endpoints exist only for WebRTC signaling, auth, device status, and media upload. That is an awkward transport to wrap: a Terraform provider or Ansible module would need a WebRTC client, not an HTTP client.

The JSON-RPC method names are not in the reverse-engineered docs but are readable from `jsonrpc.go`:

| Concern | Methods |
|---|---|
| Power / ATX | `setATXPowerAction`, `getATXState`, `setDCPowerState` |
| Virtual media | `mountWithHTTP`, `mountWithStorage`, `unmountImage`, `setMassStorageMode`, `startStorageFileUpload` |
| Auth / security | `setSSHKeyState`, `setTLSState`, `setDevModeState` |

The one project on the registry with "terraform" and "jetkvm" in its name, [dotWee/terraform-jetkvm-install-tailscale](https://github.com/dotWee/terraform-jetkvm-install-tailscale), does not touch any JetKVM API — it SSHes into the JetKVM device itself with generic `provisioner` blocks to install Tailscale on it. It manages the KVM, not the machine behind the KVM.

The practical automation seam today is **SSH into the JetKVM** (it runs Linux; `setSSHKeyState` enables key auth) and drive things from there.

Sources: [jetkvm/kvm](https://github.com/jetkvm/kvm) · [JSON-RPC interface](https://deepwiki.com/jetkvm/kvm/2.2-json-rpc-interface) · [control plane](https://deepwiki.com/jetkvm/kvm/2.3-json-rpc-control-plane) · [discussion #942](https://github.com/jetkvm/kvm/discussions/942) (confirms no published local HTTP control API).

## 2. Provisioning a box from scratch via JetKVM: yes, manually

Confirmed. JetKVM mounts ISO, IMG, QCOW2, WDI, and VMDK images as virtual USB media that BIOS/UEFI sees at boot, explicitly "for tasks like reinstalling an operating system." A first-person account documents a complete remote reinstall of a headless home server — upload ISO, Storage Mount, boot — with no physical keyboard or monitor ([unfinished.bike](https://unfinished.bike/reinstalling-our-home-storage-server-with-jetkvm)).

Limitations that survived verification:

- Storage mount runs at **USB 2.0 speed**. A 1.3 GB Proxmox ISO is tolerable; do not plan on it for anything larger.
- **One drive mountable at a time.**
- CD/DVD-style ISOs boot reliably. One blog reported memstick-style images failing, but the blanket claim "memstick images never boot" was **refuted 0-3** — it appears to be a one-off, not a JetKVM limitation.

What does *not* exist: any packaged automation. No Ansible module, no maintained Python/Go client that the verifiers could confirm. (`davehorner/jetkvm_control` and a Rust `jetkvm_control` crate surfaced in verifier evidence but were not independently confirmed — worth a look.) Remote install via JetKVM is a hands-on-keyboard operation, not an IaC one.

Source: [official mount-drive docs](https://jetkvm.com/docs/peripheral-devices/mount-drive).

## 3. Intel AMT: no Terraform provider either, but a real REST API

No AMT Terraform provider exists. What does exist is Intel's **Device Management Toolkit** — renamed from Open AMT Cloud Toolkit, repos moved to [github.com/device-management-toolkit](https://github.com/device-management-toolkit), and actively maintained (10 repos updated 2026-07-09/10).

Two usable layers:

**MPS REST API** ([mps](https://github.com/device-management-toolkit/mps)) — JWT bearer auth, device-GUID-keyed:

```
POST /mps/login/api/v1/authorize                  → JWT
GET  /mps/api/v1/amt/powercapabilities/{GUID}     → what power actions this box supports
POST /mps/api/v1/amt/power/action/{GUID}          → power on/off/cycle/boot-to-media
```

This is directly scriptable from Ansible `uri` tasks. It is IaC-adjacent even without a provider.

**MeshCentral** ([docs](https://docs.meshcentral.com/intelamt/)) — a free management server that *is* an MPS. AMT tunnels back to it over TLS on port 4433 via Intel's APF protocol (Mesh Agents use 443). It supports Admin Control Mode activation (requires an AMT activation cert plus DHCP option 15 or a trusted FQDN), and gives out-of-band KVM, remote power, and remote BIOS access that work when the OS is dead — AMT KVM runs in ME firmware on ports 16992-16995, independent of the host OS.

### Measured state of `crete` / `crete2` (2026-07-10, over SSH)

Both nodes are **identical and unprovisioned**:

| | crete | crete2 |
|---|---|---|
| ME device | `/dev/mei0` present | same |
| ME firmware | `16.1.25.2049` (CSME 16.1, Alder/Raptor Lake) | same |
| `fw_status` HFS1 | `0x90000255` | same |
| HECI controller | `00:16.0 [8086:51e0]` | same |
| I226-**LM** (AMT NIC) | `5a:00.0` → `enp90s0` | `5a:00.0` → `nic1` |
| AMT ports 16992-16995 | all closed | all closed |

Decoding HFS1 `0x90000255`: working state 5 (Normal), `fw_init_complete` set, operation mode 0 (Normal — not disabled or temp-disabled), **`mfg_mode` bit set**. The ME is alive and healthy but has never been provisioned out of manufacturing mode, which is why nothing is listening on 16992.

**The vPro tier question is settled: Enterprise.** The i9-13900H ships full vPro Enterprise with AMT, ISM, Remote Platform Erase, and One-Click Recovery — it is the 13900**HK** that drops manageability in exchange for an unlocked multiplier. Minisforum sells the MS-01 explicitly as "vPro Enterprise Support." So **KVM redirection and IDE-R virtual-media boot are both available** once provisioned.

Two things to know before you provision, from the [MS-01 vPro BIOS guide](https://spaceterran.com/posts/step-by-step-guide-enabling-intel-vpro-on-your-minisforum-ms-01-bios/):

- **ASPM must be disabled** (Advanced → Onboard Devices, both SA-PCIE and PCH-PCIE port settings) or AMT networking misbehaves.
- **The author reports Proxmox interferes with the AMT NIC**, and recommends a static AMT IP because DHCP was inconsistent. This is directly relevant here: on both nodes the I226-LM is not idle — it is the *active uplink enslaved to `vmbr0`*. Verify AMT still answers on 16992 after the bridge comes up; if it doesn't, give AMT its own static address rather than sharing the host's.

MEBx entry is `Del` at boot from a **physical monitor** (not through a KVM), default password `admin`, then a complex password with upper, digit, and special character. Expect to need an HDMI dummy plug to avoid a black screen once the OS loads.

## 4. The answer: Proxmox's own unattended installer

Proxmox VE 8.2+ ships this officially, and it is the shortest path.

- `answer.toml` — TOML declaring root password, network config, target disk.
- `proxmox-auto-install-assistant` — apt-installable; subcommands `prepare-iso`, `validate-answer`, `inspect-iso`.
- `prepare-iso --pxe` splits the image into `vmlinuz` + `initrd.img` for network boot.

A full PVE install then runs over iPXE/PXE via **HTTP** (recommended, faster) or TFTP. No physical media. No KVM. No AMT redirection. Working references: [Ciechom/pve-auto-install-pxe](https://github.com/Ciechom/pve-auto-install-pxe) (documents iPXE-over-HTTP, PXE-over-HTTP, PXE-over-TFTP), [SlothCroissant/proxmox-auto-installer-server](https://github.com/SlothCroissant/proxmox-auto-installer-server), [Hetzner's unattended tutorial](https://community.hetzner.com/tutorials/install-proxmox-unattended-hetzner/).

The one thing PXE cannot do is **power the machine on and make it network-boot**. That is precisely the niche JetKVM and AMT fill.

Source: [Proxmox wiki — Automated Installation](https://pve.proxmox.com/wiki/Automated_Installation).

### The heavyweight alternatives, and why not

Tinkerbell (CNCF sandbox, K8s-declarative, actively maintained), Canonical MAAS, Metal3/Ironic, netboot.xyz, and Matchbox are all live projects ([awesome-baremetal](https://github.com/alexellis/awesome-baremetal)). None of them has a first-class "provision this host" Terraform provider that replaces the PXE + answer-file workflow — they *are* PXE + answer-file workflows with an API and a database in front. For three nodes, that is a control plane to maintain in exchange for nothing. (Confidence: medium — the tool comparison leans on one curated secondary list.)

## 5. Terraform for bare metal: the wrong layer

No cited postmortem survived verification, so this is inference rather than quoted authority (confidence: medium). But the inference is well-supported: the confirmed absence of a host-provisioning Terraform provider for either JetKVM or AMT, and the confirmed existence of an official PXE path, point the same direction. Terraform's model is "reconcile declared resources against an API." Bare metal has no API — it has a power button and a network card.

Related: [hashicorp/terraform#23513](https://github.com/hashicorp/terraform/issues/23513), [Ansible for infrastructure: lessons learned in my homelab](https://joshrnoll.com/ansible-for-infrastructure-lessons-learned-in-my-homelab-automation-efforts/).

## Recommended architecture

```
Host lifecycle (all 3 nodes)
  DHCP + HTTP  →  iPXE  →  PVE vmlinuz/initrd + answer.toml  →  Ansible
                                    ↑ generated by proxmox-auto-install-assistant,
                                      answer.toml templated per-host from vlans.yaml

Out-of-band (break-glass + remote power/boot-order)
  pve     →  JetKVM (SSH in; JSON-RPC setATXPowerAction / mountWithHTTP)
  crete   →  Intel AMT via MeshCentral or MPS REST (POST /mps/api/v1/amt/power/action/{GUID})
  crete2  →  same

VMs + SDN  →  Terraform (unchanged)
```

Concretely, per host: template `answer.toml` from the same inventory that drives everything else, serve it over HTTP alongside the split PVE image, and let Ansible take over at first boot. JetKVM's role shrinks to "press the power button and force network boot," which is one SSH command, not a Terraform provider.

## Open questions

1. ~~Does the JetKVM ATX extension have to be physically installed to cold-power-on `pve`?~~ **Moot** — the JetKVM and ATX power board are already on hand.
2. ~~Does the i9-13900H expose full vPro Enterprise or only Essentials?~~ **Resolved: Enterprise.** KVM + IDE-R available. AMT is present but unprovisioned on both nodes (manufacturing mode, ports closed).
3. Does AMT on the I226-LM still answer once Linux enslaves that NIC to `vmbr0`? Both MS-01 nodes are in exactly that configuration today. If not, AMT needs its own static IP.
4. Is there a maintained JSON-RPC/WebRTC client (Go/Python/Rust) for JetKVM that could become an Ansible module, or does SSH remain the only seam? `davehorner/jetkvm_control` is the lead.
5. No documented Terraform-for-bare-metal homelab postmortem was found to firm up §5 beyond inference.

## Appendix: physical placement, rack, and noise (2026-07-13 session)

Decisions and findings from planning the physical rebuild, kept here so the repo stays source of truth. **Final placement landed on a single vented network closet — see the [physical build-out plan](physical-buildout-plan.md).** The nook/garage and bedroom-rack options explored during the session were rejected (sealed cavity can't cool the full stack; closet is already the MDF and contains noise best). The notes below on the MS-01 mount and the deferred noise test still stand.

**MS-01 rack mount.** Two units fit one kit. Recommended: [thingsINrack 2U dual-mount (Amazon)](https://www.amazon.com/thingsINrack-Mount-MiniSforum-19inch-Dual-Mount/dp/B0FC2FYSRC) over the denser [racknex UM-MIN-201](https://racknex.com/minisforum-ms-01-work-station-rackmount-kit-um-min-201/) — the MS-01 runs hot (i9-13900H + dual X710), its intake vents are bottom/side, and dual mounts are notorious for blocking them; 2U buys clearance. Power bricks: velcro to the tray, or a 1U vented shelf under the units — never leave them hanging by the DC pigtail. Verify the kit clears the rear PCIe slot (the 25G Ceph NIC lands there).

**Noise measurement: DONE (2026-07, superseding the deferral below).** Measured with the RTX 5000 at its **full 231W / 100% util / 81°C / blower 60%** (BOINC PrimeGrid GPU work units drove it): **pve is quiet. The Synology's 8 drives are the loudest thing in the closet.** This inverts the assumption that pve's blower Quadro was the node that "cannot be made quiet" — that assumption drove the (abandoned) garage-exile plan. Real noise mitigation target = the Synology (closed door, drive spin-down).

**Correction — the vGPU is NOT compute-throttled.** Earlier note claimed `License Status: Unlicensed` throttled CUDA because a `gpu_burn` container produced zero load. **False** — BOINC gets full CUDA throughput on the same vGPU (231W, 100%). The gpu_burn container failed for its own reasons (image/CUDA mismatch), not licensing. The licensing question may still be worth a look for Plex transcode, but it does **not** cap compute.

~~**Noise measurement: deferred.**~~ *(Original deferral: a representative GPU-noise number "cannot be produced in the current config" because of vGPU slicing. Wrong — BOINC produced a full-TDP load and answered it. Idle baseline for reference: 0% util / 33% fan / 35°C / 17W.)*

## Caveats

- Intel renamed Open AMT Cloud Toolkit → Device Management Toolkit; some `docs/2.18/` URLs 404 on direct fetch though the content persists at other versions.
- Several JetKVM claims rest partly on DeepWiki (AI-generated reverse-engineering), each corroborated against primary source in `jetkvm/kvm`.
- GitHub "Updated" timestamps reflect any repo activity, not human commits — "actively maintained" for the Intel toolkit is well-supported but the exact cadence is approximate.
