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

## sweep — n-cpu-moe 24, JEDEC 4000, 230 W — 2026-09-11T21:55:28Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3-30B-A3B-Q4_K_M.gguf sha256:9f1a24700a339b09c06009b729b5c809e0b64c213b8af5b711b3dbdfd0c5ba48 · threads: 6 · n-cpu-moe: 40 · extra args: --n-cpu-moe 24 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           pp512 |        264.88 ± 4.02 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |          pp8192 |        271.27 ± 2.03 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           tg128 |         36.97 ± 0.95 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |           pp512 |        373.11 ± 4.06 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |          pp8192 |        378.37 ± 1.53 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |           tg128 |         50.86 ± 0.29 |

build: 5266f24da (10809)

## sweep — n-cpu-moe 16, JEDEC 4000, 230 W — 2026-09-11T21:59:54Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3-30B-A3B-Q4_K_M.gguf sha256:9f1a24700a339b09c06009b729b5c809e0b64c213b8af5b711b3dbdfd0c5ba48 · threads: 6 · n-cpu-moe: 40 · extra args: --n-cpu-moe 16 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           pp512 |        264.08 ± 4.24 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |          pp8192 |        271.50 ± 1.97 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           tg128 |         37.45 ± 0.14 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |           pp512 |        487.27 ± 5.31 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |          pp8192 |        485.84 ± 1.90 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |           tg128 |         62.90 ± 0.94 |

build: 5266f24da (10809)

## smoke-3.6-35B — arch load check — 2026-09-11T22:33:36Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3.6-35B-A3B-UD-Q4_K_M.gguf sha256:ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61 · threads: 6 · ngl: 99 · n-cpu-moe: 24 · extra args: -p 32 -n 16 -r 1 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |           pp512 |        304.46 ± 0.00 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |          pp8192 |        297.40 ± 0.00 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |            pp32 |         51.21 ± 0.00 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |           tg128 |         51.51 ± 0.00 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |            tg16 |         48.87 ± 0.00 |

build: 5266f24da (10809)

## Qwen3.6-35B-A3B — n-cpu-moe 24/20/16, JEDEC 4000, 230 W — 2026-09-11T22:41:44Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3.6-35B-A3B-UD-Q4_K_M.gguf sha256:ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61 · threads: 6 · ngl: 99 · n-cpu-moe: 24 · extra args: --n-cpu-moe 20 --n-cpu-moe 16 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |           pp512 |        311.56 ± 5.98 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |          pp8192 |        297.34 ± 0.20 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         24 |   1 |           tg128 |         54.21 ± 0.27 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         20 |   1 |           pp512 |        348.80 ± 7.75 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         20 |   1 |          pp8192 |        344.34 ± 1.44 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         20 |   1 |           tg128 |         57.38 ± 0.67 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         16 |   1 |           pp512 |        405.51 ± 2.70 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         16 |   1 |          pp8192 |        395.48 ± 0.84 |
| qwen35moe 35B.A3B Q4_K - Medium |  20.60 GiB |    34.66 B | CUDA       |  99 |         16 |   1 |           tg128 |         62.22 ± 0.44 |

build: 5266f24da (10809)

## probe-3.8-27B — ngl 60 ceiling check — 2026-09-11T22:48:16Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3.8-27B-UD-Q4_K_M.gguf sha256:322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482 · threads: 6 · ngl: 60 · n-cpu-moe: n/a (dense) · extra args: -p 32 -n 16 -r 1 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |           pp512 |        443.36 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |          pp8192 |        436.22 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |            pp32 |         87.93 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |           tg128 |         13.62 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |            tg16 |         13.11 ± 0.00 |

build: 5266f24da (10809)

## probe-3.8-27B — ngl 64 full-offload check — 2026-09-11T22:49:50Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3.8-27B-UD-Q4_K_M.gguf sha256:322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482 · threads: 6 · ngl: 64 · n-cpu-moe: n/a (dense) · extra args: -p 32 -n 16 -r 1 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |           pp512 |        519.10 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |          pp8192 |        510.17 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |            pp32 |        180.52 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |           tg128 |         17.64 ± 0.00 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |            tg16 |         17.99 ± 0.00 |

