#!/usr/bin/env bash
set -euo pipefail

MODE="local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--mode local|ci]" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "local" && "$MODE" != "ci" ]]; then
  echo "Invalid mode: $MODE (expected: local|ci)" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_CONFIG="$ROOT_DIR/.sops.yaml"
SECRETS_EXAMPLE="$ROOT_DIR/ansible/group_vars/secrets.sops.example.yml"
SECRETS_LOCAL="$ROOT_DIR/ansible/group_vars/secrets.sops.yml"

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[pr3] missing required command: $1" >&2
    exit 1
  fi
}

check_cmd sops

if [[ "$MODE" == "local" ]]; then
  check_cmd age
fi

if [[ ! -f "$SOPS_CONFIG" ]]; then
  echo "[pr3] missing .sops.yaml" >&2
  exit 1
fi

if grep -q "REPLACE_WITH_AGE_PUBLIC_KEY" "$SOPS_CONFIG"; then
  echo "[pr3] .sops.yaml still contains placeholder age key; update recipient before production use" >&2
fi

if [[ ! -f "$SECRETS_EXAMPLE" ]]; then
  echo "[pr3] missing secrets example file: ansible/group_vars/secrets.sops.example.yml" >&2
  exit 1
fi

if ! grep -q '^secrets:' "$SECRETS_EXAMPLE"; then
  echo "[pr3] secrets example does not contain top-level secrets map" >&2
  exit 1
fi

if [[ "$MODE" == "local" ]]; then
  if [[ ! -f "$SECRETS_LOCAL" ]]; then
    echo "[pr3] local secrets file is missing; run make bootstrap-local" >&2
    exit 1
  fi

  if grep -q '^sops:' "$SECRETS_LOCAL"; then
    if ! sops --decrypt "$SECRETS_LOCAL" >/dev/null; then
      echo "[pr3] failed to decrypt local secrets.sops.yml" >&2
      exit 1
    fi
    echo "[pr3] local secrets file is encrypted and decryptable"
  else
    echo "[pr3] local secrets.sops.yml appears unencrypted; encrypt with: sops --encrypt --in-place ansible/group_vars/secrets.sops.yml" >&2
  fi
fi

if [[ "$MODE" == "ci" ]]; then
  if [[ -z "${SOPS_AGE_KEY:-}" && ! -f "$HOME/.config/sops/age/keys.txt" ]]; then
    echo "[pr3] CI mode requires SOPS_AGE_KEY env var or ~/.config/sops/age/keys.txt" >&2
    exit 1
  fi
fi

echo "[pr3] sops workflow checks passed (mode=$MODE)"
