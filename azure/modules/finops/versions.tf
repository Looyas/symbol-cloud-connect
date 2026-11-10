# A module that uses a provider must declare it, and a NON-HASHICORP one must name its
# source: without this block Terraform resolves `azapi_resource` as hashicorp/azapi,
# which does not exist. The root's required_providers does not reach into modules.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    azapi = {
      source = "Azure/azapi"
    }
  }
}