build: 5266f24da (10809)

## Qwen3.8-27B dense — ngl 64/60/56, JEDEC 4000, 230 W — 2026-09-11T22:51:24Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3.8-27B-UD-Q4_K_M.gguf sha256:322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482 · threads: 6 · ngl: 64 · n-cpu-moe: n/a (dense) · extra args: -ngl 60 -ngl 56 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |           pp512 |        538.11 ± 3.54 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |          pp8192 |        507.93 ± 2.10 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  64 |   1 |           tg128 |         17.22 ± 0.40 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |           pp512 |        451.96 ± 4.84 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |          pp8192 |        432.85 ± 2.73 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  60 |   1 |           tg128 |         12.76 ± 0.56 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  56 |   1 |           pp512 |       387.97 ± 19.52 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  56 |   1 |          pp8192 |        377.18 ± 1.95 |
| qwen35 27B Q4_K - Medium       |  15.32 GiB |    27.32 B | CUDA       |  56 |   1 |           tg128 |         10.29 ± 1.23 |

build: 5266f24da (10809)

---

## Findings — candidate-model evaluation, 2026-09-11 (JEDEC 4000 MT/s, 230 W, 6 P-cores)

Measured outside the `llama-bench` harness where noted. All three GGUFs are pinned to an HF
revision + LFS oid and verified by sha256 on download, the same provenance rule the role's
default model follows.

### Model geometry (why the old sweep points do not transfer)

| model | layers | shape | GGUF |
| --- | --- | --- | --- |
| Qwen3-30B-A3B (serving default) | 48 | MoE, 128 experts | 17.28 GiB Q4_K_M |
| Qwen3.6-35B-A3B | 40 | MoE, 256 experts, 2 KV heads | 20.60 GiB UD-Q4_K_M |
| Qwen3.8-27B | 64 | dense, head_dim 256, 4 KV heads | 15.32 GiB UD-Q4_K_M |

`--n-cpu-moe 40` means *all* layers on the 35B but 40-of-48 on the 30B — the baseline's sweep
points are not comparable across the two without rescaling.

### tg128 / pp512 at matched n-cpu-moe

| model | n-cpu-moe | pp512 | pp8192 | tg128 |
| --- | ---: | ---: | ---: | ---: |
| Qwen3-30B-A3B | 24 | 373.1 | 378.4 | 50.9 |
| Qwen3-30B-A3B | 16 | 487.3 | 485.8 | 62.9 |
| Qwen3.6-35B-A3B | 24 | 311.6 | 297.3 | 54.2 |
| Qwen3.6-35B-A3B | 20 | 348.8 | 344.3 | 57.4 |
| Qwen3.6-35B-A3B | 16 | 405.5 | 395.5 | 62.2 |

The 35B matches the 30B's token generation (62.2 vs 62.9) for ~17 % less prompt throughput,
at 15 % more parameters — it has 8 fewer layers and half the KV heads, which offsets its size.

### The dense lesson (Qwen3.8-27B, no MoE tensors, `-ngl` sweep)

| -ngl | CPU layers | pp512 | tg128 |
| ---: | ---: | ---: | ---: |
| 64 | 0 | 538.1 | 17.2 |
| 60 | 4 | 452.0 | 12.8 |
| 56 | 8 | 388.0 | 10.3 |

Dense prompt processing is the best of any model here (538 pp512, GPU compute-bound), and
generation is the worst by 3.5x — every token streams all 15.32 GiB of weights instead of the
MoE's ~3 B active parameters. Four CPU layers out of 64 cost a quarter of the token rate.
Fully GPU-resident tg128 of 17.2 t/s against 15.32 GiB implies **283 GB/s achieved, 63 % of the
card's 448 GB/s** — the dense case is purely memory-bandwidth-bound, not compute-bound.
It is also not servable at the fleet's 32k context: 15.32 GiB of weights plus a ~4.5 GB q8 KV
exceeds the 15.55 GiB card, so real serving would force CPU layers and land near 13 t/s.

### MTP is inert on the pinned build — do not adopt

