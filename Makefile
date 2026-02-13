# Makefile for Homelab Automation

.PHONY: all infra services inventory ansible apply update plan destroy validate-public-policy security-check security-check-range setup-hooks bootstrap-local pr1-overlay-smoke pr3-secrets-check pr4-tf-check tf-plan-infra-secure tf-plan-services-secure tf-apply-infra-secure tf-apply-services-secure pr6-render pr6-render-check pr6-render-local pr7-consumer-smoke pr8-audit-deprecated pr8-deprecated-check

all: apply

validate-public-policy:
	@python3 scripts/validate_public_policy.py network-data/public_policy.yaml

security-check:
	@bash scripts/security_guardrails.sh --staged

security-check-range:
	@bash scripts/security_guardrails.sh --range HEAD~1..HEAD

setup-hooks:
	@pre-commit install --install-hooks

bootstrap-local:
	@bash scripts/bootstrap_local_config.sh

pr1-overlay-smoke:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/docker.yml --limit docker --check --list-tasks

pr3-secrets-check:
	@bash scripts/validate_sops_workflow.sh --mode local

pr4-tf-check:
	@bash scripts/validate_terraform_sensitive_inputs.sh --mode local

tf-plan-infra-secure:
	@cd terraform/infrastructure && terraform init && terraform plan -no-color -var-file=vars.local.auto.tfvars

tf-plan-services-secure:
	@cd terraform/services && terraform init && terraform plan -no-color -var-file=vars.local.auto.tfvars

tf-apply-infra-secure:
	@cd terraform/infrastructure && terraform init && terraform apply -no-color -auto-approve -var-file=vars.local.auto.tfvars

tf-apply-services-secure:
	@cd terraform/services && terraform init && terraform apply -no-color -auto-approve -var-file=vars.local.auto.tfvars

pr6-render:
	@python3 scripts/render_policy_artifact.py --public network-data/public_policy.yaml --private network-data/private_bindings.example.yaml --output network-data/generated/policy_render.public.json

pr6-render-check:
	@python3 scripts/render_policy_artifact.py --public network-data/public_policy.yaml --private network-data/private_bindings.example.yaml --output network-data/generated/policy_render.public.json --check

pr6-render-local:
	@python3 scripts/render_policy_artifact.py --public network-data/public_policy.yaml --private network-data/local/private_bindings.yaml --output network-data/local/rendered/policy_render.local.json

pr7-consumer-smoke:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/proxmox.yaml ansible/playbooks/infrastructure.yml --check --list-tasks -e use_rendered_policy=true

pr8-audit-deprecated:
	@python3 scripts/audit_deprecated_vars.py --root . --output docs/pr8-deprecated-var-audit.md

pr8-deprecated-check:
	@python3 scripts/check_deprecated_var_usage.py --root .

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml
	@cd terraform/infrastructure && terraform init
	@cd terraform/services && terraform init
	@cd ansible && ansible-galaxy install -r requirements.yml --force

infra: terraform-infra inventory ansible-infra

services: terraform-services inventory ansible-services

inventory: clean-ssh
	@cd terraform/infrastructure && terraform output -no-color -raw ansible_inventory_yaml > /tmp/vms-infra.yaml 2>/dev/null || true
	@cd terraform/services && terraform output -no-color -raw ansible_inventory_yaml > /tmp/vms-services.yaml 2>/dev/null || true
	@. .venv/bin/activate && python3 merge_inventory.py

terraform-infra:
	@cd terraform/infrastructure && terraform init && terraform apply -no-color -auto-approve

terraform-services:
	@cd terraform/services && terraform init && terraform apply -no-color -auto-approve

ansible-infra:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/infrastructure.yml

ansible-services:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/services.yml

ansible-all:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/all.yml

docker-deploy:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/docker.yml

apply: terraform-infra terraform-services inventory ansible-all

update:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/update-all.yml

update-dns:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml -i ansible/inventory/proxmox.yaml ansible/playbooks/update-dns.yml

plan:
	@cd terraform/infrastructure && terraform init && terraform plan -no-color
	@cd terraform/services && terraform init && terraform plan -no-color

expand-disk:
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/expand-disk.yml

clean-infra:
	@cd terraform/infrastructure && terraform destroy -no-color -auto-approve

clean-services:
	@cd terraform/services && terraform destroy -no-color -auto-approve

clean-ssh:
	@. .venv/bin/activate && python3 -c "import yaml; f=open('ansible/inventory/vms.yaml'); ips=[h['ansible_host'] for h in yaml.safe_load(f)['all']['hosts'].values()]; [__import__('os').system(f'ssh-keygen -R {ip}') for ip in ips]"

clean: clean-services clean-infra clean-ssh
