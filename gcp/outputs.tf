# Contract v2 §5.7. The connection code carries identifiers only, never a secret.
# Disabled modules (and identities a module set does not need) are null.
# jsonencode() produces compact JSON with sorted keys.

locals {
  connection = {
    v               = 1
    org             = var.symbol_org_id
    session         = var.setup_session_id
    template        = var.template_version
    project         = var.project_id
    project_number  = tostring(data.google_project.this.number)
    organization_id = var.organization_id
    scope = {
      type = var.scope_type
      id   = local.scope_id
    }
    identity_mode = var.identity_mode
    modules       = local.enabled_modules

    principals = local.key_upload ? null : {
      finops        = local.needs_finops_identity ? var.finops_principal : null
      observability = local.needs_observability_identity ? var.observability_principal : null
    }

    key = local.key_upload ? {
      finops = local.needs_finops_identity ? {
        service_account = module.identity[0].finops_email
        key_id          = module.identity[0].finops_key_id
      } : null
      observability = local.needs_observability_identity ? {
        service_account = module.identity[0].observability_email
        key_id          = module.identity[0].observability_key_id
      } : null
    } : null

    finops = var.enable_finops ? {
      project_id              = var.project_id
      dataset                 = module.finops[0].dataset_id
      table                   = module.finops[0].table_id
      billing_account_id      = var.billing_account_id == "" ? null : var.billing_account_id
      billing_export_detected = var.billing_export_detected
      focus_view_created      = module.finops[0].focus_view_created
    } : null

    observability = local.needs_observability_identity ? {
      project_id          = var.project_id
      subscription_id     = var.enable_monitoring ? module.monitoring[0].subscription_id : null
      scc_subscription_id = var.enable_monitoring ? module.monitoring[0].scc_subscription_id : null
      audit_scope_type    = var.scope_type
      audit_scope_id      = local.scope_id
    } : null
  }

  # Unpadded base64url (RFC 4648 §5): '+' -> '-', '/' -> '_', drop the '=' padding.
  connection_b64url = replace(replace(replace(base64encode(jsonencode(local.connection)), "+", "-"), "/", "_"), "/=+$/", "")
  connection_code   = "SYMBOL-GCP-1.${local.connection_b64url}"
}

output "symbol_connection_code" {
  description = "Paste this code into Symbol (Administration > Cloud configuration > GCP). It contains identifiers only, no secret."
  value       = local.connection_code

  precondition {
    condition     = length(local.connection_code) <= 8192
    error_message = "The connection code exceeds 8192 characters (contract §4.5 decoder limit)."
  }
}

output "symbol_connection_summary" {
  description = "Human-readable summary of what this template configured."
  value       = <<-EOT
    Symbol Cloud Connect ${var.template_version}
    Project ${var.project_id} (number ${data.google_project.this.number})${var.organization_id == "" ? ", no organisation" : ", organisation ${var.organization_id}"}
    Scope: ${var.scope_type} ${local.scope_id}
    Modules: ${join(", ", local.enabled_modules)}
    Identity mode: ${var.identity_mode}
    %{~if local.needs_finops_identity}
    FinOps identity: ${coalesce(local.finops_email, "n/a")}${local.key_upload ? " (key ${module.identity[0].finops_key_id})" : ""}
    %{~endif}
    %{~if local.needs_observability_identity}
    Observability identity: ${coalesce(local.observability_email, "n/a")}${local.key_upload ? " (key ${module.identity[0].observability_key_id})" : ""}
    %{~endif}
    %{~if var.enable_finops}
    FinOps: dataset ${var.project_id}.${module.finops[0].dataset_id}, table ${module.finops[0].table_id}${module.finops[0].focus_view_created ? " (FOCUS view managed by this template)" : ""}, billing account ${var.billing_account_id == "" ? "unknown" : var.billing_account_id}.
    %{~if !var.billing_export_detected}
      WARNING: the detailed billing export was not found. Enable it, then run symbol-setup.sh again.
    %{~endif}
    %{~endif}
    %{~if var.enable_monitoring}
    Monitoring: sink symbol-audit-sink (${var.scope_type}) -> topic symbol-monitoring -> ${module.monitoring[0].subscription_id}${var.enable_scc ? ", SCC findings -> ${module.monitoring[0].scc_subscription_id}" : ""}.
    %{~endif}
    %{~if var.enable_security}
    Security: roles/viewer, roles/iam.securityReviewer, roles/cloudasset.viewer at ${var.scope_type} ${local.scope_id}.
    %{~endif}
    To revoke everything: symbol-setup.sh --destroy --org ${var.symbol_org_id} --project ${var.project_id}
  EOT
}