`llama-bench` has no speculative-decoding support at all, so MTP can only be measured
server-side. Against a real `llama-server` at 32k, `--n-cpu-moe 20`, 256 predicted tokens:

| build | tg (3 reps) |
| --- | --- |
| Qwen3.6-35B-A3B plain | 55.12 / 55.15 / 55.41 |
| Qwen3.6-35B-A3B MTP | 51.24 / 55.61 / 55.91 (first rep cold) |

Identical within noise, because the server logs
`model has unused tensor blk.40.nextn.eh_proj.weight -- ignoring`: build 5266f24da loads the
nextn tensors and never uses them. The upstream 1.5–2x claim needs a runtime that implements
nextn self-drafting for `qwen35moe`; this one does not. The MTP GGUF is 530 MB of dead weight.
Re-test only after a deliberate llama.cpp roll that lands the feature.

### Serving ceiling at the real 32k q8 KV (llama-bench's ceiling is optimistic)

| n-cpu-moe | loads at 32k | VRAM used | headroom |
| ---: | --- | --- | ---: |
| 20 | yes | 12470 / 16384 MiB | 3.9 GB |
| 16 | yes | 14328 / 16384 MiB | 2.0 GB |
| 12 | **out of memory** | — | — |

### Harness changes made for this run

- `LLM_BENCH_MODEL` / `LLM_BENCH_NGL` / `LLM_BENCH_NCPU` override what the live unit serves, so a
  candidate model is benched without touching the unit. `LLM_BENCH_NCPU=` (empty) drops
  `--n-cpu-moe` entirely, which a dense model requires — it has no MoE tensors to place.
- The restart trap now runs `systemctl reset-failed` first. A back-to-back bench series trips
  systemd's start rate limit (`start-limit-hit`), which silently left the box serving nothing.

### KV-cache scaling vs context — does a bigger card remove the DDR dependency? (2026-09-11)

Measured on Qwen3.6-35B-A3B at a fixed `--n-cpu-moe 32`, sweeping `-c` and reading VRAM.

| ctx | VRAM | Δ vs previous |
| ---: | ---: | ---: |
| 32768 | 6904 MiB | — |
| 65536 | 7276 MiB | +372 |
| 131072 | 8108 MiB | +832 |
| 262144 | 9852 MiB | +1744 |

Slope is **~13.1 KiB/token**, about 3.2x cheaper than the naive
40 layers x 2 KV heads x 256 head_dim x q8 arithmetic (42.5 KiB/token). The shortfall is
consistent with most layers using sliding-window attention and only a subset retaining a full
KV cache — inferred from the slope, not confirmed against the model config.

Derived constants, all from measurement: **464.5 MiB per expert layer** (the n-cpu-moe 20 vs 16
VRAM delta at 32k, 1858 MiB / 4 layers), 2.46 GiB non-expert weights, ~250 MiB compute buffers.
These predict the 32k / n-cpu-moe 32 load to within 8 MiB (6896 predicted vs 6904 measured).

Extrapolated to a 24 GB card at `n-cpu-moe 0` (all experts resident): ~21.3 GiB at 32k, ~22.4 GiB
at 128k, hitting the 24 GB ceiling near 240k. **So a 24 GB card removes the system-RAM expert
path for this model across its whole practical context range, and with it the XMP payoff** —
KV never grows expensive enough to push experts back into DDR.

XMP retains its full value for (1) the planned gpt-oss-120b lane, which cannot fit 24 GB at any
context and therefore keeps its experts in DDR permanently, (2) serving near the 262k maximum,
where the ceiling above is marginal, and (3) any future model above ~20 GiB of weights.
Sequencing consequence: the XMP evening's worth is tied to the 120B lane, not to the 35B.

Method note: a first attempt produced identical VRAM at every context. The run had died at a
non-matching `grep` under `set -o pipefail` *before* its `kill`, leaving a 32k server bound to the
port; every later server then failed to bind while `curl /health` kept answering from the stale
process. The rerun asserts the port is free before each start. A health check is not proof that
the process you just launched is the one answering.

