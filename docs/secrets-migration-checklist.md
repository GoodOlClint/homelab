# Secrets Migration Checklist (PR0)

Use this checklist before opening the PR0 completion PR.

## 1) Move secrets out of tracked files

- [ ] Move credentials from `ansible/group_vars/all.yml` into local/sops files.
- [ ] Move sensitive values from Terraform `vars.auto.tfvars` into local-only variables or env vars.
- [ ] Keep only placeholders/examples in tracked templates.

## 2) Rotate exposed credentials

- [ ] Proxmox API credentials/tokens
- [ ] UniFi controller credentials/tokens
- [ ] PBS tokens/passwords
- [ ] Cloudflare tunnel tokens
- [ ] Any DB/service passwords in tracked history

## 3) History remediation

- [ ] Remove sensitive historical blobs with `git filter-repo` (or BFG).
- [ ] Force push rewritten history.
- [ ] Notify collaborators to re-clone (or hard reset) after rewrite.

## 4) Guardrails verification

- [ ] `make validate-public-policy`
- [ ] `make security-check` (with `gitleaks` installed)
- [ ] Confirm GitHub Action `security-guardrails` passes on PR

## 5) Operational backup

- [ ] Backup `~/.config/sops/age/keys.txt` securely (encrypted backup/NAS secret store).
- [ ] Verify at least one restore/decrypt path exists.
