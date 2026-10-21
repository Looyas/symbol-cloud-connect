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
  key_upload                   = var.identity_mode == "key_upload"

  # Project scope always means "this project": scope_id is only read for folders and
  # organisations, so a stale value cannot widen a project-scoped setup.
  scope_id = var.scope_type == "project" ? var.project_id : var.scope_id

  # Members granted the roles. key_upload: the service accounts this template creates
  # in the customer project. symbol_principal: Symbol's per-org service accounts.
  finops_email         = local.key_upload ? try(module.identity[0].finops_email, null) : var.finops_principal
  observability_email  = local.key_upload ? try(module.identity[0].observability_email, null) : var.observability_principal
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
# key_upload: the X.509 certificates Symbol generated for this session (public
# material, served at the session's public .crt URLs). The postconditions stop the plan
# when a URL does not answer 200 with exactly one PEM certificate (expired session,
# wrong URL, proxy page), before any service account is created. Never downloaded in
# destroy_mode: expired sessions answer 404 and deleting a key needs no certificate.
###############################################################################

locals {
  certificate_urls = {
    finops        = local.needs_finops_identity ? var.finops_certificate_url : ""
    observability = local.needs_observability_identity ? var.observability_certificate_url : ""
  }
  certificate_downloads = local.key_upload && !var.destroy_mode ? { for k, url in local.certificate_urls : k => url if url != "" } : {}
  certificate_regex     = "^-----BEGIN CERTIFICATE-----\\r?\\n[A-Za-z0-9+/=\\r\\n]+-----END CERTIFICATE-----\\r?\\n?$"
}

data "http" "certificate" {
  for_each = local.certificate_downloads
  url      = each.value

  request_headers = { Accept = "application/x-x509-ca-cert, application/x-pem-file" }

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not download Symbol's ${each.key} certificate (HTTP ${self.status_code}). Setup links expire after 24 hours: start a new setup in Symbol and run the new command."
    }
    postcondition {
      condition     = can(regex(local.certificate_regex, self.response_body))
      error_message = "The ${each.key} certificate URL did not return a single PEM certificate."
    }
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
      condition     = var.destroy_mode || local.key_upload || !local.needs_finops_identity || var.finops_principal != ""
      error_message = "identity_mode = symbol_principal and FinOps is enabled, but finops_principal is empty. Start a new setup in Symbol, or use identity_mode = key_upload."
    }

    precondition {
      condition     = var.destroy_mode || local.key_upload || !local.needs_observability_identity || var.observability_principal != ""
      error_message = "identity_mode = symbol_principal and Monitoring or Security is enabled, but observability_principal is empty. Start a new setup in Symbol, or use identity_mode = key_upload."
    }

    precondition {
      condition     = var.destroy_mode || local.key_upload || var.finops_principal == "" || var.finops_principal != var.observability_principal
      error_message = "finops_principal and observability_principal must be two different service accounts (least privilege: one identity per purpose)."
    }

    precondition {
      condition     = var.destroy_mode || !local.key_upload || !local.needs_finops_identity || var.finops_certificate_url != ""
      error_message = "identity_mode = key_upload and FinOps is enabled, but finops_certificate_url is empty."
    }

    precondition {
      condition     = var.destroy_mode || !local.key_upload || !local.needs_observability_identity || var.observability_certificate_url != ""
      error_message = "identity_mode = key_upload and Monitoring or Security is enabled, but observability_certificate_url is empty."
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
# precondition already stops the run at plan time, and depends_on would defer the
# certificate downloads to apply time.
###############################################################################

module "identity" {
  source = "./modules/identity"
  count  = local.key_upload && (local.needs_finops_identity || local.needs_observability_identity) ? 1 : 0

  project_id           = var.project_id
  symbol_org_id        = var.symbol_org_id
  create_finops        = local.needs_finops_identity
  create_observability = local.needs_observability_identity
  certificates         = { for k, d in data.http.certificate : k => d.response_body }
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

check "billing_export" {
  assert {
    condition     = !var.enable_finops || var.billing_export_detected
    error_message = "The Cloud Billing detailed usage cost export was not found in ${var.project_id}.${var.billing_dataset}. Enable it in the Billing console (Billing > Billing export > BigQuery export > Detailed usage cost, dataset ${var.billing_dataset}), then run symbol-setup.sh again to create the FOCUS view. There is no API for this step."
  }
}
