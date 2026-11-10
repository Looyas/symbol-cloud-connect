# Credentials: in Azure Cloud Shell every provider uses the signed-in admin's own
# token (`az login` is implicit there). Nothing Symbol-owned is ever used to apply
# this template -- Symbol has no principal in the customer's tenant under azure-v1,
# and the identities this template creates belong to the customer.

provider "azurerm" {
  subscription_id = var.subscription_id

  # Resource providers are registered by symbol-setup.sh, which can report a missing
  # registration with the exact fix. Leaving it to the provider would surface the
  # same failure as an opaque mid-apply error.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # The resource group this template creates is its own; a leftover resource in
      # it means the destroy was incomplete and must be looked at, not force-deleted.
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}
