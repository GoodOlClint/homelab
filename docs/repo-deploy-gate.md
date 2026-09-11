# Repo deploy gate — branch protection for a Flux-deployed repository

Status: **RECOMMENDATION, 2026-09-10.** Nothing here is applied; rulesets and CODEOWNERS are operator changes. Prerequisite for tranche 1 of [local-ai-plan.md](local-ai-plan.md) per [ADR 0052](decisions/0052-the-agent-plane-is-an-agent-runner-vm-on-a-dedicated-automation-vlan-and-a-homelab-mcp-gateway-vm-on-the-services-vlan-both-on-msi-outside-the-talos-cluster.md); closes the "branch protection is made real before Flux tracks `main`" sentence in [ADR 0048](decisions/0048-flux-reconciles-the-kubernetes-services-plane-from-the-repo-replacing-the-kubernetes-shell-deploy-layer-in-app-configuration-is-ansible-and-the-talos-lifecycle-stays-on-talos-sh.md).

## Why this is the security point

Under ADR 0048, Flux reads `main` of this public repo every 5 minutes with no credential and reconciles `kubernetes/` with `prune: true` at the root. A commit on `main` is therefore a cluster deploy, and a deletion on `main` is a cluster prune. The two agent GitHub Apps (`goodolclint-claude`, `goodolclint-codex`) hold **Contents: read/write** on this repo. Whatever VLAN an agent sits on, commit rights on `main` are Flux's credential.

## Verified current state (2026-09-10, public API)

| Control | State |
|---|---|
| Ruleset `main` (id 22745111, active, `~DEFAULT_BRANCH`) | rules: `deletion`, `non_fast_forward`, `required_linear_history` — **nothing else** |
| Pull request required | **no** |
| Required approvals / code-owner review / dismiss stale | **none** |
| Required status checks | **none** (`validate.yml` runs but is not required) |
| Signed commits / Flux `GitRepository.verify` | **none** (deliberate today, ADR 0048 comment) |
| Bypass actors | none visible on the public endpoint |
| CODEOWNERS | **absent** |
| Automated reviewer workflow | **absent** (`validate.yml` is `contents: read`, no reviews, no merges) |
| Agent Apps | Contents RW, PRs RW, Issues RW; Workflows none |
| Documented intent ([github-agent-identity.md §3](github-agent-identity.md)) | PR required, 1 approval, code-owner review, dismiss stale, `* @GoodOlClint` CODEOWNERS, operator bypass — **not what is live** |

Consequence today: any write-capable identity can push directly to `main`, and Flux deploys it within 5 minutes.

## Recommendations

Ordered by blast radius closed per unit of operator effort. Items 1–3 are the tranche-1 prerequisite; 4–6 are strong-form follow-ons.

### 1. Ruleset `main`: add the pull-request rule

Add to the existing ruleset (UI: Settings → Rules → `main`; or the REST rulesets API):

| Rule | Value | Why |
|---|---|---|
| `pull_request` | required approvals **1**; `dismiss_stale_reviews_on_push: true`; `require_code_owner_review: true`; `required_review_thread_resolution: false`; allowed merge methods: squash + rebase (linear history already required) | No direct pushes by anyone, including the Apps. A bot cannot be a code owner, so code-owned paths always need the operator |
| `required_status_checks` | `validate` (the job in `.github/workflows/validate.yml`); `strict_required_status_checks_policy: false` | The guardrails + `make validate` become a merge gate instead of advisory; "up to date" off so parallel PRs do not invalidate each other |
| `deletion`, `non_fast_forward`, `required_linear_history` | keep | already live |
| Bypass actors | **`GoodOlClint` only, mode `always`**; **no App, no team** | Governance paths need an operator path; an App with bypass is the hole this doc exists to close |

`required_signatures` is item 5, not here (it changes how the operator merges).

### 2. CODEOWNERS, deliberately narrow

`docs/github-agent-identity.md` prescribes `* @GoodOlClint`. With code-owner review on, a wildcard blocks *every* PR on the operator, which is fine while the operator merges everything by hand but removes the option of ever letting the automated-review model merge a routine PR. Own only the paths where an automated approval must never be sufficient:

