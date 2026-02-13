# PR7 Controlled Consumer Adoption

Goal: adopt generated policy output in one consumer path with explicit safety toggle and rollback.

## First Consumer

- Consumer: `ansible/playbooks/infrastructure.yml`
- Toggle variable: `use_rendered_policy` (default `false`)
- Artifact consumed: `network-data/generated/policy_render.public.json`

## Behavior

- Toggle off (`use_rendered_policy=false`): legacy behavior, no rendered artifact load.
- Toggle on (`use_rendered_policy=true`):
  - assert artifact exists
  - load rendered artifact into `rendered_policy`
  - show summary debug for verification

## Cutover Command

- `make pr6-render`
- `make pr7-consumer-smoke`

## Rollback Command

- Stop passing `-e use_rendered_policy=true`
- Or set `-e use_rendered_policy=false`

This provides one-step rollback to legacy behavior.
