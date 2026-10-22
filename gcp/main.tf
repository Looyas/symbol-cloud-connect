###############################################################################
# Project facts and derived values.
###############################################################################

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  module_flags = {
    finops     = var.enable_finops
    monitoring = var.enable_monitoring
    security   = var.enable_security
  }
  # Contract §1 screen order.
  enabled_modules = [for m in ["finops", "monitoring", "security"] : m if local.module_flags[m]]

  needs_finops_identity        = var.enable_finops
  needs_observability_identity = var.enable_monitoring || var.enable_security

  # Project scope always means "this project": scope_id is only read for folders and
  # organisations, so a stale value cannot widen a project-scoped setup.
  scope_id = var.scope_type == "project" ? var.project_id : var.scope_id

  # Members granted the roles: the two service accounts this template creates in the
  # customer project (modules/identity).
  finops_email         = try(module.identity[0].finops_email, null)
  observability_email  = try(module.identity[0].observability_email, null)
  finops_member        = "serviceAccount:${coalesce(local.finops_email, "unset")}"
  observability_member = "serviceAccount:${coalesce(local.observability_email, "unset")}"

  # Label values: [a-z0-9_-], at most 63 characters.
  labels = {
    "symbol-managed"  = "true"
    "symbol-org"      = substr(lower(var.symbol_org_id), 0, 63)
    "symbol-template" = replace(var.template_version, ".", "-")
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
      error_message = "No module is enabled. Set at least one of enable_finops, enable_monitoring, enable_security (the Symbol launch command sets them for you)."
    }

    precondition {
      condition     = var.scope_type == "project" || var.scope_id != ""
      error_message = "scope_type = ${var.scope_type} needs scope_id (the ${var.scope_type} number)."
    }

    precondition {
      condition     = var.destroy_mode || var.scope_type != "organization" || var.organization_id == "" || var.scope_id == var.organization_id
      error_message = "scope_type = organization: scope_id (${var.scope_id}) must be the organisation of project ${var.project_id} (${var.organization_id})."
    }

    precondition {
      condition     = var.destroy_mode || var.scope_type == "project" || var.organization_id != ""
      error_message = "Project ${var.project_id} has no organisation: only scope_type = project is possible."
    }

    precondition {
      condition     = var.destroy_mode || !var.enable_scc || (var.enable_monitoring && var.scope_type == "organization" && var.organization_id != "")
      error_message = "enable_scc needs the Monitoring module and scope_type = organization (Security Command Center notifications are organisation resources)."
    }

    precondition {
      condition     = var.destroy_mode || !var.create_focus_view || (var.enable_finops && var.billing_export_detected && var.billing_account_id != "")
      error_message = "create_focus_view needs the FinOps module, the detailed billing export table (billing_export_detected) and billing_account_id."
    }

    precondition {
      condition     = var.destroy_mode || !var.billing_export_detected || var.billing_account_id != ""
      error_message = "billing_export_detected is true but billing_account_id is empty: the FOCUS view and Symbol both need the billing account id."
    }
  }
}

###############################################################################
# Modules (contract §5.6 table). No module-level depends_on on the preflight: a failing
# precondition already stops the run at plan time.
#
# key_policy runs first: it stops the plan when the organisation forbids key creation
# (or lifts that for this project, on request), and the identity module waits for it.
# Its policy reads are data sources of its own, so the identity module's depends_on
# defers nothing that the plan needs.
###############################################################################

module "key_policy" {
  source = "./modules/key-policy"

  project_id      = var.project_id
  organization_id = var.organization_id
  check_enabled   = !var.destroy_mode
  allow_exception = var.allow_key_creation_exception
}

# Stops the plan BEFORE anything is created when the organisation forbids key creation
# on this project and no exception was requested -- with the exact fix in the message.
resource "terraform_data" "key_creation_gate" {
  input = {
    enforced  = module.key_policy.enforced
    exception = module.key_policy.exception_created
  }

  lifecycle {
    precondition {
      condition     = var.destroy_mode || length(module.key_policy.enforced) == 0 || module.key_policy.exception_created
      error_message = "Service-account key creation is forbidden on project ${var.project_id} by ${join(" and ", module.key_policy.enforced)}. Nothing was created. Fix it in one of two ways, then run the same Symbol command again: (1) an Organization Policy Administrator (roles/orgpolicy.policyAdmin on organisation ${var.organization_id}) sets 'enforce: false' for ${join(" and ", module.key_policy.constraints)} on projects/${var.project_id} only (commands in PERMISSIONS.md, section 'Organisation policy: service-account keys'); or (2) if you hold that role yourself, add --allow-key-creation-exception to the command: this template then creates that exception, and --destroy removes it."
    }
  }
}

module "identity" {
  source = "./modules/identity"
  count  = local.needs_finops_identity || local.needs_observability_identity ? 1 : 0

  project_id           = var.project_id
  symbol_org_id        = var.symbol_org_id
  create_finops        = local.needs_finops_identity
  create_observability = local.needs_observability_identity
  key_rotation_ids     = var.key_rotation_ids

  depends_on = [module.key_policy, terraform_data.key_creation_gate]
}

module "finops" {
  source = "./modules/finops"
  count  = var.enable_finops ? 1 : 0

  project_id         = var.project_id
  member             = local.finops_member
  scope_type         = var.scope_type
  scope_id           = local.scope_id
  dataset_id         = var.billing_dataset
  dataset_location   = var.billing_dataset_location
  create_dataset     = var.create_dataset
  create_focus_view  = var.create_focus_view
  billing_account_id = var.billing_account_id
}

module "monitoring" {
  source = "./modules/monitoring"
  count  = var.enable_monitoring ? 1 : 0

  project_id      = var.project_id
  member          = local.observability_member
  scope_type      = var.scope_type
  scope_id        = local.scope_id
  organization_id = var.organization_id
  enable_scc      = var.enable_scc
}

module "security" {
  source = "./modules/security"
  count  = var.enable_security ? 1 : 0

  project_id = var.project_id
  member     = local.observability_member
  scope_type = var.scope_type
  scope_id   = local.scope_id
}

###############################################################################
# Warnings (check blocks report in plan/apply output but never block a run).
###############################################################################

check "key_creation_policy_readable" {
  assert {
    condition     = length(module.key_policy.unreadable) == 0
    error_message = "Could not read the organisation policy ${join(", ", module.key_policy.unreadable)} on ${var.project_id} (you may lack orgpolicy.policies.get, or orgpolicy.googleapis.com is disabled). Continuing: if key creation is forbidden, the apply stops at the service-account keys with FAILED_PRECONDITION -- then run the Symbol command again with --allow-key-creation-exception, or ask an Organization Policy Administrator for an exception on this project."
  }
}

check "billing_export" {
  assert {
    condition     = !var.enable_finops || var.billing_export_detected
    error_message = "The Cloud Billing detailed usage cost export was not found in ${var.project_id}.${var.billing_dataset}. Enable it in the Billing console (Billing > Billing export > BigQuery export > Detailed usage cost, dataset ${var.billing_dataset}), then run symbol-setup.sh again to create the FOCUS view. There is no API for this step."
  }
}
