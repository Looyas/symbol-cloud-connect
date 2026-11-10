###############################################################################
# Subscription facts and derived values.
###############################################################################

data "azurerm_subscription" "this" {
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}

locals {
  module_flags = {
    signin     = var.enable_signin
    finops     = var.enable_finops
    monitoring = var.enable_monitoring
    security   = var.enable_security
  }
  # Contract §1 screen order.
  enabled_modules = [for m in ["signin", "finops", "monitoring", "security"] : m if local.module_flags[m]]

  # Which identity each module signs with (contract §1). `signin` has none: members
  # sign in as themselves through Symbol's own Entra application, and this template
  # creates nothing for it -- the directory id is the whole of what Symbol needs.
  needs_finops_identity        = var.enable_finops
  needs_observability_identity = var.enable_monitoring || var.enable_security

  creates_export       = var.enable_finops && var.create_cost_export
  creates_eventhub     = var.enable_monitoring && var.create_eventhub
  needs_resource_group = local.creates_export || local.creates_eventhub

  # A storage account name is 3-24 lower-case alphanumerics and globally unique, and an
  # Event Hubs namespace is globally unique too. Derived from the subscription and the
  # organisation rather than random: a re-run after a lost state file then plans the
  # SAME names instead of creating a second set beside the first.
  name_hash = substr(sha1("${lower(var.subscription_id)}-${lower(var.symbol_org_id)}"), 0, 18)

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "symbol-cloud-connect"

  storage_account_name    = "symbol${substr(local.name_hash, 0, 18)}"
  eventhub_namespace_name = "symbol-${substr(local.name_hash, 0, 16)}"

  # The names the MANUAL guide also uses, so a manual and an automatic setup leave the
  # subscription in the same shape and the same preflight reads both the same way.
  export_container = "symbol-focus"
  export_directory = "symbol-focus"
  export_name      = "symbol-focus-${var.symbol_org_id}"
  eventhub_name    = "symbol-activity"
  consumer_group   = "symbol-monitoring"
  diagnostic_name  = "symbol-activity-log"

  # What the connection code reports, whichever side created it.
  export_storage_account = local.creates_export ? local.storage_account_name : var.existing_export_storage_account
  export_container_final = local.creates_export ? local.export_container : var.existing_export_container
  export_directory_final = local.creates_export ? local.export_directory : var.existing_export_directory
  export_name_final      = local.creates_export ? local.export_name : var.existing_export_name

  eventhub_namespace_final = local.creates_eventhub ? local.eventhub_namespace_name : var.existing_eventhub_namespace
  eventhub_name_final      = local.creates_eventhub ? local.eventhub_name : var.existing_eventhub_name

  tags = {
    "symbol-managed"  = "true"
    "symbol-org"      = var.symbol_org_id
    "symbol-template" = var.template_version
  }
}

###############################################################################
# Preflight: cross-variable checks. Preconditions are evaluated at plan time, so a
# misconfigured run fails before anything is created. destroy_mode (symbol-setup.sh
# --destroy) bypasses them: revocation must always work.
###############################################################################

resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition     = var.destroy_mode || length(local.enabled_modules) > 0
      error_message = "No module is enabled. Set at least one of enable_signin, enable_finops, enable_monitoring, enable_security (the Symbol launch command sets them for you)."
    }

    precondition {
      condition = var.destroy_mode || !var.enable_finops || var.create_cost_export || (
        var.existing_export_storage_account != "" &&
        var.existing_export_container != "" &&
        var.existing_export_name != ""
      )
      error_message = "create_cost_export = false needs existing_export_storage_account, existing_export_container and existing_export_name (the export Symbol should read)."
    }

    precondition {
      condition     = var.destroy_mode || !var.enable_finops || var.create_cost_export || var.existing_export_resource_group != ""
      error_message = "create_cost_export = false needs existing_export_resource_group: the Storage Blob Data Reader assignment is scoped to that container, which has to be addressed by its full resource id."
    }

    precondition {
      condition = var.destroy_mode || !var.enable_monitoring || var.create_eventhub || (
        var.existing_eventhub_namespace != "" &&
        var.existing_eventhub_name != "" &&
        var.existing_eventhub_resource_group != ""
      )
      error_message = "create_eventhub = false needs existing_eventhub_namespace, existing_eventhub_name and existing_eventhub_resource_group."
    }

    precondition {
      # The template creates the applications in the tenant the admin is signed in to.
      # A mismatch means the subscription belongs to another directory, and every role
      # assignment would then name a principal that does not exist there.
      condition     = var.destroy_mode || lower(var.tenant_id) == lower(data.azurerm_subscription.this.tenant_id)
      error_message = "Subscription ${var.subscription_id} belongs to directory ${data.azurerm_subscription.this.tenant_id}, not ${var.tenant_id}. Sign in to the right directory (az login --tenant <id>) and run the command again."
    }
  }
}

###############################################################################
# The resource group this template owns.
#
# Everything it CREATES lives here, which is what makes `--destroy` complete: an
# existing export or namespace the customer pointed us at stays where it is and is
# never touched.
###############################################################################

resource "azurerm_resource_group" "symbol" {
  count = local.needs_resource_group ? 1 : 0

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  depends_on = [terraform_data.preflight]
}

###############################################################################
# The identities (contract §6.4).
#
# One Entra application per credential set, each with ONE secret Microsoft generates.
# The secret is delivered to Symbol once, inside the connection code, and lives in
# Symbol's vault afterwards. Nothing of Symbol's exists in this directory.
###############################################################################

module "identity" {
  source = "./modules/identity"
  count  = (local.needs_finops_identity || local.needs_observability_identity) ? 1 : 0

  symbol_org_id       = var.symbol_org_id
  needs_finops        = local.needs_finops_identity
  needs_observability = local.needs_observability_identity
  secret_valid_months = var.secret_valid_months
  secret_rotation_ids = var.secret_rotation_ids
  # The admin running the setup owns both applications, so they can manage and delete
  # them afterwards without holding Application Administrator in the directory.
  owner_object_id = data.azurerm_client_config.current.object_id

  depends_on = [terraform_data.preflight]
}

###############################################################################
# FinOps: the FOCUS 1.0 export and the one role that reads it.
###############################################################################

module "finops" {
  source = "./modules/finops"
  count  = var.enable_finops ? 1 : 0

  subscription_scope = data.azurerm_subscription.this.id
  location           = var.location
  tags               = local.tags

  create_export        = var.create_cost_export
  resource_group_name  = local.creates_export ? azurerm_resource_group.symbol[0].name : var.existing_export_resource_group
  storage_account_name = local.export_storage_account
  container_name       = local.export_container_final
  directory            = local.export_directory_final
  export_name          = local.export_name_final

  principal_id = module.identity[0].finops_object_id
}

###############################################################################
# Monitoring: the Activity Log pipe.
###############################################################################

module "monitoring" {
  source = "./modules/monitoring"
  count  = var.enable_monitoring ? 1 : 0

  subscription_scope = data.azurerm_subscription.this.id
  location           = var.location
  tags               = local.tags

  create_namespace    = var.create_eventhub
  resource_group_name = local.creates_eventhub ? azurerm_resource_group.symbol[0].name : var.existing_eventhub_resource_group
  namespace_name      = local.eventhub_namespace_final
  eventhub_name       = local.eventhub_name_final
  consumer_group      = local.consumer_group
  diagnostic_name     = local.diagnostic_name
  partition_count     = var.eventhub_partition_count
  retention_days      = var.eventhub_retention_days

  principal_id = module.identity[0].observability_object_id
}

###############################################################################
# Security posture: read-only roles over the subscription.
###############################################################################

module "security" {
  source = "./modules/security"
  count  = local.needs_observability_identity ? 1 : 0

  subscription_scope = data.azurerm_subscription.this.id
  principal_id       = module.identity[0].observability_object_id
}
