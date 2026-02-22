# Makefile for Homelab Automation

# === Core Operations ===
.PHONY: all apply plan init terraform-apply inventory

all: apply

apply: terraform-apply inventory ansible-all

plan:
	@cd terraform && terraform init && terraform plan -no-color

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml
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
