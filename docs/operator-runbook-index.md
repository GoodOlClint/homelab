# Operator Runbook Index

This index is the starting point for day-2 operations and controlled change workflows.

## Security and Secrets

- PR0 baseline and guardrails:
  - `docs/pr0-security-baseline.md`
- SOPS runtime workflow:
  - `docs/pr3-sops-runtime-workflow.md`

## Terraform Input Hygiene

- Secure local/CI variable workflow:
  - `docs/pr4-terraform-sensitive-inputs.md`

## Network Policy and Rendering

- Policy expansion tracker:
  - `docs/pr5-working-checklist.md`
- Policy flow inventory:
  - `docs/pr5-policy-flow-inventory.md`
- Render pipeline runbook:
  - `docs/pr6-render-pipeline.md`

## Consumer Adoption

- Controlled rollout and rollback for rendered policy usage:
  - `docs/pr7-controlled-adoption.md`

## Program Tracking

- Master tracker:
  - `docs/refactor-master-checklist.md`
- Long-horizon roadmap:
  - `docs/refactor-program-roadmap.md`

## Recommended Operator Sequence

1. Run guardrails and policy validation:
   - `make validate-public-policy`
   - `make security-check`
2. Render policy artifact:
   - `make pr6-render`
   - `make pr6-render-check`
3. (Optional) Validate consumer toggle path:
   - `make pr7-consumer-smoke`
