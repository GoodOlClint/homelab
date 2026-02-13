# Docs-Only Onboarding Walkthrough

This walkthrough verifies that a new operator can execute core validation and render workflows using repository docs only.

## Prerequisites

- macOS/Linux shell with:
  - `python3`
  - `pre-commit`
  - `gitleaks`
  - `ansible-playbook`
- Repo cloned and dependencies available.

## Step 1 — Baseline Guardrails

- `make validate-public-policy`
- `make security-check`
- `make security-check-range`

Expected: all commands pass.

## Step 2 — Render Pipeline

- `make pr6-render`
- `make pr6-render-check`

Expected: artifact writes and check reports up-to-date output.

## Step 3 — Controlled Consumer Smoke

- `make pr7-consumer-smoke`

Expected: list-tasks run succeeds with rendered-policy tasks visible when toggle is enabled.

## Step 4 — Cleanup Health Checks

- `make pr8-audit-deprecated`
- `make pr8-deprecated-check`

Expected:

- audit report is generated/updated
- deprecated check passes (or warns in non-strict mode without failing)

## One-command smoke path

- `make pr8-onboarding-smoke`
