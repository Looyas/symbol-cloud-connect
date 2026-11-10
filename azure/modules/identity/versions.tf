terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azuread = {
      source = "hashicorp/azuread"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}
