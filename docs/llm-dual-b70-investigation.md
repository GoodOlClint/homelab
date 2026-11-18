# Dual B70 communication investigation — 2026-11-18

Status: communication failure isolated and a working two-GPU workaround demonstrated; production adoption rejected on the existing performance criteria. This records the Codex investigation after the handover from the Claude testing session. The earlier experiment matrix is in [the change plan](llm-dual-b70-plan.md). Final service restoration is recorded below.

The shared virtual bridge does not enable correct GPU-to-GPU transfers on this system. It changes peer-access eligibility, but our transfers return corrupted bytes and trigger host DMA faults. Correct two-GPU collectives and vLLM generation work on the original separate-root-port layout with `CCL_ENABLE_SYCL_KERNELS=0 CCL_TOPO_ALGO=0` and `--enforce-eager`. This bypasses the failing peer-transfer route through host-staged collectives. It does not repair physical peer DMA. Graph execution with the same settings produces invalid answers and must not be used for this workaround.

## Verified environment

VM 240 (`llm`) runs Ubuntu 26.04.1, kernel `7.0.0-43-generic`, with 6 virtual CPUs and 48 GiB of RAM. The user brief's Ubuntu 24.04 description does not match the live guest. The container has Ubuntu 24.04 runtime packages. Both GPUs use the guest `xe` driver and GuC firmware `70.58.0`.

The served image is `intel/llm-scaler-vllm@sha256:52218ad85513ab6686d4c090c83c2bd8c5b02423c63aa4dabd41837fe641fe3b`. Installed metadata reports vLLM `0.26.1.dev0+g568afb3a1.d20260907.xpu`, PyTorch `2.12.0+xpu`, `vllm-xpu-kernels` `0.1.11.2.dev0+ga692986.d20260907`, and Intel SYCL runtime `2025.3.2`. The earlier B1 full log identifies oneCCL `Gold-2021.15.9`, build `HEAD/145258356`.

Actual vLLM process mappings include `/opt/intel/oneapi/ccl/2021.15/lib/libccl.so.1.0`, `/opt/venv/lib/libsycl.so.8`, `/opt/intel/oneapi/compiler/2025.3/lib/libur_adapter_level_zero.so.0.12.0`, `/usr/lib/x86_64-linux-gnu/libze_intel_gpu.so.1.15.37833`, and `/usr/lib/x86_64-linux-gnu/libze_loader.so.1.28.2`. Container packages are `libze-intel-gpu1=26.14.37833.4-1~24.04~ppa1` and `libze1=1.28.2-1~24.04~ppa1`. The guest package version recorded by the earlier benchmark, `26.31.39395.13-1~26.04~ppa1`, does not identify the driver loaded inside vLLM.

The image entrypoint sources oneAPI and oneCCL before starting vLLM. The running process has `CCL_ROOT=/opt/intel/oneapi/ccl/2021.15` and the associated library search path; the engine process also has `UR_ENABLE_LAYERS=UR_LAYER_TRACING`. An empty interactive-shell environment was therefore not a runtime inventory. The served unit has no tensor-parallel flag and remains configured for one GPU.

## Topology and host observations

Host `msi` runs kernel `7.0.14-29-pve` and QEMU `11.1.3` (`pve-qemu-kvm_11.1.3-2`). Physical GPUs `03:00.0` and `07:00.0` bind to `vfio-pci` and occupy IOMMU groups 24 and 29. An IOMMU translates and restricts device memory accesses. Their physical upstream paths lead to separate CPU root ports `00:01.0` and `00:01.1`; both links report PCIe 5.0, eight lanes. Both root ports have ACS request and completion redirection enabled; ACS is PCIe access-control routing. No ACS or IOMMU settings have been changed by this investigation.

The inherited shared-switch configuration removes `hostpci0/1` and injects these QEMU arguments:

```text
-device x3130-upstream,id=sw_up,bus=ich9-pcie-port-3
-device xio3130-downstream,id=sw_dn1,bus=sw_up,chassis=21,slot=1
-device xio3130-downstream,id=sw_dn2,bus=sw_up,chassis=22,slot=2
-device vfio-pci,host=0000:03:00.0,id=gpu0,bus=sw_dn1,addr=0x0
-device vfio-pci,host=0000:07:00.0,id=gpu1,bus=sw_dn2,addr=0x0
```

