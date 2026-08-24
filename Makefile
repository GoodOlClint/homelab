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
export TF_VAR_worklab_password := $(call _read_secret,worklab_password)

# === Bootstrap Terraform Targets ===
# Only create the AdGuard and Infisical guests (+ network dependencies).
# Resolved at recipe time by scripts/guest-targets.sh (B2): correct whether
# adguard is a VM (today), an LXC, or numbered instances (adguard1/adguard2 —
# group-targets matches the WP4 redundancy convention). Resolution failure must
# abort the recipe: an empty expansion would make the apply unscoped.

# === Per-VM Argument Capture ===
# Enables: make plan <vm>, make build <vm>, make rebuild <vm>
# Captures the VM name from the second word in MAKECMDGOALS and creates a no-op
# target for it so Make doesn't error on the unknown target name.
ifneq (,$(filter build rebuild plan ansible docker-config update,$(firstword $(MAKECMDGOALS))))
  VM := $(wordlist 2,2,$(MAKECMDGOALS))
  ifneq (,$(VM))
    $(eval $(VM):;@:)
  endif
endif

# === Core Operations ===
.PHONY: talos-plan talos-build talos-secrets talos-apply talos-bootstrap talos-csi talos-smoke talos-lb talos-certs talos-registry talos-trust registry-smoke talos-arc talos-ingress talos-infisical infisical-smoke talos-homepage all apply plan init terraform-apply terraform-bootstrap inventory bootstrap ansible-bootstrap build rebuild rebuild-infisical data-volumes backup-jobs sdn-apply

all: apply

apply: terraform-apply inventory ansible-all

# First-time deployment: AdGuard + Infisical only (no Infisical dependency)
bootstrap: terraform-bootstrap inventory ansible-bootstrap

ansible-bootstrap:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/bootstrap.yml

plan:
ifdef VM
	@cd terraform && TARGETS="$$(../scripts/guest-targets.sh $(VM) group-targets)" \
		&& terraform init && terraform plan -no-color $$TARGETS
else
	@cd terraform && terraform init && terraform plan -no-color
endif

# Prefer the repo venv's ansible/python for every bare ansible-* invocation —
# proxmoxer (ADR 0023 delegated modules) lives there, and a system ansible's
# interpreter can't see it. Falls through to PATH when .venv doesn't exist.
export PATH := $(CURDIR)/.venv/bin:$(PATH)

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml infisicalsdk ansible 'proxmoxer>=2.3' requests bcrypt
	@cd terraform && terraform init
	@cd ansible && ansible-galaxy install -r requirements.yml --force

terraform-apply:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve

terraform-bootstrap:
	@cd terraform \
		&& ADGUARD_TARGETS="$$(../scripts/guest-targets.sh adguard group-targets)" \
		&& INFISICAL_TARGETS="$$(../scripts/guest-targets.sh infisical group-targets)" \
		&& terraform init && terraform apply -no-color -auto-approve $$ADGUARD_TARGETS $$INFISICAL_TARGETS

# Targeted applies (build/rebuild) never recompute outputs — refresh first so
# the inventory reflects the guest that actually exists (PBS re-home, 2026-08-23).
inventory: clean-ssh
	@cd terraform && terraform apply -refresh-only -auto-approve -no-color > /dev/null
	@cd terraform && terraform output -no-color -raw ansible_inventory_yaml > ../ansible/inventory/vms.yaml

# === Per-VM Build/Rebuild ===
# make build <vm>   — terraform-apply + inventory + ansible for a single guest
# make rebuild <vm>  — replace the guest in one apply, clean SSH key, reconfigure
# Guest type (VM vs LXC) is resolved by scripts/guest-targets.sh (B2) — the
# holder container is never targeted (ADR 0015).
build:
ifndef VM
	$(error Usage: make build <vm-name>)
endif
	@echo "Building guest: $(VM)"
	@cd terraform && TARGETS="$$(../scripts/guest-targets.sh $(VM) group-targets)" \
		&& terraform init && terraform apply -no-color -auto-approve $$TARGETS
	@$(MAKE) inventory
	@echo "Configuring guest: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml --limit $(VM)

