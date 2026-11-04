# GitHub agent identity: change plan

Status: landed 2026-11-04. ADR 0059 is Accepted; this document is kept as the plan of record, and the as-built notes are in the ADR.

Records [ADR 0059](decisions/0059-agent-github-identity-is-selected-per-session-by-a-wrapper-that-reads-the-repo-origin-and-a-per-org-map.md) (Proposed). Rulings cited by number are the 2026-11-04 GitHub identity discussion rulings.

Terms. An App is a GitHub App, a bot identity installed on an account or organization; each agent kind (Claude, Codex) has one. MCP is the Model Context Protocol the CLIs use to talk to tool servers. `github-mcp-server` is the GitHub MCP server. `push_verified` is the tool in `mcp-server-github` (server binary `push-verified`) that re-authors a local branch as the App through the GitHub API so the commit is Verified.

## Decisions for the operator to veto or confirm

- Homelab stays `plain` push mode (ruling 4): the operator authors pushes, the App only does MCP calls (PRs, issues, reads).
- The `push-verified` root narrows from `~/Source` to one repo per session. Catch: a session can push_verified only its own repo.
- Cutover happens before the US-Law-Dev Apps exist. us-law sessions lose public-repo reads until then; org calls already fail today.
- No new stray-push hook. Claude's `ask: Bash(git push:*)` already is the approval gate; Codex has none (named gap).
- WP3 proof repo: proposed `GoodOlClint/mcp-server-github` (origin confirmed; a push_verified repo where a throwaway branch costs nothing). Operator confirms or names another.
- WP0 adds a small Go change to `push_verified` (`--bind-repo`, estimated about 20 lines plus tests; size not measured). Codex showed the per-repo mode is otherwise evadable. Declining it leaves mode enforced at session start only, with that gap named.

## Design

- Wrapper `scripts/github-agent-mcp <claude|codex> <github|push>`: python stdlib, absolute path in each CLI's config. getcwd only, never env. Drops every `GIT_*` variable and every `GITHUB_*` variable except `GITHUB_TOOLSETS` and `GITHUB_EXCLUDE_TOOLS`, then parses `git config --local --get remote.origin.url` strictly (host github.com; scp and `ssh://` forms with the literal `git@` user, `https://` with no userinfo; no port, query or fragment; org case-insensitive; names ASCII, never `.` or `..`). Refuses with a one-line stderr reason on no repo, no origin, other host, unknown org, or no entry for that agent. Else sets `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_PATH` and execs the server.
- Map `~/.config/github-agent/identities.json` (untracked; example `docs/github-identities.example.json`): `orgs -> org -> {agents: {claude|codex: {app_id, installation_id, key_path}}, push_mode, repos: {repo: push_mode}}` plus server binary paths. Silent means push_verified. JSON, not TOML: under Codex's scrubbed env `env python3` may be the macOS system python without `tomllib` (unverified; JSON removes the question).
- `push` mode also refuses any layout whose `git rev-parse --git-common-dir` is not named `.git` (bare repo, bare worktree, submodule, separate-git-dir), since `--repo-root` would otherwise point at the wrong tree. Residual: a separate-git-dir store literally named `.git` passes; `--bind-repo` still holds, so the destination is still the origin's repo.
- `push_mode` allows only `plain` and `push_verified`; absent means default, anything else refuses before either server starts.
- `push` mode: effective mode plain refuses to start; else exec `push-verified --repo-root <main tree> --bind-repo <owner>/<repo>`, main tree from `git rev-parse --git-common-dir`.
- Toolsets and exclude-tools stay in each CLI's config env. Codex gains a push-verified entry and excludes `push_files` and `create_or_update_file`, as Claude does. Codex does not get `required = true` (13 repos have no origin; it would break Codex there, review included). Cost: refusal is silent to a Codex session, so run the wrapper by hand in the directory to see the reason.
- Worktrees: `push_verified` refuses a linked worktree path, so agents pass the main tree path plus the branch name (ADR 0005; branch refs are shared). This corrects the rulings' "covers worktrees", true for MCP calls only.
- Map at landing: GoodOlClint default push_verified, repo homelab plain; US-Law-Dev absent. Sessions must start inside a repo (`~/Source/us-law` is not one; third-party clones are refused). `us-law-dev-bot` stays CI-only and unconfirmed (us-law coordinator).
- Rejected here: an explicit repo-dir wrapper argument (needs per-project config, ruling 2), reading the map per call (one session is one org), a stray-push hook.

## Sequence (small commits, each test-pinned)

