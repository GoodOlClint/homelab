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
	@cd terraform/infrastructure && terraform output -raw ansible_inventory_yaml > /tmp/vms-infra.yaml || true
	@cd terraform/services && terraform output -raw ansible_inventory_yaml > /tmp/vms-services.yaml || true
	@. .venv/bin/activate && python3 -c "import yaml, sys; infra=yaml.safe_load(open('/tmp/vms-infra.yaml')); services=yaml.safe_load(open('/tmp/vms-services.yaml')); merged={'all': {'hosts': {}}}; merged['all']['hosts'].update(infra.get('all', {}).get('hosts', {})); merged['all']['hosts'].update(services.get('all', {}).get('hosts', {})); yaml.safe_dump(merged, open('ansible/inventory/vms.yaml', 'w'))"

terraform-infra:
	@cd terraform/infrastructure && terraform init && terraform apply -auto-approve

terraform-services:
	@cd terraform/services && terraform init && terraform apply -auto-approve

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
	@ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/vms.yaml ansible/playbooks/update-all.yml

plan:
	@cd terraform/infrastructure && terraform init && terraform plan
	@cd terraform/services && terraform init && terraform plan

clean-infra:
	@cd terraform/infrastructure && terraform destroy -auto-approve

clean-services:
	@cd terraform/services && terraform destroy -auto-approve

clean-ssh:
	@. .venv/bin/activate && python3 -c "import yaml; f=open('ansible/inventory/vms.yaml'); ips=[h['ansible_host'] for h in yaml.safe_load(f)['all']['hosts'].values()]; [__import__('os').system(f'ssh-keygen -R {ip}') for ip in ips]"

clean: clean-infra clean-services clean-ssh

