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
| Workflows | none at first | needed the first time an agent pushes a change under `.github/workflows/`; grant then, not before |

Everything else (Administration, Secrets, Environments, Deployments, Pages, Packages, Discussions, Projects, Code/Secret scanning) stays **No access**. Account permissions: none.

Do **not** grant Pull requests beyond what is listed above for review submission: an App with PR write can submit an *approving* review, so with two Apps one bot could approve the other's PR. Section 3 closes that.

### Install + key

1. *Install App* → `GoodOlClint` → **Only select repositories** → the repos agents may touch. The installation page URL ends in the **installation id**. The **App ID** is on the App's General page.
2. *Private keys → Generate a private key* — one PEM download per App. GitHub keeps no copy.
3. Store both in Infisical `/github/mcp`: `claude_app_id`, `claude_app_installation_id`, `claude_mcp_app_private_key`, and the `codex_app_id` / `codex_app_installation_id` / `codex_mcp_app_private_key` trio. User-provided, never generated.

## 2. The operator's workstation

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

Claude Code, user scope so every repo gets it; toolsets narrowed at the server:

```
claude mcp add --scope user github \
  -e GITHUB_APP_ID=<claude app id> \
  -e GITHUB_APP_INSTALLATION_ID=<claude installation id> \
  -e GITHUB_APP_PRIVATE_KEY_PATH=$HOME/.config/github-agent/claude.pem \
  -e GITHUB_TOOLSETS=repos,pull_requests,issues,actions,labels \
  -- github-mcp-server stdio
```

Codex, same shape with its own App:

```
codex mcp add github \
  --env GITHUB_APP_ID=<codex app id> \
  --env GITHUB_APP_INSTALLATION_ID=<codex installation id> \
  --env GITHUB_APP_PRIVATE_KEY_PATH=$HOME/.config/github-agent/codex.pem \
  --env GITHUB_TOOLSETS=repos,pull_requests,issues,actions,labels \
  -- github-mcp-server stdio
```

The ids are not secrets; the PEM path is the only sensitive reference and it points at a 0600 file. `~/.claude/settings.json`: allow `mcp__github__*`. `Bash(gh pr create:*)` and `Bash(git push:*)` can leave the `ask` list once section 3 is live — the ruleset is the control, the prompt was standing in for it. `gh` stays logged in as the operator for reads; agents use the MCP tools for every write.

`git push` from a local checkout still rides the operator's SSH key — commits are the operator's anyway (`user.email`), and only the PR/issue lifecycle carries the bot identity. Moving pushes onto the App means minting an installation token for a git credential helper; not needed for the stated goal, skip until it is.

## 3. The gate lives on GitHub, not in a permission prompt

Ruleset on `main` in each installed repo (*Settings → Rules → Rulesets*): require a pull request, **1 required approval**, **Require review from Code Owners**, dismiss stale approvals on push, block force-push and deletion; `GoodOlClint` on the bypass list so direct operator pushes keep working. `CODEOWNERS` = `* @GoodOlClint`. Code-owner review is what makes the approval human-only — a bot cannot be a code owner, so neither App can approve the other's PR, and an author never approves its own.

## 4. Proof

- `github-mcp-server stdio` with the three env vars set answers an MCP `initialize` (or `/mcp` in Claude Code shows `github` connected) — a 401 from the installation-token endpoint means wrong App ID/key/clock, a 404 means the installation id is wrong or the App is not installed on that account.
- From an agent session, `get_me` returns `goodolclint-claude[bot]`; Codex's returns `goodolclint-codex[bot]`.
- A throwaway PR opened by the agent is bot-authored, its merge button is blocked pending a code-owner review, and the session was not prompted.
- The tool list contains nothing outside `repos`, `pull_requests`, `issues`, `actions`, `labels`, `context` (42 tools + 3 label tools on 1.11.0).

`labels` rides the Issues permission. The `projects` toolset stays **off**: Projects v2 owned by a personal account are unreachable by any App token — GitHub's REST docs for `GET /users/{user}/projectsV2` state it "does not work with GitHub App user access tokens, GitHub App installation access tokens, or fine-grained personal access tokens" (verified 2026-08-31: the installation held `repository_projects: write`, the classic per-repo boards, and the call still returned 403). Only a classic PAT with the `project` scope reaches them, and that is the operator's identity. Organization-owned projects work with the `Projects` organization permission; enable `projects` if the board ever moves to an org.
