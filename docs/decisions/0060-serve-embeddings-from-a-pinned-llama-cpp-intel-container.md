# ADR 0060 — Serve embeddings from a pinned llama.cpp Intel container

- **Status:** Proposed for production after the authorized side-by-side trial
- **Date:** 2026-11-18
- **Deciders:** operator + agent
- **Context source:** [VM 240 audit](../llm-vm240-configuration-audit.md) and [migration plan](../llm-embedding-container-plan.md)

## Context

BGE-M3 serves an existing 1,024-dimensional code-search index. The native build needs a compiler and a set of GPU libraries whose tested versions have disappeared from the guest's configured package indexes. An unsuccessful native upgrade can remove shared libraries used by the working executable. The chat engine already uses a container identified by its content digest.

## Decision

Use the upstream llama.cpp Intel server image by immutable digest for the embedding service. Bind its listener to guest loopback, expose only the second B70's device nodes, run as an unprivileged user and mount the checksum-verified model read-only. Preserve the existing URL, model alias, pooling and Caddy authentication. Keep the previous working deployment recoverable until a clean build and rollback have passed. This refines ADR 0051's embedding deployment.

## Rejected alternatives

Keeping the native build requires preserving its compiler and shared-library tree. Moving BGE-M3 to the Intel vLLM pooling engine also changes the model packaging and inference backend. The upstream llama.cpp container can serve the same model file and preserve the existing search behavior.

## Consequences

The qualified candidate is `ghcr.io/ggml-org/llama.cpp@sha256:56df0a745f16eed7c819c929a9b40038d169509d8d3f05edc08fd11252d14c49`, build `b12464`. Use `GGML_SYCL_ENABLE_DNN=0` and `GGML_SYCL_FA_ONEDNN=0` together for this digest. The trial with those settings reproduced all 36 labelled query vectors exactly. The digest must be retrievable after loss of the guest. Keep the GPU driver and firmware in the guest and retest physical placement and existing-index retrieval on engine or driver updates.