## Qwen3-30B-A3B — DDR5-4800 @ 1.35 V (vs JEDEC 4000 baseline), n-cpu-moe 40/24/16, 230 W — 2026-09-13T15:13:53Z
- build: 5266f24da75dc449bd56cbed7addb9c8e4a6a73e · driver: 580.178.04 · model: Qwen3-30B-A3B-Q4_K_M.gguf sha256:9f1a24700a339b09c06009b729b5c809e0b64c213b8af5b711b3dbdfd0c5ba48 · threads: 6 · ngl: 99 · n-cpu-moe: 40 · extra args: --n-cpu-moe 24 --n-cpu-moe 16 · ram: host-measured (guest dmidecode shows QEMU DIMMs)
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 15927 MiB):
  Device 0: Quadro RTX 5000, compute capability 7.5, VMM: yes, VRAM: 15927 MiB
| model                          |       size |     params | backend    | ngl |  n_cpu_moe |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --: | --------------: | -------------------: |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           pp512 |        269.16 ± 3.84 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |          pp8192 |        275.94 ± 2.02 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         40 |   1 |           tg128 |         44.95 ± 0.57 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |           pp512 |        378.81 ± 3.96 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |          pp8192 |        383.80 ± 1.56 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         24 |   1 |           tg128 |         60.26 ± 0.79 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |           pp512 |        496.98 ± 6.71 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |          pp8192 |        488.59 ± 0.55 |
| qwen3moe 30B.A3B Q4_K - Medium |  17.28 GiB |    30.53 B | CUDA       |  99 |         16 |   1 |           tg128 |         73.01 ± 0.68 |

build: 5266f24da (10809)

### Memory-speed sensitivity: DDR5-4000 vs DDR5-4800 (2026-09-13)

Controlled comparison — same GPU (Quadro RTX 5000), same model, same build 5266f24da, same
`-fa 1 -p 512,8192 -n 128 -r 3`. **Only the memory clock changed.**

| n-cpu-moe | pp512 @4000 | pp512 @4800 | delta | tg128 @4000 | tg128 @4800 | delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 40 | 264.9 | 269.2 | +1.6 % | 37.0 | 45.0 | **+21.4 %** |
| 24 | 373.1 | 378.8 | +1.5 % | 50.9 | 60.3 | **+18.5 %** |
| 16 | 487.3 | 497.0 | +2.0 % | 62.9 | 73.0 | **+16.1 %** |

Memory clock rose 19.7 % (measured IMC 4000 -> 4788). **Token generation tracks it almost
exactly; prompt processing does not move.** pp is GPU-compute-bound, tg on the CPU-expert path is
DDR-bandwidth-bound. The gain is largest at n-cpu-moe 40 (most expert layers in system RAM) and
smallest at 16 (fewest) — the mechanism, confirmed rather than assumed.

**Exchange rate to carry forward: ~1 % tg per 1 % memory bandwidth, while experts live in DDR.**
Once a GPU holds all experts resident the effect disappears entirely, which is why a 32 GB card
removes the memory-tuning question for Qwen3.6-35B-A3B (measured resident need 21.3-24.0 GiB) and
leaves it relevant only to models too large to fit, e.g. the gpt-oss-120b lane.

**Voltage caveat on this row:** the 4800 config ran at **1.35 V**, not the JEDEC 1.1 V it was
designed as — MSI's "Auto" DRAM voltage applied 1.35 V when the frequency was set manually
(`dmidecode` on all four DIMMs). 1.35 V is above XMP's 1.25 V and above the SPD maximum, so this is
an overvolted configuration, validated by 10 memtest passes / 25h03m / 0 errors but **not adopted**.
Whether 4800 holds at a manually-set 1.1 V is untested and is the experiment that would make it
adoptable. The bandwidth numbers above are unaffected — bandwidth follows frequency, not voltage.

## Arc Pro B70 (32 GB) — first light, llama.cpp Vulkan (2026-09-14)

