#!/usr/bin/env bash
set -euo pipefail

MODE="staged"
RANGE=""

PROTECTED_PATH_REGEX='(^|/)(ansible/group_vars/all\.yml|terraform/(infrastructure|services)/vars\.auto\.tfvars|terraform/(infrastructure|services)/terraform\.tfstate(\.backup)?|ansible/inventory/vms\.yaml)$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged)
      MODE="staged"
      shift
      ;;
    --range)
      MODE="range"
      RANGE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--staged] | [--range <git-range>]" >&2
      exit 2
      ;;
  esac
done

changed_files() {
  if [[ "$MODE" == "staged" ]]; then
    git diff --cached --name-only
  else
    git diff --name-only "$RANGE"
  fi
}

echo "[guardrails] checking protected paths"
if changed_files | grep -E "$PROTECTED_PATH_REGEX" >/dev/null 2>&1; then
  echo "[guardrails] blocked: commit touches protected high-risk files." >&2
  echo "[guardrails] move secrets/topology to local overlays or encrypted sops files before committing." >&2
  echo "[guardrails] blocked files:" >&2
  changed_files | grep -E "$PROTECTED_PATH_REGEX" | sed 's/^/  - /' >&2
  exit 1
fi

echo "[guardrails] validating publishable policy files"
python3 scripts/validate_public_policy.py network-data/public_policy.yaml

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "[guardrails] gitleaks not found in PATH. Install it to enable secret scanning." >&2
  echo "[guardrails] macOS: brew install gitleaks" >&2
  exit 1
fi

if [[ "$MODE" == "staged" ]]; then
  echo "[guardrails] scanning staged changes for secrets (gitleaks protect --staged)"
  gitleaks protect --staged --redact --verbose
else
  if [[ -z "$RANGE" ]]; then
    echo "[guardrails] --range mode requires a git range" >&2
    exit 2
  fi
  echo "[guardrails] scanning commit range for secrets: $RANGE"
  gitleaks git --redact --verbose --log-opts "$RANGE"
fi

echo "[guardrails] all checks passed"
