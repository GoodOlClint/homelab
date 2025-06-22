# Makefile for Homelab Automation

.PHONY: all infra services inventory ansible apply update plan destroy

all: apply

init:
	@python3 -m venv .venv
	@. .venv/bin/activate && pip install pyyaml
	@cd terraform/infrastructure && terraform init
	@cd terraform/services && terraform init

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
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/update-dns.yml

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