The guest enumerates the GPUs as `05:00.0` and `06:00.0`. This changes the topology seen by the guest kernel; it does not physically connect the GPUs through a shared switch.

The host boot log reports a 39-bit host address width. Host faults during earlier runs and the independent copy probes report `Access beyond MGAW` (maximum guest-address width), including `0x427f8400000` during the copy probe. These are real host DMA faults. Their addresses are outside the guest GPU BARs (PCI memory windows) at `0x382000000000` and `0x381000000000`; deriving them from BAR placement is still unproven.

## Handover recovery

The handover initially said that the `host-phys-bits-limit=39` experiment had not applied. Direct captures of both `qm config 240` and the running QEMU process proved that it had applied as a second `-cpu` argument. The guest agent was unavailable and a QEMU console capture showed that the guest had not initialized the display. Claude subsequently acknowledged that its interrupted SSH command had applied the change.

Codex stopped the pre-boot-stalled VM, removed only that appended CPU override, set `cpu: host`, and restarted VM 240. SSH and the guest agent returned. The shared-switch topology remained unchanged. This recovers a bootable state; it does not validate two-GPU communication.

Before GPU probes, `systemctl stop vllm` timed out and left the Docker container running. `docker stop -t 10 vllm` removed that remaining container. The embedder remained active. All probes run serially in a separate `b70-diag` container using the exact served image, `/dev/dri`, the read-only `/dev/dri/by-path` mount, and `SYS_PTRACE` capability for the previously verified process-ID file-descriptor exchange path. The service definition and model files are unchanged.

## Independent communication results

