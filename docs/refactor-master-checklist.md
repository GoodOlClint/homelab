# Refactor Master Checklist (Program Tracker)

Use this file as the live execution tracker across PR1-PR8.

Status legend:

- `[ ]` not started
- `[-]` in progress
- `[x]` done
- `[!]` blocked

## Program Health Snapshot

- Current phase: `PR4`
- Last validated date: `2026-02-12`
- Guardrails baseline status: `[x] passing`

---

## PR1 — Overlay Foundation + Secret Inventory

### Scope Checklist

- [x] Validate PR0 baseline on current `main`
- [x] Add optional local overlay loading in active playbooks
- [x] Add smoke-check command(s) for overlay loading
- [x] Document variable precedence behavior and examples
- [x] Build complete sensitive-variable inventory (source -> consumer)

### Verification Checklist

- [x] `make validate-public-policy`
- [x] `make security-check`
- [x] `make security-check-range`
- [x] Ansible smoke-check completed for at least 2 playbooks

### Artifacts

- [x] `docs/pr1-working-checklist.md`
- [x] `docs/variable-inventory.md`
- [x] `docs/pr1-variable-precedence.md`

### PR1 Done Definition

- [x] Overlay behavior documented and testable
- [x] Variable inventory ready for PR2 role migration
- [x] Active Ansible consumers use `secrets.*` fallback for migrated secret paths

---

## PR2 — Ansible Secret Namespace Migration

### Scope Checklist

- [x] Create migration map from legacy vars to `secrets.*`
- [x] Refactor highest-risk roles/templates first
- [x] Add safe defaults/placeholders for non-secret tracked vars
- [x] Remove hard dependency on tracked secrets in `group_vars/all.yml`

### Verification Checklist

- [x] `make validate-public-policy`
- [x] `make security-check`
- [x] `make security-check-range`
- [x] `ansible-playbook --check` for changed playbooks succeeds

### PR2 Done Definition

- [x] Required runtime secrets are sourced from local/sops paths
- [x] No role requires tracked secret values to run

### PR2 Artifacts

- [x] `docs/pr2-working-checklist.md`

---

## PR3 — SOPS Runtime Workflow Standardization

### Scope Checklist

- [x] Define standard local decrypt workflow
- [x] Define standard CI-safe secret handling workflow
- [x] Document secret creation/update/rotation runbook
- [x] Add helper command(s) for secret workflow validation

### Verification Checklist

- [x] Operator dry-run of documented workflow completes
- [x] New workflow docs reviewed for first-time usability

### PR3 Done Definition

- [x] Secret workflow can be executed from docs only

### PR3 Artifacts

- [x] `docs/pr3-sops-runtime-workflow.md`
- [x] `docs/pr3-working-checklist.md`
- [x] `scripts/validate_sops_workflow.sh`
- [x] `Makefile` target `pr3-secrets-check`

---

## PR4 — Terraform Sensitive Input Migration

### Scope Checklist

- [x] Inventory sensitive Terraform inputs in tracked files
- [x] Move sensitive values to local-only/encrypted input path
- [x] Add/refresh tracked example templates
- [x] Update Make/docs for new Terraform input process

### Verification Checklist

- [ ] Terraform plan works with new secure input path
- [x] Guardrails remain green

### PR4 Done Definition

- [x] No sensitive Terraform value required in tracked tfvars

### PR4 Artifacts

- [x] `docs/pr4-working-checklist.md`
- [x] `docs/pr4-terraform-sensitive-inputs.md`
- [x] `scripts/validate_terraform_sensitive_inputs.sh`
- [x] `Makefile` secure Terraform targets
- [x] `scripts/bootstrap_local_config.sh` terraform local tfvars bootstrap

### PR4 Note

- [ ] Final secure-plan verification depends on real local values in `vars.local.auto.tfvars`

---

## PR5 — Policy Model Expansion

### Scope Checklist

- [-] Expand public policy coverage for all active zones and core flows
- [x] Keep private mappings only in local/encrypted bindings
- [x] Strengthen validation checks for policy schema/consistency

### Verification Checklist

- [ ] Validation catches malformed policies
- [-] Policy review confirms complete intended flow coverage

### PR5 Done Definition

- [ ] Policy model is complete enough for renderer adoption

### PR5 Artifacts

- [x] `docs/pr5-working-checklist.md`
- [x] `scripts/validate_public_policy.py` structural validation enhancements
- [x] `docs/pr5-policy-flow-inventory.md`

---

## PR6 — Render Pipeline (Policy -> Consumer Config)

### Scope Checklist

- [ ] Implement deterministic renderer
- [ ] Produce auditable generated artifacts
- [ ] Add docs for generation and review workflow

### Verification Checklist

- [ ] Renderer output reproducible from same inputs
- [ ] Guardrails and generator checks pass

### PR6 Done Definition

- [ ] One supported generated output path is production-ready

---

## PR7 — Controlled Consumer Adoption

### Scope Checklist

- [ ] Integrate generated output into one consumer with safety toggle
- [ ] Create cutover and rollback runbook
- [ ] Validate expected behavior in controlled rollout

### Verification Checklist

- [ ] Consumer behavior matches policy intent
- [ ] Rollback tested and documented

### PR7 Done Definition

- [ ] Generated policy path runs safely in active workflow

---

## PR8 — Cleanup and Closure

### Scope Checklist

- [ ] Remove deprecated legacy var paths
- [ ] Close docs debt and stale references
- [ ] Complete credential rotation and history remediation checklist
- [ ] Publish final operator runbook index

### Verification Checklist

- [ ] Guardrails pass
- [ ] No open high-severity migration TODOs
- [ ] Onboarding from docs-only walkthrough succeeds

### PR8 Done Definition

- [ ] Program objectives fully met

---

## Security/Recovery Critical Tasks (Track to Closure)

- [ ] Rotate all credentials previously exposed in tracked history
- [ ] Complete git history rewrite/remediation
- [ ] Notify collaborators and enforce reset/re-clone guidance
- [ ] Verify backup and recovery for SOPS age keys

---

## Weekly Update Template

Copy/paste this section into PR notes each week:

- Week of: `<YYYY-MM-DD>`
- Current PR phase: `<PR#>`
- Completed this week:
  - `<item>`
- Next up:
  - `<item>`
- Risks/blocks:
  - `<item>`
- Guardrails status:
  - `validate-public-policy: <pass/fail>`
  - `security-check: <pass/fail>`
  - `security-check-range: <pass/fail>`