# === Talos control plane (ADR 0031/0033) ===
# Terraform owns the VMs only; everything past first boot is talosctl driven
# from kubernetes/talos (the canonical pipeline — never Ansible).
TALOS_TARGETS = -target=proxmox_virtual_environment_download_file.talos -target=proxmox_virtual_environment_download_file.talos_worklab -target=proxmox_virtual_environment_vm.talos_cp -target=proxmox_virtual_environment_vm.talos_cp_worklab
talos-plan:
	@cd terraform && terraform init && terraform plan -no-color $(TALOS_TARGETS)
talos-build:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve $(TALOS_TARGETS)
	@cd terraform && terraform output -json talos_nodes > ../kubernetes/talos/.secrets/nodes.json
talos-secrets:
	@kubernetes/talos/talos.sh secrets
talos-apply:
	@kubernetes/talos/talos.sh apply
talos-bootstrap:
	@kubernetes/talos/talos.sh bootstrap
talos-csi:
	@kubernetes/ceph-csi/deploy.sh
talos-smoke:
	@kubernetes/ceph-csi/deploy.sh smoke
# P3b (ADR 0034): MetalLB L2, internal CA, Zot, ARC runners
talos-lb:
	@kubernetes/metallb/deploy.sh
talos-certs:
	@kubernetes/cert-manager/deploy.sh
talos-trust:
	@kubernetes/talos/talos.sh apply
talos-registry:
	@kubernetes/zot/deploy.sh
registry-smoke:
	@kubernetes/zot/deploy.sh smoke
talos-arc:
	@kubernetes/arc/deploy.sh
# P4a (ADR 0035): Traefik ingress, Infisical operator (the k8s secret path), homepage
talos-ingress:
	@kubernetes/traefik/deploy.sh
talos-infisical:
	@kubernetes/infisical/deploy.sh
infisical-smoke:
	@kubernetes/infisical/deploy.sh smoke
talos-homepage:
	@kubernetes/homepage/deploy.sh
# P4b (ADR 0036): monitoring stack; axosyslog LB on services offset 66; history migration from the old guest
talos-monitoring:
	@kubernetes/monitoring/deploy.sh
monitoring-migrate:
	@kubernetes/monitoring/deploy.sh migrate $(FROM)
# monitoring@pve + its token on the cluster: needs proxmox.yaml so proxmox_host resolves to a live node;
# the play tag (not a task tag) so its pre_tasks load; the UniFi half is skipped (never probe the controller with monitor creds)
monitoring-users:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/infrastructure.yml --tags monitoring-users --skip-tags unifi-user
# P4c (ADR 0037): plex-services stack; media via a kubelet-mounted NFS PV; pg dumps pushed to PBS
talos-plex-services:
	@kubernetes/plex-services/deploy.sh
plex-services-smoke:
	@kubernetes/plex-services/deploy.sh smoke
plex-services-migrate:
	@kubernetes/plex-services/deploy.sh migrate $(FROM)
plex-services-kuma:
	@kubernetes/plex-services/deploy.sh kuma
# Build + push the pg-backup CronJob's proxmox-backup-client image (the registry's one local push);
# re-run when the PBS server major rolls (client suite tracks the Debian base)
plex-pbs-image:
	@DOMAIN=$$(jq -r .domain kubernetes/talos/.secrets/nodes.json); \
	docker build --platform linux/amd64 -t registry.$$DOMAIN/homelab/proxmox-backup-client:trixie kubernetes/plex-services/pbs-client && \
	docker push registry.$$DOMAIN/homelab/proxmox-backup-client:trixie

# PVE backup jobs (B3): apply only the job resources after editing
# `backup_jobs` in vars.auto.tfvars — never a bare apply while old-shape
# guests are unmanaged by state (ADR 0028).
backup-jobs:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -target=proxmox_backup_job.jobs

# SDN only (zones + VNETs from vlans.yaml): adding a guest VLAN must never be a
# bare fleet apply while old-shape guests sit outside state (ADR 0028).
sdn-apply:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -target=module.network $(if $(REAPPLY),-replace='module.network.proxmox_virtual_environment_sdn_applier.apply[0]',)