The [Level Zero C++ probe](../scripts/diagnostics/b70-level-zero-probe.cpp) uses the installed API headers and loader, synchronous immediate command lists, nonuniform byte patterns, and full-buffer comparison. Each source GPU first passes a host-to-device-to-host control copy. Tests allocate only 4 MiB per device. The [PyTorch collective probe](../scripts/diagnostics/b70-collective-probe.py) tests the installed XCCL backend (PyTorch's Intel collective-communication backend). Copies remain in `/home/goodolclint/b70-diag/` on the guest.

| Test | Shared-switch result |
|---|---|
| `zeDeviceCanAccessPeer`, both directions | Success, capability true in both directions |
| Same-device round trip, each GPU, 4 KiB and 4 MiB | Every byte matches |
| GPU 0 to GPU 1, 4 KiB and 4 MiB | API calls return success; integrity fails; sampled returned bytes are `0xff` |
| GPU 1 to GPU 0, 4 KiB and 4 MiB | API calls return success; integrity fails; sampled returned bytes are `0xff` |
| Host kernel during peer-copy probes | GPU DMA requests fail with `Access beyond MGAW` |
| Default XCCL all-reduce with working handle-exchange permissions | Process group initializes; first one-element reduction hangs until the 120-second timeout |
| Explicit GPU → CPU Gloo reduction → GPU control | All 54 cases pass on both ranks (108 exact-result checks) |
| XCCL with `CCL_ENABLE_SYCL_KERNELS=0 CCL_ALLREDUCE=recursive_doubling` | All 54 cases pass on both ranks (108 checks) |
| XCCL with `CCL_ENABLE_SYCL_KERNELS=0 CCL_TOPO_ALGO=0` | All-reduce, all-gather, reduce-scatter, and broadcast pass (156 checks across both ranks) |

This establishes a failing device-to-device transfer path below both vLLM and oneCCL. A true peer-capability flag, disappearance of the guest's kernel rejection, successful memory import, or successful API return is not proof of correct transferred data.

The collective probe uses two ranks (one process per GPU), single-precision, half-precision and brain floating-point tensors (`float32`, `float16`, `bfloat16`), six lengths from one to 4,194,304 elements, and three repetitions. Inputs differ by rank and element; every result is synchronized, copied back to CPU memory, and checked exactly. Gather, reduce-scatter and broadcasts from both roots are additionally checked at 31 and 32,768 elements for each type. No model or vLLM code participates.

The compact successful setting disables both the SYCL collective-kernel path and topology algorithms. Earlier E1 disabled only topology algorithms and produced invalid model answers. Logs confirm that the installed library recognizes both settings. `CCL_ZE_IPC_EXCHANGE=pidfd` and the container's `SYS_PTRACE` capability are held constant in these tests.

After these results, the original separate-root-port layout was restored for comparison: delete `args`, set `hostpci0: 0000:03:00.0,pcie=1` and `hostpci1: 0000:07:00.0,pcie=1`. Expected benefit: remove the shared switch's false peer-access eligibility while retaining the verified host-memory communication route. OVMF, RAM, and the CPU model are unchanged. The previously enabled vLLM service was temporarily disabled before this restart to prevent automatic GPU initialization during the probes; it was re-enabled and started after testing.

On the restored layout the GPUs enumerate at `01:00.0` and `02:00.0`, and Level Zero correctly reports peer access unavailable in both directions. The same two-setting XCCL configuration passes all 156 checks. Direct GPU peer access is therefore unnecessary for correct tensor parallelism with these host-staged algorithms.

## First meaningful failures and discriminating verification

The complete earlier B1 vLLM log reaches distributed initialization with `backend=xccl`, then fails on the first model profiling reduction, through `XpuCommunicator.all_reduce` and `self.device_group.allreduce`. Its useful error is:

```text
RuntimeError: oneCCL: ze_call.cpp:28 do_call: EXCEPTION: ze error at zeMemOpenIpcHandle, code: ZE_RESULT_ERROR_INVALID_ARGUMENT
```

The later shared-switch test changes the symptom. Our independent probe initializes both ranks and stalls on the first scalar all-reduce, without a preceding exception. Removing vLLM from the experiment preserves the failure. Direct Level Zero copies separately demonstrate corrupt data and host DMA rejection.

Observable claim: on the shared-switch layout and identical image, permissions and exchange method, the same collective probe fails to complete its first all-reduce with defaults and completes with exact answers after disabling both SYCL collective kernels and topology algorithms. The passing probe additionally includes gather, reduce-scatter and broadcast checks.

Pre-change excerpt, `/tmp/b70-shared-xccl.log`:

```text
2026-11-18T19:53:22.220208+00:00 rank=1 group ready
2026-11-18T19:53:22.220214+00:00 rank=0 group ready
2026-11-18T19:53:22.222538+00:00 rank=0 begin dtype=torch.float32 elements=1 iteration=0
2026-11-18T19:53:22.329564+00:00 rank=1 begin dtype=torch.float32 elements=1 iteration=0
PROBE_EXIT=124
```

Post-change excerpt, `/tmp/b70-shared-xccl-all-collectives.log`:

```text
2026-11-18T19:56:34.720287+00:00 rank=1 ALL CASES PASS
2026-11-18T19:56:34.720303+00:00 rank=0 ALL CASES PASS
PROBE_EXIT=0
```

The exit value 124 means the external 120-second timeout expired; zero means successful completion. The log contains zero successful integrity checks before the change and 156 afterwards. The original-root-port confirmation also contains 156 passes and exits zero.

DoD DISCRIMINATES: pre fails as predicted, post passes

## vLLM validation

G1 uses the existing `llm-bench/scripts/tp-bench-remote.sh` harness, the served image and model, two GPUs, eager execution, four speculative tokens, prefix caching, and the active embedder. Startup completes in 80 seconds. The attention cache holds 984,482 tokens versus the historical single-GPU 255,172. Arithmetic returns `391` for 17 times 23; the first five primes and rainbow colors are correct. Reasoning and answer fields are separate, and the repeated-prefix test reports 2,048 cached tokens. The banana-reversal sample reaches its 64-token limit before finishing, so it is not counted as a passed answer check.

| Concurrent streams | Short-prompt decode, tokens/second per stream | 4,078-token prompt decode, tokens/second per stream |
|---|---:|---:|
| 1 | 47.4 | 33.9 |
| 2 | 22.9 | 32.3 |
| 4 | 34.8 | 22.7 |

These are one harness pass, with compilation warnings during inference; they are not steady-state performance estimates. Nevertheless they do not meet the plan's adoption thresholds against the recorded single-GPU baseline.

G2 changes only to graph execution, with the same communication settings, speculation and prefix caching. It starts in 61 seconds and generates tokens, but speculative acceptance is zero throughout. The arithmetic request fills the reasoning field and returns no answer. All three short answer samples produce corrupted multilingual text instead of primes, colors or reversed letters. Thus graph execution is rejected despite successful startup and a passing cache-counter check. Its four-stream long-prompt decode rate is 14.8 tokens/second per stream; these invalid outputs must not be treated as useful performance. Device process accounting also shows roughly 9 GiB of GPU-mapped system memory per worker, compared with roughly 1–1.6 GiB in eager execution.

The graph-related corruption is a separate observed failure at the captured model-execution layer. Its internal cause was not isolated; assuming that a successful collective outside graph capture guarantees correct captured execution would be unjustified. The tested workaround explicitly uses `--enforce-eager` and omits `VLLM_XPU_ENABLE_XPU_GRAPH=1`.

## Handback and remaining limits

The original separate-root-port topology is retained, with OVMF, `cpu: host`, 6 virtual CPUs and 48 GiB RAM. No ACS, IOMMU, firmware, driver, container-image, model or production service-definition change was made. The failed 39-bit CPU override and shared virtual switch are removed. Both diagnostic model containers were removed by the benchmark harness; the stopped `b70-diag` container was removed explicitly. The single-GPU vLLM service is enabled and active after its warmup, and `llama-embed` is active. A final real chat request returns exactly `391` for 17 times 23; the embedding endpoint returns 1,024 finite values with nonzero content. Docker lists only the normal `vllm` container running.

The testing-owned Ceph `noout` flag, which temporarily prevents unavailable storage daemons from being marked out, was cleared. Ceph returns `HEALTH_OK`, with all eight storage daemons up and in and all 193 placement groups active and clean.

Host kernel logs queried after the original-layout collective and model tests contain no new matching DMA faults. Guest logs still report that the devices do not share an upstream or whitelisted host bridge; the passing collectives demonstrate that this kernel eligibility rejection does not block the chosen host-memory route.

The precise physical/virtual address translation that produces the out-of-range peer DMA requests remains unresolved. Nothing here proves that disabling ACS or IOMMU would fix it. Bare-metal peer transfer was not tested, nor were runtime upgrades or the plan's 20-generation, five-minute-spacing endurance gate. The normal single-GPU configuration remains the production choice because the demonstrated eager workaround falls below the existing speed thresholds. The reproducible two-GPU route is available for further evaluation without another topology change.

Pipeline conformance: CONFORMANT. Model performance and answer checks use the existing benchmark harness. The added probes test lower-level memory transfer and collectives, and do not replace the served deployment or benchmark pipeline.

## Reproduce the working communication route

Run one experiment at a time. Stop the chat service before starting a probe container; keep the existing embedder active and warm. The commands below assume the two probe sources have been copied to `$HOME/b70-diag` on the guest. They use the tested image without installing or upgrading packages.

```bash
sudo systemctl stop vllm
sudo docker run -d --name b70-diag --device /dev/dri \
  -v /dev/dri/by-path:/dev/dri/by-path:ro --cap-add=SYS_PTRACE \
  --shm-size=1g -v "$HOME/b70-diag:/diag" --entrypoint /bin/bash \
  intel/llm-scaler-vllm@sha256:52218ad85513ab6686d4c090c83c2bd8c5b02423c63aa4dabd41837fe641fe3b \
  -c 'exec sleep infinity'
sudo docker exec b70-diag g++ -O2 -Wall -Wextra \
  /diag/b70-level-zero-probe.cpp -lze_loader -o /diag/ze-probe
sudo docker exec b70-diag /diag/ze-probe
sudo docker exec \
  -e CCL_ZE_IPC_EXCHANGE=pidfd -e CCL_LOG_LEVEL=info \
  -e CCL_ENABLE_SYCL_KERNELS=0 -e CCL_TOPO_ALGO=0 \
  b70-diag bash -lc '
    source /opt/intel/oneapi/setvars.sh --force >/dev/null
    source /opt/intel/oneapi/ccl/2021.15/env/vars.sh --force >/dev/null
    timeout -k 10s 120s torchrun --standalone --nproc-per-node=2 /diag/b70-collective-probe.py xccl
  '
sudo docker stop b70-diag
```

Expected: peer capability false in both directions on the original layout, followed by 156 integrity passes, `ALL CASES PASS` from each rank, and exit zero for the collective command. The stopped diagnostic container can be removed before another run. `ze-probe copy` performs the data-integrity test when capability is true; it returns 5 on corrupt copies or 6 when cross-device access is unavailable. A false capability should not be overridden to force a copy.

To reproduce the successful model run with the existing benchmark harness on `llm`, after stopping the diagnostic container:

```bash
cd /home/goodolclint/tp-bench
sudo env GRAPH=0 MTP=1 STREAMS='1 2 4' NO_RESTORE=1 \
  EXTRA_ENV='CCL_ZE_IPC_EXCHANGE=pidfd CCL_ENABLE_SYCL_KERNELS=0 CCL_TOPO_ALGO=0' \
  EXTRA_DOCKER='--cap-add=SYS_PTRACE' \
  timeout -k 20s 900s bash ./tp-bench-remote.sh G1-hoststage-eager
```

The harness adds `--tensor-parallel-size 2 --enforce-eager` to the existing model configuration. `NO_RESTORE=1` leaves the chat service stopped afterwards, as required between serial experiments; after the final test restore it with `sudo systemctl enable --now vllm` and wait for the unit to become `active` before a real completion request. Do not treat the harness exit code alone as a correctness verdict: its printed answer checks must also be examined. `pidfd` and `SYS_PTRACE` are retained from the verified setup, not claimed necessary to every host-staged algorithm.

## Runtime controls and references

`CCL_ZE_IPC_EXCHANGE=sockets` selects how processes exchange Level Zero IPC (interprocess communication) handles. It does not itself select a host-memory data path. Intel's llm-scaler README calls `CCL_TOPO_P2P_ACCESS=0` USM mode (unified shared memory); earlier tests still reached failing memory imports with that setting. The installed oneCCL log confirms that `CCL_ENABLE_SYCL_KERNELS` is enabled by default and that algorithm-selection controls exist. Host-staging tests must verify both the selected implementation and the reduced values.

- [Intel oneCCL environment variables](https://www.intel.com/content/www/us/en/docs/oneccl/developer-guide-reference/2021-15/environment-variables.html): IPC exchange and non-topology collective algorithms that stage GPU buffers through host memory.
- [Intel llm-scaler CCL modes](https://github.com/intel/llm-scaler/blob/main/vllm/README.md#21-ccl-support-both-p2p--usm): image-specific P2P and USM controls.
- [Linux PCI peer-to-peer DMA documentation](https://cdn.kernel.org/doc/html/latest/driver-api/pci/p2pdma.html): kernel topology eligibility and routing limitations.
- [OVMF runtime configuration](https://qemu.googlesource.com/edk2/+/refs/heads/master/OvmfPkg/RUNTIME_CONFIG.md): CPU address width controls firmware PCI memory placement. This documents a hypothesis to test, not a working fix here.

## Captures

Workstation logs: `/tmp/b70-qemu-config.log`, `/tmp/b70-host-topology.log`, `/tmp/b70-host-dmar-acs.log`, `/tmp/b70-handoff-state.log`, `/tmp/b70-installed-runtime.log`, `/tmp/b70-shared-ze-peer.log`, `/tmp/b70-shared-ze-bidirectional.log`, `/tmp/b70-shared-probe-host-faults.log`, `/tmp/b70-shared-xccl.log`, `/tmp/b70-shared-explicit-hoststage.log`, `/tmp/b70-shared-xccl-all-collectives.log`, `/tmp/b70-original-ze-peer.log`, and `/tmp/b70-original-xccl-all-collectives.log`. Complete earlier initialization logs were copied to `/tmp/B1-ptrace-pidfd.full.log` and `/tmp/F1-hang.full.log`.

Model result logs are `/tmp/b70-G1-hoststage-eager.log` and `/tmp/b70-G2-hoststage-graph.log`; full distributed initialization and inference logs are `/tmp/b70-G1-vllm-full.log` and `/tmp/b70-G2-vllm-full.log`. Host/guest follow-up logs are `/tmp/b70-post-original-host.log` and `/tmp/b70-post-original-guest.log`. Restoration results are `/tmp/b70-service-restoration.log`, `/tmp/b70-final-generation-check.log` and `/tmp/b70-final-ceph-health.log`. These temporary files are operational captures, not a durable archive; the report retains the conclusion, discriminating excerpts, parameters and reproduction instructions.
