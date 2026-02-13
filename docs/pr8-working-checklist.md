# PR8 Working Checklist (Cleanup and Closure)

Goal: close program documentation and remaining technical debt with explicit tracking of external/manual tasks.

## Phase A — Repo Cleanup

- [-] Remove deprecated legacy variable paths where safe
- [x] Publish operator runbook index
- [-] Close remaining migration documentation debt

## Phase A.1 — Deprecated Variable Audit

- [x] Generate repository-wide deprecated variable reference report
- [x] Add repeatable audit command (`make pr8-audit-deprecated`)

## Phase B — Security Closure Tasks (Manual/External)

- [ ] Rotate previously exposed credentials
- [ ] Complete git history rewrite/remediation
- [ ] Notify collaborators to reset/re-clone after history rewrite
- [ ] Verify SOPS age key backup and restore path

## Phase C — Verification and Program Closure

- [ ] `make validate-public-policy`
- [ ] `make security-check`
- [ ] `make security-check-range`
- [ ] Docs-only onboarding walkthrough succeeds

## Artifacts

- [x] `docs/pr8-working-checklist.md`
- [x] `docs/operator-runbook-index.md`
- [x] `docs/pr8-deprecated-var-audit.md`
- [x] `scripts/audit_deprecated_vars.py`
