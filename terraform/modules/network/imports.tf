# Import blocks for existing Proxmox SDN resources
#
# Import blocks cannot be conditional, so they live in the calling project
# (terraform/infrastructure/imports.tf) rather than here in the module.
# See terraform/infrastructure/imports.tf for the import commands.
#
# After the first successful apply, the imports file can be removed.