- WP0 (`mcp-server-github`, its own PR): `--bind-repo <owner>/<repo>` refuses any other destination before a network call. Negative tests: an alternate remote and a nested clone with a different origin are both refused; the bound repo and an unset flag behave as today. Prerequisite for WP4.
- WP1: wrapper plus `scripts/test_github_agent_mcp.py` using stub server binaries that print their env and args, wired into `make validate`. Cases that fail before and pass after: each org picks its own App; refuse on unknown org, no origin, no repo, non-github host with a matching path, missing agent entry; plain repo refuses push; silent repo gets push_verified; linked worktree resolves to the main tree; empty environment still works; inherited `GIT_DIR` pointing at another repo is ignored; a global `insteadOf` rewrite does not change the selection; a misspelled or non-string `push_mode`, as org default or repo override, refuses both servers.
- WP2: write the map. Trial with per-invocation config only (`--mcp-config --strict-mcp-config` for Claude, `-c` for Codex), no global change. Live reads on GoodOlClint with each App; confirm the refuse cases; measure what the spike left open: a session started with `hc run --cwd`, and Codex through the companion runtime.
- WP3 (operator-approved remote write): one throwaway branch per agent on the proof repo, from a linked-worktree session passing main path plus branch. The commit shows Verified and is authored by that agent's App; delete the branch after. First check the Codex App has Contents write.
- WP4: cutover with `claude mcp remove` and `add -s user` and a backed-up `~/.codex/config.toml` edit; rollback restores both. Check a fresh session of each CLI in a GoodOlClint repo (tools, push), in plain homelab (no push server), and in `~/Source` (no tools).
  - Before cutover: rebuild and reinstall `push-verified` after the WP0 PR (#9) merges. The installed binary rejects `--bind-repo`, so cutting over first breaks every push server.
  - At cutover: stop the running Codex companion brokers. They keep the old server, and a fresh session does not replace them.
  - Check which App answered each live read (for example the author or installation shown on a read), not only that a read worked.
  - After cutover: run a real `adversarial-review` on the branch.
- WP5: rewrite `docs/github-agent-identity.md` (its line 79 goes), add a pointer in homelab `CLAUDE.md`, flip ADR 0059 to Accepted.

## Out of scope, with owner

- us-law ADR 0031 amendment and map entry: us-law coordinator; the operator creates the Apps.
- Skills updates (agent-repo-setup, repo-remediation) and the global `CLAUDE.md` "Git & delivery" text: Skills Coordinator and operator, notified at landing.

## Gaps and detours (filed, not fixed)

- Codex has no gate on shell `git push`; `~/.codex/hooks.json` exists (rulings said not) but hooks nothing on shell push, and whether it can is unchecked.
- `push_verified` linked-worktree fix (about 15 lines of go-git options): issue on `mcp-server-github`.
- Athena `AGENTS.md` line 92 says push via `push_files`, which Claude's config excludes.
- Global `CLAUDE.md` merge loop (merges as the App) conflicts with `docs/repo-deploy-gate.md` lines 69-71 (Apps never merge).
- Global `CLAUDE.md` says `Bash(gh` is denied; `settings.json` `deny` is empty.
- The ADR 0052 deploy-gate prerequisite is unaffected (homelab stays plain; App-authored PRs via MCP unchanged).

## Review disposition

Codex adversarial review, 2026-11-04, verdict needs-attention, 3 findings; all 3 accepted. Plan and ADR were revised after it, and the revised text was not re-reviewed.

- High, `--repo-root` does not bind the destination: accepted, in part. The `--bind-repo` flag (WP0) is added as a cutover prerequisite. Rejected: also binding the exact local repo and refusing nested repos; the destination check already refuses a nested clone of another repo, and a nested clone of the same repo is harmless.
- Medium, `GIT_DIR` and URL rewrites can select another repo: accepted. The wrapper drops `GIT_*` and reads the raw local origin; both pinned in WP1.
- Medium, a misspelled push mode enables pushes: accepted. Allowlist, pinned in WP1.

Codex did not check live authentication, remote writes or rollback. WP2 to WP4 cover those.

Second round, 2026-11-04, after cutover: Codex adversarial review, High, an inherited `GITHUB_HOST` or `GITHUB_PERSONAL_ACCESS_TOKEN` survives the wrapper (redirects the App token exchange; makes the server exit). Fixed in f7a9451 (all `GITHUB_*` dropped except toolsets and exclude-tools, test first). Re-review against 354156c: approve, 0 findings.
