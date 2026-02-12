# Homelab Refactor Program Roadmap (Post-PR0)

This is the single source of truth for the remaining refactor program after PR0.

## Program Objective

Build a safe, incremental architecture where:

- Public repo contains policy intent, not topology secrets.
- Network/VLAN/firewall intent is modeled once and rendered for consumers.
- Terraform owns infrastructure provisioning concerns.
- Ansible owns host/service configuration concerns.
- Migration remains reversible at each phase.

## Guardrails and Constraints

- Keep changes additive first; avoid breaking runtime behavior during migration.
- One primary concern per PR; avoid mixing unrelated role rewrites with security migrations.
- Every PR must include explicit verification steps and rollback notes.
- Keep existing deployment entrypoints functional (`make apply`, existing playbooks).

## Target End State

- Secrets removed from tracked runtime var files.
- Public policy files validated by CI and local hooks.
- Private bindings maintained locally/encrypted.
- Ansible role inputs standardized around clear variable namespaces.
- Terraform sensitive values moved to local-only/encrypted inputs.
- Documentation supports cold-start continuation without chat history.

## Program Structure

The remaining work is split into 8 PRs (PR1 through PR8).

---

## PR1 — Overlay Foundation + Secret Inventory

### Scope

- Keep optional local override loading active in all primary playbooks.
- Add operator smoke-check commands for overlay loading.
- Build definitive inventory of sensitive variables and where they are consumed.

### Deliverables

- Playbook-level local overlay loading documented and validated.
- Variable inventory document with source-of-truth mapping.
- Updated `docs/pr1-working-checklist.md` aligned to actual findings.

### Exit Criteria

- Overlay loading is verified in at least one infrastructure and one service playbook.
- Sensitive variable inventory is complete enough to drive PR2 implementation.

### Rollback

- Remove pre_tasks include blocks from playbooks if unexpected precedence side effects occur.

---

## PR2 — Ansible Secret Namespace Migration

### Scope

- Introduce stable `secrets.*` variable namespace for sensitive values.
- Refactor roles/templates to consume `secrets.*` with non-breaking fallbacks where needed.
- Keep non-secret defaults/placeholders in tracked files.

### Deliverables

- Role/template updates for highest-risk credentials first:
  - UniFi
  - Proxmox/PBS
  - Cloudflare tunnel
  - Service database credentials where applicable
- Migration notes for each variable moved.

### Exit Criteria

- Primary playbooks run in check mode without missing-var failures (with local/sops files present).
- No critical secret remains required in tracked `group_vars/all.yml`.

### Rollback

- Re-enable legacy variable lookups for affected roles until mappings are corrected.

---

## PR3 — SOPS Runtime Workflow Standardization

### Scope

- Standardize how encrypted vars are decrypted/consumed during Ansible runs.
- Document one official local workflow (developer laptop) and one CI-safe workflow.

### Deliverables

- Clear operational guide for creating, rotating, and decrypting SOPS secrets.
- Optional helper targets/scripts for encrypted file validation before deploy.

### Exit Criteria

- Team can execute a documented end-to-end encrypted-vars runbook without ad-hoc steps.

### Rollback

- Fall back to local untracked plaintext overlays temporarily while keeping secrets out of tracked files.

---

## PR4 — Terraform Sensitive Input Migration

### Scope

- Move sensitive Terraform values out of tracked `vars.auto.tfvars`.
- Adopt local-only or encrypted input flow with tracked examples.

### Deliverables

- `*.example` templates for any removed tracked sensitive inputs.
- Updated Terraform invocation docs and Make workflow notes.

### Exit Criteria

- Terraform plan/apply works with local secure inputs and no sensitive tracked values.

### Rollback

- Restore previous var loading path temporarily (without reintroducing real secrets to git).

---

## PR5 — Policy Model Expansion (Network + Firewall)

### Scope

- Expand publishable policy model from initial skeleton to full intended segmentation and service policy intent.
- Keep private bindings as the only place for CIDRs/interfaces/host-IP details.

### Deliverables

- Extended policy schema usage in `network-data/public_policy.yaml`.
- Validation updates as needed (schema checks, structural checks, invariants).

### Exit Criteria

- Policy intent covers all active VLAN/zone relationships and major service flows.
- Validation blocks malformed policy updates.

### Rollback

- Revert to minimal policy set while retaining PR0 guardrails.

---

## PR6 — Render Pipeline (Policy -> Consumer Config)

### Scope

- Create rendering/transformation layer for policy consumption.
- First consumer should be low-risk (report output, dry-run artifact, or non-authoritative config).

### Deliverables

- Deterministic renderer with documented inputs/outputs.
- Generated artifact path(s) and review workflow.

### Exit Criteria

- Renderer produces reproducible output from public policy + private bindings.
- CI/local checks validate renderer output integrity.

### Rollback

- Disable generated artifact usage; keep renderer as optional tooling.

---

## PR7 — Controlled Consumer Adoption

### Scope

- Adopt rendered policy output in one production consumer path (incremental).
- Prefer read-only or auditable integration first, then enforcement path.

### Deliverables

- Consumer integration with explicit safety flags/toggles.
- Migration playbook for cutover and rollback.

### Exit Criteria

- Consumer behavior matches expected policy in controlled validation.
- Rollback can restore previous behavior in a single operator action.

### Rollback

- Flip integration toggle to legacy/static path.

---

## PR8 — Cleanup, Hardening, and Program Closure

### Scope

- Remove deprecated variable paths and stale docs.
- Close all migration checklists and finalize operator runbooks.
- Confirm history remediation and credential rotation are fully complete.

### Deliverables

- Finalized docs set and reduced technical debt footprint.
- Closure report for security and architecture goals.

### Exit Criteria

- All checklists complete.
- No known secret exposure pathways in current code state.
- Team can onboard and operate from docs alone.

### Rollback

- N/A for closure; use per-PR rollback from earlier steps if regressions appear.

---

## Cross-PR Verification Matrix

Run these at minimum for each PR:

1. `make validate-public-policy`
2. `make security-check`
3. `make security-check-range`
4. Targeted playbook check-mode or smoke run for changed paths
5. Manual review that no sensitive tracked files were introduced

## Context-Reset Recovery Protocol

If chat context is lost, resume in this order:

1. Read `docs/refactor-program-roadmap.md` (this file).
2. Read `docs/refactor-master-checklist.md` for exact current tasks.
3. Read `docs/pr1-working-checklist.md` for in-flight PR1 details.
4. Run `git status --short` and verify staged/unstaged scope.
5. Run guardrails before continuing.

## Ownership Suggestion

- Security/Data hygiene stream: secrets migration, rotation, history remediation.
- IaC stream: Terraform input hygiene and module alignment.
- Automation stream: policy rendering and consumer adoption.
- Ops/docs stream: runbooks, smoke checks, rollback playbooks.

## Non-Goals for This Program

- Full Terraform root restructuring in the same sequence unless explicitly scheduled.
- Large role rewrites unrelated to secrets/policy migration.
- UI/dashboard redesigns outside network/security architecture work.
