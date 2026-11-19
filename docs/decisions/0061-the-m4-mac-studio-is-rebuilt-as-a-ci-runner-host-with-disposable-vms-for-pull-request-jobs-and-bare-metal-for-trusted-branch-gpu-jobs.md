# ADR 0061 — The M4 Mac Studio is rebuilt as a CI runner host with disposable VMs for pull-request jobs and bare metal for trusted-branch GPU jobs

- **Status:** Accepted
- **Date:** 2026-11-19
- **Deciders:** operator + Claude, reviewed by Codex
- **Context source:** session 2026-11-19 (operator rulings on isolation and scope; two Codex design reviews over CrossTalk, the second on dispatch enforcement after the public-repo ruling)

## Context

The GitHub-hosted Actions minutes are exhausted, and the ThreadRecall worker stops on the operator for every build, acceptance run and UI check. The older Mac Studio (M4 Max, 48 GB) is free to be wiped. [ADR 0032](0032-ci-runners-are-ephemeral-and-build-their-own-guests-inside-a-pve-pool-on-an-isolated-vlan-and-the-mac-studio-is-a-separate-trust-tier.md) made the Mac Studio a persistent runner for trusted-branch workflows only, which excludes the pull-request jobs that cause the stops. UI tests need a logged-in desktop session, and unattended auto-login on the host conflicts with FileVault.

## Decision

The M4 Mac Studio is wiped and rebuilt as a dedicated CI runner host with two tiers. This amends the Mac Studio clause of ADR 0032; its Linux ARC decisions and [ADR 0034](0034-p3b-metallb-l2-on-a-reserved-vlan40-slice-zot-behind-an-internal-cert-manager-ca-arc-scale-sets-as-hostnetwork-dind-pods-pinned-to-one-node-and-a-cronjob-reaper.md) are unchanged.

- **VM tier (pull-request jobs).** Each job runs in a macOS guest cloned from a golden image and destroyed after that one job, including on cancellation, timeout and supervisor restart. The guest registers with a just-in-time, single-use runner configuration. The golden image carries the auto-login user and the privacy grants, so UI tests get a desktop without auto-login on the host.
- **Bare-metal lane (GPU jobs): operator-started one-offs, not a registered runner (operator direction 2026-11-19).** Only Athena and MLX builds need the real GPU. The operator starts those by hand on a trusted ref of a private repository. No bare-metal runner is registered with GitHub, so no workflow and no pull request can reach the host. Registering one later is a new decision and takes the control-repository pattern.
- **Host.** FileVault on, no agent credentials, no signing identity, no real data. Job code never runs on the host in the VM tier.
- **Network: the `ci` VLAN of ADR 0032 (operator direction 2026-11-19).** The Mac sits on the VLAN the CI-built guests use: internet allowed, every internal network denied. The Linux runners themselves are pods on a services-plane node, not on this VLAN.
- **Guest isolation is enforced outside the guest.** No route to the host, the registration broker, other `ci` VLAN hosts or any internal network; no host mounts and no shared writable cache.
- **Registration.** A broker outside guest reach holds the GitHub App key and hands the guest only its one-job configuration. Registration is per repository; the App is installed only on repositories that use the runner.
- **Scope: private and public repositories (operator ruling).** Public repositories use the VM tier only.
- **The VM tier gets more leeway than bare metal (operator direction 2026-11-19).** VM tier: trusted pushes and same-repository pull requests run unprompted; a fork pull request runs only after the operator approves that run. This relaxes ADR 0032's unconditional fork ban for the VM tier only. Bare metal takes no GitHub job at all. `pull_request_target` stays banned.
- **A runner label is not access control.** Any workflow in a repository a runner is registered to can ask for its label, and a pull request can edit the workflow. This is why the host carries no registered runner: only disposable guests take jobs.
- **Stays with the operator:** Developer ID signing, the Keychain self-test, real Messages data and real-device checks.

## Rejected alternatives

- **Hosted macOS runners** — no minutes left.
- **Bare-metal runner for pull-request jobs** — job leftovers persist between runs, and UI tests would need FileVault off or a hand unlock after every restart.
- **A development or ad hoc signing identity on the runner** — `build-app.sh --local` needs Developer ID and a matching provisioning profile, and an ad hoc build cannot open a real encrypted case (ThreadRecall ADR 0007).
- **An autonomous agent with GitHub credentials on the Studio** — adds no coverage over scripted checks and puts a credential on a machine that runs untrusted code.
- **Private repositories only** — recommended by Claude and assumed in the Codex review; the operator chose to include public repositories.

## Consequences

- Acceptance gates before the first real job: two consecutive jobs prove a marker file from the first is absent in the second; a guest cannot reach the host or an internal address; one UI test launches the packaged app, clicks a control and asserts a visible result with no permission prompt, on two fresh clones.
- MLX in a guest passed one spike (2026-11-19, M5 Max host on macOS 27.2.1, macOS 26.4 guest, 8 CPUs and 16 GB): ThreadRecall's EmbeddingGemma-2 self-test printed every PASS line on the paravirtual GPU, 10 s against 4 s on the host, with similarity scores differing in the third decimal. Unproven: the M4 host, a build done inside the guest, and any larger model. The self-test returns success silently when `MODEL_DIR` is unset, so the PASS line is the evidence; a check that fails in a guest joins the operator-started bare-metal lane.
- UI in a guest passed one spike (same date and guest): with auto-login set, the ad hoc ThreadRecall build opened its main window, and a click sent through the hypervisor's VNC server opened the More menu, with no guest permission involved. An accessibility query from an ssh session inside the guest hung with no visible prompt, so in-guest scripting needs a privacy grant baked into the image. XCUITest was not tried; the image has no Xcode.
- Apple's licence allows two additional macOS instances per host, so at most two jobs run at once and image maintenance counts against the limit. The VM tool is pinned and the licence of the pinned release is read before adoption.
- Just-in-time registration needs the App's repository Administration write permission, which is broader than registration.
- A cold start still needs the operator to unlock FileVault.
- Dispatch gates before the first real job: a same-repository pull request gets a guest; a fork pull request gets no machine before approval and a guest after it; no job of any kind lands on the host.
- "Require approval for all external contributors" is the fork gate on each public repository, so the guest must be safe to hand to approved fork code: the isolation gates above are what make that approval low-stakes.
- The existing `ci → talos-cp-a` firewall allow (ADR 0034, for the nested-PVE tests) is by VLAN; it is narrowed by source so the Mac and its guests do not inherit it. The operator's management path into the `ci` VLAN is a new named rule.
- A workflow file in a pull request can name any secret the repository holds. Secrets for review and for build stay separate, and no repository that sends jobs here holds a secret a pull-request workflow should not see.
- Open: ThreadRecall's review workflow still runs on a hosted Linux runner and still needs minutes; the existing ARC runners are the candidate.
- The build is a separate change plan (brownfield gate); `openclaw-mac-studio-setup` no longer describes this machine.
