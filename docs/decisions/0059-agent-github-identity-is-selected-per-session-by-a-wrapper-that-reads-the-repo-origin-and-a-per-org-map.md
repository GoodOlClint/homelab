# ADR 0059 — Agent GitHub identity is selected per session by a wrapper that reads the repo origin and a per-org map

- **Status:** Proposed
- **Date:** 2026-11-04
- **Deciders:** operator + Claude
- **Context source:** the GitHub identity discussion rulings of 2026-11-04 (cited below as ruling N) and the change plan [docs/github-identity-plan.md](../github-identity-plan.md)

## Context

An App is a GitHub App: a bot identity installed on an account or organization. Each agent kind (Claude, Codex) has one App installed on the personal account only, and each CLI starts `github-mcp-server` (the GitHub MCP server; MCP is the Model Context Protocol the CLIs use to reach tools) with that App's id, installation id and key path fixed in its own config. `push_verified` (the `mcp-server-github` tool that replays a local branch through the GitHub API so the commit is authored and Verified as the App) reads the same triple once at startup. So one App serves every repo, and a session in an organization the App is not installed on gets 404 or 403 on every call. The us-law repos live in such an organization, and the second MCP entry its ADR 0031 contemplated was never built.

The operator also wants push mode (App-authored push versus plain operator push) set per repo, and wants it enforceable rather than written in prose (ruling 4).

## Decision

1. A tracked wrapper, `scripts/github-agent-mcp <claude|codex> <github|push>`, starts both servers. It reads the session's working directory with getcwd (never an environment variable: Codex does not pass the parent environment to MCP servers and does not set `$PWD`), drops every `GIT_*` variable from the environment it passes on (an inherited `GIT_DIR` would select another repo), reads `git config --local --get remote.origin.url` (the raw local value, because `git remote get-url` applies global `insteadOf` rewrites that `push_verified`'s go-git does not, so the two could disagree), and accepts only host `github.com` in scp, `ssh://` and `https://` forms. It looks the org up case-insensitively in an untracked map and execs the server with `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY_PATH` for that org and agent. It refuses (nonzero exit, one-line stderr reason) with no repo, no origin, another host, an unknown org, or an org with no entry for that agent (ruling 2).
2. The map is `~/.config/github-agent/identities.json` (untracked; example at `docs/github-identities.example.json`). It holds identity only: per org the Apps per agent, a default `push_mode` and per-repo overrides, plus the server binary paths. A silent repo is `push_verified` (ruling 4). Toolsets and excluded tools stay in each CLI's server config.
3. `push_mode` values are `plain` or `push_verified` only; defaults apply to absent fields, and any other value or type makes the wrapper refuse before starting either server. In `push` mode the wrapper refuses to start when the repo's effective mode is `plain`; otherwise it execs `push-verified` with `--repo-root` set to the session's main working tree, found through `git rev-parse --git-common-dir` so a linked worktree resolves to its main tree, and with `--bind-repo <owner>/<repo>` from the origin. The cost: a session can push_verified only its own repo.
4. `push_verified` gains one flag, `--bind-repo`, and otherwise stays as it is. The destination comes from a caller-selected remote on every call (ADR 0005 in `mcp-server-github` leaves it unconstrained), so narrowing `--repo-root` alone does not stop a push to a plain repo through another remote or a nested clone. With the flag set, the server refuses any other destination before a network call. Selection stays at server start, since one session is one org (ruling 2). Because it refuses a linked-worktree path, agents in a worktree pass the main tree path plus the branch name (ADR 0005; branch refs are shared). This corrects ruling 2's claim that the wrapper covers worktrees: it holds for MCP calls only. A go-git fix is a separate issue on `mcp-server-github`.
5. Codex gets a `push-verified` entry, and its `github` server excludes `push_files` and `create_or_update_file`, matching Claude. Codex's `github` entry does not set `required = true`: 13 repos under `~/Source` have no origin, the wrapper refuses there, and `required` would make Codex fail to start in them, adversarial review included.
6. No new stray-push hook. Claude's `ask: Bash(git push:*)` is the operator-approval gate ruling 3 asks for. Codex has no equivalent; this is a named gap (see Consequences).
7. At landing the map has GoodOlClint with default `push_verified` and repo `homelab` set `plain` (ruling 4; homelab AGENTS.md already treats it so). US-Law-Dev has no entry until the operator creates its Apps (ruling 6).

## Rejected alternatives

- A credential helper that mints installation tokens for plain `git push`: new unverified code, breaks the us-law rule (ruling 3).
- Per-repo override files in each repo, or a map keyed by repo: overrides fall back to the default, and a repo key needs an entry for every repo (ruling 2).
- Reading the map on every `push_verified` call (a 100 to 200 line Go change): one session is one org, so start-time selection suffices.
- A wrapper argument naming the repo directory (suggested by the cwd spike): a user-scoped server config cannot carry a per-project argument without per-project files, which ruling 2 rejected. A Claude subagent in a worktree inherits its parent's server, which is the same repo and org.
- TOML for the map: under Codex's scrubbed environment `env python3` may resolve to the macOS system python, which has no `tomllib`. That is unverified; JSON removes the question.
- `required = true` on Codex's server: see Decision 5.
- A shared third App, or one App per session or model (ruling 5).

## Consequences

- A session started in `~/Source` or any non-repo directory (`~/Source/us-law` is not a repo), in a repo with no origin, or in a third-party clone gets no GitHub tools. Claude shows a failed connection only; Codex continues silently and the agent is not told. Docs say to run the wrapper by hand in that directory to see the reason.
- us-law sessions lose public-repo reads at cutover, since org calls already fail today. Cutover does not wait for the US-Law-Dev Apps. The us-law ADR 0031 amendment, the map entry and the question whether `us-law-dev-bot` exists (CI only) belong to the us-law coordinator.
- Live sessions keep the old server until restart. Cutover uses `claude mcp remove` and `claude mcp add -s user` (never hand-edit `~/.claude.json`) and a backed-up edit of `~/.codex/config.toml`; rollback restores both.
- Named gap: Codex has no gate on shell `git push`. `~/.codex/hooks.json` exists (rulings said Codex had no hooks) but nothing hooks shell push; whether it can is unchecked.
- Worktree pushes pass the main tree path plus the branch name until `push_verified` learns linked worktrees.
- `docs/github-agent-identity.md` is rewritten and its line saying local pushes ride the operator's SSH key goes; the homelab `CLAUDE.md` gains a pointer.
