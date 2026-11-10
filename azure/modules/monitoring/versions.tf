# Modules state a FLOOR; the root pins the exact version (see ../../versions.tf) and
# .terraform.lock.hcl records the checksums.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}
