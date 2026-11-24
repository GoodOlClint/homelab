# ADR 0066 — Fleet runs on a Premium license during a trial, and the homelab and LLC split is decided before Apple Business enrollment

- **Status:** Provisional (operator 2026-11-24)
- **Date:** 2026-11-24
- **Deciders:** operator + agent
- **Context source:** the Fleet MDM build ([plan](../fleetdm-plan.md)), after WP7

## Context

[ADR 0065](0065-fleet-mdm-runs-on-the-services-cluster-as-tree-fleetdm-on-the-free-tier-lan-only-with-its-own-mysql-and-saml-login.md) put Fleet on the free tier. Building WP4–WP7 showed what free leaves out of what the operator wants from an MDM: package deployment (free has scripts only), CIS reports, OS update enforcement, FileVault key escrow, Recovery Lock and certificate-authority integrations are Premium. Premium is $7 per host per month, self-hosted, and Fleet sells it to an individual registered with a custom-domain email.

Separately, Apple's schema marks the DDM software-update declarations supervised-only on macOS, and the legacy update controls are reported dead on macOS 27, so OS update enforcement needs supervised Macs on any MDM. Supervision means Automated Device Enrollment through an Apple Business organization; a retail Mac joins one through Apple Configurator after an erase, with a 30-day window in which it can be released.

The operator plans an LLC whose equipment Fleet would mainly manage, and the homelab must separate cleanly from it. Both a Premium license and an Apple Business organization belong to a legal entity, and a Mac's ADE assignment belongs to exactly one organization (moving it later means release and erase).

## Decision

- Fleet runs on a Premium license for a trial. The key is operator-provided in Infisical `/fleetdm/license_key` and reaches the server as `FLEET_LICENSE_KEY` through the `fleetdm-secrets` managed Secret (chart `fleet.license`).
- No Apple Business organization is created and no Mac is enrolled through ADE until the operator has settled, with tax advice, which entity owns which equipment.
- Fleet configuration stays free-tier-compatible where it can (mSCP profiles and the compliance script), so the trial can end or move to a second Fleet instance without rework.

This amends ADR 0065's free-tier clause only; everything else in 0065 stands.

## Rejected alternatives

- **Stay on free and build around it.** Package deployment, OS update enforcement, FileVault escrow and Recovery Lock have no free path in Fleet; scripting around them recreates Premium badly.
- **Microsoft Intune Plan 1** ($8 per user per month, the operator has an Entra tenant). Cheaper and strong on Windows, but it cannot manage servers today, which is most of what this Fleet manages, and it is cloud-only with no CIS reports for macOS.
- **Apple Business's built-in MDM.** Free, but no CIS, no maintenance windows, no Windows and thin reporting; its value here is ADE, which Fleet can use through the same organization.
- **SimpleMDM, Hexnode, Jamf, Mosyle, Iru, Addigy.** Cloud-only, and either missing CIS or carrying 15–30 device minimums or $200+ monthly minimums.
- **Create the Apple Business organization now.** ADE assignments would land in an entity that may not be the final owner, and moving a Mac between organizations costs an erase.

## Consequences

- The `fleetdm-secrets` template references `license_key`, so the key must be in Infisical before that change reaches the cluster; a missing key can fail the whole Secret's render, MySQL passwords included.
- Premium features (packages, CIS policies, OS updates, disk encryption, Recovery Lock) become WP9+ work in the plan; OS update enforcement waits for supervision and so for the entity decision.
- If the trial ends, removing the key returns Fleet to free; Premium-only settings stop applying and the free-tier configuration in the tree still works.

## Trial record

- **Council verdict:** none; operator decision in session (2026-11-24).
- **Rests on:** ADR 0065.
- **Commits:** `git log --grep 'Provisional-ADR: 0066'`.
- **Pinning test:** `GET /api/v1/fleet/config` reports `license.tier` = `premium` after the key is delivered.
- **Outcome:** open.