# Data-volume holder (ADR 0020): apply the holder ALONE, then format+chown the
# new volume(s) on the cluster plane — never the holder and its consumer in one
# apply (the consumer would start against a raw disk).
data-volumes:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -target=module.vms.proxmox_virtual_environment_vm.data_volume_holder
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/data-volumes.yml

# Rebuild = one atomic apply with -replace: no destroyed-but-not-rebuilt window,
# and cloud-init/file resources refresh in the same graph. Still staged with
# -target pre-cutover (a full-graph apply proposes the known replace-all drift);
# drop the `targets` part once the post-cutover plan is clean.
rebuild:
ifndef VM
	$(error Usage: make rebuild <vm-name>)
endif
	@echo "Replacing guest: $(VM)"
	@VM_IP=$$(python3 -c "import yaml; print(yaml.safe_load(open('ansible/inventory/vms.yaml'))['all']['hosts']['$(VM)']['ansible_host'])" 2>/dev/null); \
		[ -n "$$VM_IP" ] && ssh-keygen -R "$$VM_IP" 2>/dev/null || true
	@cd terraform && TARGETS="$$(../scripts/guest-targets.sh $(VM) targets)" \
		&& REPLACE="$$(../scripts/guest-targets.sh $(VM) replace)" \
		&& terraform init && terraform apply -no-color -auto-approve $$TARGETS $$REPLACE
	@$(MAKE) inventory
	@echo "Configuring guest: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml --limit $(VM)

# Rebuild Infisical VM — destroys, recreates, and re-bootstraps.
# Stale credential detection in bootstrap_infisical_setup.yml handles
# re-creating the admin account, project, identity, and folder structure.
rebuild-infisical:
	@echo "Removing Infisical VM protection via Proxmox..."
	@PROXMOX_HOST=$$($(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('ansible/group_vars/all.yml'))['proxmox_host'])"); \
		ssh "root@$$PROXMOX_HOST" "qm set \$$(qm list | awk '/infisical/{print \$$1}') --protection 0" 2>/dev/null || true
	@echo "Destroying Infisical VM..."
	@cd terraform && terraform init && terraform destroy -no-color -auto-approve \
		-target='module.vms.proxmox_virtual_environment_vm.vms["infisical"]' \
		-var 'unprotect=true'
	@VM_IP=$$($(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('ansible/inventory/vms.yaml'))['all']['hosts']['infisical']['ansible_host'])"); \
		ssh-keygen -R "$$VM_IP" 2>/dev/null || true
	@echo "Rebuilding Infisical VM..."
	@cd terraform && terraform apply -no-color -auto-approve \
		-target=module.network \
		-target='module.vms.proxmox_virtual_environment_vm.vms["infisical"]' \
		-target='module.vms.proxmox_virtual_environment_file.user_data["infisical"]' \
		-target='module.vms.proxmox_virtual_environment_file.network_data["infisical"]'
	@$(MAKE) inventory
	@echo "Re-bootstrapping Infisical (skipping AdGuard)..."
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/bootstrap.yml --skip-tags adguard

# === Targeted Ansible Deploy ===
# make ansible <vm>  — run site.yml limited to a single host
ansible:
ifndef VM
	$(error Usage: make ansible <vm-name>)
endif
	@echo "Running Ansible for: $(VM)"
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml --limit $(VM) $(if $(TAGS),--tags $(TAGS))

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
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/site.yml $(if $(TAGS),--tags $(TAGS))

ansible-infra:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/infrastructure.yml $(if $(TAGS),--tags $(TAGS))

ansible-services:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/services.yml $(if $(TAGS),--tags $(TAGS))

ansible-pfsense:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/pfsense.yaml ansible/playbooks/pfsense.yml

docker-deploy:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/docker.yml

# update-all.yml is hosts:all with parallel reboot-if-required and no serial
# batching — against the cluster it can reboot every PVE node and both DNS
# replicas in one play (audit 2026-08-10 B4). Gated until the serialized,
# quorum/Ceph/DNS-aware rewrite lands post-cutover. UNSAFE_UPDATE=true is the
# emergency bypass; prefer VM=<host> which limits the play to one guest.
update:
ifneq ($(UNSAFE_UPDATE),true)
ifndef VM
	$(error make update is gated until the serialized update play lands (gap-remediation plan B4). Use 'make update <vm>' for a single host, or UNSAFE_UPDATE=true to bypass)
