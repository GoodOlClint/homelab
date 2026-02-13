# PR4 Working Checklist (Terraform Sensitive Input Migration)

Goal: move Terraform sensitive values to local-only/env-based inputs and stop relying on tracked secret-bearing tfvars.

## Phase A — Inventory and Workflow Definition

- [x] Inventory sensitive Terraform variables used by providers
- [x] Define secure local input workflow (`vars.local.auto.tfvars` + `TF_VAR_*`)
- [x] Document operator commands for secure plan/apply

## Phase B — Tooling and Guardrails

- [x] Add helper validation script for Terraform sensitive input readiness
- [x] Add Make targets for secure Terraform commands
- [ ] Optional: CI guidance for secure Terraform variable injection

## Phase C — Migration Execution

- [ ] Move real sensitive values out of tracked `vars.auto.tfvars` in both Terraform roots
- [ ] Keep tracked tfvars content as non-secret placeholders/examples only
- [ ] Confirm no sensitive Terraform values remain in tracked tfvars

## Verification

- [x] `make pr4-tf-check`
- [ ] `make tf-plan-infra-secure`
- [ ] `make tf-plan-services-secure`
- [x] `make security-check`
- [x] `make security-check-range`

## Artifacts

- [x] `docs/pr4-working-checklist.md`
- [x] `docs/pr4-terraform-sensitive-inputs.md`
- [x] `scripts/validate_terraform_sensitive_inputs.sh`
- [x] `Makefile` PR4 secure Terraform targets
