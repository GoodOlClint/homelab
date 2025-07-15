#!/usr/bin/env python3
"""
Merge Terraform-generated inventory files into the main Ansible inventory.
This script combines infrastructure and services VM inventories.
"""

import yaml
import os
import sys
from pathlib import Path

def load_yaml_file(filepath):
    """Load YAML file and return data, or empty dict if file doesn't exist."""
    try:
        with open(filepath, 'r') as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        print(f"Warning: {filepath} not found, skipping...")
        return {}
    except Exception as e:
        print(f"Error loading {filepath}: {e}")
        return {}

def merge_inventories():
    """Merge infrastructure and services inventories into main VMs inventory."""
    
    # Load Terraform-generated inventories
    infra_inventory = load_yaml_file('/tmp/vms-infra.yaml')
    services_inventory = load_yaml_file('/tmp/vms-services.yaml')
    
    # Load existing inventory as base
    existing_inventory = load_yaml_file('ansible/inventory/vms.yaml')
    
    # Initialize merged inventory structure
    merged_inventory = {
        'all': {
            'hosts': {}
        }
    }
    
    # Start with existing inventory hosts
    if 'all' in existing_inventory and 'hosts' in existing_inventory['all']:
        merged_inventory['all']['hosts'].update(existing_inventory['all']['hosts'])
    
    # Add infrastructure hosts
    if 'all' in infra_inventory and 'hosts' in infra_inventory['all']:
        for hostname, host_data in infra_inventory['all']['hosts'].items():
            merged_inventory['all']['hosts'][hostname] = host_data
            print(f"Added infrastructure host: {hostname} -> {host_data.get('ansible_host', 'N/A')}")
    
    # Add services hosts
    if 'all' in services_inventory and 'hosts' in services_inventory['all']:
        for hostname, host_data in services_inventory['all']['hosts'].items():
            merged_inventory['all']['hosts'][hostname] = host_data
            print(f"Added services host: {hostname} -> {host_data.get('ansible_host', 'N/A')}")
    
    # Write merged inventory
    output_path = 'ansible/inventory/vms.yaml'
    try:
        with open(output_path, 'w') as f:
            yaml.safe_dump(merged_inventory, f, default_flow_style=False, sort_keys=True)
        print(f"Successfully wrote merged inventory to {output_path}")
        
        # Print summary
        total_hosts = len(merged_inventory['all']['hosts'])
        print(f"Total hosts in inventory: {total_hosts}")
        
    except Exception as e:
        print(f"Error writing merged inventory: {e}")
        sys.exit(1)

if __name__ == '__main__':
    merge_inventories()
