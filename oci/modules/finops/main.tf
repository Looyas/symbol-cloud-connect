# FinOps: symbol-finops service identity and its read-only policy (plan §3 ②).
# Consumers at Symbol: ingestion-service (FOCUS cost reports), inventory-collector,
# cloud-api-rec (Cloud Advisor), budget-system.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.3.0"
    }
  }
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID; the policy is attached to the root compartment."
}

variable "idcs_endpoint" {
  type        = string
  description = "URL of the Default identity domain."
}

variable "public_key_pem" {
  type        = string
  description = "Symbol-generated public key for symbol-finops."
}

variable "network_source_name" {
  type        = string
  description = "Name of the Symbol network source (output of the network module)."
}

variable "service_user_email_domain" {
  type        = string
  description = "Domain of the service user's primary email (symbol-finops@<domain>)."
}

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags."
}

locals {
  # Oracle's tenancy that hosts the cost and usage reports (bucket "bling"), commercial
  # realm (oc1). The root module refuses other realms.
  # https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/costusagereportsoverview.htm
  usage_report_tenancy = "ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq"

  condition = "where request.networkSource.name='${var.network_source_name}'"
  group     = module.identity.group_name

  # `define` cannot carry a condition. `endorse` is left exactly as in the plan (no
  # network-source condition): the request is authorised cross-tenancy against Oracle's
  # usage-report tenancy and the condition is unverified there (to be confirmed in POC).
  statements = concat(
    [
      "define tenancy usage-report as ${local.usage_report_tenancy}",
      "endorse group ${local.group} to read objects in tenancy usage-report",
    ],
    [for s in [
      "inspect tenancies",
      "inspect all-resources",
      "read buckets",
      "inspect objects",
      "read volume-family",
      "read audit-events",
      "read optimizer-api-family",
    ] : "allow group ${local.group} to ${s} in tenancy ${local.condition}"]
  )
}

module "identity" {
  source = "../service-identity"

  name           = "symbol-finops"
  description    = "Symbol FinOps service identity (cost reports, inventory, Cloud Advisor). Managed by the symbol-cloud-connect stack."
  idcs_endpoint  = var.idcs_endpoint
  public_key_pem = var.public_key_pem
  email          = "symbol-finops@${var.service_user_email_domain}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "finops" {
  compartment_id = var.tenancy_ocid
  name           = "symbol-finops-policy"
  description    = "Symbol FinOps: read-only cost, usage, inventory and Cloud Advisor access, from Symbol IPs only."
  statements     = local.statements
  freeform_tags  = var.freeform_tags
}

output "user_ocid" {
  description = "OCID of symbol-finops."
  value       = module.identity.user_ocid
}

output "email" {
  description = "Primary email of symbol-finops."
  value       = module.identity.email
}

output "fingerprint" {
  description = "Fingerprint of the symbol-finops API key."
  value       = module.identity.fingerprint
}

output "policy_statements" {
  description = "Statements of symbol-finops-policy (for the summary)."
  value       = oci_identity_policy.finops.statements
}