Card replaced the Quadro RTX 5000 in msi; passed through whole to VM 240 (`hostpci0` → the GPU behind the
card's own PCIe switch). Host link Gen5 x8, full 32 GB ReBAR, host stable under sustained load, 0 MCE.
Guest: Ubuntu resolute kernel 7.0.0-31, `xe` driver (needs `linux-firmware` — the cloud image lacks
`bmg_guc_70.bin` and the probe fails `-ENOENT` without it), **Mesa 26.0.8** ANV, device reported as
`Intel(R) Graphics (BMG G31)`. llama.cpp **same pinned commit 5266f24da**, built `-DGGML_VULKAN=ON`
(`KHR_coopmat` compiled in). All models fully resident (`-ngl 99`, no `--n-cpu-moe`), `-fa 1 -p 512,8192 -n 128 -r 3`.

| model | arch | pp512 | pp8192 | tg128 | vs RTX 5000 best tg |
| --- | --- | ---: | ---: | ---: | ---: |
| Qwen3-30B-A3B Q4_K_M | qwen3moe | 1596.0 | 591.5 | 66.16 | 62.90 (n-cpu-moe 16) — **+5 %** |
| Qwen3.6-35B-A3B UD-Q4_K_M | qwen35moe | 1372.4 | 999.3 | 39.76 | 62.22 (n-cpu-moe 16) — **-36 %** |
| Qwen3.8-27B UD-Q4_K_M | qwen35 (dense) | 548.5 | 410.6 | 12.26 | 17.22 (ngl 64) — **-29 %** |

Prefill wins 2.5-3.4x at pp512. Decode regresses **only on the `qwen35`-architecture models** (the ones with
linear-attention layers); the standard-attention `qwen3moe` model is at parity. A published B70 measurement of
the same Qwen3.6-35B-A3B Q4_K_M reports **76 t/s tg** on Mesa 26.1 with a newer llama.cpp, so this row is taken
to be a software gap (pinned llama.cpp and/or Mesa 26.0 lacking optimized Vulkan kernels for those layers), not
the card's ceiling. Untested yet: llama.cpp HEAD, Mesa 26.1, SYCL, vLLM (Intel llm-scaler).

### B70: isolating the decode gap — llama.cpp version vs Mesa version (2026-09-14)

Same card, same models, same `-ngl 99 -fa 1 -p 512,8192 -n 128 -r 3`. One variable changed per row.

| model | pin 5266f24da + Mesa 26.0.8 | HEAD 41abbfd + Mesa 26.0.8 | **HEAD 41abbfd + Mesa 26.2.2** |
| --- | ---: | ---: | ---: |
| Qwen3-30B-A3B tg128 | 66.16 | 66.18 | **109.57** |
| Qwen3.6-35B-A3B tg128 | 39.76 | 39.87 | **88.22** |
| Qwen3.8-27B tg128 | 12.26 | 14.69 | **22.98** |
| Qwen3-30B-A3B pp512 | 1596.0 | 1691.1 | **1836.3** |
| Qwen3.6-35B-A3B pp512 | 1372.4 | 1573.0 | **1708.4** |
| Qwen3.6-35B-A3B pp8192 | 999.3 | 1102.7 | **1186.8** |
| Qwen3.8-27B pp512 | 548.5 | 681.5 | **739.1** |

**The Mesa version is what decides decode.** Ten days of llama.cpp moved prefill 7-24 % and the dense model's decode
20 %, but left the MoE decode untouched (39.76 -> 39.87); Mesa 26.0.8 -> 26.2.2 (kisak-mesa PPA; resolute ships
26.0.8) then took Qwen3.6-35B-A3B from 39.9 to **88.2 t/s** and Qwen3-30B-A3B from 66 to **110 t/s**. The tell before
the fix: the 35B and 30B activate similar parameter counts yet decoded 40 vs 66 on the same card, which rules out
bandwidth and points at a slow Vulkan path for the qwen35 linear-attention layers. After it, the dense 27B's 22.98
t/s x 15.32 GiB = ~62 % of the card's 608 GB/s — the same 63 % efficiency the RTX 5000 reached, i.e. the dense
model is now bandwidth-bound as expected and no longer kernel-bound.

**Against the RTX 5000 best rows:** Qwen3-30B-A3B tg +74 %, Qwen3.6-35B-A3B +42 %, Qwen3.8-27B +34 %; prefill
3.4-4.2x at pp512. A published run of the same 35B Q4_K_M on this card reported 76 t/s on Mesa 26.1.
