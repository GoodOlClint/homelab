# VM 240 on two Arc Pro B70s — change plan

- **Status:** APPROVED by the operator 2026-11-18; in progress.
- **Amends:** [ADR 0051](decisions/0051-local-inference-on-vm-240-is-ollama-plus-nvidia-pair-behind-caddy-with-per-client-keys-pair-is-opt-in-and-the-macs-join-only-after-a-cross-vlan-enrollment-gate.md) (engine layout), consistent with [ADR 0056](decisions/0056-msi-leaves-ceph-but-stays-a-non-ceph-cluster-member-as-the-gpu-host-and-its-drain-waits-for-three-healthy-osd-hosts.md) (msi as the 2× B70 GPU host).
- **Operator decisions (interview 2026-11-18):** the chat model spans both cards with vLLM tensor parallel (TP: each layer's weights are split across the cards and both compute every token); VM 240 may be restarted as needed.

## Goal

Both B70s are passed to VM 240 and the served chat engine runs one model across the two cards, with every served number measured on this guest, or the plan ends on a named, measured fallback.

## Existing state (mapped 2026-11-18)

| Fact | Source |
|---|---|
| Card 2 is at host `0000:07:00` (GPU, IOMMU group 29), its audio at `08:00` (group 30), both on `vfio-pci`. Card 1 is `03:00` (group 24). | read live on msi |
| The host binding needs no change: `proxmox_host_vfio_pci_ids.msi` lists device ids `8086:e223` and `8086:e2f7`, which match both cards. | `ansible/roles/proxmox_host/defaults/main.yml` |
| VM 240 passes only the GPU function of card 1 (`pci_devices = [{ id = "0000:03:00" }]`), 32 GB, 6 vCPUs pinned to P-cores, running. | `terraform/vm-configs.tf`, `qm config 240` |
| msi has 64 GB of memory available, with 57 GB committed to guests. | `free -g`, `qm list` |
| Chat is vLLM XPU in a digest-pinned container at `0.90 / 8 / 4096` (GPU memory fraction / max concurrent sequences / max batched tokens), 200k context, MTP (multi-token prediction, the model's built-in speculative decoding head), prefix caching, XPU graph capture on. | `ansible/roles/llm/defaults/main.yml` |
| The bge-m3 embedder is a host llama.cpp SYCL process on the same card. It must be warm before the engine sizes the card (`PartOf=`, `is-active` gate). | `vllm.service.j2`, `llama-embed.service.j2` |
| Single-card baseline: 61 / 57 / 40 tokens per second per stream at 1 / 2 / 4 streams on 4k prompts; KV pool (the key-value attention cache, which bounds context × concurrency) 255,172 tokens with prefix caching. | role defaults, ADR 0051 2026-09-16 |
| Intel's llm-scaler README documents `--tensor-parallel-size 2`, `VLLM_WORKER_MULTIPROC_METHOD=spawn`, `ZE_AFFINITY_MASK`, `--shm-size 32g`, and the `/dev/dri/by-path` mount (already present here). Its multi-GPU examples all use `--enforce-eager`; graph capture under TP is not covered. | fetched 2026-11-18 |

## Known risks, each with its check

| Risk | Why it is real here | Check |
|---|---|---|
| TP workers trip the two-XPU-processes rule | Two XPU processes initialising at once failed an engine init through the shared triton/NEO compile cache (rules file). TP=2 starts two workers by design. | Phase 2, first run. If init fails on the cache, try a per-worker cache dir; two failures on this point stops the phase (two-attempt box). |
| Graph capture under TP | Served config sets `VLLM_XPU_ENABLE_XPU_GRAPH=1`; Intel's TP examples run eager. | Bench both; eager is an accepted served mode if graph fails. |
| MTP, prefix caching and Mamba `align` under TP | None is documented as limited, none is measured here. | Bench matrix below; correctness spot-check, not only speed. |
| Guest RAM | One card's Level Zero stack pins about 11 GB of guest RAM; a second worker adds an unmeasured amount, and a guest OOM during init costs a 20-minute cycle. | Raise to 48 GB with the attach; record `MemAvailable` and `drm-total-gtt` at peak; shrink afterwards if the peak allows. |
| Embedder lands on the wrong card or on both | A SYCL process with two cards visible picks a default device. | Pin with `ONEAPI_DEVICE_SELECTOR` (verify the index with `sycl-ls` in the guest; not taken from documentation). The engine's sizing gate stays. |
| PCIe link | TP moves activations between cards every layer. The endpoints report 2.5 GT/s x1, which is normal behind the on-card switch; the real link is on the upstream bridge. | Read the upstream bridges' `LnkSta` on msi in phase 1; expect x8 on both. |
| Power | Two B70s plus a 253 W CPU; the PSU is now 1200 W (ADR 0056 amendment). This box has reset on PSU behaviour before (the ECO switch). | Phase 2 watches msi for a reset under the 8-stream run. |
| Wedge detection | `vllm-wedge-capture` reads `xpu-smi stats -d 0` only. | Phase 3 edit covers both devices. |

## ADR 0056 conditions (operator ruling 2026-11-18)

ADR 0056 set two conditions on the second B70. Both are settled and recorded as an amendment in ADR 0056:

| ADR 0056 condition | Ruling |
|---|---|
| A PSU upgrade (1000–1200 W) or enforced power caps before B70 #2 | Met: the PSU is an ASRock Steel Legend SL-1200P (1200 W). "No power cap" stands. |
| The second B70 waits for the msi OSD drain | Relaxed: another MS-01 failure keeps msi's OSDs in service, so testing proceeds now under `ceph osd set noout` with msi as one of three OSD hosts. |

## Phases

### Phase 0 — preflight (no changes)

1. The operator's ruling on the two ADR 0056 conditions above is written into this plan (done 2026-11-18).
2. `ceph -s` is `HEALTH_OK` and `ceph osd set noout` is in place before any two-card load on msi (rules file: noout before any msi experiment); it is unset when phase 2 ends.
3. The single-card rollback point is named: `fba62b9`, the commit before phase 1, which holds the complete served config (arguments, environment, warm-up, embedder unit, device checks).

### Phase 1 — attach the card (one commit, one restart)

1. `terraform/vm-configs.tf`: `pci_devices = [{ id = "0000:03:00" }, { id = "0000:07:00" }]`, `memory_mb = 49152`.
2. `llama-embed.service.j2`: pin the embedder to card 1.
3. `make plan` must show an in-place update of VM 240 and nothing else. Check that no code-intel index build is in flight, then stop and start the guest.

**Done when:** the guest shows two render nodes and `xpu-smi discovery` lists two devices; the upstream bridges report the expected link width; `systemctl is-active llama-embed vllm` is `active`; the liveness probe passes; the embedder's memory appears on card 1 only. The served config is still the measured single-card one, so this state is safe to stay in.

### Phase 2 — measure TP on the guest (no commits to the served config)

The harness is b70-bench's `scripts/bakeoff-remote.sh` vLLM arm with `oai-bench.py`, not `llm-bench.sh`: that script still drives the retired `llama-server` router and stops the embedder. The vLLM arm needs three changes in b70-bench first: the image pinned by the served digest instead of the `0.26.0-b2` tag, the served checkpoint path, and a TP arm. Each candidate runs as a `vllm-bench` container with `vllm.service` stopped and `llama-embed` active and warmed, because the embedder's residency is part of the memory budget. When the phase ends the bench container is removed, `systemctl start vllm` restores the served engine, and a completed generation through Caddy confirms it. The first result is whether the engine initialises at all.

| Run | Config |
|---|---|
| A | TP=2, current flags (graph on, MTP, prefix caching), `spawn`, `--shm-size 32g` |
| B | A with `--enforce-eager` (only if A fails or to compare) |
| C | Best of A/B without MTP |
| D | Best config with `--max-num-seqs 16` |

Recorded per run: decode tokens per second per stream at 1 / 2 / 4 / 8 streams on 4k prompts, prefill speed, KV pool size in tokens, warm-up time, peak guest RAM and `drm-total-gtt`, `cached_tokens` on a repeated prefix, `reasoning` field present, and a fixed-prompt answer comparison against the single-card engine at temperature 0.

**Adoption thresholds (proposed, the operator may change them):** KV pool at least 1.8× the baseline 255k tokens, single-stream decode at least 80 % of 61 t/s, 4-stream decode at least the baseline 40 t/s, no wrong-answer regression, and 20 completed generations sent to the candidate's own port five minutes apart, each inside the 90-second liveness timeout. The `vllm-liveness` script does not count here: it exits 0 whenever `vllm.service` is inactive, which it is for the whole phase.

**Fallback if TP misses them or will not initialise:** serve split by role (chat alone on card 1, embedder alone on card 2), which needs no new engine mode. The ADR amendment records the measured reason. The cards still share the workload, but not one model.

### Phase 3 — land the served config (role, docs, ADR)

- `llm_vllm_args` and `vllm.service.j2`: the TP flag, environment and shm size that phase 2 measured; the budget comment replaced with the new measured figures.
- `vllm-warmup.j2`: warm the concurrency shape the new `--max-num-seqs` implies.
- `tasks/main.yml`: the render-node check covers both cards.
- `vllm-wedge-capture.j2`: `xpu-smi` statistics for both devices, and a stack dump of every process in the engine container, not only the API server and one `EngineCore`. Under TP a hung worker leaves `EngineCore` waiting, and the worker's stack is the evidence. A forced capture must show both workers before adoption.
- ADR 0051 consequence note with the numbers; `.claude/rules/llm.md` pipeline paragraph and any new What Never To Do line; `docs/LESSONS.md`; results published in b70-bench.
- Codex adversarial review of the branch before it is pushed.

**Done when:** `make ansible llm` is zero-changed on a second run; over 24 hours the journal shows every liveness probe as a completed generation with `vllm.service` continuously active, zero probe failures and zero engine restarts (a green timer alone proves nothing, since the probe exits 0 on a stopped engine); a code-intel embed run and a 4-stream chat run complete together; and `make plan` is clean for VM 240.

## Phase 2 results (2026-11-18)

Tensor parallel does not work on this guest. Reports: b70-bench `runs/2026-11-18-tp2/`, harness `scripts/tp-bench-remote.sh`.

**Baseline, one card, both cards attached:** 62.6 / 54.9 / 50.7 / 39.1 tokens per second per stream at 1 / 2 / 4 / 8 streams (short prompts), KV pool 268,965 tokens, prefix cache and reasoning checks pass.

| Run | Guest layout and container | Result |
|---|---|---|
| A, A2 | PCIe root ports, SeaBIOS, unprivileged (A2: `CCL_TOPO_P2P_ACCESS=0`) | `oneCCL: mem_to_ipc_handle: device_fd is invalid value` |
| A3 | A, `--privileged` | `zeMemOpenIpcHandle ... ZE_RESULT_ERROR_INVALID_ARGUMENT` |
| B1–B4 | A, `--cap-add=SYS_PTRACE`, exchange mode `pidfd` or `sockets`, with and without USM mode and graph capture | Handle exchange succeeds (`pidfd exchange mode is verified successfully`); same `zeMemOpenIpcHandle` failure |
| C1 | Both cards on the one conventional PCI bridge (`pcie = false`) | Kernel refusal gone; both workers spin in `empty_cache` (`xpu_worker.py:115`) for 14 minutes, never finish |
| D1 | PCIe root ports, OVMF | Same failure as B1 |
| E1 | D1 plus `CCL_TOPO_ALGO=0` | **Starts**, KV pool 934,482 tokens, but the output is garbage: MTP acceptance 0 %, nonsense text at temperature 0, decode 28 tokens per second |

**Cause, as far as it is established.** On every failing run the guest kernel logs `xe 0000:01:00.0: cannot be used for peer-to-peer DMA as the client and provider (0000:02:00.0) do not share an upstream bridge or whitelisted host bridge`. Proxmox gives each `hostpci` device its own root port under the emulated q35 host bridge, the kernel refuses peer-to-peer DMA across them, the cross-card memory import fails, and Level Zero reports `p2p_access: 0`. Two container facts sit in front of that: Docker's default seccomp profile blocks `pidfd_getfd` without `SYS_PTRACE`, and `CCL_TOPO_P2P_ACCESS=0` does not avoid the import. Firmware type is ruled out (D1). E1 shows the engine can be made to start without the direct path, and that doing so corrupts the data, so a start is not evidence of a working config: any future attempt must pass the answer check, not only `/health`.

**Not established:** why other Proxmox users report success with the same layout (guest kernel 7.0's `xe` is the first suspect, unverified), and whether a real shared PCIe upstream bridge (an emulated PCIe switch, not Proxmox's `hostpci` placement) would carry the transfer or hang as C1 did.

### After the first eleven runs (same day)

| Run | Guest layout and container | Result |
|---|---|---|
| F1 | OVMF, both cards behind one emulated PCIe switch (raw QEMU `args`: `x3130-upstream` on `ich9-pcie-port-3`, two `xio3130-downstream`, two `vfio-pci`; no `hostpci` lines), `--cap-add=SYS_PTRACE`, `pidfd` | Guest kernel refusal gone (zero peer-to-peer lines). Workers hang in `empty_cache` (`xpu_worker.py:115`), as in C1. |

**What F1 added.** While F1 hung, the **host** logged `DMAR: [DMA Read NO_PASID] Request device [07:00.0] fault addr 0x427a0e40000 [fault reason 0x04] Access beyond MGAW`, for both cards. msi's VT-d is 39-bit (`DMAR: Host address width 39`, a 512 GB limit). The guest runs `cpu: host` with 46 physical address bits, and OVMF places the cards' 32 GB BARs at `0x381000000000` and `0x382000000000`. The faulting address is beyond the 39-bit limit, so the address-width fault is real, but `0x427a0e40000` lies outside both BAR ranges and outside the guest's 64-bit PCI window (`0x380000000000`–`0x3857ffffffff`), so where that address comes from is not established (Codex session's check, 2026-11-18). BAR placement is a suspect for the C1 and F1 hangs, not a proven cause. The Codex session also confirmed host DMAR faults at 12:45, during C1.

**Tried and not effective:** `qm set 240 --cpu host,phys-bits=39`. QEMU received `phys-bits=39` and warned `Host physical bits (46) does not match phys-bits property (39)`, but the guest still reports 46 bits and the same BAR placement.

**Not yet tried:** capping the guest with `host-phys-bits-limit=39` (a second `-cpu` in `args`), SeaBIOS with the switch layout, a patched communicator that stages through host memory (the image hardcodes `dist_backend = "xccl"`), a standalone two-card all-reduce and `zeDeviceCanAccessPeer` integrity test outside vLLM.

**Correction to the state below (2026-11-18, from the Codex session's `qm config` capture at 13:42:54, not re-verified by this session):** the `host-phys-bits-limit=39` change listed above as not yet tried was interrupted mid-command and did reach the VM config. `args` ends with `-cpu host,+kvm_pv_eoi,+kvm_pv_unhalt,host-phys-bits=on,host-phys-bits-limit=39`, `cpu:` is `host`, and the guest agent stopped responding afterwards, so whether VM 240 restarted, and whether the served engine is up, is unknown. No run has tested that setting. Later findings are in the Codex session's own investigation file, not here.

**Testing handed to the Codex session 2026-11-18 (operator instruction).** State of VM 240 at handover, all firmware and topology settings made by hand with `qm set` and absent from Terraform (`make plan llm` will show drift, and an apply would put the `hostpci` lines back beside the `args` devices):

- `bios: ovmf` with `efidisk0` on `ceph-rbd`; `cpu: host,phys-bits=39` (ineffective, safe to remove); `memory: 49152`.
- No `hostpci0`/`hostpci1`. `args:` carries the emulated switch and both `vfio-pci` devices; the cards are guest `05:00.0` and `06:00.0`.
- Served single-card engine and embedder start at boot and answer correctly on every layout tested. No bench container is running.
- `ceph osd set noout` is still set and must be unset when two-card testing ends.
- Guest `~/tp-bench/` holds every report and full log; copies of the reports through E1 are in b70-bench `runs/2026-11-18-tp2/`; `scripts/tp-bench-remote.sh` there is uncommitted. Never stop a run with `pkill -f`; kill the pid in the run's `.pid` file.

### Rollback

Order matters: restore the single-card service config first, detach the card second.

1. Engine: `git revert` the phase 3 commit and run `make ansible llm`. That restores the whole served config from the phase 0 rollback point (arguments, environment, shm size, warm-up, wedge capture, device checks), not only the TP flag. Verify one chat generation and one embedding through Caddy.
2. Card: only then revert the phase 1 commit (the `pci_devices` line, memory, and the embedder pin, which must not name a card that is gone) and restart the guest. Verify chat and embeddings again.

## Out of scope

- A larger chat model on the 64 GB pair. TP is proven on the current model first; a model change is its own bench and ADR note.
- Passing the audio functions (`04:00`, `08:00`). Card 1 never needed its own.
- GPU temperature alerting for the second card.

## Review disposition

One Codex adversarial pass, 2026-11-18. Each finding was checked against the repo before it was accepted.

| Finding (severity) | Disposition |
|---|---|
| ADR 0056 requires a PSU upgrade or power caps before card 2, and makes the card wait for the Ceph drain; the plan replaced both with "watch for resets" (high) | **Accepted.** Verified in ADR 0056 and live (`osd.2`, `osd.3` up on msi). Now a blocking section and phase 0; the ruling is the operator's. |
| `llm-bench.sh` drives the retired llama.cpp router and stops the embedder (high) | **Accepted.** Verified in `llm-bench-remote.sh`. Phase 2 names `bakeoff-remote.sh`'s vLLM arm and the three changes it needs. |
| Liveness acceptance can pass with no generation, because the probe exits 0 on an inactive unit (high) | **Accepted.** Verified in `vllm-liveness.j2`. Both acceptance checks now count completed generations. |
| Rollback restored only the TP flag and could detach a card the embedder is pinned to (medium) | **Accepted.** Rollback is a revert of whole commits, in a fixed order. |
| Wedge capture dumps one `EngineCore` and would miss a hung TP worker (medium) | **Accepted.** Phase 3 captures every process in the container. |
