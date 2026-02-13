# PR7 Working Checklist (Controlled Consumer Adoption)

Goal: integrate generated policy output into one active consumer with toggle + rollback.

## Phase A — Integration

- [x] Integrate generated artifact into one consumer path
- [x] Add explicit safety toggle for adoption
- [x] Keep default behavior unchanged when toggle is off

## Phase B — Cutover and Rollback

- [x] Document cutover command(s)
- [x] Document rollback command(s)
- [x] Add smoke command for toggle-on validation

## Phase C — Verification

- [x] `make pr6-render`
- [x] `make pr7-consumer-smoke`
- [x] `make security-check`
- [x] `make security-check-range`

## Artifacts

- [x] `docs/pr7-working-checklist.md`
- [x] `docs/pr7-controlled-adoption.md`
- [x] `ansible/playbooks/infrastructure.yml` toggle integration
- [x] `Makefile` target `pr7-consumer-smoke`
