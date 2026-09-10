# Agent guidelines — homelab

Read [CLAUDE.md](CLAUDE.md). It is the single source of conventions for every coding agent working in this repo — architecture and ADR map, canonical pipelines, secrets handling, Ansible/Terraform/Kubernetes conventions, the Make surface, and the "What Never To Do" list. Do not maintain a second copy here; a convention or gotcha learned in a session goes into CLAUDE.md (or `docs/decisions/` for a decision), never into this file.

## Codex-specific

- **Identity:** Codex acts on GitHub as the `goodolclint-codex` App (`goodolclint-codex[bot]`), through the `github` MCP server in `stdio` mode with App auth — never as the operator, never with `gh`. Setup, permissions and the toolset allowlist: [docs/github-agent-identity.md](docs/github-agent-identity.md).
- **Push and PR rules** are CLAUDE.md "Git & delivery discipline": `git push` is a local command over the operator's key and stays gated; never open a PR unless asked; the bot never approves a PR; never `--no-verify`.
- **Review role:** when Codex runs as the pre-commit / PR reviewer, judge the diff against CLAUDE.md as it stands on `main`; comments in the code are claims, not evidence (CLAUDE.md "Code comment discipline").
