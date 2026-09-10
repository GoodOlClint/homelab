# Makefile for Homelab Automation

# === Virtual Environment ===
# Prepend .venv/bin to PATH so all targets (especially Ansible on localhost)
# use the venv's python3 which has infisicalsdk and other dependencies.
VENV_PYTHON := $(CURDIR)/.venv/bin/python3
export PATH := $(CURDIR)/.venv/bin:$(PATH)

# Python clients (ansible uri, infisicalsdk/requests, proxmoxer) trust certifi only; the fleet root
# rides a certifi+root bundle written by make pki-hosts (ADR 0042). Go/curl use the keychain.
CA_BUNDLE := $(CURDIR)/kubernetes/.secrets/ca-bundle.pem
ifneq ($(wildcard $(CA_BUNDLE)),)
export SSL_CERT_FILE := $(CA_BUNDLE)
export REQUESTS_CA_BUNDLE := $(CA_BUNDLE)
endif

# === Bootstrap Secrets ===
# Read bootstrap secrets and export as TF_VAR_ environment variables.
# Supports both SOPS-encrypted and plaintext YAML (for pre-SOPS setup).
# Top-level exports ensure env vars propagate to ALL child processes.
SOPS_BOOTSTRAP := ansible/group_vars/bootstrap.sops.yml
ANSIBLE_PLAYBOOK := ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml
# Helper: try sops decrypt first, fall back to plaintext YAML read
_read_secret = $(shell sops -d --extract '["bootstrap"]["$(1)"]' $(SOPS_BOOTSTRAP) 2>/dev/null || $(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('$(SOPS_BOOTSTRAP)'))['bootstrap']['$(1)'])" 2>/dev/null)

# Decrypted only for the targets whose recipes reach terraform: a recursively-expanded
# target-specific export resolves when a recipe line runs (never at parse time), and
# _secret memoizes each key so the five sops calls happen once per make, not per line.
_secret = $(if $(_sc_$(1)),,$(eval _sc_$(1) := $$(call _read_secret,$(1))))$(_sc_$(1))
TF_TARGETS := plan apply init terraform-apply terraform-bootstrap ansible-bootstrap inventory refresh build rebuild \
  rebuild-infisical data-volumes backup-jobs sdn-apply expand-disk update-dns clean clean-vps-ssh \
  hosts-plan hosts-apply unifi-plan unifi-apply talos-plan talos-build validate \
  vps-deploy vps-rebuild vps-destroy vps-close-ssh vps-rotate-keys
$(TF_TARGETS): export TF_VAR_virtual_environment_password = $(call _secret,proxmox_password)
$(TF_TARGETS): export TF_VAR_vultr_api_key = $(call _secret,vultr_api_key)
$(TF_TARGETS): export TF_VAR_cloudflare_api_token = $(call _secret,cloudflare_api_token)
$(TF_TARGETS): export TF_VAR_unifi_password = $(call _secret,unifi_admin_password)
$(TF_TARGETS): export TF_VAR_worklab_password = $(call _secret,worklab_password)

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
ifneq (,$(filter build rebuild plan ansible update,$(firstword $(MAKECMDGOALS))))
  VM := $(wordlist 2,2,$(MAKECMDGOALS))
  ifneq (,$(VM))
    $(eval $(VM):;@:)
  endif
endif

# === Core Operations ===
.PHONY: refresh k8s-seed k8s-apps k8s-smoke k8s-update plex-pbs-image flux-check flux-reconcile monitoring-users talos-plan talos-build talos-secrets talos-apply talos-bootstrap all apply plan init terraform-apply terraform-bootstrap inventory bootstrap ansible-bootstrap build rebuild rebuild-infisical data-volumes backup-jobs sdn-apply

all: apply

apply: terraform-apply inventory ansible-all

# First-time deployment: AdGuard + Infisical only (no Infisical dependency)
bootstrap: terraform-bootstrap inventory ansible-bootstrap

ansible-bootstrap:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/bootstrap.yml

# Refresh state + outputs (terraform refresh updates state but NOT outputs) — settles agent-reported drift after a guest change.
refresh:
	@cd terraform && terraform apply -refresh-only -auto-approve -no-color -input=false > /dev/null && echo "state refreshed"

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
	@. .venv/bin/activate && pip install pyyaml infisicalsdk ansible 'proxmoxer>=2.3' requests 'bcrypt<5' passlib 'python-socketio[client]>=5.0' dnspython kubernetes
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
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/site.yml --limit $(VM)

