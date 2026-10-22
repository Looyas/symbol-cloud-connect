# Inputs follow CLOUD-SETUP-CONTRACT-V2.md §5.6. symbol-setup.sh fills every one of them
# from the Symbol launch command and from what it detects in the project; the names are
# part of the contract (the script and Symbol's manual guide use them): do not rename.
#
# Terraform 1.5 cannot validate one variable against another. Cross-variable rules
# ("folder scope needs a folder number", "SCC needs the organisation scope", ...)
# are preconditions on terraform_data.preflight in main.tf and fail at plan time.

###############################################################################
# From the Symbol launch command - do not change
###############################################################################

variable "symbol_org_id" {
  type        = string
  description = "Symbol organisation id. Echoed in the connection code and in the symbol-org label."

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.symbol_org_id))
    error_message = "symbol_org_id must be 1-64 characters: letters, digits, '_' or '-'."
  }
}

variable "setup_session_id" {
  type        = string
  description = "Symbol setup session id (UUID). Echoed in the connection code; Symbol accepts the code only for this session."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.setup_session_id))
    error_message = "setup_session_id must be a UUID."
  }
}

variable "template_version" {
  type        = string
  default     = "gcp-v2.0.2"
  description = "Version of this template. Must equal the git tag Symbol pinned in the launch command."

  validation {
    condition     = can(regex("^gcp-v[0-9]+\\.[0-9]+\\.[0-9]+$", var.template_version))
    error_message = "template_version must look like gcp-v1.2.3."
  }
}

variable "enable_finops" {
  type        = bool
  default     = false
  description = "FinOps module: billing dataset access, FOCUS view, inventory and recommender read access."
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Monitoring module: Pub/Sub topic + subscription fed by a Cloud Audit Logs sink (and optionally SCC findings)."
}

variable "enable_security" {
  type        = bool
  default     = false
  description = "Security module: read-only roles for Symbol's security scanner at the chosen scope."
}

variable "allow_key_creation_exception" {
  type        = bool
  default     = false
  description = "Set by symbol-setup.sh --allow-key-creation-exception. When the organisation forbids service-account key creation (iam.disableServiceAccountKeyCreation / iam.managed.disableServiceAccountKeyCreation), create a policy exception on THIS project only (needs roles/orgpolicy.policyAdmin on the organisation). Destroy removes the exception."
}

variable "key_rotation_ids" {
  type        = map(string)
  default     = {}
  description = "Per identity (finops, observability): changing a value replaces that identity's key (symbol-setup.sh --rotate <identity>). A missing identity uses \"initial\". symbol-setup.sh keeps the values of the previous run, so a re-run never rotates a key by accident."

  validation {
    condition = alltrue([
      for k, v in var.key_rotation_ids :
      contains(["finops", "observability"], k) && can(regex("^[A-Za-z0-9-]{1,64}$", v))
    ])
    error_message = "key_rotation_ids keys must be finops or observability, values 1-64 characters: letters, digits or '-'."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "symbol_egress_cidrs" {
  type        = list(string)
  default     = []
  description = "Symbol's egress CIDRs. UNUSED in gcp-v2: GCP IAM has no per-principal source-IP condition outside VPC Service Controls access levels, which this template does not create. Accepted so the launch command is uniform across providers."

  validation {
    condition = alltrue([
      for c in var.symbol_egress_cidrs :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", c)) && can(cidrhost(c, 0))
    ])
    error_message = "Every symbol_egress_cidrs entry must be an IPv4 CIDR such as 203.0.113.10/32."
  }
}

###############################################################################
# Your project (resolved / detected by symbol-setup.sh)
###############################################################################

variable "project_id" {
  type        = string
  description = "Project that hosts the billing dataset, the Pub/Sub resources and Symbol's two service accounts with their keys. BigQuery jobs and API quota are billed to it."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a GCP project id (6-30 characters, lowercase letters, digits and hyphens)."
  }
}

variable "organization_id" {
  type        = string
  default     = ""
  description = "Numeric id of the organisation the project belongs to; empty when the project has no organisation."

  validation {
    condition     = can(regex("^([0-9]{1,20})?$", var.organization_id))
    error_message = "organization_id must be empty or a numeric organisation id."
  }
}

variable "scope_type" {
  type        = string
  default     = "project"
  description = "Where inventory, recommender, security and audit-log access is granted: project, folder or organization."

  validation {
    condition     = contains(["project", "folder", "organization"], var.scope_type)
    error_message = "scope_type must be project, folder or organization."
  }
}

variable "scope_id" {
  type        = string
  default     = ""
  description = "Folder number (folder scope) or organisation number (organization scope). Ignored for project scope, which always uses project_id."

  validation {
    condition     = can(regex("^([0-9]{1,20})?$", var.scope_id))
    error_message = "scope_id must be empty or a folder / organisation number."
  }
}

variable "billing_dataset" {
  type        = string
  default     = "billing_export"
  description = "BigQuery dataset that receives the Cloud Billing detailed usage cost export, and where the FOCUS view is created."

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.billing_dataset)) && length(var.billing_dataset) <= 1024
    error_message = "billing_dataset must be a BigQuery dataset id (letters, digits, underscores)."
  }
}

variable "billing_dataset_location" {
  type        = string
  default     = "US"
  description = "Location of the billing dataset when this template creates it (create_dataset). Must match the location chosen for the billing export."

  validation {
    condition     = can(regex("^[A-Za-z]{2,}([0-9a-z-]*[0-9a-z])?$", var.billing_dataset_location))
    error_message = "billing_dataset_location must be a BigQuery location such as US, EU or europe-west1."
  }
}

variable "billing_account_id" {
  type        = string
  default     = ""
  description = "Cloud Billing account whose detailed export lands in billing_dataset (0123AB-CDEF45-6789AB). Empty when unknown."

  validation {
    condition     = can(regex("^([0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6})?$", var.billing_account_id))
    error_message = "billing_account_id must be empty or a billing account id such as 0123AB-CDEF45-6789AB."
  }
}

variable "create_dataset" {
  type        = bool
  default     = false
  description = "Create billing_dataset (it did not exist, or this template already manages it). Destroy keeps it: symbol-setup.sh --destroy removes it from state first."
}

variable "billing_export_detected" {
  type        = bool
  default     = false
  description = "The detailed usage cost export table gcp_billing_export_resource_v1_<ACCOUNT> exists in billing_dataset."
}

variable "create_focus_view" {
  type        = bool
  default     = false
  description = "Create the FOCUS view gcp_focus_v1 over the detailed export (the export exists and the view does not, or this template already manages it)."
}

variable "enable_scc" {
  type        = bool
  default     = false
  description = "Monitoring: also stream active Security Command Center findings to Symbol (organization scope only; SCC must be activated)."
}

variable "destroy_mode" {
  type        = bool
  default     = false
  description = "Set by symbol-setup.sh --destroy: skips the organisation-policy reads and the setup checks so revocation always works."
}