endif
endif
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml -i ansible/inventory/vps.yaml ansible/playbooks/update-all.yml $(if $(VM),--limit $(VM),)

# Pause AdGuard filtering on BOTH resolver instances (no config sync — IaC deploys them identically)
adguard-pause:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/adguard-pause.yml -e "adguard_pause_minutes=$(or $(MINUTES),10)"

# Add a DNS rewrite on BOTH resolver instances (config template is initial-only; live edits go via API)
adguard-rewrite:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/adguard-rewrite.yml -e "adguard_rewrite_domain=$(DOMAIN) adguard_rewrite_answer=$(ANSWER)"

update-dns:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/update-dns.yml

# B3: register the PBS datastore as PVE storage (run once after PBS provisioning,
# before the first terraform apply with backup_jobs populated)
backup-finalize:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/backup-finalize.yml

expand-disk:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/expand-disk.yml

# === VPS Management ===
.PHONY: vps-deploy vps-ansible vps-close-ssh vps-destroy vps-rebuild vps-rotate-keys clean-vps-ssh

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

# Day-2: run the vps playbook over the tunnel (post-hardening, root SSH is gone)
vps-ansible:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml -i ansible/inventory/vms.yaml ansible/playbooks/vps.yml

# Day-2: close the provisioning SSH rule if a failed vps-deploy left it open
vps-close-ssh:
	@echo "Closing SSH in Vultr firewall..."
	@cd terraform && terraform apply -no-color -auto-approve -var vps_provisioning=false $(VPS_TF_TARGETS)

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

# Restore Infisical from backup (disaster recovery)
infisical-seed:
	@bash scripts/seed_infisical.sh

# Export ALL Infisical secrets to SOPS backup (disaster recovery)
# Run before major infrastructure changes and periodically (monthly) as DR insurance.
# Output: ansible/group_vars/secrets.sops.yml (gitignored DR artifact — never committed;
# previous export preserved at .bak). Restores via make infisical-seed.
infisical-backup:
	@bash scripts/infisical_backup.sh

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

# === Host/cluster plane — terraform/hosts/ (ADR-0002, WP1) =====================
# Separate state from the main fleet project. ENDPOINT points at the node's stable
# VLAN 30 mgmt URL during bring-up (never the bond being reconfigured), the VLAN 40
# VIP later. TF_VAR_virtual_environment_endpoint is passed INLINE (never exported
# globally — that would clobber the main project's endpoint from its tfvars).
# hosts-apply is deliberately INTERACTIVE (no auto-approve): a host-networking apply
# can drop connectivity, so review the plan and confirm by hand.
.PHONY: node-iso node-bootstrap hosts-plan hosts-apply proxmox-hosts nut-clients

# Bake a node's answer file (+ optional ISO): make node-iso NODE=crete [ISO=/path/pve-9.iso]
node-iso:
	@bash scripts/bake-answer.sh $(NODE) $(ISO)

# Bake the answer file for EVERY node in host-bindings (PXE answer endpoint
# serves them by install-NIC MAC — ADR 0026). Then `make ansible pxe` to ship.
node-answers:
	@for n in $$(.venv/bin/python3 -c "import yaml;print(' '.join(yaml.safe_load(open('network-data/local/host-bindings.yaml'))['nodes']))"); do bash scripts/bake-answer.sh $$n || exit 1; done

# --- PXE install safety gate (ADR 0026) --------------------------------------
# A node will ONLY receive its answer file (and thus be wiped+installed) while it
# is ARMED. Default is disarmed, so an accidental PXE boot never erases a host.
# Arm deliberately right before an install; it auto-expires after ARM_MINUTES.
ARM_MINUTES ?= 30
node-arm:
	@test -n "$(NODE)" || { echo "ERROR: set NODE=<ms-01a|ms-01b|msi>"; exit 1; }
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible pxe -i ansible/inventory/vms.yaml -b -o -m ansible.builtin.shell 		-a "mkdir -p /srv/pxe/answers/armed && date -d '+$(ARM_MINUTES) min' +%s > /srv/pxe/answers/armed/$(NODE)" >/dev/null
	@echo "ARMED $(NODE) for install for $(ARM_MINUTES) min. It will be WIPED on its next PXE boot. 'make node-disarm NODE=$(NODE)' to cancel."

