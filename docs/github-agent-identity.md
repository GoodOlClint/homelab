# GitHub identities for coding agents — the `goodolclint-claude` and `goodolclint-codex` Apps

Coding agents act on GitHub as their own identity, never as the operator: Claude Code as `goodolclint-claude[bot]`, Codex as `goodolclint-codex[bot]`. The operator reviews and merges as `GoodOlClint`. Each agent runs the GitHub MCP server locally in `stdio` mode with **GitHub App authentication** — the server signs a JWT with the App's private key, exchanges it for a 1 h installation token and refreshes it itself; no PAT, no machine user, no browser. App auth is `stdio`-only (`docs/github-app-auth.md`: "not available for the `http` command"), which is why the hosted server at `api.githubcopilot.com` is not used. Sources: `github/github-mcp-server` `README.md`, `docs/github-app-auth.md`, `docs/remote-server.md` (toolset names).

## 1. Create the two Apps

*Settings → Developer settings → GitHub Apps → New GitHub App*, once per name. Identical settings apart from the name:

| Field | Value |
|---|---|
| GitHub App name | `goodolclint-claude` / `goodolclint-codex` |
| Homepage URL | `https://github.com/GoodOlClint` |
| Callback URL, Device flow, Setup URL | empty / off — the App never does user OAuth |
| Webhook | **Active unchecked** — nothing listens |
| Where can this App be installed? | **Only on this account** |

### Repository permissions

| Permission | Level | Why (toolset that needs it) |
|---|---|---|
| Metadata | Read | mandatory for every App; `context` (`get_me`), search |
| Contents | **Read and write** | `repos` — read files, `create_branch`, `push_files`; also what a PR merge writes |
| Pull requests | **Read and write** | `pull_requests` — open, update, comment, request reviewers |
| Issues | **Read and write** | `issues` |
| Actions | Read | `actions` — list runs, read job logs. Raise to write only if agents should `rerun`/`cancel` |
| Checks | Read | PR status rollup |
| Commit statuses | Read | PR status rollup |
| Workflows | none at first | needed the first time an agent pushes a change under `.github/workflows/`; grant then, not before (the 2026-11-04 installations show `workflows: write`) |

Everything else (Administration, Secrets, Environments, Deployments, Pages, Packages, Discussions, Projects, Code/Secret scanning) stays **No access**. Account permissions: none.

Do **not** grant Pull requests beyond what is listed above for review submission: an App with PR write can submit an *approving* review, so with two Apps one bot could approve the other's PR. Section 3 closes that.

### Install + key

1. *Install App* → `GoodOlClint` → the repos agents may touch (the installations read on 2026-11-04 are `repository_selection: all`; narrow them if that is not intended). The installation page URL ends in the **installation id**. The **App ID** is on the App's General page.
2. *Private keys → Generate a private key* — one PEM download per App. GitHub keeps no copy.
3. Store both in Infisical `/github/mcp`: `claude_app_id`, `claude_app_installation_id`, `claude_mcp_app_private_key`, and the `codex_app_id` / `codex_app_installation_id` / `codex_mcp_app_private_key` trio. User-provided, never generated.

## 2. The operator's workstation

Design record: [ADR 0059](decisions/0059-agent-github-identity-is-selected-per-session-by-a-wrapper-that-reads-the-repo-origin-and-a-per-org-map.md) and [the change plan](github-identity-plan.md). In short: which App a session uses is decided at session start from the repo's `origin`, by one wrapper, from one untracked map.

### Keys, binaries, map

```
brew install github-mcp-server
mkdir -p ~/.config/github-agent && chmod 700 ~/.config/github-agent
cd ~/Source/homelab   # the CLI takes its project from the repo's .infisical.json; elsewhere pass --projectId
infisical login --domain "$(sops -d --extract '["bootstrap_config"]["infisical_url"]' ansible/group_vars/bootstrap.sops.yml)/api"   # once; a login saved against the pre-P8 :8080 address is refused
infisical secrets get claude_mcp_app_private_key --path /github/mcp --env prod --plain > ~/.config/github-agent/claude.pem
infisical secrets get codex_mcp_app_private_key  --path /github/mcp --env prod --plain > ~/.config/github-agent/codex.pem
chmod 600 ~/.config/github-agent/*.pem
openssl rsa -in ~/.config/github-agent/claude.pem -check -noout   # "RSA key ok" — a misspelled key name exits 0 and writes an EMPTY file
```

