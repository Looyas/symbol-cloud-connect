# A module that uses a provider must declare it, and a NON-HASHICORP one must name its
# source: without this block Terraform resolves `azapi_resource` as hashicorp/azapi,
# which does not exist. The root's required_providers does not reach into modules.
#
# Modules state a FLOOR; the root pins the exact version and .terraform.lock.hcl records
# the checksums. That is the documented split, and it is what keeps a release immutable
# without repeating one version string in five files.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0"
    }
  }
}
