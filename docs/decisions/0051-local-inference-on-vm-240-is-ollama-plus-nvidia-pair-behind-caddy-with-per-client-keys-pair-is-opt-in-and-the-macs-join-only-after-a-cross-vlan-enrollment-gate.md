# ADR 0051 — Local inference on VM 240 is Ollama plus NVIDIA PAIR behind Caddy with per-client keys; PAIR is opt-in and the Macs join only after a cross-VLAN enrollment gate

- **Status:** Proposed (awaiting operator review of [docs/local-ai-plan.md](../local-ai-plan.md))
- **Date:** 2026-09-10
- **Deciders:** operator + agent
- **Context source:** [docs/local-ai-plan.md](../local-ai-plan.md) (two council rounds, Claude + Codex, 2026-09-10) · consequence of [ADR 0001](0001-repoint-iac-to-a-3-node-pve-9-cluster-with-ceph.md)/[ADR 0003](0003-decompose-services-to-static-ip-lxcs-vms-only-where-isolation-demands.md) (LLM = passthrough VM) and [ADR 0031](0031-a-three-node-talos-kubernetes-cluster-becomes-the-services-plane-and-the-bootstrap-tier-stays-on-proxmox.md) (LLM VM in the bootstrap tier) · builds on [ADR 0041](0041-p7-per-host-certs-are-acme-dns-01-against-infisical-through-bind-s-dynamic-update-path-on-a-scoped-tsig-key-pbs-fingerprint-pins-retire-infisical-s-own-cert-is-api-issued-behind-caddy.md) (fleet-hosts certs)

## Context