Two CLI traps met on the first run: the repo's gitignored `.infisical.json` carried the project ID from before the vault rebuild (404 "not found during bot lookup" — rewrite `workspaceId` from `bootstrap_config.infisical_project_id`, and set `defaultEnvironment` to `prod` so `--env` is optional), and `secrets get` of a key that does not exist prints nothing and exits 0.

`push_verified` is the `mcp-server-github` binary (Go). Build it from its repo with `go build -o ~/go/bin/mcp-server-github ./cmd/mcp-server-github` and confirm `mcp-server-github -h` lists `-bind-repo`; the wrapper passes that flag, so an older binary makes every push server fail to start. Rebuild after each pull of that repo.

The map is `~/.config/github-agent/identities.json` (mode 0600, directory 0700, never tracked; the shape is [github-identities.example.json](github-identities.example.json)). Per org it holds each agent's `app_id`, `installation_id` and `key_path`, a default `push_mode` and per-repo overrides, plus the absolute paths of the two server binaries. The ids are not secrets; the key path points at a 0600 file. `~/.claude/settings.json` allows `mcp__github__*`.

### The wrapper

`scripts/github-agent-mcp <claude|codex> <github|push>` is what both CLIs run. The CLI configs reference it by its absolute path in the main checkout (`~/Source/homelab/scripts/github-agent-mcp`), so it must exist there.

- It reads the session's working directory (never an environment variable), then `git config --local --get remote.origin.url`, and accepts only `github.com` in scp, `ssh://git@` and userinfo-free `https://` forms. It looks the org up case-insensitively in the map and execs the server with that org's App for that agent.
- It drops every `GIT_*` variable and every `GITHUB_*` variable except `GITHUB_TOOLSETS` and `GITHUB_EXCLUDE_TOOLS`, then sets the App triple. An inherited `GITHUB_HOST` would redirect the App token exchange and an inherited `GITHUB_PERSONAL_ACCESS_TOKEN` makes the server exit.
- It refuses, with a one-line reason on stderr, when there is no repo, no origin, another host, an unknown org, or no entry for that agent in the org.

CLI entries (the only environment is toolsets and exclusions; no App id, installation id or key path appears in either CLI's config):

```
claude mcp add github -s user \
  -e GITHUB_TOOLSETS=repos,pull_requests,issues,actions,labels -e GITHUB_EXCLUDE_TOOLS=create_or_update_file,push_files \
  -- ~/Source/homelab/scripts/github-agent-mcp claude github
claude mcp add push-verified -s user -- ~/Source/homelab/scripts/github-agent-mcp claude push
codex mcp add github --env GITHUB_TOOLSETS=repos,pull_requests,issues,actions,labels --env GITHUB_EXCLUDE_TOOLS=create_or_update_file,push_files \
  -- ~/Source/homelab/scripts/github-agent-mcp codex github
codex mcp add push-verified -- ~/Source/homelab/scripts/github-agent-mcp codex push
```

(Use absolute paths in the commands.) Never hand-edit `~/.claude.json`. Codex's `github` server carries no `required = true`: repos without an origin would otherwise stop Codex starting at all, adversarial review included.

### Push modes

`push_mode` is `push_verified` (the default when the map is silent) or `plain`, set per org with per-repo overrides; any other value, or a non-string, makes the wrapper refuse both servers.

| Mode | Pushes | Servers |
|---|---|---|
| `push_verified` | the agent calls `push_verified`: the branch is replayed through the GitHub API so the commit is authored by the App and Verified | `push` starts `mcp-server-github --repo-root <main tree> --bind-repo <owner>/<repo>`, so a session can push only its own repo; a nested clone or another remote is refused before any network call |
| `plain` | the operator pushes; the App only does PRs, issues and reads | `push` refuses to start; `github` still works |

`homelab` is `plain` in the map. `push` also refuses any layout whose git common dir is not named `.git` (bare, bare worktree, submodule, separate-git-dir); a separate-git-dir store literally named `.git` passes, and `--bind-repo` still holds.

### Worktrees

`push_verified` refuses a linked-worktree path. In a worktree, pass the main tree's path (the wrapper's `--repo-root`) plus the branch name; branch refs are shared, so the commits made in the worktree are found. MCP read/write calls other than `push_verified` work from a worktree unchanged.

### Seeing a refusal

A refusal looks like a failed connection in Claude (`CONNECTION_CLOSED`) and like missing tools in Codex, which carries on silently. To read the reason, run the wrapper by hand in the directory:

