# PR5 Working Checklist (Policy Model Expansion)

Goal: expand publishable network policy coverage while keeping topology data private.

## Phase A — Policy Baseline Hardening

- [x] Strengthen policy validator with structural checks
- [x] Validate rule references (`from_zone`, `to_zone`, `service`) against declared objects
- [x] Validate rule semantics (`action`, `state`, duplicate IDs)

## Phase B — Coverage Expansion

- [x] Inventory active zone-to-zone flows from current infrastructure/services behavior
- [x] Add missing policy intents for core service dependencies
- [ ] Keep all address/interface specifics in private bindings only

## Phase C — Validation and Review

- [x] `make validate-public-policy`
- [x] `make security-check`
- [x] `make security-check-range`
- [-] Manual review for intent completeness and non-sensitive content

## Artifacts

- [x] `docs/pr5-working-checklist.md`
- [x] `docs/pr5-policy-flow-inventory.md`
- [x] `scripts/validate_public_policy.py` structural validation enhancements
