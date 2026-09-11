# llm bench results (tranche 1b, plan §7.9)

Appended by `scripts/llm-bench.sh <label>`; one block per run with provenance. Never edit rows by hand.

## smoke — tiny run to prove the harness — 2026-09-11T21:49:24Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3-30B-A3B-Q4_K_M.gguf sha256:9f1a24700a339b09c06009b729b5c809e0b64c213b8af5b711b3dbdfd0c5ba48 · threads: 6 · n-cpu-moe: 40 · extra args: -p 32 -n 16 -r 1 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-blas.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-zendnn.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-cann.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-cuda.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-hip.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-metal.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-rpc.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-sycl.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-vulkan.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-virtgpu.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-opencl.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-hexagon.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-musa.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-openvino.so) failure, error-message: Permission denied
ggml_backend_load_best: posix_stat(/home/goodolclint/libggml-cpu.so) failure, error-message: Permission denied
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           pp512 |        233.82 ± 0.00 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |          pp8192 |        235.41 ± 0.00 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |            pp32 |         27.14 ± 0.00 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           tg128 |         30.80 ± 0.00 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |            tg16 |         29.61 ± 0.00 |

build: 5266f24da (10809)

## baseline — JEDEC 4000 MT/s, cpu host, 6 P-cores, n-cpu-moe 40, power 230 W — 2026-09-11T21:52:14Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3-30B-A3B-Q4_K_M.gguf sha256:9f1a24700a339b09c06009b729b5c809e0b64c213b8af5b711b3dbdfd0c5ba48 · threads: 6 · n-cpu-moe: 40 · extra args: none · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           pp512 |        264.92 ± 3.64 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |          pp8192 |        271.69 ± 2.14 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           tg128 |         37.02 ± 0.26 |

build: 5266f24da (10809)