# === Talos control plane (ADR 0031/0033) ===
# Terraform owns the VMs only; everything past first boot is talosctl driven
# from kubernetes/talos (the canonical pipeline — never Ansible).
TALOS_TARGETS = -target=proxmox_virtual_environment_download_file.talos -target=proxmox_virtual_environment_vm.talos_cp
talos-plan:
	@cd terraform && terraform init && terraform plan -no-color $(TALOS_TARGETS)
talos-build:
	@cd terraform && terraform init && terraform apply -no-color -auto-approve $(TALOS_TARGETS)
	@cd terraform && terraform output -json talos_nodes > ../kubernetes/talos/.secrets/nodes.json
talos-secrets:
	@kubernetes/talos/talos.sh secrets
# apply is also how the nodes pick up a changed root CA (machine.registries) or kubelet args
talos-apply:
	@kubernetes/talos/talos.sh apply
talos-bootstrap:
	@kubernetes/talos/talos.sh bootstrap

# === Services plane (ADR 0048) ===
# Flux owns every workload from kubernetes/<tree> (one Kustomization per tree in kubernetes/flux/apps/);
# a push to main is the deploy. Ansible owns the seed (bindings, generated ConfigMaps, root-CA ConfigMaps,
# the cert-manager intermediate, bootstrap Secrets) and the in-app tail. Needs vms.yaml and proxmox.yaml.
K8S_PLAY = $(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/kubernetes.yml $(if $(CHECK),--check --diff,)
# Refuse to adopt a tree whose ${VAR}s are not all bound — Flux blanks the rest and fails open.
flux-check:
	@.venv/bin/python3 scripts/flux_check.py $(CURDIR)
# Reconcile one tree now instead of waiting for its interval: make flux-reconcile TREE=traefik
flux-reconcile:
	@test -n "$(TREE)" || { echo "usage: make flux-reconcile TREE=<name from kubernetes/flux/apps/>"; exit 1; }
	@flux --kubeconfig kubernetes/talos/.secrets/kubeconfig reconcile kustomization $(TREE) --with-source
k8s-seed:
	@$(K8S_PLAY) --tags seed
# In-app tail (jellyfin wizard/LDAP plugin/libraries, arr external auth + SAB whitelist, authentik-ext secrets + blueprint)
k8s-apps:
	@$(K8S_PLAY) --tags apps
# Fail-loud smokes: rbd, registry, nfs, infisical
k8s-smoke:
	@$(K8S_PLAY) --tags smoke
# Cluster half of `make update`: deletes the pods of every :latest workload so they re-pull through Zot
# (never rollout restart — Flux reverts the annotation and it bounces twice); NS= scopes it
k8s-update:
	@$(K8S_PLAY) --tags update $(if $(NS),-e k8s_apps_update_ns=$(NS),)
# Build + push the pg-backup CronJob's proxmox-backup-client image (the registry's one local push);
# re-run when the PBS server major rolls (client suite tracks the Debian base)
plex-pbs-image:
	@$(K8S_PLAY) --tags pbs-image
# monitoring@pve + its token on the cluster: needs proxmox.yaml so proxmox_host resolves to a live node;
# the play tag (not a task tag) so its pre_tasks load; the UniFi half is skipped (never probe the controller with monitor creds)
monitoring-users:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/infrastructure.yml --tags monitoring-users --skip-tags unifi-user

# Fleet-root terraform passthrough with the TF_VAR_* exports (raw terraform hangs prompting for them);
# the retirement step is `make tf ARGS='state rm <address>'` (ADR 0028: stopped, never destroyed)
tf:
	@cd terraform && terraform $(ARGS)

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
# and cloud-init/file resources refresh in the same graph. PVE prunes the
# destroyed VMID from every backup job, so the rebuild ends by re-adding it. Still staged with
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
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/site.yml --limit $(VM)
	@$(MAKE) backup-jobs

# Rebuild the Infisical VM and restore the vault from its PBS dump (ADR 0039):
# unprotect through the cluster API, replace the guest, bring the stack up with
# the bootstrap keys, restore the newest databases/infisical snapshot, then bake
# the real PBS creds + confirm every machine identity. Never re-bootstraps —
# that path discards the PKI root and every identity (make bootstrap is for an
# empty fleet only). The first site.yml pass is allowed to fail: once the Phase 1
# play has the empty stack answering, a later play's secrets login gets 401 —
# the restore fixes that and the second pass must be clean. The dump is taken
# right before the replace (after an ansible pass so the vault's own PBS creds
# are current): restoring an older snapshot rewinds every secret rotated since
# it — P6 restored a pre-PBS-roll dump and /shared came back with the dead token.
rebuild-infisical:
	@echo "Taking a fresh vault dump on the running VM (a restore rewinds /shared to the snapshot)..."
	@$(MAKE) ansible VM=infisical
	@VM_IP=$$($(VENV_PYTHON) -c "import yaml; print(yaml.safe_load(open('ansible/inventory/vms.yaml'))['all']['hosts']['infisical']['ansible_host'])"); \
		ssh -o BatchMode=yes "$$VM_IP" 'sudo /usr/local/bin/infisical_pbs_backup.sh | tail -3'
	@echo "Removing Infisical VM protection via the cluster API..."
	@PVE=$$($(VENV_PYTHON) -c "import yaml; print(next(iter(yaml.safe_load(open('ansible/inventory/proxmox.yaml'))['proxmox']['hosts'].values()))['ansible_host'])"); \
		ssh -o BatchMode=yes "root@$$PVE" 'pvesh get /cluster/resources --type vm --output-format json' \
		| $(VENV_PYTHON) -c "import json,sys; r=[x for x in json.load(sys.stdin) if x['name']=='infisical' and x['status']=='running']; print(r[0]['node'], r[0]['vmid'])" \
		| { read -r node vmid; ssh "root@$$PVE" "pvesh set /nodes/$$node/qemu/$$vmid/config --protection 0"; }
	-@$(MAKE) rebuild VM=infisical
	@$(MAKE) infisical-restore
	@$(MAKE) ansible VM=infisical
	@$(MAKE) refresh-identity

# === Targeted Ansible Deploy ===
# make ansible <vm>  — run site.yml limited to a single host
ansible:
ifndef VM
	$(error Usage: make ansible <vm-name>)
endif
	@echo "Running Ansible for: $(VM)"
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/site.yml --limit $(VM) $(if $(TAGS),--tags $(TAGS)) $(if $(CHECK),--check --diff,)


# === Ansible Playbooks ===
.PHONY: ansible ansible-all ansible-infra ansible-services ansible-pfsense update update-dns expand-disk

ansible-all:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/site.yml --skip-tags unifi-user $(if $(TAGS),--tags $(TAGS))

ansible-infra:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/infrastructure.yml --skip-tags unifi-user $(if $(TAGS),--tags $(TAGS))

ansible-services:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/services.yml $(if $(TAGS),--tags $(TAGS))

ansible-pfsense:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/pfsense.yaml ansible/playbooks/pfsense.yml

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
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml -i ansible/inventory/vps.yaml ansible/playbooks/update-all.yml $(if $(VM),--limit $(VM),)

# Pause AdGuard filtering on BOTH resolver instances (no config sync — IaC deploys them identically)
adguard-pause:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/adguard-pause.yml -e "adguard_pause_minutes=$(or $(MINUTES),10)"

# Push every inventory-derived name (guests, nodes, VIPs, MetalLB addresses, mirrored
# public records) into the flat service zone over RFC 2136 (ADR 0040). Second run = 0 changed.
dns-records:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/dns-records.yml

update-dns:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/update-dns.yml

# B3: register the PBS datastore as PVE storage (run once after PBS provisioning,
# before the first terraform apply with backup_jobs populated)
backup-finalize:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/backup-finalize.yml

expand-disk:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/expand-disk.yml

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
	-target=cloudflare_dns_record.plex_ipv6 \
	-target=cloudflare_dns_record.jellyfin \
	-target=cloudflare_dns_record.jellyfin_ipv6

vps-deploy:
	@echo "Phase 1: Provisioning VPS with SSH access..."
	@cd terraform && terraform init && terraform apply -no-color -auto-approve -var vps_provisioning=true $(VPS_TF_TARGETS)
	@echo "Phase 2: Configuring VPS via Ansible (IP from terraform output)..."
	@VPS_IP=$$(cd terraform && terraform output -raw vps_reserved_ip) && [ -n "$$VPS_IP" ] && \
	  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml -i ansible/inventory/vms.yaml ansible/playbooks/vps.yml -e "ansible_host=$$VPS_IP ansible_user=root"
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
	@VPS_IP=$$(cd terraform && terraform output -raw vps_reserved_ip) && ssh-keygen -R "$$VPS_IP" 2>/dev/null || true

vps-rebuild: vps-destroy clean-vps-ssh vps-deploy

vps-rotate-keys:
	@VPS_IP=$$(cd terraform && terraform output -raw vps_reserved_ip) && [ -n "$$VPS_IP" ] && \
	  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vps.yaml ansible/playbooks/vps-rotate-keys.yml -e "ansible_host=$$VPS_IP"

# === Secrets Management ===
.PHONY: infisical-seed infisical-backup infisical-restore refresh-identity plex-token

# Restore Infisical from backup (disaster recovery)
infisical-seed:
	@bash scripts/seed_infisical.sh

# Export ALL Infisical secrets to SOPS backup (disaster recovery)
# Run before major infrastructure changes and periodically (monthly) as DR insurance.
# Output: ansible/group_vars/secrets.sops.yml (gitignored DR artifact — never committed;
# previous export preserved at .bak). Restores via make infisical-seed.
infisical-backup:
	@bash scripts/infisical_backup.sh

# Restore the newest PBS databases/infisical dump into a stack (ADR 0039 DR path).
# HOST= (default: the inventory's infisical) DIR= (default /opt/infisical; an
# empty dir gets a throwaway stack — the rehearsal) SNAPSHOT= (default newest)
infisical-restore:
	@HOST=$(HOST) DIR=$(DIR) SNAPSHOT=$(SNAPSHOT) SSH_USER=$(SSH_USER) bash scripts/infisical_pbs_restore.sh

# One-time: organize flat Infisical secrets into per-VM folders
# Retrieve Plex token from plex.tv and store in Infisical
# Requires plex_username and plex_password in bootstrap.sops.yml
plex-token:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/services.yml --limit plex

# Refresh Infisical Machine Identities (delete + re-provision)
# Optional: LIMIT=hostname to target specific VMs, TAGS=cleanup to remove orphans, FORCE=true to override health check
refresh-identity:
	@$(ANSIBLE_PLAYBOOK) ansible/playbooks/refresh-identity.yml $(if $(LIMIT),--limit $(LIMIT)) $(if $(TAGS),--tags $(TAGS)) $(if $(FORCE),-e force=true)

# === Setup & Security ===
.PHONY: setup-hooks bootstrap-local validate security-check security-check-range

setup-hooks:
	@pre-commit install --install-hooks

bootstrap-local:
	@bash scripts/bootstrap_local_config.sh

security-check:
	@bash scripts/security_guardrails.sh --staged

security-check-range:
	@bash scripts/security_guardrails.sh --range HEAD~1..HEAD

# What CI runs (.github/workflows/validate.yml) — the three terraform roots must already be init'd.
TF_ROOTS := terraform terraform/hosts terraform/unifi
validate:
	@for r in $(TF_ROOTS); do terraform -chdir=$$r fmt -check -recursive -diff && terraform -chdir=$$r validate -no-color >/dev/null && echo "$$r: validate ok" || exit 1; done
	@terraform -chdir=terraform/modules/proxmox-vm init -backend=false -input=false >/dev/null && terraform -chdir=terraform/modules/proxmox-vm test -no-color 2>&1 | grep -E '^(Success|Failure)!' | grep Success >/dev/null && echo "proxmox-vm module: terraform test ok" || { terraform -chdir=terraform/modules/proxmox-vm test -no-color; exit 1; }
	@cd ansible && ../.venv/bin/ansible-lint --offline playbooks/*.yml
	@cd ansible && $(VENV_PYTHON) -c "import re,glob,json,sys; g={h for f in glob.glob('playbooks/*.yml') for h in re.findall(r'^\s*hosts:\s*([\w,:-]+)', open(f).read(), re.M) for h in h.split(',') if h not in ('all','localhost')}; json.dump({'all':{'children':{k:{'hosts':{'stub':{}}} for k in sorted(g)}}}, open('/tmp/stub-inventory.json','w'))" \
	  && for p in playbooks/*.yml; do ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore ../.venv/bin/ansible-playbook --syntax-check -i /tmp/stub-inventory.json $$p >/dev/null || exit 1; done && echo "syntax-check: $$(ls playbooks/*.yml | wc -l | tr -d ' ') playbooks ok"
	@$(VENV_PYTHON) scripts/flux_check.py $(CURDIR) --build-only >/dev/null && echo "flux trees build"
	@$(VENV_PYTHON) scripts/test_axosyslog_routing.py
	@bash scripts/test_security_guardrails.sh
	@! grep -rnE "from-literal=|(echo|printf '%s') '\{\{[^}]*(password|secret|token|private_key)" ansible/roles ansible/tasks ansible/playbooks kubernetes scripts || { echo "secret on argv (#17): use stdin: / --value-stdin"; exit 1; }
	@echo "argv-secrets: none"
	@$(MAKE) -s -n vps-deploy | grep -q 'VPS_IP=$$(cd terraform' && echo "vps-deploy: IP resolved in-recipe"

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
	[ips.update((h or {}).get('ansible_host','') for g in (yaml.safe_load(open(f)) or {}).values() for h in (g or {}).get('hosts',{}).values()) for f in glob.glob('ansible/inventory/*.yaml')];\
	[os.system(f'ssh-keygen -R {ip}') for ip in ips if ip]"

# === Host/cluster plane — terraform/hosts/ (ADR-0002, WP1) =====================
# Separate state from the main fleet project. ENDPOINT points at the node's stable
# VLAN 30 mgmt URL during bring-up (never the bond being reconfigured), the VLAN 40
# VIP later. TF_VAR_virtual_environment_endpoint is passed INLINE (never exported
# globally — that would clobber the main project's endpoint from its tfvars).
# hosts-apply is deliberately INTERACTIVE (no auto-approve): a host-networking apply
# can drop connectivity, so review the plan and confirm by hand.
.PHONY: node-iso node-bootstrap hosts-plan hosts-apply proxmox-hosts uptime-kuma apt-proxy nut-clients ca-trust pki-hosts

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
# ENDPOINT defaults to the VIP name (its SAN is on every node cert, ADR 0041); pass a node URL during bring-up.
ENDPOINT ?= https://pve.$(shell .venv/bin/python3 -c "import yaml;print(yaml.safe_load(open('network-data/vlans.yaml'))['service_domain'])"):8006/
hosts-plan:
	@cd terraform/hosts && terraform init -input=false >/dev/null && \
		TF_VAR_virtual_environment_endpoint="$(ENDPOINT)" terraform plan -no-color -input=false $(HOSTS_TARGETS)

# Apply the host plane (interactive confirm; AUTO=1 skips it). make hosts-apply ENDPOINT=https://<node-vlan30-ip>:8006/
hosts-apply:
	@cd terraform/hosts && terraform init -input=false >/dev/null && \
		TF_VAR_virtual_environment_endpoint="$(ENDPOINT)" terraform apply -input=false $(if $(AUTO),-auto-approve,) $(HOSTS_TARGETS)

# WP2: cluster plane (pvecm, corosync rings, Ceph, VIP). Day-1: run AFTER
# hosts-apply. Needs ansible/inventory/proxmox.yaml (see proxmox.example.yml)
# and the WP2 fields in network-data/local/host-bindings.yaml.
proxmox-hosts:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml $(if $(wildcard ansible/inventory/vms.yaml),-i ansible/inventory/vms.yaml,) ansible/playbooks/proxmox-hosts.yml $(if $(LIMIT),--limit $(LIMIT),) $(if $(TAGS),--tags $(TAGS),)

# Uptime Kuma monitors + ntfy channel via the goodolclint.uptime_kuma collection (ADR 0011).
# CHECK=1 runs check mode with diff — the acceptance test is 0 changes.
uptime-kuma:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/playbooks/uptime-kuma.yml $(if $(CHECK),--check --diff,)

# apt Proxy-Auto-Detect on every node + guest (ADR 0021 client half).
apt-proxy:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/apt-proxy.yml $(if $(LIMIT),--limit $(LIMIT),)

# NUT upsmon secondaries on the physical hosts (nut_clients inventory group).
# Server side is the pfSense NUT package — see docs/pfsense-nut.md.
nut-clients:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/nut-clients.yml $(if $(LIMIT),--limit $(LIMIT),)

# ADR 0041: the Infisical root into every node's, worklab's and guest's trust store (both inventories, LIMIT=).
ca-trust:
	@$(ANSIBLE_PLAYBOOK) -i ansible/inventory/proxmox.yaml ansible/playbooks/ca-trust.yml $(if $(LIMIT),--limit $(LIMIT),)

# ADR 0041: Infisical PKI policy/profile/application + ACME/API enrollment for the fleet hosts (idempotent by name).
pki-hosts:
	@/bin/bash scripts/pki_hosts.sh

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
