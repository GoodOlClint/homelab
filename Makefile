# Makefile for Homelab Automation

# === Virtual Environment ===
# Prepend .venv/bin to PATH so all targets (especially Ansible on localhost)
# use the venv's python3 which has infisicalsdk and other dependencies.
VENV_PYTHON := $(CURDIR)/.venv/bin/python3
export PATH := $(CURDIR)/.venv/bin:$(PATH)

# === Bootstrap Secrets ===
# Read bootstrap secrets and export as TF_VAR_ environment variables.
# Supports both SOPS-encrypted and plaintext YAML (for pre-SOPS setup).
# Top-level exports ensure env vars propagate to ALL child processes.
SOPS_BOOTSTRAP := ansible/group_vars/bootstrap.sops.yml
# Helper: try sops decrypt first, fall back to plaintext YAML read
_read_secret = $(shell sops -d --extract '["bootstrap"]["$(1)"]' $(SOPS_BOOTSTRAP) 2>/dev/null || $(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('$(SOPS_BOOTSTRAP)'))['bootstrap']['$(1)'])" 2>/dev/null)

export TF_VAR_virtual_environment_password := $(call _read_secret,proxmox_password)
export TF_VAR_vultr_api_key := $(call _read_secret,vultr_api_key)
export TF_VAR_cloudflare_api_token := $(call _read_secret,cloudflare_api_token)
export TF_VAR_unifi_password := $(call _read_secret,unifi_admin_password)

