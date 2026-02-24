# Makefile for Homelab Automation

# === Bootstrap Secrets ===
# Read bootstrap secrets and export as TF_VAR_ environment variables.
# Supports both SOPS-encrypted and plaintext YAML (for pre-SOPS setup).
# Top-level exports ensure env vars propagate to ALL child processes.
SOPS_BOOTSTRAP := ansible/group_vars/bootstrap.sops.yml
# Helper: try sops decrypt first, fall back to plaintext YAML read
VENV_PYTHON := $(CURDIR)/.venv/bin/python3
_read_secret = $(shell sops -d --extract '["bootstrap"]["$(1)"]' $(SOPS_BOOTSTRAP) 2>/dev/null || $(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('$(SOPS_BOOTSTRAP)'))['bootstrap']['$(1)'])" 2>/dev/null)

export TF_VAR_virtual_environment_password := $(call _read_secret,proxmox_password)
export TF_VAR_vultr_api_key := $(call _read_secret,vultr_api_key)
export TF_VAR_cloudflare_api_token := $(call _read_secret,cloudflare_api_token)
export TF_VAR_unifi_password := $(call _read_secret,unifi_admin_password)

# === Core Operations ===
.PHONY: all apply plan init terraform-apply inventory bootstrap ansible-bootstrap

all: apply

apply: terraform-apply inventory ansible-all

# First-time deployment: DNS + AdGuard + Infisical only (no Infisical dependency)
bootstrap: terraform-apply inventory ansible-bootstrap

ansible-bootstrap:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/bootstrap.yml

plan:
	@cd terraform && terraform init && terraform plan -no-color

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml infisicalsdk
	@cd terraform && terraform init
	@cd ansible && ansible-galaxy install -r requirements.yml --force

terraform-apply:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve

inventory: clean-ssh
	@cd terraform && terraform output -no-color -raw ansible_inventory_yaml > ../ansible/inventory/vms.yaml

# === Ansible Playbooks ===
.PHONY: ansible-all ansible-infra ansible-services ansible-pfsense docker-deploy update update-dns expand-disk

ansible-all:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml

ansible-infra:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/infrastructure.yml

ansible-services:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/services.yml

ansible-pfsense:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/pfsense.yaml ansible/playbooks/pfsense.yml

docker-deploy:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/docker.yml

update:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/update-all.yml

update-dns:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/update-dns.yml

expand-disk:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/expand-disk.yml

# === VPS Management ===
.PHONY: vps-deploy vps-destroy vps-rebuild vps-rotate-keys

# Phase 1: terraform with SSH open -> ansible configures everything -> terraform closes SSH
vps-deploy:
	@echo "Phase 1: Provisioning VPS with SSH access..."
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -var vps_provisioning=true
	@echo "Phase 2: Configuring VPS via Ansible (IP from terraform output)..."
	$(eval VPS_IP := $(shell cd terraform && terraform output -raw vps_reserved_ip))
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml -i ansible/inventory/vms.yaml ansible/playbooks/vps.yml -e "ansible_host=$(VPS_IP) ansible_user=root"
	@echo "Phase 3: Closing SSH in Vultr firewall..."
	@cd terraform && terraform apply -no-color -auto-approve -var vps_provisioning=false
	@echo "VPS deployment complete. SSH now only accessible via WireGuard tunnel."

vps-destroy:
	@echo "Destroying VPS instance (keeping reserved IP)..."
	@cd terraform && terraform init && terraform destroy -no-color -auto-approve -target=vultr_instance.vps

vps-rebuild: vps-destroy vps-deploy

vps-rotate-keys:
	$(eval VPS_IP := $(shell cd terraform && terraform output -raw vps_reserved_ip))
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml ansible/playbooks/vps-rotate-keys.yml -e "ansible_host=$(VPS_IP)"

# === Secrets Management ===
.PHONY: infisical-seed infisical-backup infisical-organize

# One-time: migrate SOPS secrets to Infisical
infisical-seed:
	@bash scripts/seed_infisical.sh

# Export Infisical secrets back to SOPS (backup/disaster recovery)
infisical-backup:
	@echo "Backing up Infisical secrets to SOPS..."
	@infisical secrets list --env prod --path / --format json | \
		$(VENV_PYTHON) scripts/infisical_to_sops.py > ansible/group_vars/secrets.sops.yml.bak
	@sops --encrypt --in-place ansible/group_vars/secrets.sops.yml.bak
	@echo "Backup saved to ansible/group_vars/secrets.sops.yml.bak"

# One-time: organize flat Infisical secrets into per-VM folders
infisical-organize:
	@bash scripts/organize_infisical_folders.sh

# === Setup & Security ===
.PHONY: setup-hooks bootstrap-local validate-public-policy security-check security-check-range

setup-hooks:
	@pre-commit install --install-hooks

bootstrap-local:
	@bash scripts/bootstrap_local_config.sh

validate-public-policy:
	@python3 scripts/validate_public_policy.py network-data/public_policy.yaml

security-check:
	@bash scripts/security_guardrails.sh --staged

security-check-range:
	@bash scripts/security_guardrails.sh --range HEAD~1..HEAD

# === Cleanup ===
.PHONY: clean clean-terraform clean-ssh

clean: clean-terraform clean-ssh

clean-terraform:
	@cd terraform && terraform destroy -no-color -auto-approve

clean-ssh:
	@. .venv/bin/activate && python3 -c "\
	import yaml, os, glob;\
	ips = set();\
	[ips.update(h.get('ansible_host','') for h in yaml.safe_load(open(f)).get('all',{}).get('hosts',{}).values()) for f in glob.glob('ansible/inventory/*.yaml')];\
	[os.system(f'ssh-keygen -R {ip}') for ip in ips if ip]"
