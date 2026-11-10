# Symbol Cloud Connect for Azure (contract v2 §6.6, azure-v1).
#
# Run by symbol-setup.sh from the customer's Azure Cloud Shell. The script guarantees
# Terraform >= 1.5 (it installs a pinned, checksum-verified release otherwise), so the
# language stays 1.5-compatible: cross-variable rules are lifecycle preconditions on
# terraform_data.preflight (main.tf), not variable validations.
#
# WHY TERRAFORM AND NOT BICEP
# ---------------------------
# This template creates an Entra ID application per identity, with a client secret
# Microsoft generates. Applications are Microsoft Graph objects, and ARM -- which is
# what Bicep compiles to -- cannot create them: it is the resource plane only. The
# `azuread` provider can, which is the one reason this folder is Terraform while
# `aws/` is a CloudFormation template.
#
# WHY azapi IS HERE TOO
# ---------------------
# `azurerm_subscription_cost_management_export` writes ActualCost and AmortizedCost
# exports only; the FOCUS 1.0 export this platform's ingestion reads is not modelled
# by the provider (hashicorp/terraform-provider-azurerm#29705). `azapi` calls
# Microsoft.CostManagement/exports directly, so the export is still declarative and
# still in state -- a `null_resource` running `az` would be neither.
#
# Providers are pinned to exact versions: a release of this template is immutable and
# must plan the same way on every run. .terraform.lock.hcl is committed (with hashes for
# linux/darwin/windows) so `terraform init` also verifies the provider binaries.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.49.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "3.6.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "2.7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  # Partial configuration: symbol-setup.sh passes
  #   -backend-config=resource_group_name=<rg>
  #   -backend-config=storage_account_name=symboltfstate<hash>
  #   -backend-config=container_name=tfstate
  #   -backend-config=key=symbol-cloud-connect/<org>.tfstate
  # so any subscription admin can later upgrade or destroy from the same state.
  backend "azurerm" {}
}
