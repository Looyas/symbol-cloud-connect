# Observability: symbol-observability service identity, shared by monitoring-service
# (Cloud Guard problems through the stream) and Security-agent-scanner (CIS checks).
# Statements are generated only for the modules that are enabled (plan §3 ③ and ④).

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
  description = "Symbol-generated public key for symbol-observability."
}

variable "network_source_name" {
  type        = string
  description = "Name of the Symbol network source."
}

variable "service_user_email_domain" {
  type        = string
  description = "Domain of the service user's primary email (symbol-observability@<domain>)."
}

variable "enable_monitoring" {
  type        = bool
  description = "Grant the monitoring statements."
}

variable "enable_security" {
  type        = bool
  description = "Grant the security-scan statements."
}

variable "monitoring_compartment_id" {
  type        = string
  description = "Compartment holding the monitoring stream (may be the tenancy OCID)."
}

variable "scan_compartment_id" {
  type        = string
  default     = null
  description = "Compartment the security scan is limited to; null means the tenancy."
}

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags."
}

locals {
  condition = "where request.networkSource.name='${var.network_source_name}'"
  group     = module.identity.group_name

  # A policy cannot say "in compartment id <tenancy ocid>": the root is "in tenancy".
  monitoring_scope = var.monitoring_compartment_id == var.tenancy_ocid ? "tenancy" : "compartment id ${var.monitoring_compartment_id}"
  scan_scope       = var.scan_compartment_id == null || var.scan_compartment_id == var.tenancy_ocid ? "tenancy" : "compartment id ${var.scan_compartment_id}"

  monitoring_permissions = var.enable_monitoring ? [
    # GetMessages, CreateCursor, CreateGroupCursor, ConsumerCommit/Heartbeat only.
    "use stream-pull in ${local.monitoring_scope}",
    # ListProblems for the backfill of problems that were already open.
    "read cloud-guard-family in tenancy",
  ] : []

  # Note: users and groups only exist in the root compartment. With a compartment scope
  # the identity checks of the CIS scan return no data.
  security_permissions = var.enable_security ? [for p in [
    "inspect compartments",
    "inspect groups",
    "inspect policies",
    "read users",
    "inspect virtual-network-family",
    "inspect instance-family",
    "inspect volume-family",
    "inspect database-family",
    "read buckets",
    "read log-groups",
    "inspect alarms",
    "inspect tag-namespaces",
    "inspect usage-budgets",
    "inspect vaults",
    "inspect keys",
    "read cloud-guard-family",
  ] : "${p} in ${local.scan_scope}"] : []

  statements = [
    for p in distinct(concat(local.monitoring_permissions, local.security_permissions)) :
    "allow group ${local.group} to ${p} ${local.condition}"
  ]
}

module "identity" {
  source = "../service-identity"

  name           = "symbol-observability"
  description    = "Symbol observability service identity (Cloud Guard monitoring and security scans). Managed by the symbol-cloud-connect stack."
  idcs_endpoint  = var.idcs_endpoint
  public_key_pem = var.public_key_pem
  email          = "symbol-observability@${var.service_user_email_domain}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "observability" {
  compartment_id = var.tenancy_ocid
  name           = "symbol-observability-policy"
  description    = "Symbol monitoring and security scan: stream consumption and read/inspect access, from Symbol IPs only."
  statements     = local.statements
  freeform_tags  = var.freeform_tags

  lifecycle {
    precondition {
      condition     = length(local.statements) > 0
      error_message = "The observability module needs enable_monitoring or enable_security."
    }
  }
}

output "user_ocid" {
  description = "OCID of symbol-observability."
  value       = module.identity.user_ocid
}

output "email" {
  description = "Primary email of symbol-observability."
  value       = module.identity.email
}

output "fingerprint" {
  description = "Fingerprint of the symbol-observability API key."
  value       = module.identity.fingerprint
}

output "policy_statements" {
  description = "Statements of symbol-observability-policy."
  value       = oci_identity_policy.observability.statements
}