VM 240 `llm` (msi, Quadro RTX 5000 whole-passthrough, model cache on holder slot 6) has been proven as a passthrough guest but its software is hand-installed: NVIDIA driver, Ollama, and a now-unneeded power cap (the 2026-09-09 host resets were the PSU's ECO switch, not the GPU). `onboot` is hand-set in pmxcfs, `make update` rebooted the guest into a crash loop once, (the dead vGPU-era `nvidia`/`nvidia_licensing` roles were removed on main the same day). Nothing in the fleet can reach the model through code.

The inference estate is multi-provider by design: the RTX 5000, the Mac Studio (the operator's MLX appliance Athena), the MacBook Pro, Claude, Codex, and OpenRouter. VM 240 is the only inference node in this repo, not the only one. The operator wants **NVIDIA PAIR** (Personal AI Router, Apache-2.0) as the one local inference endpoint across the GPU VM and the Macs, proven on the VM first. PAIR's published facts constrain the design: it routes whole requests to one node (no VRAM pooling); it supports only Ollama and LM Studio as engines (a third-party engine means overwriting the bundled LM Studio manifest and `chattr +i`, because the manifest directory doubles as PAIR's own port-override store); its OpenAI/Ollama-compatible proxy is **plaintext on loopback only**, with the same port serving a mutual-TLS ingress for paired members; the six-digit PIN is a bootstrap, not a durable credential; discovery is LAN-local plain HTTP with an unpublished protocol; and NVIDIA states that segmentation and host firewalling are the operator's responsibility. Ollama itself has no authentication.

The Turing card (sm_75, 16 GB) rules out FP8 and FlashAttention-2, so the model set is roughly 12B at 4-bit or 8B at fp16. Model choice stays a variable.

## Decision

- **Engine = Ollama**, chosen for PAIR compatibility. vLLM is revisited only when PAIR grows a generic OpenAI-compatible backend; the manifest-overwrite hack is not used.
- **VM 240 becomes a code-defined guest**: a new `ollama` role installs the pinned NVIDIA driver, Ollama (`OLLAMA_HOST` on loopback, models on `/data`), PAIR (`nvpair` from a version-pinned, checksum-verified package, headless mode), and Caddy. No power cap. `make update` excludes the guest. Per-VM `on_boot` becomes a module input and 240's value lives in `vm-configs.tf`. Model name and quantization are role variables.
- **Exposure = Caddy on 240** with a `fleet-hosts` certificate (`cert_client`, ADR 0041) on `llm.<service domain>`, serving two separately authenticated routes: PAIR's loopback proxy and direct Ollama. Raw Ollama (11434) and PAIR's plaintext proxy never leave loopback. Callers present a per-client API key rendered from Infisical (folder `/llm`), giving attribution and revocation; a PVE guest-firewall allowlist is defense in depth once the VM module supports it. "Network reachability only" is rejected.
- **PAIR is opt-in, never a dependency.** Consumers pick a backend by URL (an agent's YAML `base_url`); the direct-Ollama route and cloud providers stay independently selectable. No automatic failover is claimed. Nothing other than VM 240 and the Macs ever runs `nvpair`; in particular the agents host is a routed client, not a PAIR member.
- **The Macs join only after the enrollment gate passes** on the real client/services boundary: PAIR's discovery and node-metadata flows captured and reduced to named pfSense rules; PIN bootstrap followed by member mutual TLS; both engines and their models visible and requests routed to the expected engine; pairing survives service and host restarts; `make rebuild llm` restores member identity from `/data` or recreates it non-interactively. If routed cross-VLAN membership needs a broadcast relay, a dual-homed guest, or a fresh PIN per rebuild, PAIR is not rebuild-proven and the Macs wait. The Mac-side engine is LM Studio or Ollama installed beside Athena; Athena keeps its own clients.

## Rejected alternatives

- **vLLM under PAIR via the manifest hack** — undocumented, breaks on any PAIR update, and PAIR's routing layer hard-codes Ollama/LM Studio; the operator ranked PAIR above vLLM.
- **Skip PAIR and expose Ollama directly** (both councils' round-1 verdict) — overruled by the operator: PAIR is the intended multi-node endpoint and the VM is where it gets proven.
- **Make the agents host a PAIR member for mTLS access** — installs beta cluster software with an unpublished discovery protocol on the highest-value credential guest.
- **Access control by IP allowlist alone** — no revocation, no attribution; compromise of one allowed host defeats it.
- **Keep the power cap** — the reset cause was the PSU; the cap only costs throughput.
- **Bare-metal AI box** — msi stays a Proxmox node forever; the LLM is always a passthrough VM.

## Consequences

- **Amended 2026-09-11 (tranche 1b, [plan §7](../local-ai-plan.md)):** the engine is **llama-server** (MoE with CPU expert offload: attention/KV on the 16 GB card, routed experts in system RAM), reached through the same Caddy front door as a keyed `/llama/` route; Ollama remains solely as PAIR's supported backend until PAIR grows a llama.cpp adapter, then retires. The guest stays a **VM**: msi runs Secure Boot and the Debian/Proxmox NVIDIA module is an unsigned DKMS build, so an LXC with the host driver would need a MOK enrollment on every kernel roll; the guest's Ubuntu driver is signed. VM 240 is respecced (`cpu: host`, P-core affinity, ~96 GB, no balloon; module inputs added like `on_boot`), the holder slot grows for the bench set, and XMP on msi is a gated hand step (noout, drain, memtest). Consequence for ADR 0052: with 240 at ~96 GB, `agents`/`mcp` cannot also sit on msi until it leaves Ceph.

- New: `ansible/roles/ollama`, an `llm` play + tag, Infisical folder `/llm` (added to `infisical_login.yml` and the ownership table), Kuma rows that distinguish "PAIR healthy", "PAIR down, direct Ollama healthy" and "local inference down", a homepage tile, `make dns-records` unchanged (the name exists).
- Module work before the role lands: per-VM `on_boot` (and later guest-firewall rules) in `modules/proxmox-vm`, applied against the ADR 0016 replace foot-gun with a plan that shows in-place changes only.
- PAIR lifecycle is recorded in the plan: package version + checksum, config/identity paths on `/data`, upgrade and rollback, re-pair behaviour.
- The `ollama` role installs Ollama and `nvpair` from upstream — an ADR 0022 stays-upstream exception like the registry's own refs; Zot mirrors nothing here.
- When msi leaves Ceph (the 2026-09-09 re-plan), 240's rootfs and holder slot 6 move to local storage; that is a scheduled rebuild, not a surprise.
- Renewal proof and the enrollment gate are the two acceptance tests that gate any Mac joining; they are written into [docs/local-ai-plan.md](../local-ai-plan.md).
