# PR3 Working Checklist (SOPS Runtime Workflow)

Goal: standardize encrypted secret handling across local operator runs and CI-safe execution.

## Phase A — Local Workflow Standard

- [x] Define one standard local decrypt/edit workflow
- [x] Document exact tool prerequisites (`sops`, `age`)
- [x] Document bootstrap + validation sequence

## Phase B — CI-Safe Workflow Standard

- [x] Define one CI-safe secret handling pattern
- [x] Document ephemeral key materialization and cleanup
- [x] Keep tracked repository free of real secret payloads

## Phase C — Helper Validation Commands

- [x] Add helper script to validate SOPS workflow preconditions
- [x] Add Make target for operator-friendly invocation
- [ ] Optional: add CI workflow job wiring for helper command

## Verification

- [ ] `make pr3-secrets-check`
- [x] `make security-check`
- [x] `make security-check-range`

## Artifacts

- [x] `docs/pr3-sops-runtime-workflow.md`
- [x] `docs/pr3-working-checklist.md`
- [x] `scripts/validate_sops_workflow.sh`
- [x] `Makefile` target `pr3-secrets-check`
