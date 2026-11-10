# Modules state a FLOOR; the root pins the exact version (see ../../versions.tf) and
# .terraform.lock.hcl records the checksums.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0"
    }
    # Only this module uses it, so this is where it is pinned exactly: an absolute
    # secret expiry must not shift because a floor resolved differently.
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}