node-disarm:
	@test -n "$(NODE)" || { echo "ERROR: set NODE=<node>"; exit 1; }
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible pxe -i ansible/inventory/vms.yaml -b -o -m ansible.builtin.file 		-a "path=/srv/pxe/answers/armed/$(NODE) state=absent" >/dev/null && echo "DISARMED $(NODE)."

node-arm-status:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible pxe -i ansible/inventory/vms.yaml -b -m ansible.builtin.shell -a 'set -- /srv/pxe/answers/armed/*; if [ -e "$$1" ]; then for f; do echo "$$(basename "$$f"): armed until $$(date -d @"$$(cat "$$f")" 2>/dev/null)"; done; else echo "(no nodes armed)"; fi'

# One hand-off step: create terraform@pve token on a fresh node. make node-bootstrap IP=<node-vlan30-ip>
node-bootstrap:
	@bash scripts/node-bootstrap.sh $(IP)

# Plan the host plane. make hosts-plan ENDPOINT=https://<node-vlan30-ip>:8006/
# NODE=<name> scopes the plan/apply to that node's resources — REQUIRED before the
# node is clustered (a standalone node's API cannot reach the others); omit it
# once the cluster exists to converge every node through the VIP.
HOSTS_TARGETS = $(if $(NODE),-target='proxmox_network_linux_bond.bond0["$(NODE)"]' -target='proxmox_network_linux_bridge.vmbr0["$(NODE)"]' -target='proxmox_network_linux_vlan.storage["$(NODE)"]',)
hosts-plan:
	@test -n "$(ENDPOINT)" || { echo "ERROR: set ENDPOINT=https://<node-vlan30-ip>:8006/"; exit 1; }
	@cd terraform/hosts && terraform init -input=false >/dev/null && \
		TF_VAR_virtual_environment_endpoint="$(ENDPOINT)" terraform plan -no-color -input=false $(HOSTS_TARGETS)

# Apply the host plane (interactive confirm; AUTO=1 skips it). make hosts-apply ENDPOINT=https://<node-vlan30-ip>:8006/
hosts-apply:
	@test -n "$(ENDPOINT)" || { echo "ERROR: set ENDPOINT=https://<node-vlan30-ip>:8006/"; exit 1; }
	@cd terraform/hosts && terraform init -input=false >/dev/null && \
		TF_VAR_virtual_environment_endpoint="$(ENDPOINT)" terraform apply -input=false $(if $(AUTO),-auto-approve,) $(HOSTS_TARGETS)

# WP2: cluster plane (pvecm, corosync rings, Ceph, VIP). Day-1: run AFTER
# hosts-apply. Needs ansible/inventory/proxmox.yaml (see proxmox.example.yml)
# and the WP2 fields in network-data/local/host-bindings.yaml.
proxmox-hosts:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/proxmox-hosts.yml $(if $(LIMIT),--limit $(LIMIT),) $(if $(TAGS),--tags $(TAGS),)

# NUT upsmon secondaries on the physical hosts (nut_clients inventory group).
# Server side is the pfSense NUT package — see docs/pfsense-nut.md.
nut-clients:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/nut-clients.yml $(if $(LIMIT),--limit $(LIMIT),)

# === UniFi plane — terraform/unifi/ (WP5, ADR 0005) ============================
# Separate root: the unifi provider connects to the controller at plan time, so
# it must never sit in the fleet project. Day-0: adopt the switch, fill
# network-data/local/unifi-ports.yaml + terraform/unifi/vars.auto.tfvars, then
# plan/apply. TF_VAR_unifi_password comes from bootstrap.sops.yml (top of file).
.PHONY: unifi-plan unifi-apply
unifi-plan:
	@cd terraform/unifi && terraform init -input=false >/dev/null && terraform plan -no-color -input=false

# Interactive confirm (like hosts-apply): switch-port changes can cut off nodes.
unifi-apply:
	@cd terraform/unifi && terraform init -input=false >/dev/null && terraform apply -input=false
