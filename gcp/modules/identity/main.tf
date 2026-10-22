# Symbol's two identities in the customer project (contract v2 §5.3, gcp-v2).
#
# Two service accounts, symbol-finops and symbol-observability, each with ONE key that
# Google generates (TYPE_GOOGLE_CREDENTIALS_FILE: the standard JSON key file). The key
# leaves Terraform only through the sensitive connection code the customer pastes into
# Symbol, which stores it in its Vault. It stays in this project's Terraform state
# (the private, versioned state bucket symbol-setup.sh creates), like any key managed
# with Terraform.
#
# A key is replaced only when its key_rotation_ids entry changes (symbol-setup.sh
# --rotate <identity>): a plain re-run keeps the key Symbol already holds. The new key
# is created before the old one is deleted, so the only window without a working key
# on Symbol's side is between the apply and the paste of the new code.
#
# Whether the organisation allows key creation at all is checked before this module
# runs (modules/key-policy).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Project where the service accounts and their keys are created."
}

variable "symbol_org_id" {
  type        = string
  description = "Symbol organisation id (descriptions only)."
}

variable "create_finops" {
  type        = bool
  description = "Create symbol-finops (FinOps module enabled)."
}

variable "create_observability" {
  type        = bool
  description = "Create symbol-observability (Monitoring or Security enabled)."
}

variable "key_rotation_ids" {
  type        = map(string)
  description = "Per identity: a new value replaces that identity's key. Missing = \"initial\"."
}

locals {
  identities = {
    finops = {
      enabled     = var.create_finops
      account_id  = "symbol-finops"
      name        = "Symbol FinOps"
      description = "Symbol FinOps (billing export, inventory, recommendations) for Symbol org ${var.symbol_org_id}. Key held by Symbol. Managed by symbol-cloud-connect."
    }
    observability = {
      enabled     = var.create_observability
      account_id  = "symbol-observability"
      name        = "Symbol Observability"
      description = "Symbol monitoring and security scan for Symbol org ${var.symbol_org_id}. Key held by Symbol. Managed by symbol-cloud-connect."
    }
  }

  enabled = { for k, v in local.identities : k => v if v.enabled }
}

resource "google_service_account" "this" {
  for_each = local.enabled

  project      = var.project_id
  account_id   = each.value.account_id
  display_name = each.value.name
  description  = each.value.description
}

resource "google_service_account_key" "this" {
  #checkov:skip=CKV2_GCP_3:By design (contract v2 section 5.3, gcp-v2): Symbol reads the project from outside Google Cloud with this user-managed key, delivered once through the connection code and stored in Symbol's Vault. Rotation: symbol-setup.sh --rotate.
  for_each = local.enabled

  service_account_id = google_service_account.this[each.key].name
  key_algorithm      = "KEY_ALG_RSA_2048"
  private_key_type   = "TYPE_GOOGLE_CREDENTIALS_FILE"

  keepers = {
    rotation = lookup(var.key_rotation_ids, each.key, "initial")
  }

  lifecycle {
    create_before_destroy = true

    postcondition {
      condition     = can(regex("/keys/[0-9a-f]{40}$", self.name))
      error_message = "Unexpected key name ${self.name}: Symbol expects a 40-hex key id."
    }

    postcondition {
      # The key file is the one Symbol will store: it must be a service-account key of
      # THIS account, under the key id the code announces.
      condition = try(
        jsondecode(base64decode(self.private_key)).type == "service_account" &&
        jsondecode(base64decode(self.private_key)).private_key_id == regex("[0-9a-f]{40}$", self.name) &&
        jsondecode(base64decode(self.private_key)).client_email == google_service_account.this[each.key].email,
        false
      )
      error_message = "Google returned a key file that is not the service-account key of ${each.value.account_id} (unexpected private_key_type?)."
    }
  }
}

output "finops_email" {
  description = "Email of symbol-finops (null when not created)."
  value       = try(google_service_account.this["finops"].email, null)
}

output "observability_email" {
  description = "Email of symbol-observability (null when not created)."
  value       = try(google_service_account.this["observability"].email, null)
}

# The key's resource name is projects/<p>/serviceAccounts/<email>/keys/<KEY_ID>; KEY_ID is
# the private_key_id inside the key file.
output "finops_key_id" {
  description = "Key id of the symbol-finops key (null when not created)."
  value       = try(regex("[0-9a-f]{40}$", google_service_account_key.this["finops"].name), null)
}

output "observability_key_id" {
  description = "Key id of the symbol-observability key (null when not created)."
  value       = try(regex("[0-9a-f]{40}$", google_service_account_key.this["observability"].name), null)
}

output "service_account_ids" {
  description = "account_id of each created service account."
  value       = { for k, sa in google_service_account.this : k => sa.account_id }
}

output "rotation_ids" {
  description = "The rotation id each key was created for (its keepers.rotation)."
  value       = { for k, key in google_service_account_key.this : k => key.keepers.rotation }
}

output "keys" {
  description = "Per created identity: service account, key id, validity and the decoded key file (SECRET)."
  sensitive   = true
  value = {
    for k, key in google_service_account_key.this : k => {
      service_account = google_service_account.this[k].email
      key_id          = regex("[0-9a-f]{40}$", key.name)
      valid_after     = key.valid_after
      valid_before    = key.valid_before
      credentials     = jsondecode(base64decode(key.private_key))
    }
  }
}
