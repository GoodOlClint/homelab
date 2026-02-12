# PR1 Working Checklist (Variable Overlay + Secret Migration)

Goal: move runtime configuration off tracked sensitive files while keeping deployments stable.

## Program Navigation

- Master roadmap: `docs/refactor-program-roadmap.md`
- Master tracker: `docs/refactor-master-checklist.md`
- This file tracks only PR1 implementation details.

## Phase A — Foundation (this PR1 branch)

- [x] Validate PR0 guardrails on main (`make validate-public-policy`, `make security-check-range`)
- [x] Add optional local override loading in active playbooks
  - [x] `ansible/playbooks/infrastructure.yml`
  - [x] `ansible/playbooks/services.yml`
  - [x] `ansible/playbooks/docker.yml`
- [x] Add a dry-run smoke command for overlay loading (single host)
- [x] Document precedence rules (`group_vars/all.yml` vs `group_vars/local/all.yml`)

## Phase B — Secret Consumption Migration

- [x] Inventory secret variables currently read from tracked files
  - [x] UniFi credentials
  - [x] Proxmox API credentials/tokens
  - [x] PBS credentials/tokens
  - [x] Cloudflare tunnel token
  - [x] Any DB/service passwords in templates
- [ ] Refactor roles/templates to read from `secrets.*` namespace where applicable
  - [x] First migration slice applied for monitoring + tunnel paths (with fallback)
  - [x] Second migration slice applied for PostgreSQL service password consumers (with fallback)
  - [ ] Remaining role/template consumers migrated
- [ ] Add non-secret defaults/placeholders for required vars in tracked files
- [x] Validate all affected playbooks in check mode (`--check`) where possible

## Phase C — Terraform Hygiene Follow-up

- [x] Identify sensitive values in Terraform `vars.auto.tfvars` (captured in `docs/variable-inventory.md`)
- [x] Keep tracked `*.example` files as templates only
- [x] Documented Terraform sensitive-input migration path and ownership under PR4
- [x] Confirm PR0 guardrails still pass after migration planning updates

## Phase D — Closure Criteria

- [x] `make validate-public-policy` passes
- [x] `make security-check` passes
- [x] `make security-check-range` passes
- [x] No required **Ansible runtime path** depends on tracked sensitive files (fallback to `secrets.*` in active consumers)
- [x] PR1 handoff explicitly points Terraform-sensitive-value execution to PR4

## Notes

- Current PR1 implementation is additive and non-breaking: if `ansible/group_vars/local/all.yml` exists, values are loaded at play runtime and can override tracked defaults.
- SOPS-encrypted runtime loading is intentionally deferred to a dedicated follow-up (requires selected decrypt strategy/plugin workflow).
- Variable precedence guide: `docs/pr1-variable-precedence.md`
- Inventory artifact for PR2 input mapping: `docs/variable-inventory.md`
- Terraform sensitive-input execution is tracked in PR4 by design; PR1 only establishes inventory + migration path.
