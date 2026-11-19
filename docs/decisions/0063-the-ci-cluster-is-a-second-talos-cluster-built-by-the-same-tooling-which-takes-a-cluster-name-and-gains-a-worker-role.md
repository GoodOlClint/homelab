# ADR 0063 — The CI cluster is a second Talos cluster built by the same tooling, which takes a cluster name and gains a worker role

- **Status:** Proposed
- **Date:** 2026-11-19
- **Deciders:** operator + Claude
- **Context source:** brownfield gate for [ADR 0062](0062-arc-moves-off-the-services-cluster-onto-a-dedicated-two-node-ci-cluster-with-the-github-app-key-kept-from-job-nodes.md); plan in [docs/ci-cluster-plan.md](../ci-cluster-plan.md)

## Context

ADR 0062 needs a two-node Kubernetes cluster. Nothing in the Talos tooling is built for a second cluster: `kubernetes/talos/talos.sh` hardcodes the cluster name, the secrets directory, the Infisical folder and a control-plane-only render; `terraform/talos.tf` hardcodes one node map; the Flux root, the `k8s_seed` role, `scripts/flux_check.py` and the Makefile hardcode one kubeconfig path.

## Decision

The CI cluster is Talos, built by the existing tooling. `talos.sh`, `talos.tf`, the seed role, `flux_check.py` and the Make targets take a cluster name, defaulting to the services cluster, and `talos.sh` gains a worker render. The CI cluster is one control-plane node and one worker. It has its own secrets directory, its own Infisical folder, its own Flux root and its own seed object set. The rule in [ADR 0033](0033-talos-p3a-rides-talosctl-from-a-kubernetes-tree-with-the-factory-image-pinned-in-cloud-images-the-worklab-member-via-a-second-bpg-provider-alias-flannel-and-cluster-secrets-in-infisical.md) and [ADR 0048](0048-flux-reconciles-the-kubernetes-services-plane-from-the-repo-replacing-the-kubernetes-shell-deploy-layer-in-app-configuration-is-ansible-and-the-talos-lifecycle-stays-on-talos-sh.md) stands for both clusters: only `talos.sh` renders machine configs, Flux owns charts, Ansible owns seed objects.

## Rejected alternatives

- **k3s on two Ubuntu VMs** — faster to a first run, but a second distribution to patch and a mutable operating system on the node that runs job code.
- **A separate copy of the Talos tooling for the CI cluster** — no risk to the production script, but two copies drift, and a parallel pipeline is a defect by this repo's own rule.

## Consequences

- The change edits the script that owns the production cluster's lifecycle. The proof it is safe: the machine configs rendered for the services cluster are byte-identical before and after, and a Terraform plan shows no change to the existing Talos VMs.
- Terraform resource addresses of the existing Talos VMs do not change; the node map gains entries and attributes, not a new resource block.
- The CI cluster has no Ceph leg, no VIP, no registry trust patch and no Infisical operator.
- Every hardcoded kubeconfig path becomes a cluster argument; a caller that omits it still reaches the services cluster.
