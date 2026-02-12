# PR1 Variable Precedence and Overlay Rules

This document defines how PR1 overlay variables are loaded and which values win.

## Current Loading Model

Playbooks load variables in this order:

1. `vars_files` base file: `ansible/group_vars/all.yml`
2. Optional runtime overlay file (if present): `ansible/group_vars/local/all.yml`

The overlay file is loaded through `pre_tasks` using `include_vars`.

## Effective Precedence Rule

When the same variable key exists in both places:

- `ansible/group_vars/local/all.yml` overrides `ansible/group_vars/all.yml`

This is intentional for local/private runtime customization.

## Safety Intent

- Keep non-sensitive defaults/placeholders in tracked files.
- Keep environment-specific and sensitive values local or encrypted.
- Avoid putting real secrets back into tracked files.

## Operator Smoke Check

Use this command to verify playbook parsing and task graph with PR1 overlay wiring:

```bash
make pr1-overlay-smoke
```

What this validates:

- Playbook parses successfully.
- PR1 `pre_tasks` blocks are syntactically valid.
- Overlay-loading tasks are visible in execution graph.

## Recommended Working Pattern

1. Set baseline non-sensitive defaults in `ansible/group_vars/all.yml`.
2. Put local/private overrides in `ansible/group_vars/local/all.yml`.
3. Run `make pr1-overlay-smoke` before broader playbook runs.
4. Run `make security-check` before commit.
