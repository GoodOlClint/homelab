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

required_vars=(
  TF_VAR_virtual_environment_password
  TF_VAR_unifi_password
  TF_VAR_virtual_machine_password_hash
)

required_local_keys=(
  virtual_environment_endpoint
  virtual_environment_password
  unifi_password
  unifi_api_url
  ssh_public_key_path
)

read_tfvars_value() {
  local file_path="$1"
  local key="$2"
  local line
  line="$(grep -E "^[[:space:]]*$key[[:space:]]*=" "$file_path" | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return
  fi

  echo "$line" | sed -E 's/^[^=]+= *"?([^"#]*)"?.*$/\1/' | xargs
}

looks_like_placeholder() {
  local value="$1"
  [[ "$value" =~ REPLACE_WITH_ ]] || \
    [[ "$value" =~ YOUR_ ]] || \
    [[ "$value" =~ your_ ]] || \
    [[ "$value" =~ example\.internal ]] || \
    [[ "$value" =~ your_unifi_controller ]] || \
    [[ "$value" =~ /home/your_username ]] || \
    [[ "$value" =~ ^fd00::/48$ ]]
}

check_tf_root() {
  local root="$1"
  local tf_root="$ROOT_DIR/terraform/$root"
  local local_tfvars="$tf_root/vars.local.auto.tfvars"
  local example_tfvars="$tf_root/vars.auto.tfvars.example"

  if [[ ! -d "$tf_root" ]]; then
    echo "[pr4] missing terraform root: terraform/$root" >&2
    exit 1
  fi

  if [[ ! -f "$example_tfvars" ]]; then
    echo "[pr4] missing template file: terraform/$root/vars.auto.tfvars.example" >&2
    exit 1
  fi

  if [[ "$MODE" == "local" && ! -f "$local_tfvars" ]]; then
    echo "[pr4] missing local tfvars: terraform/$root/vars.local.auto.tfvars" >&2
    echo "[pr4] create from example and keep it untracked" >&2
    exit 1
  fi

  if [[ "$MODE" == "local" ]]; then
    for key in "${required_local_keys[@]}"; do
      value="$(read_tfvars_value "$local_tfvars" "$key")"
      if [[ -z "$value" ]]; then
        echo "[pr4] missing required key in terraform/$root/vars.local.auto.tfvars: $key" >&2
        exit 1
      fi
      if looks_like_placeholder "$value"; then
        echo "[pr4] placeholder value detected in terraform/$root/vars.local.auto.tfvars: $key" >&2
        echo "[pr4] replace placeholder values before running secure terraform plans" >&2
        exit 1
      fi
    done

    ssh_key_path="$(read_tfvars_value "$local_tfvars" "ssh_public_key_path")"
    ssh_key_path="${ssh_key_path/#\~/$HOME}"
    if [[ ! -f "$ssh_key_path" ]]; then
      echo "[pr4] ssh_public_key_path does not exist for terraform/$root: $ssh_key_path" >&2
      exit 1
    fi
  fi
}

check_tf_root infrastructure
check_tf_root services

if [[ "$MODE" == "ci" ]]; then
  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      echo "[pr4] missing required CI environment variable: $var_name" >&2
      exit 1
    fi
  done
  echo "[pr4] terraform sensitive input checks passed (mode=ci)"
  exit 0
fi

echo "[pr4] local tfvars files present for both terraform roots"
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "[pr4] note: $var_name is not exported (acceptable if present in vars.local.auto.tfvars)"
  fi
done

echo "[pr4] terraform sensitive input checks passed (mode=local)"