# === Bootstrap Terraform Targets ===
# Only create the AdGuard and Infisical VMs (+ network dependencies)
BOOTSTRAP_TF_TARGETS := \
	-target=module.network \
	-target=module.vms.proxmox_virtual_environment_vm.vms[\"adguard\"] \
	-target=module.vms.proxmox_virtual_environment_file.user_data[\"adguard\"] \
	-target=module.vms.proxmox_virtual_environment_file.network_data[\"adguard\"] \
	-target=module.vms.proxmox_virtual_environment_vm.vms[\"infisical\"] \
	-target=module.vms.proxmox_virtual_environment_file.user_data[\"infisical\"] \
	-target=module.vms.proxmox_virtual_environment_file.network_data[\"infisical\"]

# === Per-VM Argument Capture ===
# Enables: make plan <vm>, make build <vm>, make rebuild <vm>
# Captures the VM name from the second word in MAKECMDGOALS and creates a no-op
# target for it so Make doesn't error on the unknown target name.
ifneq (,$(filter build rebuild plan ansible docker-config,$(firstword $(MAKECMDGOALS))))
  VM := $(wordlist 2,2,$(MAKECMDGOALS))
  ifneq (,$(VM))
    $(eval $(VM):;@:)
  endif
endif

# === Core Operations ===
.PHONY: all apply plan init terraform-apply terraform-bootstrap inventory bootstrap ansible-bootstrap build rebuild

all: apply

apply: terraform-apply inventory ansible-all

# First-time deployment: AdGuard + Infisical only (no Infisical dependency)
bootstrap: terraform-bootstrap inventory ansible-bootstrap

ansible-bootstrap:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/bootstrap.yml

plan:
ifdef VM
	@cd terraform && terraform init && terraform plan -no-color \
		-target=module.network \
		-target='module.vms.proxmox_virtual_environment_vm.vms["$(VM)"]' \
		-target='module.vms.proxmox_virtual_environment_file.user_data["$(VM)"]' \
		-target='module.vms.proxmox_virtual_environment_file.network_data["$(VM)"]'
else
	@cd terraform && terraform init && terraform plan -no-color
endif

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml infisicalsdk
	@cd terraform && terraform init
	@cd ansible && ansible-galaxy install -r requirements.yml --force

terraform-apply:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve

terraform-bootstrap:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve $(BOOTSTRAP_TF_TARGETS)

inventory: clean-ssh
	@cd terraform && terraform output -no-color -raw ansible_inventory_yaml > ../ansible/inventory/vms.yaml

# === Per-VM Build/Rebuild ===
# make build <vm>   — terraform-apply + inventory + ansible for a single VM
# make rebuild <vm>  — destroy VM, clean SSH key, then build
build:
ifndef VM
	$(error Usage: make build <vm-name>)
endif
	@echo "Building VM: $(VM)"
	@cd terraform && terraform init && terraform apply -no-color -auto-approve \
		-target=module.network \
		-target='module.vms.proxmox_virtual_environment_vm.vms["$(VM)"]' \
		-target='module.vms.proxmox_virtual_environment_file.user_data["$(VM)"]' \
		-target='module.vms.proxmox_virtual_environment_file.network_data["$(VM)"]'
	@$(MAKE) inventory
	@echo "Configuring VM: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml --limit $(VM)

rebuild:
ifndef VM
	$(error Usage: make rebuild <vm-name>)
endif
	@echo "Destroying VM: $(VM)"
	@cd terraform && terraform init && terraform destroy -no-color -auto-approve \
		-target='module.vms.proxmox_virtual_environment_vm.vms["$(VM)"]'
	@VM_IP=$$(python3 -c "import yaml; print(yaml.safe_load(open('ansible/inventory/vms.yaml'))['all']['hosts']['$(VM)']['ansible_host'])"); \
		ssh-keygen -R "$$VM_IP" 2>/dev/null || true
	@$(MAKE) build $(VM)

# === Targeted Ansible Deploy ===
# make ansible <vm>  — run site.yml limited to a single host
ansible:
ifndef VM
	$(error Usage: make ansible <vm-name>)
endif
	@echo "Running Ansible for: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml --limit $(VM)

# make docker-config <vm> — deploy only docker-compose, config templates, and restart
docker-config:
ifndef VM
	$(error Usage: make docker-config <vm-name>)
endif
	@echo "Deploying docker configs for: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/docker-config.yml --limit $(VM)

# === Ansible Playbooks ===
.PHONY: ansible ansible-all ansible-infra ansible-services ansible-pfsense docker-deploy docker-config update update-dns expand-disk

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
.PHONY: vps-deploy vps-destroy vps-rebuild vps-rotate-keys clean-vps-ssh

# Phase 1: terraform with SSH open -> ansible configures everything -> terraform closes SSH
VPS_TF_TARGETS := \
	-target=vultr_ssh_key.deploy \
	-target=vultr_startup_script.vps_bootstrap \
	-target=vultr_reserved_ip.vps \
	-target=vultr_firewall_group.vps \
	-target=vultr_firewall_rule.wg_tunnel \
	-target=vultr_firewall_rule.plex \
	-target=vultr_firewall_rule.valheim \
	-target=vultr_firewall_rule.mobile_wg \
	-target=vultr_firewall_rule.icmp \
	-target=vultr_firewall_rule.ssh_provisioning \
	-target=vultr_firewall_rule.wg_tunnel_v6 \
	-target=vultr_firewall_rule.plex_v6 \
	-target=vultr_firewall_rule.valheim_v6 \
	-target=vultr_firewall_rule.mobile_wg_v6 \
	-target=vultr_firewall_rule.icmpv6 \
	-target=vultr_firewall_rule.ssh_provisioning_v6 \
	-target=vultr_instance.vps \
	-target=cloudflare_dns_record.vps \
	-target=cloudflare_dns_record.plex \
	-target=cloudflare_dns_record.vps_ipv6 \
	-target=cloudflare_dns_record.plex_ipv6

vps-deploy:
	@echo "Phase 1: Provisioning VPS with SSH access..."
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -var vps_provisioning=true $(VPS_TF_TARGETS)
	@echo "Phase 2: Configuring VPS via Ansible (IP from terraform output)..."
	$(eval VPS_IP := $(shell cd terraform && terraform output -raw vps_reserved_ip))
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml -i ansible/inventory/vms.yaml ansible/playbooks/vps.yml -e "ansible_host=$(VPS_IP) ansible_user=root"
	@echo "Phase 3: Closing SSH in Vultr firewall..."
	@cd terraform && terraform apply -no-color -auto-approve -var vps_provisioning=false $(VPS_TF_TARGETS)
	@echo "VPS deployment complete. SSH now only accessible via WireGuard tunnel."

vps-destroy:
	@echo "Destroying VPS instance (keeping reserved IP)..."
	@cd terraform && terraform init && terraform destroy -no-color -auto-approve -target=vultr_instance.vps

clean-vps-ssh:
	$(eval VPS_IP := $(shell cd terraform && terraform output -raw vps_reserved_ip))
	@ssh-keygen -R $(VPS_IP) 2>/dev/null || true

vps-rebuild: vps-destroy clean-vps-ssh vps-deploy

vps-rotate-keys:
	$(eval VPS_IP := $(shell cd terraform && terraform output -raw vps_reserved_ip))
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml ansible/playbooks/vps-rotate-keys.yml -e "ansible_host=$(VPS_IP)"

# === Secrets Management ===
.PHONY: infisical-seed infisical-backup infisical-organize refresh-identity plex-token

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

# Retrieve Plex token from plex.tv and store in Infisical
# Requires plex_username and plex_password in bootstrap.sops.yml
plex-token:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/services.yml --limit plex

# Refresh Infisical Machine Identities (delete + re-provision)
# Optional: LIMIT=hostname to target specific VMs, TAGS=cleanup to remove orphans, FORCE=true to override health check
refresh-identity:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/refresh-identity.yml $(if $(LIMIT),--limit $(LIMIT)) $(if $(TAGS),--tags $(TAGS)) $(if $(FORCE),-e force=true)

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
.PHONY: clean clean-ssh clean-infisical-sops

# make clean       — destroy everything except protected VMs (Proxmox protection blocks deletion;
#                    dependent resources like SDN networks are also preserved)
# make clean FORCE=true — unprotect + destroy everything, reset Infisical SOPS fields
clean:
ifdef FORCE
	@cd terraform && \
	if terraform state show 'module.vms.proxmox_virtual_environment_vm.vms["infisical"]' >/dev/null 2>&1; then \
		echo "Disabling VM protection for destroy..." && \
		terraform apply -no-color -auto-approve -var unprotect=true \
			-target='module.vms.proxmox_virtual_environment_vm.vms["infisical"]'; \
	fi
	@cd terraform && terraform destroy -no-color -auto-approve
	@$(MAKE) clean-infisical-sops
else
	-@cd terraform && terraform destroy -no-color -auto-approve
	@echo ""
	@echo "Protected VMs preserved. Use 'make clean FORCE=true' to destroy everything."
endif
	@$(MAKE) clean-ssh

clean-infisical-sops:
	@SOPS_FILE=ansible/group_vars/bootstrap.sops.yml; \
	if [ -f "$$SOPS_FILE" ]; then \
		echo "Resetting Infisical fields in bootstrap.sops.yml..."; \
		for key in infisical_url infisical_project_id infisical_org_id; do \
			sops --set "[\"bootstrap_config\"][\"$$key\"] \"REPLACE_ME\"" "$$SOPS_FILE"; \
		done; \
		for key in infisical_postgres_password infisical_encryption_key infisical_auth_secret \
		           infisical_admin_password infisical_client_id infisical_client_secret; do \
			sops --set "[\"bootstrap\"][\"$$key\"] \"REPLACE_ME\"" "$$SOPS_FILE"; \
		done; \
		echo "Infisical fields reset to REPLACE_ME. Provider credentials preserved."; \
	else \
		echo "No bootstrap.sops.yml found — nothing to reset."; \
	fi

clean-ssh:
	@python3 -c "\
	import yaml, os, glob;\
	ips = set();\
	[ips.update(h.get('ansible_host','') for h in yaml.safe_load(open(f)).get('all',{}).get('hosts',{}).values()) for f in glob.glob('ansible/inventory/*.yaml')];\
	[os.system(f'ssh-keygen -R {ip}') for ip in ips if ip]"