```
cd <the repo or directory> && ~/Source/homelab/scripts/github-agent-mcp claude github < /dev/null
```

Sessions started in `~/Source` or another non-repo directory, in a repo with no origin, or in a third-party clone get no GitHub tools by design. Run `hc run --cwd <repo>` for a Herdr terminal so the wrapper sees the right directory.

### Codex specifics

- Codex's `push-verified` is prompt-gated: no `approval_mode` is set. In an interactive session the operator approves each push; non-interactive runs (`codex exec`, the companion runtime) decline it with `MCP tool call requires approval, but approval policy is never`. That is deliberate (ADR 0059 consequences).
- Codex has no gate on shell `git push`; Claude's `ask: Bash(git push:*)` is the gate on that side.
- The Codex companion keeps one broker (a background `app-server-broker` process) per workspace, and a running broker keeps the MCP servers it started with. After any change to the CLI entries, stop idle brokers (the lifecycle call `sendBrokerShutdown` in the plugin's `lib/broker-lifecycle.mjs`, the same one its session-end hook sends) and never kill a broker that has a running job; new sessions then start fresh ones. Live sessions of either CLI keep the old servers until restarted.

### Rollback

Before a cutover, copy `~/.codex/config.toml` and write the current `github` and `push-verified` entries from `~/.claude.json` to files in a 0600 directory outside any repo. To roll back: `claude mcp remove -s user <name>` then `claude mcp add-json -s user <name> "$(cat <file>)"` for each of the two, and copy the Codex config back. Reading the ids from the files keeps any id from being typed by hand. The 2026-11-04 cutover's backup is `~/.config/github-agent/backup-20261104/` and its script `~/.claude/kickoffs/reports/homelab-identity-wp4-rollback.sh`.

### Adding an org

1. The operator creates the org's two Apps in the org's own settings (not the personal account) and installs them on the org, keeping each PEM at 0600 in `~/.config/github-agent/`. The secrets go in Infisical `/github/mcp` under the existing key names with an org prefix, for example `us_law_dev_claude_app_id` and `us_law_dev_claude_mcp_app_private_key`.
2. Add `orgs.<Org>.agents.{claude,codex}` (app id, installation id, key path) and, if the default should not be `push_verified`, `push_mode` and `repos` overrides to the map. No code and no CLI change: the next session started in a repo of that org picks it up.
3. From a repo of that org, run the wrapper by hand for each agent and kind, then a fresh session of each CLI (see the proof list below).

`git push` itself stays the operator's: a plain `git push` rides the operator's SSH key and Claude prompts for it. Only the PR, issue and (in `push_verified` repos) branch lifecycle carries the bot identity.

## 3. The gate lives on GitHub, not in a permission prompt

Ruleset on `main` in each installed repo (*Settings → Rules → Rulesets*): require a pull request, **1 required approval**, **Require review from Code Owners**, dismiss stale approvals on push, block force-push and deletion; `GoodOlClint` on the bypass list so direct operator pushes keep working. `CODEOWNERS` = `* @GoodOlClint`. Code-owner review is what makes the approval human-only — a bot cannot be a code owner, so neither App can approve the other's PR, and an author never approves its own.

## 4. Proof

- `github-mcp-server stdio` with the three env vars set answers an MCP `initialize` (or `/mcp` in Claude Code shows `github` connected) — a 401 from the installation-token endpoint means wrong App ID/key/clock, a 404 means the installation id is wrong or the App is not installed on that account.
- Which App a session uses is shown by a `push_verified` commit's author (`goodolclint-claude[bot]` or `goodolclint-codex[bot]`, `verification.verified: true`); the GitHub read tools do not name the caller (measured 2026-11-04).
- A throwaway PR opened by the agent is bot-authored, its merge button is blocked pending a code-owner review, and the session was not prompted.
- The tool list contains nothing outside `repos`, `pull_requests`, `issues`, `actions`, `labels`, `context` (42 tools + 3 label tools on 1.11.0).

`labels` rides the Issues permission. The `projects` toolset stays **off**: Projects v2 owned by a personal account are unreachable by any App token — GitHub's REST docs for `GET /users/{user}/projectsV2` state it "does not work with GitHub App user access tokens, GitHub App installation access tokens, or fine-grained personal access tokens" (verified 2026-08-31: the installation held `repository_projects: write`, the classic per-repo boards, and the call still returned 403). Only a classic PAT with the `project` scope reaches them, and that is the operator's identity. Organization-owned projects work with the `Projects` organization permission; enable `projects` if the board ever moves to an org.
