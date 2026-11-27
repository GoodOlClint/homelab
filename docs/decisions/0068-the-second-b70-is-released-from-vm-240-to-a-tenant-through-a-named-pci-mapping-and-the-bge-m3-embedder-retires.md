# ADR 0068 — The second B70 is released from VM 240 to a tenant through a named PCI mapping, and the BGE-M3 embedder retires

- **Status:** Accepted (operator, 2026-11-27)
- **Date:** 2026-11-25
- **Deciders:** operator + agent
- **Context source:** design session 2026-11-25; [VM 240 configuration audit](../llm-vm240-configuration-audit.md); Codex design review 2026-11-25

## Context

VM 240 on msi holds both Arc Pro B70 cards: Qwen chat on the first, the BGE-M3 embedder on the second ([ADR 0060](0060-serve-embeddings-from-a-pinned-llama-cpp-intel-container.md)). BGE-M3 was chosen for code search; code-intel was a spike and is retired as a project, so nothing uses the second card (operator, 2026-11-25). Its configuration is still wired in: `vllm.service` waits in `ExecStartPre` for `llama-embed` to be active and healthy; the mcp gateway sets `CODE_INTEL_EMBED_URL` and reads `llm_api_key_mcp` and `/codeintel` `reader_password`; `k8s_apps` (`codeintel.yml`) generates `/codeintel` credentials and waits for the cluster Postgres. A tenant enclave ([ADR 0067](0067-the-homelab-hosts-tenant-enclaves-through-a-fixed-set-of-interface-edges.md)) will use the card. Proxmox reserves raw (unmapped) PCI passthrough to `root@pam`, so a pool-scoped token cannot attach a card by host address. [ADR 0056](0056-msi-leaves-ceph-but-stays-a-non-ceph-cluster-member-as-the-gpu-host-and-its-drain-waits-for-three-healthy-osd-hosts.md) makes msi the host for AI-plane VMs.

## Decision

- **Timing (operator, 2026-11-27):** the code-intel and embedder retirement and both cards' mappings land first, in one VM 240 restart, independent of ms-01b. Releasing the second card to the tenant waits for ms-01b to return (msi memory); until then it stays attached to VM 240, idle.
- **Both B70s get a named PCI resource mapping, one mapping per card.** The VM module gains support for mapped devices, and VM 240 attaches its first card through its mapping instead of raw `hostpci` by address. Gate: the Terraform plan for VM 240's switch is an in-place update, not a replace, and chat answers after the restart.
- The second B70 (host function `07:00.0` per the audit) leaves VM 240. The tenant's token is granted `Mapping.Use` on that card's mapping alone. Gate: the tenant's scoped token builds its GPU VM with the mapping before the card is released from VM 240.
- **A later move of the first card is a grant, not a new decision here.** If VM 240 is decommissioned or the tenant takes the first card, the change is: stop or remove VM 240, then grant `Mapping.Use` on the first card's mapping to the tenant, which is the PCI edge already in [ADR 0067](0067-the-homelab-hosts-tenant-enclaves-through-a-fixed-set-of-interface-edges.md). Where homelab chat goes after that is its own homelab decision.
- **VM 240 keeps the first B70 and homelab chat.** Its BGE-M3 embedder service, Caddy route and model retire, and in the same change `vllm.service` loses its `llama-embed` ordering, `PartOf` and `ExecStartPre` health gate. Gate: cold-start VM 240 with only the first card and get a real authenticated chat answer. This supersedes ADR 0060's embedder placement once Accepted.
- **Code-intel retires as a whole, in one change:** the mcp gateway's code-intel tools, `CODE_INTEL_EMBED_URL` and its secret templates; `k8s_apps` `codeintel.yml` and the `codeintel` Flux tree; LXC 280; the `scratch` delivery; the `/codeintel` folder and its loader-loop entry; `llm_api_key_code_intel` and `llm_api_key_mcp`; their CLAUDE.md rows. Gate: a normal fleet run and a gateway restart succeed before the folder is deleted, and nothing regenerates it.

## Rejected alternatives

- **Raw `hostpci` by host address, as VM 240 does.** Needs `root@pam`; the tenant could not manage its own GPU VM.
- **Map only the released card; leave VM 240 on raw `hostpci`.** Works today, but moving the first card later would need another change to VM 240's PCI wiring and to this ADR.
- **Retire the embedder without touching `vllm.service`.** Chat would fail on its next start after a five-minute wait.
- **Keep both cards in VM 240 and give the tenant an API key.** Keeps a tenant workload inside a homelab guest and makes the hand-over split a running guest.
- **Delete only LXC 280 and the keys.** The gateway and `k8s_apps` still consume and regenerate them.

## Consequences

- VM 240's two-card layout in the audit and the dual-B70 plan becomes one card; its PCI and memory settings are revised in the change plan, and its 48 GiB may shrink.
- msi's memory budget at that time must cover the tenant's GPU VM.
- The VM module's mapped-device support is reusable for any later device released to a tenant.
- Every GPU on msi is addressed by mapping name, so a card's host address changing (a slot move, a BIOS update) is fixed in the mapping once, not in each VM.
