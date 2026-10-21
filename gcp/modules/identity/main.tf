# Key-upload identities (contract v2 §5.3), used only when identity_mode = key_upload.
#
# Two service accounts in the customer project, symbol-finops and symbol-observability.
# Each gets ONE key whose public half is the X.509 certificate Symbol generated for this
# setup session; the private key never leaves Symbol's Vault. Nothing secret is created
# here: a google_service_account_key made from public_key_data has no private key.
#
# https://cloud.google.com/iam/docs/keys-upload
# Provider 8.7.0 docs: public_key_data is "a base64 encoded X509_PEM".
#
# The certificates are downloaded by data "http" "certificate" in the root module
# (main.tf), where their HTTP-status postcondition lives.

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
  description = "Project where the service accounts are created."
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

variable "certificates" {
  type        = map(string)
  description = "PEM certificate per identity (finops, observability). Empty during symbol-setup.sh --destroy, when nothing needs it."
}

locals {
  identities = {
    finops = {
      enabled     = var.create_finops
      account_id  = "symbol-finops"
      name        = "Symbol FinOps"
      description = "Symbol FinOps (billing export, inventory, recommendations) for Symbol org ${var.symbol_org_id}. Key = Symbol-held certificate. Managed by symbol-cloud-connect."
    }
    observability = {
      enabled     = var.create_observability
      account_id  = "symbol-observability"
      name        = "Symbol Observability"
      description = "Symbol monitoring and security scan for Symbol org ${var.symbol_org_id}. Key = Symbol-held certificate. Managed by symbol-cloud-connect."
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
  #checkov:skip=CKV2_GCP_3:key_upload mode by design (contract v2 section 5.3): the key is Symbol's uploaded public certificate; the private key never exists in this project. symbol_principal mode creates no key.
  for_each = local.enabled

  service_account_id = google_service_account.this[each.key].name
  # Base64 of the PEM text, as the IAM keys.upload API and the provider expect.
  # A new certificate (new setup session, rotation) replaces the key.
  public_key_data = base64encode(lookup(var.certificates, each.key, ""))

  lifecycle {
    postcondition {
      condition     = can(regex("/keys/[0-9a-f]{40}$", self.name))
      error_message = "Unexpected key name ${self.name}: Symbol expects a 40-hex key id."
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
# the 40-hex private_key_id Symbol puts in the service-account JSON it assembles.
output "finops_key_id" {
  description = "Key id of the uploaded symbol-finops certificate."
  value       = try(regex("[^/]+$", google_service_account_key.this["finops"].name), null)
}

output "observability_key_id" {
  description = "Key id of the uploaded symbol-observability certificate."
  value       = try(regex("[^/]+$", google_service_account_key.this["observability"].name), null)
}

output "service_account_ids" {
  description = "account_id of each created service account."
  value       = { for k, sa in google_service_account.this : k => sa.account_id }
}

output "public_key_data" {
  description = "public_key_data sent for each key (base64 of the certificate PEM; public material)."
  value       = { for k, key in google_service_account_key.this : k => key.public_key_data }
}
