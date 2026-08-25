# ADR 0016 — Guest OS images are pinned and deliberately rolled; container tags stay latest

- **Status:** Accepted
- **Date:** 2026-07-28
- **Deciders:** operator (interview 2026-07-28)
- **Context source:** docs/rebuild-as-routine-design.md · ADR 0012 Consequences (replace-all-17-VMs drift)

## Context

The fleet currently tracks the `latest` Ubuntu cloud image. Upstream image churn (size drift) is one of the two reasons `terraform plan` wants to replace all 17 VMs today (ADR 0012 Consequences) — making `make apply` a destroy-the-fleet foot-gun and `plan` output unreadable as a statement of intended change. `lifecycle.ignore_changes` workarounds paper over the drift rather than remove it. CLAUDE.md's "no version pinning without reason" rule was written for Docker tags; OS images turned out to be the place where the reason exists.

## Decision

Guest OS images (Ubuntu cloud image, LXC templates) are **pinned by explicit version URL + checksum** in tfvars, downloaded once to shared storage so guest creation is node-agnostic. An image bump is a deliberate commit: edit the pin → `plan` shows exactly which guests would replace → roll per-service via `make rebuild <guest>` (paired services one instance at a time). Cadence is operator-driven — roughly monthly or on a CVE that matters — never upstream-driven.

**Container image tags stay `latest`** (CLAUDE.md rule unchanged for Docker): container updates flow through `make update` and never touch Terraform state.

`terraform plan` is therefore always a pure statement of the operator's changes; ambient drift proposing guest replacement is a defect. The pin lands at the greenfield cutover, which dissolves the current drift rather than reconciling it in place.

## Rejected alternatives

- **Latest + rebuild-on-drift.** Zero pin maintenance, but every apply is potentially a fleet event and plan output never cleanly answers "what am I changing" — the current foot-gun as a permanent policy.
- **Pinning container tags too.** No evidence of need: container churn never destabilizes Terraform, `make update` is already the controlled roll, and per-image pins across ~40 containers is maintenance without payoff. Pin an individual image only on a demonstrated compatibility break (existing convention, e.g. the OpenObserve v0.92.0-rc2 schema pin).
- **Keeping `ignore_changes` as the drift shield.** Hides the diff instead of removing it, and still detonates whenever a guest is legitimately replaced.

## Consequences

- WP3: pinned `download_file` resources replace the `latest` image download; the cloud-init `ignore_changes` workarounds that existed to mask drift are dropped.
- CLAUDE.md's Greenfield Philosophy line is scoped in the same edit window: `latest` applies to Docker tags; OS images are pinned per this ADR.
- Image bumps are now visible, reviewable commits — the rebuild schedule is the operator's, and stale-image risk is accepted between deliberate rolls.
- A clean `plan` becomes an enforceable invariant: any unexplained guest-replacement diff is a bug to fix, not noise to ignore.
- P6 (2026-08-25) was the first whole-fleet roll under this rule: a one-line snippet change showed exactly the six VMs as `must be replaced` and they rolled one at a time (`make rebuild <vm>`); resolute stayed on 20260731 because it was still the newest serial, Debian 13 bumped to 20260819-2575. Runbook: [p6-vm-roll-plan.md](../p6-vm-roll-plan.md).
