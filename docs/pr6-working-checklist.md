# PR6 Working Checklist (Render Pipeline)

Goal: implement deterministic rendering from policy inputs to auditable generated artifacts.

## Phase A — Renderer Foundation

- [x] Implement deterministic renderer script
- [x] Parse public policy zones, services, and rules
- [x] Include private-binding completeness metadata without exposing private values

## Phase B — Artifact Workflow

- [x] Add generated artifact path and render command
- [x] Add render check command to enforce reproducibility
- [x] Document generation and review workflow

## Phase C — Validation

- [x] `make pr6-render`
- [x] `make pr6-render-check`
- [x] `make security-check`
- [x] `make security-check-range`

## Artifacts

- [x] `scripts/render_policy_artifact.py`
- [x] `docs/pr6-render-pipeline.md`
- [x] `docs/pr6-working-checklist.md`
- [x] `network-data/generated/policy_render.public.json`
