# Change plan — VM 240's chat engine moves to vLLM XPU, the embedder to bge-m3

- **Status:** awaiting operator approval (brownfield gate; no implementation before it)
- **Date:** 2026-09-16
- **Decision record:** [ADR 0051](decisions/0051-local-inference-on-vm-240-is-ollama-plus-nvidia-pair-behind-caddy-with-per-client-keys-pair-is-opt-in-and-the-macs-join-only-after-a-cross-vlan-enrollment-gate.md) (amended by this change)
- **Evidence:** [b70-bench `results.md`](https://github.com/GoodOlClint/b70-bench) — the bakeoff, the 200k-beside-an-embedder run, and the rejected 27B quants

## Why

The served engine on VM 240 is llama.cpp SYCL in router mode. ADR 0051 deferred vLLM "until concurrency exceeds ~5 requests". The 2026-09-16 bakeoff retires that condition: vLLM beats llama.cpp in every one of the 24 cells per model, at one stream as well as four, and it keeps MTP's gain under concurrency where llama.cpp's speculative path collapses (4-stream 4k prompts: 52.7 t/s per stream against 4.8).

With bge-m3 resident and the same 200k context served today, measured per-stream decode on 4k prompts:

| streams | llama.cpp SYCL (served today) | vLLM GPTQ-Int4 + MTP k=4 |
| ---: | ---: | ---: |
| 1 | 20.7 | **61.2** |
| 2 | 14.5 | **56.7** |
| 4 | 8.3 | **39.9** |

Time to first token on a 4k prompt falls from 6.5 s to 2.3 s. The embedder change rides along because both embedders cannot sit beside vLLM at `--gpu-memory-utilization 0.90`, and code-intelligence's own bakeoff found bge-m3 (0.57B, 1024 dims) ties Qwen3-Embedding-4B (4B, 2560 dims) on their retrieval set while running 2.6x faster on this card.

## Operator decisions taken at the gate (2026-09-16)

1. **Storage: everything on `/dev/vdc`.** Docker's data-root, the containerd content store and the GPTQ checkpoint all live under `/var/lib/llm/models` — 295 GB, node-local, `backup = false`, and already the disk for re-downloadable weights. `/data` returns to being the ADR 0015 holder slot; the bench's 32 GB image and 21 GB checkpoint come off it.
2. **Embedder: hard swap.** The role serves bge-m3 only. 1024-dim and 2560-dim vectors cannot share an index, so a dual-embedder transition buys nothing; code-intelligence re-embeds from scratch after the window.
3. **Router: deleted, and the bench GGUFs with it.** One served model means no presets, no `--models-max`, no swap. `llm_bench_models` and `llm_model_*` are removed and their ~84 GB comes off the disk. Rollback to llama.cpp chat is `git revert` plus a re-download, not same-day — accepted.
4. **Quality: accepted on the bench numbers.** No side-by-side against the unsloth GGUF. GPTQ-Int4 sym G128 is a standard scheme, Qwen's own FP8 stays in the ledger as the quality reference, and a regression is one revert away.

## Target state

```
client ──443──▶ Caddy on llm.<service domain>        (unchanged: per-client keys, fleet-hosts cert)
                 ├─ /llama/v1/embeddings ─▶ 127.0.0.1:8082  llama-embed  (llama.cpp SYCL, bge-m3)
                 ├─ /llama/*              ─▶ 127.0.0.1:8081  vllm        (docker, Qwen3.8-27B GPTQ-Int4)
                 ├─ POST|DELETE /models   ─▶ 403
                 └─ /pair/*               ─▶ 503 (PAIR unpinned)
```

The Caddy contract does not change: same host, same routes, same per-client keys, same ports. **No client changes anywhere** except code-intelligence's embedding model name and dimension.

Pins, all mandatory:

| thing | pin |
| --- | --- |
| engine image | `intel/llm-scaler-vllm@sha256:52218ad85513ab6686d4c090c83c2bd8c5b02423c63aa4dabd41837fe641fe3b` |
| chat checkpoint | `SergiioB/Qwen3.8-27B-GPTQ-Int4-sym-G128-MTP-BF16` @ `e28c5f952bdd5d814297a07d85a064a87af26a3f`, every file sha256-verified |
| embed model | `gpustack/bge-m3-GGUF` @ `2d48f1737679ad900d5c26c5aad5410e9c70fdca`, `bge-m3-FP16.gguf` sha256 `daec91ff…3062c` |
| llama.cpp | `41abbfd` SYCL — unchanged, it still builds the embedder |
| host oneAPI / Level Zero / Mesa | **untouched.** The container carries its own userspace and uses the host `xe` driver through `/dev/dri` |

Serve flags, verbatim from the measured run:

```
--quantization gptq --dtype float16 --kv-cache-dtype fp8
--gpu-memory-utilization 0.90 --max-num-seqs 8 --max-num-batched-tokens 4096
--max-model-len 200000 --language-model-only --served-model-name Qwen3.8-27B
--speculative-config '{"method":"mtp","num_speculative_tokens":4}'
```

`0.88` / `64` OOM-kills the guest during init — the pressure is host memory pinned by GPU-mapped buffers, not VRAM, so it is invisible to `xpu-smi` and to VRAM headroom arithmetic. The budget at 0.90 is 17.47 GiB weights, 2.85 GiB peak activation, 0.74 GiB non-torch, 2.13 GiB graph capture, 7.63 GiB KV = 201,769 tokens.

## Work packages

Each is one commit. `make validate` green on every one; the role is idempotent at each step.

**WP0 — fold in the uncommitted line.** `case_project` in `llm_api_clients` is deployed but uncommitted. Commit it alone first so the cutover diff is clean.

**WP1 — the container host.** `docker.io` from the Ubuntu archive (29.1.3, the benched version). `/etc/docker/daemon.json` sets `data-root` to `{{ llm_models_dir }}/docker`; `/var/lib/containerd` becomes a symlink to `{{ llm_models_dir }}/containerd`, created **before** the package installs so the postinst honours it (the 32 GB image does not fit the 30 GB root disk, and the containerd content store is a separate store that `data-root` does not cover). The image is pulled by digest. The `llm` user does not need docker; the units run as root because the container drops to its own user.

**WP2 — the chat engine.** A `vllm.service` unit running `docker run --rm --name vllm`, ordered `After=docker.service llama-embed.service` and gated on the embedder actually answering before it starts — the start order is load-bearing twice over: the triton/NEO compile cache is shared and two XPU processes initialising at once reproduced a failed init, and GPU buffer placement is fixed at load, so the embedder must claim VRAM first. `--group-add` takes the `render` gid read from the guest, never a literal. `ExecStartPost` polls `/health` and then fires one short and one 4k-token request at 1 and at 4 streams, so the first-shape kernel compiles (5–10 s typical, 86 s seen once) happen before a client meets them.

**WP3 — the embedder.** `llm_embed_*` move to bge-m3: `--pooling cls` (not `last`), alias `baai/bge-m3` (the exact string code-intelligence's generator records as provider/model and compares across endpoints), 1024 dims. Args are the measured line plus `--cache-ram 0` (llama-server's default 8 GiB host prompt cache is host RAM an embedding server never hits).

**WP4 — delete the router.** `llama-server.service.j2`, `models.ini.j2`, the `Restart llama-server` handler, the preset tasks, `llm_llama_models_max`, `llm_llama_args`, `llm_model_args` and `llm_model_*`/`llm_bench_models` all go. `llm_llama_port` is renamed `llm_chat_port` — it is no longer llama.cpp's. The `.github/ISSUE_TEMPLATE/llm-model.yml` form is reworded from "GGUF file / llama-server flags / swapped one at a time" to "checkpoint and revision / vLLM flags / one served model", because the old text describes a machine that will not exist.

**WP6 — the two adjacent asks from code-intelligence-16** (homelab#63), each one line and each flagged rather than silent:
- `scratch_guests.code-intel.secrets` gains `openrouter_api_key: ci-writer`, so the bulk-re-embed key the session placed by hand at `/etc/scratch-secrets/openrouter_api_key` survives a role run. **This needs `/scratch/code-intel/openrouter_api_key` seeded in Infisical first** — the folder is operator-seeded under ADR 0054, and `make ansible code-intel` fails on a key the spec names and the vault does not hold.
- `mcp_code_intel_embed_model` becomes `baai/bge-m3`. The value ships with this change; **applying it is a separate deliberate `make ansible mcp`**, because a gateway restart drops pending approval tickets, and code-intelligence only cuts maintenance over to the VM after its cosine test (same ~200 chunks on both endpoints, min cosine ≥ 0.999) passes.

**WP5 — docs.** ADR 0051 amendment, CLAUDE.md's Local AI paragraph, the What-Never-To-Do entries that name the router, the Kuma row name, and the memory index.

## Cutover runbook

The GPU is unavailable for the whole window. Announce to both code-intelligence sessions before and after.

1. Announce the window. Stop `llama-server`.
2. `make ansible llm` — installs docker on the models disk, pulls the image by digest, downloads the checkpoint (~19 GB, ~12 min), swaps the embed model, writes the units.
3. Second `make ansible llm` — must be **0 changed**.
4. Reboot the guest. Both units come back in order, unprompted.
5. Acceptance (below).
6. Remove the bench leftovers: `/data/vllm` entirely (21 GB bnb-4bit checkpoint, scripts, logs, the old compile cache), the five GGUFs on the models disk, `/data/docker` and `/data/containerd`.
7. Announce the window closed; code-intelligence re-embeds at 1024 dims.

## Acceptance

- `make validate` green; a second `make ansible llm` reports 0 changed.
- After a reboot, `vllm` and `llama-embed` are both `active`, in that start order, with no hand start.
- `https://llm.<service domain>/llama/v1/models` returns **401** with no key, and with a key lists `Qwen3.8-27B`.
- A POST to `/llama/v1/embeddings` with a key returns **1024-dim** vectors under the alias `baai/bge-m3`.
- Two concurrent 4k-prompt streams through Caddy sustain **≥ 50 t/s each** (measured 56.7).
- `ss -Hltn` shows 8081 and 8082 on loopback only — the role already asserts this.

## Risks

- **Guest OOM during init.** The failure mode is pinned host memory, not VRAM, and the killer takes `VLLM::EngineCore`. Mitigation: the flags are the measured-safe set and are pinned, not derived; `0.88`/`64` is recorded here as the thing that kills it.
- **First-shape compile stalls.** A new batch shape can stall a request 7–90 s once. Mitigation: the warm-up covers the shapes clients use; it is not a guarantee for an unusual one.
- **Two XPU processes.** Reproduced as a failed engine init. Mitigation: the unit ordering plus a readiness gate, and the rule stays written down.
- **Rollback is not same-day.** With the GGUFs deleted, reverting to llama.cpp chat needs a 16 GB re-download. Accepted at the gate.
- **The image is 32 GB and unmirrored.** ADR 0022's stays-upstream exemption already covers this guest's refs; Zot mirrors nothing here. A rebuild re-pulls from Docker Hub by digest.

## As built (2026-09-16)

Landed. All six acceptance checks pass; the numbers reproduce the b70-bench ledger through Caddy with a per-client key: **61.2 t/s single stream, 56.0 t/s per stream at two streams** on 4k prompts (ledger: 61.2 and 56.7), TTFT 2.0 s, and the full sweep gives 63.7 / 57.1 / 50.9 short and 60.4 / 52.5 / 40.3 long at 1 / 2 / 4 streams. A second `make ansible llm` is 0 changed and both units come back in the right order after a reboot with no hand start. `/data` fell from ~75 % to 18 % once Docker's stores came off it; the weights disk holds everything at 46 % of 295 GB.

### Four defects the cutover exposed, each fixed in the role

1. **containerd kept the old content store open.** `data-root` in `daemon.json` does not cover it, so the move needs a `/var/lib/containerd` symlink *and* a containerd restart. Restarting docker alone failed every pull with `failed to lease content: ... blob not found`, which reads like a bad digest and is not.
2. **Handlers flushed after the engine started.** The engine reads free VRAM at init, so an embedder still holding the previous model left it short — `Free memory on device xpu:0 (24.57/31.89 GiB) ... less than desired (0.9, 28.7 GiB)`. Handlers now flush first.
3. **A handler could not fix (2) anyway.** Once a failed run had written the new unit file, the template task reported `ok`, nothing notified, and the embedder kept serving the old model. The role now asks the embedder *which model it is serving* and restarts it when that is not the declared one — state, not file convergence.
4. **The warm-up's abort check raced its own container.** `ExecStartPre` removes the old container on a restart, so "not running" means "not created yet" for the first seconds; treating it as fatal killed the unit the instant it was asked to restart. It is now fatal only after the container has been seen running. The start limit also moved from an hour to 15 minutes, because three init failures locked the unit out and a latched unit hides whether the next fix worked.

### A fifth defect, found by a client rather than by the acceptance tests

code-intelligence's first real embedding request core-dumped `llama-embed` twice. Two compounding mistakes, both mine:

- I had **widened** CLAUDE.md's hard-won `-ub 2048` rule to the bench's `-ub 8192` on the strength of a measurement taken with ~900-token chunks and no engine competing for the card. Beside an engine holding 0.90, the SYCL flash-attention path cannot reserve its scratch from the VMM pool and llama-server **aborts** rather than refusing the request, so a client's input size crashes the service. `-ub 2048` is restored, and the rule now says a bench number is not licence to raise it.
- Even at 2048 the embedder aborted after a clean boot, because the scratch is allocated **lazily and retained**: 0.96 GB idle, 2.66 GB after a real batch. Starting the embedder first is not enough if the engine measures free memory before that growth happens — the engine takes 28.7 GiB of a card that still looks empty. `llama-embed` now has an `ExecStartPost` warm-up driving one full micro-batch, and the engine gates on `systemctl is-active llama-embed` rather than its `/health`, which is up before `ExecStartPost` finishes.

Verified after a clean reboot at the client's own shapes: 5x200 tokens, 25 chunks, 5x1500 chars, and a 30-chunk 51,180-token maintenance batch all return 1024-dim vectors, with acceptance still 6/6.

**The lesson worth keeping:** the acceptance tests passed throughout. A one-word embedding probe proves the alias and the dimension and nothing about the working set. A client sending real data found this in under an hour.

### Answers the two client sessions needed, read from the running engine

- `chat_template_kwargs {"enable_thinking": false}` **is** honoured (4 tokens and a bare answer, against 68 tokens of reasoning without it).
- **No reasoning parser is configured** (`reasoning_parser=''`), so with thinking on the reasoning arrives inline in `content`, the `reasoning` field is null, and there is no `completion_tokens_details`.
- **Prefix caching is off** (`enable_prefix_caching=False`): the same 12,001-token prompt sent twice reported 12,001 prompt tokens both times, hit rate 0.0 %, and `usage.prompt_tokens_details` is `null`, so `cached_tokens` is not reported.
- **The two engines contend.** With the embedder saturated (16,766 requests during a sweep) chat decode fell from 52.5 to 36.2 t/s per stream at 2 streams and 40.3 to 25.8 at 4. A bulk re-embed roughly halves chat throughput while it runs.

### Open: one unexplained wedge

The engine wedged once, at 00:06:40Z: `/health` kept answering 200 and the API server kept logging, while no request completed and the GPU span at 22 % with zero requests running. No `xe` hang or reset in dmesg. It recovered fully on `systemctl restart vllm` and **could not be reproduced** in four deliberate attempts — single and repeated chat requests, the full 1/2/4-stream sweep, the sweep under saturated embedding load, and clients killed mid-request.

Two things follow whatever the cause turns out to be. **`/health` cannot detect this**, so neither the Kuma row nor systemd would have noticed; a liveness check that costs the engine a token is the only kind that would. And the main consumer is an unattended timer, so a wedge would present as a hung job rather than a failed one.

**Resolved by operator decision, 2026-09-16:** a watchdog was added. `vllm-liveness.timer` sends a 4-token generation every 5 minutes and restarts the engine after **two** consecutive failures — one is not enough, because a request can legitimately queue behind a long generation. The cause of the wedge itself remains open; the watchdog bounds its blast radius to about ten minutes instead of until someone notices.

Adding it also exposed a coupling worth stating plainly: **the embedder cannot be restarted while the engine is up.** The engine holds 0.90 of the card, so the embedder has nowhere to re-allocate its 2.66 GB pool and aborts. `vllm.service` now carries `PartOf=llama-embed.service`, so an embedder restart cycles the engine and the existing `After=` orders it — engine down, embedder restarts and warms, engine back up sizing against the warmed card.

The five llama.cpp GGUFs (84 GB) are **deliberately still on disk** despite the gate's decision to remove them: they are the rollback, and deleting them before the operator has used the new engine would trade a reversible change for an irreversible one. They come off on sign-off.
