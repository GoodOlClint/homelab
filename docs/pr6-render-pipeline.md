# PR6 Render Pipeline (Policy -> Artifact)

Goal: provide a deterministic render step that produces an auditable artifact from policy inputs.

## Renderer

- Script: `scripts/render_policy_artifact.py`
- Inputs:
  - public policy: `network-data/public_policy.yaml`
  - private bindings template: `network-data/private_bindings.example.yaml`
- Output:
  - `network-data/generated/policy_render.public.json`

## Why this first artifact

- Low-risk consumer output (report-style JSON)
- Deterministic, sorted output suitable for diff review
- No address/interface values are rendered into tracked artifact

## Commands

- Generate artifact:
  - `make pr6-render`
- Validate artifact is up to date:
  - `make pr6-render-check`
- Optional local rendering using local private bindings:
  - `make pr6-render-local`

## Review workflow

1. Update policy input files.
2. Run `make pr6-render`.
3. Inspect diff of `network-data/generated/policy_render.public.json`.
4. Run guardrails and commit.
