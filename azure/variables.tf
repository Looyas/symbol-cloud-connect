# Every input of the Azure template (contract v2 §6.3).
#
# The values symbol-setup.sh passes come from the Symbol setup session: the
# organisation, the session, the release, the modules and the admin's options. Nothing
# here is a secret, and nothing here is read from Symbol at apply time -- the template
# talks to Azure only.
#
# Validation here is per-variable (format). Rules that span variables are lifecycle
# preconditions on terraform_data.preflight in main.tf, so they are reported by `plan`
# with a message the admin can act on, and so the language stays Terraform 1.5.

# -- identity of the setup ----------------------------------------------------------

variable "symbol_org_id" {
  description = "The Symbol organisation this setup connects to. Echoed in the connection code."
  type        = string

  validation {
    # Also the suffix of every resource name below: Azure storage account names allow
    # 24 lower-case alphanumerics, which is what caps this at 44 like AWS's role names.
    condition     = can(regex("^[A-Za-z0-9_-]{1,44}$", var.symbol_org_id))
    error_message = "symbol_org_id must be 1-44 characters of letters, digits, '_' and '-'."
  }
}

variable "setup_session_id" {
  description = "The Symbol setup session. The connection code is accepted by this session only."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.setup_session_id))
    error_message = "setup_session_id must be a UUID."
  }
}

variable "template_version" {
  description = "The release of this template, echoed in the code and checked against Symbol's registry."
  type        = string

  validation {
    condition     = can(regex("^azure-v[0-9]+\\.[0-9]+\\.[0-9]+$", var.template_version))
    error_message = "template_version must be 'azure-vX.Y.Z'."
  }
}

# -- where it runs ------------------------------------------------------------------

variable "tenant_id" {
  description = "The Microsoft Entra ID directory. The applications are created here."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", lower(var.tenant_id)))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "The subscription everything is read from and created in."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", lower(var.subscription_id)))
    error_message = "subscription_id must be a GUID."
  }
}

variable "location" {
  description = "The Azure region of the resource group, storage account and Event Hubs namespace."
  type        = string
  default     = "westeurope"

  validation {
    condition     = can(regex("^[a-z0-9]{3,40}$", var.location))
    error_message = "location must be an Azure region name such as 'westeurope'."
  }
}

variable "resource_group_name" {
  description = "The resource group this template owns. Everything it creates lives here, so a destroy is complete."
  type        = string
  default     = ""

  validation {
    condition     = var.resource_group_name == "" || can(regex("^[A-Za-z0-9._()-]{1,90}$", var.resource_group_name))
    error_message = "resource_group_name must be a valid Azure resource group name."
  }
}

variable "destroy_mode" {
  description = <<-EOT
    Set by `symbol-setup.sh --destroy`. It turns off the preflight preconditions:
    revocation must always work, including from a configuration the preflight would
    now refuse (an option that has since become invalid, a module switched off).
  EOT
  type        = bool
  default     = false
}

# -- modules ------------------------------------------------------------------------

variable "enable_signin" {
  description = "Members sign in to Azure through Symbol. Creates nothing: Symbol needs the directory id only."
  type        = bool
  default     = false
}

variable "enable_finops" {
  description = "Cost ingestion from a FOCUS 1.0 export in blob storage."
  type        = bool
  default     = false
}

variable "enable_monitoring" {
  description = "Activity Log events streamed to an Event Hub that Symbol reads."
  type        = bool
  default     = false
}

variable "enable_security" {
  description = "Read-only CIS posture scanning over the subscription."
  type        = bool
  default     = false
}

# -- FinOps: the cost export --------------------------------------------------------

variable "create_cost_export" {
  description = <<-EOT
    Create the storage account, the container and the FOCUS 1.0 export. False points the
    setup at an export you already run, so an organisation that already pays for one is
    not made to pay for a second.
  EOT
  type        = bool
  default     = true
}