```
# Deploy paths — a merge here is a cluster change (ADR 0048)
/kubernetes/                        @GoodOlClint
/ansible/roles/k8s_seed/            @GoodOlClint
/ansible/roles/k8s_apps/            @GoodOlClint
/ansible/playbooks/kubernetes.yml   @GoodOlClint
/scripts/flux_check.py              @GoodOlClint

# Governance — a PR must not edit the rules it is judged by
/.github/                           @GoodOlClint
/CODEOWNERS                         @GoodOlClint
/CLAUDE.md                          @GoodOlClint
/AGENTS.md                          @GoodOlClint
/docs/decisions/                    @GoodOlClint
/.claude/                           @GoodOlClint
/.pre-commit-config.yaml            @GoodOlClint
/scripts/security_guardrails.sh     @GoodOlClint
/renovate.json                      @GoodOlClint
```

Terraform and the Ansible roles are deliberately *not* owned: nothing applies them on merge (operator-run `make`), so the PR review model can cover them later. If the operator prefers "I review everything" for now, `* @GoodOlClint` is acceptable and this list becomes the minimum that must survive any future narrowing.

### 3. The Apps never merge, and never push to `main`

- Remove the "merge as the App on APPROVED" pattern from this repo's contract (there is no reviewer workflow here to produce an APPROVED, and even with one, a merge to `main` is a deploy). Record in `AGENTS.md`: agents open PRs only when asked, never merge, never push `main`.
- Keep the Apps' **Workflows** permission at none (already the case) so no agent PR can edit `.github/`; CODEOWNERS makes that a human review anyway.
- The agents VM (ADR 0052) holds **no** GitHub credential with Contents write on this repo. If a future agent must open PRs here, it gets a separate App scoped to this repo with Contents write on *branches other than `main`* enforced by the ruleset above, never a bypass.

### 4. Flux-side defence in depth

- Root `Kustomization` stays `prune: true`, but every per-app `Kustomization` under `kubernetes/flux/apps/` should carry an explicit `prune:` and a `healthChecks:` block so a bad merge fails a tree rather than the root; PVC `Retain` (already in the StorageClass) is what makes a wrong prune recoverable.
- `kustomize-controller` already runs `--no-cross-namespace-refs` and `--no-remote-bases`; keep them. Consider `--concurrent=1` on this small cluster so a bad tree cannot race a good one.
- Flux's `GitRepository.interval` of 5 m is the deploy latency *and* the revert latency: a revert commit on `main` is the rollback path. Document `git revert` + `make flux-reconcile TREE=` as the runbook.

### 5. Strong form: signed commits + `GitRepository.verify`

`required_signatures` on the ruleset plus a `verify:` block on the `GitRepository` (mode `HEAD`, a Secret holding the operator's public GPG/SSH key) makes Flux refuse any commit not signed by the operator. Trade-offs that must be understood before enabling:

- Web-UI merges are signed by GitHub's web-flow key, not the operator's. With `verify` pinned to the operator's key, the operator must merge **locally** (`git merge --ff-only` / signed squash) and push; a web merge stops deploying. That is a workflow change, not a checkbox.
- Renovate PRs are unsigned until merged; the local signed merge covers them.
- The `verify` Secret in `flux-system` is a public key, so it is safe in the seed (`k8s_seed`, ADR-level allowlist addition).

Recommendation: enable `required_signatures` on the ruleset first (cheap, enforces the operator's key on local pushes and lets web merges through), and add Flux `verify` only if the operator is willing to merge locally.

### 6. Secrets scanner as a required check

`validate.yml` already runs gitleaks and the guardrails. Once the job is a required check (item 1), a credential in a diff blocks the merge. Keep the job name stable; a renamed job silently drops out of the required list.

## What this does not solve

- Prompt injection through an agent's *authorized* egress (OpenRouter, Anthropic, OpenAI, GitHub reads) — ADR 0052's residual risk; the deploy gate stops it from becoming cluster state, not from leaking.
- Terraform and Ansible applies stay operator-run and are not gated by merge; that is a feature today (nothing auto-applies) and a separate decision if it ever changes.
- The Infisical universal-auth identity and `cluster-bindings` are readable by anything with a cluster-scoped token; the agents VM must not hold one (ADR 0052).

## Acceptance

- A test PR from an agent App touching `kubernetes/README.md` cannot merge without the operator's review; the same PR with the `validate` job failed cannot merge at all.
- `git push origin main` from any identity without bypass is refused by the ruleset.
- The public rulesets endpoint lists the `pull_request` and `required_status_checks` rules on `main`.
- `docs/github-agent-identity.md §3` is updated to match what is live, and `AGENTS.md` carries the never-merge rule.
