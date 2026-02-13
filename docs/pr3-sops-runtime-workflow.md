# PR3 SOPS Runtime Workflow

Goal: provide one consistent local workflow and one CI-safe workflow for encrypted Ansible secrets.

## Scope

- Secrets file path: `ansible/group_vars/secrets.sops.yml` (local-only, ignored)
- Rules file: `.sops.yaml`
- Example template: `ansible/group_vars/secrets.sops.example.yml`

## Local Operator Workflow (Developer Laptop)

1. Install tools:
   - `brew install sops age`
2. Generate (or reuse) an age key:
   - `mkdir -p ~/.config/sops/age`
   - `age-keygen -o ~/.config/sops/age/keys.txt`
3. Capture your public recipient:
   - `grep '^# public key:' ~/.config/sops/age/keys.txt`
4. Update `.sops.yaml` recipient placeholders with your public key.
5. Bootstrap local files:
   - `make bootstrap-local`
6. Edit secrets using sops (preferred):
   - `sops ansible/group_vars/secrets.sops.yml`
7. Validate workflow before any run:
   - `make pr3-secrets-check`
8. Run playbooks normally (playbooks already conditionally load secrets file):
   - `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/services.yml --check`

## Secret Rotation Workflow

Use this for token/password rotation while preserving encrypted-at-rest handling.

1. Rotate credential at source system (Proxmox/UniFi/PBS/Cloudflare/etc.).
2. Update local encrypted file with `sops ansible/group_vars/secrets.sops.yml`.
3. Validate decryptability and schema shape:
   - `make pr3-secrets-check`
4. Run guardrails and targeted playbook check mode:
   - `make security-check`
   - `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/infrastructure.yml --check --list-tasks`
5. Never commit local decrypted secrets files.

## CI-Safe Workflow

This repository does not track real secrets. CI should use ephemeral secret material only.

### Recommended model

- Store age private key in CI secret manager as `SOPS_AGE_KEY` (multiline value from `~/.config/sops/age/keys.txt`).
- Materialize key at runtime only in temporary location.
- Decrypt only for the job duration.
- Remove temp key file in cleanup step.

### Minimal CI pattern

```yaml
- name: Prepare age key for sops
  run: |
    mkdir -p "$HOME/.config/sops/age"
    cat > "$HOME/.config/sops/age/keys.txt" <<'EOF'
    ${{ secrets.SOPS_AGE_KEY }}
    EOF
    chmod 600 "$HOME/.config/sops/age/keys.txt"

- name: Validate sops workflow (CI mode)
  run: bash scripts/validate_sops_workflow.sh --mode ci

- name: Secure cleanup
  if: always()
  run: rm -f "$HOME/.config/sops/age/keys.txt"
```

## Recovery Notes

- Backup age key securely (encrypted backup location).
- Verify decrypt path after backup restore at least once.
- If key is lost, existing encrypted files cannot be decrypted.

## PR3 Completion Commands

- `make pr3-secrets-check`
- `make security-check`
- `make security-check-range`
