# PR4 Terraform Sensitive Inputs Runbook

This runbook standardizes secure Terraform input handling for both roots:

- `terraform/infrastructure`
- `terraform/services`

## Sensitive Variable Inventory

The following are sensitive and should not be stored with real values in tracked tfvars:

- `virtual_environment_password`
- `unifi_password`
- `virtual_machine_password_hash`

## Standard Input Strategy

Use one of these two secure methods:

1. Local-only tfvars file (preferred for operators)
   - `terraform/<root>/vars.local.auto.tfvars` (ignored by `.gitignore`)
2. Environment variables for automation/CI
   - `TF_VAR_virtual_environment_password`
   - `TF_VAR_unifi_password`
   - `TF_VAR_virtual_machine_password_hash`

## Local Operator Workflow

1. Create local-only vars files (not tracked):
   - `cp terraform/infrastructure/vars.auto.tfvars.example terraform/infrastructure/vars.local.auto.tfvars`
   - `cp terraform/services/vars.auto.tfvars.example terraform/services/vars.local.auto.tfvars`
2. Fill sensitive values only in local files or export `TF_VAR_*` env vars.
3. Validate readiness:
   - `make pr4-tf-check`
4. Run secure plans:
   - `make tf-plan-infra-secure`
   - `make tf-plan-services-secure`

## CI-Safe Pattern

- Inject sensitive values as `TF_VAR_*` environment variables from CI secret manager.
- Do not persist plaintext tfvars in repository or artifacts.
- Run helper in CI mode:
  - `bash scripts/validate_terraform_sensitive_inputs.sh --mode ci`

## Migration Constraint Note

Current guardrails protect tracked `terraform/*/vars.auto.tfvars` from direct commits.
That protection is intentional to prevent accidental leaks.

To complete PR4 migration execution safely:

1. Move live runtime usage to local-only/env flow (this runbook + new make targets).
2. In a controlled follow-up, sanitize tracked `vars.auto.tfvars` to placeholders/examples only,
   while preserving guardrail enforcement posture.

### Controlled commit override for placeholder-only tfvars edits

`vars.auto.tfvars` files remain protected by default.
During the one-time sanitization commit, enable this explicit override:

- `GUARDRAILS_ALLOW_TFVARS_EDIT=1 git commit -m "PR4: sanitize tracked tfvars placeholders"`

Notes:

- Override only relaxes protection for `terraform/*/vars.auto.tfvars`.
- Other protected paths remain blocked.
- `gitleaks` scanning still runs and must pass.
