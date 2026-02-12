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

- [ ] Inventory secret variables currently read from tracked files
  - [ ] UniFi credentials
  - [ ] Proxmox API credentials/tokens
  - [ ] PBS credentials/tokens
  - [ ] Cloudflare tunnel token
  - [ ] Any DB/service passwords in templates
- [ ] Refactor roles/templates to read from `secrets.*` namespace where applicable
- [ ] Add non-secret defaults/placeholders for required vars in tracked files
- [ ] Validate all affected playbooks in check mode (`--check`) where possible

## Phase C — Terraform Hygiene Follow-up

- [ ] Identify sensitive values in Terraform `vars.auto.tfvars`
- [ ] Move to local-only or environment variables
- [ ] Keep tracked `*.example` files as templates only
- [ ] Confirm PR0 guardrails still pass after migration

## Phase D — Closure Criteria

- [ ] `make validate-public-policy` passes
- [ ] `make security-check` passes
- [ ] `make security-check-range` passes
- [ ] No required deploy variable depends on tracked sensitive files
- [ ] Update `docs/secrets-migration-checklist.md` with completed items

## Notes

- Current PR1 implementation is additive and non-breaking: if `ansible/group_vars/local/all.yml` exists, values are loaded at play runtime and can override tracked defaults.
- SOPS-encrypted runtime loading is intentionally deferred to a dedicated follow-up (requires selected decrypt strategy/plugin workflow).
- Variable precedence guide: `docs/pr1-variable-precedence.md`