variable "existing_export_storage_account" {
  description = "With create_cost_export = false: the storage account the export writes to."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_export_storage_account == "" || can(regex("^[a-z0-9]{3,24}$", var.existing_export_storage_account))
    error_message = "existing_export_storage_account must be 3-24 lower-case alphanumerics."
  }
}

variable "existing_export_resource_group" {
  description = "With create_cost_export = false: the resource group of that storage account (for the role assignment)."
  type        = string
  default     = ""
}

variable "existing_export_container" {
  description = "With create_cost_export = false: the container the export writes to."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_export_container == "" || can(regex("^[a-z0-9](?:-?[a-z0-9]){2,62}$", var.existing_export_container))
    error_message = "existing_export_container must be a valid blob container name."
  }
}

variable "existing_export_directory" {
  description = "With create_cost_export = false: the root folder of the export inside the container."
  type        = string
  default     = ""
}

variable "existing_export_name" {
  description = "With create_cost_export = false: the name of the export, which is also its folder."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_export_name == "" || can(regex("^[A-Za-z0-9_-]{1,64}$", var.existing_export_name))
    error_message = "existing_export_name must be 1-64 characters of letters, digits, '_' and '-'."
  }
}

# -- Monitoring: the event pipe -----------------------------------------------------

variable "create_eventhub" {
  description = <<-EOT
    Create the Event Hubs namespace, the hub and the consumer group. False points the
    setup at a namespace you already run -- an Event Hubs namespace has a monthly floor,
    unlike an SQS queue, so reusing one is a real saving.

    The CONSUMER GROUP is created either way: two readers on one group compete for the
    same partitions, and Symbol's checkpoint store assumes it owns its group.
  EOT
  type        = bool
  default     = true
}

variable "existing_eventhub_namespace" {
  description = "With create_eventhub = false: the namespace, its name alone."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_eventhub_namespace == "" || can(regex("^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$", var.existing_eventhub_namespace))
    error_message = "existing_eventhub_namespace must be a valid Event Hubs namespace name."
  }
}

variable "existing_eventhub_resource_group" {
  description = "With create_eventhub = false: the resource group of that namespace."
  type        = string
  default     = ""
}

variable "existing_eventhub_name" {
  description = "With create_eventhub = false: the hub inside that namespace the Activity Log is streamed to."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_eventhub_name == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,48}[A-Za-z0-9]$", var.existing_eventhub_name))
    error_message = "existing_eventhub_name must be a valid Event Hub name."
  }
}

variable "eventhub_partition_count" {
  description = "Partitions of the hub this template creates. Symbol reads every partition."
  type        = number
  default     = 2

  validation {
    condition     = var.eventhub_partition_count >= 1 && var.eventhub_partition_count <= 32
    error_message = "eventhub_partition_count must be between 1 and 32."
  }
}

variable "eventhub_retention_days" {
  description = "Message retention of the hub this template creates, in days."
  type        = number
  default     = 1

  validation {
    condition     = var.eventhub_retention_days >= 1 && var.eventhub_retention_days <= 7
    error_message = "eventhub_retention_days must be between 1 and 7 (Standard tier)."
  }
}

# -- the identities -----------------------------------------------------------------

variable "secret_valid_months" {
  description = <<-EOT
    How long the client secret of each application is valid. Azure allows at most 24
    months and many tenants cap it lower by policy; Symbol shows the expiry on the
    integration card and the setup can be re-run with --rotate before it passes.
  EOT
  type        = number
  default     = 12

  validation {
    condition     = var.secret_valid_months >= 1 && var.secret_valid_months <= 24
    error_message = "secret_valid_months must be between 1 and 24."
  }
}

variable "secret_rotation_ids" {
  description = <<-EOT
    Per identity, an opaque value that changes ONLY when that identity's secret should be
    replaced. symbol-setup.sh keeps the previous run's values beside the state and sets a
    new one for --rotate's identity alone, so an ordinary re-run keeps the secrets Symbol
    already holds and does not silently cut its own access.
  EOT
  type        = map(string)
  default     = {}
}
